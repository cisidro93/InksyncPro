import SwiftUI
import Vision

struct PanelEditorView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @Environment(\.dismiss) var dismiss
    
    let pdf: ConvertedPDF
    let pageIndex: Int
    
    // Local State
    @State private var pageImage: UIImage?
    @State private var isLoading = true
    @State private var panels: [CGRect] = []
    @State private var selectedPanelIndex: Int?
    @State private var isProcessing = false
    @State private var imageSize: CGSize = .zero
    
    var body: some View {
        VStack {
            HStack {
                Text("Page \(pageIndex + 1)").font(.headline)
                Spacer()
                Button(action: runAutoDetection) { Label("Auto-Detect", systemImage: "sparkles") }
                    .disabled(isLoading || isProcessing)
                Button(action: addNewPanel) { Label("Add Box", systemImage: "plus.rectangle") }
                    .disabled(isLoading)
            }
            .padding()
            .background(Color(UIColor.secondarySystemBackground))
            
            GeometryReader { geo in
                ZStack {
                    if let image = pageImage {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .position(x: geo.frame(in: .local).midX, y: geo.frame(in: .local).midY)
                            .background(GeometryReader { imageGeo in
                                Color.clear.onAppear { self.imageSize = imageGeo.size }
                                    .onChange(of: imageGeo.size) { newSize in self.imageSize = newSize }
                            })
                        
                        if imageSize != .zero {
                            ForEach(0..<panels.count, id: \.self) { index in
                                DraggablePanelBox(
                                    rect: $panels[index],
                                    isSelected: selectedPanelIndex == index,
                                    containerSize: imageSize
                                )
                                .onTapGesture { selectedPanelIndex = index }
                            }
                        }
                    } else if isLoading {
                        ProgressView("Loading...")
                    }
                    
                    if isProcessing {
                        ProgressView().scaleEffect(2).padding().background(.ultraThinMaterial).cornerRadius(12)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.9))
                .clipped()
                .onTapGesture { selectedPanelIndex = nil }
            }
            
            HStack {
                Button(role: .destructive, action: deleteSelectedPanel) { Label("Delete Box", systemImage: "trash") }
                    .disabled(selectedPanelIndex == nil)
                Spacer()
                Button("Save Changes") { saveAndClose() }
                    .buttonStyle(.borderedProminent)
                    .disabled(isLoading)
            }
            .padding()
            .background(Color(UIColor.secondarySystemBackground))
        }
        .task {
            // Memory Cleanup before loading new heavy image
            conversionManager.cleanupMemory()
            
            do {
                // Load 1920px image (Good for eyes, okay for RAM)
                if let image = try await conversionManager.extractFullPage(from: pdf, index: pageIndex) {
                    self.pageImage = image
                    loadExistingPanels()
                    self.isLoading = false
                }
            } catch {
                print("Failed to load editor image: \(error)")
            }
        }
        .onDisappear {
            // Dump the image immediately when closing
            self.pageImage = nil
            conversionManager.cleanupMemory()
        }
    }
    
    func loadExistingPanels() {
        if let overrides = conversionManager.panelOverrides[pdf.id]?[pageIndex] {
            self.panels = overrides.map { $0.boundingBox }
        } else {
            runAutoDetection()
        }
    }
    
    func runAutoDetection() {
        guard let img = pageImage else { return }
        isProcessing = true
        
        Task(priority: .userInitiated) {
            // ✅ FIX: Create a tiny 800px copy for the AI to chew on
            // This prevents the "Vision Framework OOM" crash
            let smallImage = resizeImageForAI(image: img, targetSize: 800)
            
            if (try? await PanelExtractor.extractPanels(from: smallImage, mode: .automatic, mangaMode: false)) != nil {
                await MainActor.run {
                    if self.panels.isEmpty { self.panels = [CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)] }
                    self.isProcessing = false
                }
            }
        }
    }
    
    // Helper: Tiny Image Generator
    func resizeImageForAI(image: UIImage, targetSize: CGFloat) -> UIImage {
        let size = image.size
        let ratio = min(targetSize / size.width, targetSize / size.height)
        let newSize = CGSize(width: size.width * ratio, height: size.height * ratio)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1 // No retina needed for AI
        return UIGraphicsImageRenderer(size: newSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
    
    func addNewPanel() {
        panels.append(CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        selectedPanelIndex = panels.count - 1
    }
    
    func deleteSelectedPanel() {
        guard let index = selectedPanelIndex else { return }
        panels.remove(at: index)
        selectedPanelIndex = nil
    }
    
    func saveAndClose() {
        let finalPanels = panels.map { PanelExtractor.Panel(boundingBox: $0) }
        Task {
            await conversionManager.savePanelOverrides(for: pdf.id, pageIndex: pageIndex, panels: finalPanels)
            dismiss()
        }
    }
}

struct DraggablePanelBox: View {
    @Binding var rect: CGRect
    let isSelected: Bool
    let containerSize: CGSize
    var screenRect: CGRect {
        CGRect(x: rect.origin.x * containerSize.width, y: rect.origin.y * containerSize.height, width: rect.width * containerSize.width, height: rect.height * containerSize.height)
    }
    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().stroke(isSelected ? Color.yellow : Color.blue, lineWidth: isSelected ? 3 : 2)
                .background(Color.blue.opacity(0.1))
                .offset(x: screenRect.origin.x, y: screenRect.origin.y)
                .frame(width: screenRect.width, height: screenRect.height)
                .gesture(DragGesture().onChanged { value in
                    if isSelected {
                        rect.origin.x += value.translation.width / containerSize.width
                        rect.origin.y += value.translation.height / containerSize.height
                    }
                })
            if isSelected {
                Circle().fill(Color.yellow).frame(width: 20, height: 20)
                    .offset(x: screenRect.maxX - 10, y: screenRect.maxY - 10)
                    .gesture(DragGesture().onChanged { value in
                        rect.size.width += value.translation.width / containerSize.width
                        rect.size.height += value.translation.height / containerSize.height
                    })
            }
            Text("#").font(.caption2).bold().padding(4).background(Color.blue).foregroundColor(.white)
                .offset(x: screenRect.origin.x, y: screenRect.origin.y - 20)
        }.frame(width: containerSize.width, height: containerSize.height)
    }
}
