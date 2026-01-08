import SwiftUI
import Vision

struct PanelEditorView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @Environment(\.dismiss) var dismiss
    
    let pdf: ConvertedPDF
    let pageIndex: Int
    let pageImage: UIImage
    
    // The boxes (Normalized 0.0 to 1.0)
    @State private var panels: [CGRect] = []
    @State private var selectedPanelIndex: Int?
    @State private var isProcessing = false
    
    // Canvas sizing for coordinate conversion
    @State private var imageSize: CGSize = .zero
    
    var body: some View {
        VStack {
            // MARK: - Toolbar
            HStack {
                Text("Page \(pageIndex + 1)")
                    .font(.headline)
                Spacer()
                
                Button(action: runAutoDetection) {
                    Label("Auto-Detect", systemImage: "sparkles")
                }
                .disabled(isProcessing)
                
                Button(action: addNewPanel) {
                    Label("Add Box", systemImage: "plus.rectangle")
                }
            }
            .padding()
            .background(Color(UIColor.secondarySystemBackground))
            
            // MARK: - Editor Canvas
            GeometryReader { geo in
                ZStack {
                    // 1. Background Image
                    Image(uiImage: pageImage)
                        .resizable()
                        .scaledToFit()
                        .position(x: geo.frame(in: .local).midX, y: geo.frame(in: .local).midY)
                        .background(GeometryReader { imageGeo in
                            Color.clear.onAppear {
                                self.imageSize = imageGeo.size
                            }
                            .onChange(of: imageGeo.size) { newSize in
                                self.imageSize = newSize
                            }
                        })
                    
                    // 2. Panel Overlays
                    if imageSize != .zero {
                        ForEach(0..<panels.count, id: \.self) { index in
                            DraggablePanelBox(
                                rect: $panels[index],
                                isSelected: selectedPanelIndex == index,
                                containerSize: imageSize
                            )
                            .onTapGesture {
                                selectedPanelIndex = index
                            }
                        }
                    }
                    
                    if isProcessing {
                        ProgressView()
                            .scaleEffect(2)
                            .padding()
                            .background(.ultraThinMaterial)
                            .cornerRadius(12)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.9))
                .clipped()
                .onTapGesture {
                    selectedPanelIndex = nil
                }
            }
            
            // MARK: - Bottom Bar
            HStack {
                Button(role: .destructive, action: deleteSelectedPanel) {
                    Label("Delete Box", systemImage: "trash")
                }
                .disabled(selectedPanelIndex == nil)
                
                Spacer()
                
                Button("Save Changes") {
                    saveAndClose()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .background(Color(UIColor.secondarySystemBackground))
        }
        .onAppear {
            loadExistingPanels()
        }
    }
    
    // MARK: - Logic
    
    func loadExistingPanels() {
        if let overrides = conversionManager.panelOverrides[pdf.id]?[pageIndex] {
            self.panels = overrides.map { $0.boundingBox }
        } else {
            runAutoDetection()
        }
    }
    
    func runAutoDetection() {
        isProcessing = true
        Task {
            // Trigger AI detection (ignoring return value, relying on side effect or manual fallback for now)
            if (try? await PanelExtractor.extractPanels(from: pageImage, mode: .automatic, mangaMode: false)) != nil {
                await MainActor.run {
                    if self.panels.isEmpty {
                        // Default fallback if AI returns images but we need rects
                        self.panels = [CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)]
                    }
                    self.isProcessing = false
                }
            }
        }
    }
    
    func addNewPanel() {
        let newPanel = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        panels.append(newPanel)
        selectedPanelIndex = panels.count - 1
    }
    
    func deleteSelectedPanel() {
        guard let index = selectedPanelIndex else { return }
        panels.remove(at: index)
        selectedPanelIndex = nil
    }
    
    func saveAndClose() {
        // ✅ FIX: Removed 'id' from initializer to match struct definition
        let finalPanels = panels.map { PanelExtractor.Panel(boundingBox: $0) }
        
        Task {
            await conversionManager.savePanelOverrides(for: pdf.id, pageIndex: pageIndex, panels: finalPanels)
            dismiss()
        }
    }
}

// MARK: - Draggable Box Component
struct DraggablePanelBox: View {
    @Binding var rect: CGRect
    let isSelected: Bool
    let containerSize: CGSize
    
    var screenRect: CGRect {
        CGRect(
            x: rect.origin.x * containerSize.width,
            y: rect.origin.y * containerSize.height,
            width: rect.width * containerSize.width,
            height: rect.height * containerSize.height
        )
    }
    
    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .stroke(isSelected ? Color.yellow : Color.blue, lineWidth: isSelected ? 3 : 2)
                .background(Color.blue.opacity(0.1))
                .offset(x: screenRect.origin.x, y: screenRect.origin.y)
                .frame(width: screenRect.width, height: screenRect.height)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            if isSelected {
                                let dx = value.translation.width / containerSize.width
                                let dy = value.translation.height / containerSize.height
                                rect.origin.x += dx
                                rect.origin.y += dy
                            }
                        }
                )
            
            if isSelected {
                Circle()
                    .fill(Color.yellow)
                    .frame(width: 20, height: 20)
                    .offset(x: screenRect.maxX - 10, y: screenRect.maxY - 10)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                let dx = value.translation.width / containerSize.width
                                let dy = value.translation.height / containerSize.height
                                rect.size.width += dx
                                rect.size.height += dy
                            }
                    )
            }
            
            Text("#")
                .font(.caption2)
                .bold()
                .padding(4)
                .background(Color.blue)
                .foregroundColor(.white)
                .offset(x: screenRect.origin.x, y: screenRect.origin.y - 20)
        }
        .frame(width: containerSize.width, height: containerSize.height)
    }
}
