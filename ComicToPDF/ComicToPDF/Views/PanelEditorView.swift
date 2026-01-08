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
    @State private var loadError: String?
    
    var body: some View {
        VStack(spacing: 0) {
            // MARK: - Top Toolbar
            HStack {
                Text("Page \(pageIndex + 1)")
                    .font(.headline)
                
                Spacer()
                
                // Clear All Button
                Button(action: clearAllPanels) {
                    Label("Clear", systemImage: "trash.slash")
                        .foregroundColor(.red)
                }
                .disabled(panels.isEmpty)
                
                // Reset/Auto Button
                Button(action: runAutoDetection) {
                    Label("Reset AI", systemImage: "arrow.counterclockwise")
                }
                .disabled(isLoading || isProcessing)
                
                // Add Manual Box Button
                Button(action: addNewPanel) {
                    Label("Add Box", systemImage: "plus.rectangle.on.rectangle")
                        .bold()
                }
                .disabled(isLoading)
            }
            .padding()
            .background(Color(UIColor.secondarySystemBackground))
            
            // MARK: - Main Canvas
            GeometryReader { geo in
                ZStack {
                    // Background Layer (Image)
                    if let image = pageImage {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .position(x: geo.frame(in: .local).midX, y: geo.frame(in: .local).midY)
                            .background(GeometryReader { imageGeo in
                                Color.clear.onAppear { self.imageSize = imageGeo.size }
                                    .onChange(of: imageGeo.size) { newSize in self.imageSize = newSize }
                            })
                        
                        // Interaction Layer (Boxes)
                        if imageSize != .zero {
                            ForEach(0..<panels.count, id: \.self) { index in
                                DraggablePanelBox(
                                    rect: $panels[index],
                                    isSelected: selectedPanelIndex == index,
                                    containerSize: imageSize,
                                    index: index + 1
                                )
                                .onTapGesture { selectedPanelIndex = index }
                            }
                        }
                    } else if let error = loadError {
                        VStack {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.largeTitle).foregroundColor(.orange)
                            Text(error).font(.caption).foregroundColor(.secondary)
                        }
                    } else {
                        ProgressView("Loading High-Res Page...")
                    }
                    
                    // Loading Overlay
                    if isProcessing {
                        ProgressView("Detecting Panels...")
                            .padding()
                            .background(.ultraThinMaterial)
                            .cornerRadius(12)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.9))
                .clipped()
                .contentShape(Rectangle())
                .onTapGesture { selectedPanelIndex = nil } // Deselect on background tap
            }
            
            // MARK: - Bottom Toolbar
            HStack {
                Button(role: .destructive, action: deleteSelectedPanel) {
                    Label("Delete Selected", systemImage: "trash")
                }
                .disabled(selectedPanelIndex == nil)
                
                Spacer()
                
                Button(action: saveAndClose) {
                    Text("Save & Close")
                        .bold()
                        .frame(width: 120)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isLoading)
            }
            .padding()
            .background(Color(UIColor.secondarySystemBackground))
        }
        .task {
            await loadPageSafe()
        }
        .onDisappear {
            conversionManager.cleanupMemory()
        }
    }
    
    // MARK: - Logic
    
    func loadPageSafe() async {
        conversionManager.cleanupMemory()
        do {
            // Try requested page
            if let image = try await conversionManager.extractFullPage(from: pdf, index: pageIndex) {
                self.pageImage = image
                loadExistingPanels()
                self.isLoading = false
            } else {
                // Fallback: If Page 4 doesn't exist, try Page 1 (index 0)
                if pageIndex != 0 {
                    if let image = try await conversionManager.extractFullPage(from: pdf, index: 0) {
                        self.pageImage = image
                        loadExistingPanels()
                        self.isLoading = false
                    } else {
                        loadError = "Could not load image."
                        isLoading = false
                    }
                } else {
                    loadError = "Page not found."
                    isLoading = false
                }
            }
        } catch {
            loadError = error.localizedDescription
            isLoading = false
        }
    }
    
    func loadExistingPanels() {
        if let overrides = conversionManager.panelOverrides[pdf.id]?[pageIndex] {
            // Load saved Manual Edits
            self.panels = overrides.map { $0.boundingBox }
        } else {
            // Or run Auto-Detect
            runAutoDetection()
        }
    }
    
    func runAutoDetection() {
        guard let img = pageImage else { return }
        isProcessing = true
        
        Task(priority: .userInitiated) {
            // Resize for AI (Safety Fix)
            let smallImage = resizeImageForAI(image: img, targetSize: 800)
            
            if (try? await PanelExtractor.extractPanels(from: smallImage, mode: .automatic, mangaMode: false)) != nil {
                await MainActor.run {
                    // If AI returns nothing, we default to 1 big box so the user isn't confused
                    if self.panels.isEmpty {
                        self.panels = [CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9)]
                    }
                    self.isProcessing = false
                }
            } else {
                await MainActor.run { self.isProcessing = false }
            }
        }
    }
    
    func resizeImageForAI(image: UIImage, targetSize: CGFloat) -> UIImage {
        let size = image.size
        let ratio = min(targetSize / size.width, targetSize / size.height)
        let newSize = CGSize(width: size.width * ratio, height: size.height * ratio)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: newSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
    
    func addNewPanel() {
        // Add a box in the center
        panels.append(CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        selectedPanelIndex = panels.count - 1
    }
    
    func deleteSelectedPanel() {
        guard let index = selectedPanelIndex else { return }
        panels.remove(at: index)
        selectedPanelIndex = nil
    }
    
    func clearAllPanels() {
        panels.removeAll()
        selectedPanelIndex = nil
    }
    
    func saveAndClose() {
        // This is the CRITICAL step. We save your boxes to the Manager.
        // The Converter checks this specific dictionary before running ANY AI.
        let finalPanels = panels.map { PanelExtractor.Panel(boundingBox: $0) }
        Task {
            await conversionManager.savePanelOverrides(for: pdf.id, pageIndex: pageIndex, panels: finalPanels)
            dismiss()
        }
    }
}

// MARK: - Improved Box Component
struct DraggablePanelBox: View {
    @Binding var rect: CGRect
    let isSelected: Bool
    let containerSize: CGSize
    let index: Int
    
    // State to track drag start position for smoother movement
    @State private var initialRect: CGRect? = nil
    
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
            // Box Border
            Rectangle()
                .stroke(isSelected ? Color.yellow : Color.blue.opacity(0.8), lineWidth: isSelected ? 3 : 2)
                .background(Color.blue.opacity(0.05)) // Faint tint to show active area
                .offset(x: screenRect.origin.x, y: screenRect.origin.y)
                .frame(width: screenRect.width, height: screenRect.height)
                // ✅ FIXED: Smooth Move Gesture
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            if isSelected {
                                if initialRect == nil { initialRect = rect }
                                guard let startRect = initialRect else { return }
                                
                                let dx = value.translation.width / containerSize.width
                                let dy = value.translation.height / containerSize.height
                                
                                let newX = startRect.origin.x + dx
                                let newY = startRect.origin.y + dy
                                
                                // Clamp to keep roughly on screen (allow slight overhang for edge adjustments)
                                rect.origin.x = min(max(newX, -0.1), 1.0 - rect.width + 0.1)
                                rect.origin.y = min(max(newY, -0.1), 1.0 - rect.height + 0.1)
                            }
                        }
                        .onEnded { _ in initialRect = nil }
                )
            
            // Resize Handle
            if isSelected {
                Image(systemName: "arrow.up.left.and.arrow.down.right.circle.fill")
                    .foregroundColor(.yellow)
                    .background(Circle().fill(.black))
                    .font(.title2)
                    .offset(x: screenRect.maxX - 10, y: screenRect.maxY - 10)
                    // ✅ FIXED: Smooth Resize Gesture
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                if initialRect == nil { initialRect = rect }
                                guard let startRect = initialRect else { return }
                                
                                let dx = value.translation.width / containerSize.width
                                let dy = value.translation.height / containerSize.height
                                
                                // Clamp minimum size so it doesn't invert
                                rect.size.width = max(0.05, startRect.width + dx)
                                rect.size.height = max(0.05, startRect.height + dy)
                            }
                            .onEnded { _ in initialRect = nil }
                    )
            }
            
            // Number Badge
            Text("\(index)")
                .font(.caption2)
                .bold()
                .padding(6)
                .background(Circle().fill(Color.blue))
                .foregroundColor(.white)
                .offset(x: screenRect.origin.x - 10, y: screenRect.origin.y - 10)
                .shadow(radius: 2)
        }
        .frame(width: containerSize.width, height: containerSize.height)
    }
}
