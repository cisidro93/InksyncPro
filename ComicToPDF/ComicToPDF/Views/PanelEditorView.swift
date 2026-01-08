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
    
    // Magic Wand State
    @State private var isMagicWandActive = false
    
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
                
                // Magic Wand Toggle
                Button(action: { isMagicWandActive.toggle(); selectedPanelIndex = nil }) {
                    Label("Magic Wand", systemImage: isMagicWandActive ? "wand.and.stars.inverse" : "wand.and.stars")
                        .bold()
                        .foregroundColor(isMagicWandActive ? .white : .blue)
                        .padding(6)
                        .background(isMagicWandActive ? Color.blue : Color.clear)
                        .cornerRadius(8)
                }
                .disabled(isLoading || isProcessing)
                
                // Manual Add Button
                Button(action: addNewPanel) {
                    Label("Add Box", systemImage: "plus.rectangle.on.rectangle")
                }
                .disabled(isLoading)
            }
            .padding()
            .background(Color(UIColor.secondarySystemBackground))
            
            // MARK: - Main Canvas
            GeometryReader { geo in
                ZStack {
                    // 1. Background Layer (Image) + Tap Detection
                    if let image = pageImage {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .position(x: geo.frame(in: .local).midX, y: geo.frame(in: .local).midY)
                            .background(GeometryReader { imageGeo in
                                Color.clear.onAppear { self.imageSize = imageGeo.size }
                                    .onChange(of: imageGeo.size) { newSize in self.imageSize = newSize }
                            })
                            // BACKGROUND TAP: Runs Magic Wand
                            .onTapGesture(coordinateSpace: .local) { location in
                                if isMagicWandActive {
                                    detectPanelAt(tapPoint: location, in: imageGeoSize(geo))
                                } else {
                                    selectedPanelIndex = nil
                                }
                            }
                        
                        // 2. Interaction Layer (Boxes)
                        if imageSize != .zero {
                            ForEach(0..<panels.count, id: \.self) { index in
                                DraggablePanelBox(
                                    rect: $panels[index],
                                    isSelected: selectedPanelIndex == index,
                                    containerSize: imageSize,
                                    index: index + 1
                                )
                                // BOX TAP: Selects the box (Even if Wand is active!)
                                .onTapGesture {
                                    selectedPanelIndex = index
                                }
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
                        VStack {
                            ProgressView()
                            Text("Scanning...").font(.caption).bold().foregroundColor(.white)
                        }
                        .padding()
                        .background(.ultraThinMaterial)
                        .cornerRadius(12)
                    }
                    
                    // Helper Text
                    if isMagicWandActive && !isProcessing {
                        VStack {
                            Spacer()
                            Text("Tap image to detect • Tap box to adjust")
                                .font(.headline)
                                .foregroundColor(.white)
                                .padding()
                                .background(Color.blue.opacity(0.8))
                                .cornerRadius(20)
                                .padding(.bottom, 50)
                        }
                        .allowsHitTesting(false)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.9))
                .clipped()
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
        .task { await loadPageSafe() }
        .onDisappear { conversionManager.cleanupMemory() }
    }
    
    // MARK: - Logic Helpers
    
    func imageGeoSize(_ geo: GeometryProxy) -> CGSize {
        guard let img = pageImage else { return .zero }
        let aspect = img.size.width / img.size.height
        let viewAspect = geo.size.width / geo.size.height
        
        var renderSize = CGSize.zero
        if aspect > viewAspect {
            renderSize.width = geo.size.width
            renderSize.height = geo.size.width / aspect
        } else {
            renderSize.height = geo.size.height
            renderSize.width = geo.size.height * aspect
        }
        return renderSize
    }
    
    func detectPanelAt(tapPoint: CGPoint, in renderSize: CGSize) {
        guard let image = pageImage, renderSize.width > 0 else { return }
        isProcessing = true
        
        // Convert Tap to Normalized Coordinates
        let normalizedX = tapPoint.x / imageSize.width
        let normalizedY = tapPoint.y / imageSize.height
        let normalizedPoint = CGPoint(x: normalizedX, y: normalizedY)
        
        guard normalizedX >= 0 && normalizedX <= 1 && normalizedY >= 0 && normalizedY <= 1 else {
            isProcessing = false
            return
        }
        
        Task(priority: .userInitiated) {
            // Resize for AI (Prevents Crash)
            let smallImage = resizeImageForAI(image: image, targetSize: 1000)
            let request = VNDetectRectanglesRequest()
            request.minimumConfidence = 0.6
            request.minimumAspectRatio = 0.1
            request.maximumAspectRatio = 3.0
            request.quadratureTolerance = 20
            request.minimumSize = 0.05
            
            let handler = VNImageRequestHandler(cgImage: smallImage.cgImage!, options: [:])
            try? handler.perform([request])
            
            guard let results = request.results else {
                await MainActor.run { isProcessing = false }
                return
            }
            
            // Vision coordinates are flipped (Y=0 is bottom)
            let visionPoint = CGPoint(x: normalizedPoint.x, y: 1.0 - normalizedPoint.y)
            
            let candidates = results.filter { observation in
                observation.boundingBox.contains(visionPoint)
            }
            
            // Pick smallest rect containing point (most specific panel)
            let bestMatch = candidates.sorted {
                ($0.boundingBox.width * $0.boundingBox.height) < ($1.boundingBox.width * $1.boundingBox.height)
            }.first
            
            await MainActor.run {
                if let match = bestMatch {
                    let finalRect = CGRect(
                        x: match.boundingBox.origin.x,
                        y: 1.0 - match.boundingBox.origin.y - match.boundingBox.height,
                        width: match.boundingBox.width,
                        height: match.boundingBox.height
                    )
                    
                    self.panels.append(finalRect)
                    self.selectedPanelIndex = self.panels.count - 1
                    
                    let generator = UIImpactFeedbackGenerator(style: .medium)
                    generator.impactOccurred()
                } else {
                    // Fallback: Default box if no clear panel found
                    let boxSize = 0.3
                    let fallbackRect = CGRect(
                        x: normalizedPoint.x - (boxSize/2),
                        y: normalizedPoint.y - (boxSize/2),
                        width: boxSize,
                        height: boxSize
                    )
                    self.panels.append(fallbackRect)
                    self.selectedPanelIndex = self.panels.count - 1
                }
                self.isProcessing = false
            }
        }
    }

    func loadPageSafe() async {
        conversionManager.cleanupMemory()
        do {
            if let image = try await conversionManager.extractFullPage(from: pdf, index: pageIndex) {
                self.pageImage = image
                loadExistingPanels()
                self.isLoading = false
            } else {
                 if pageIndex != 0 {
                     // Fallback to Page 1 if Page 4 doesn't exist
                    if let image = try await conversionManager.extractFullPage(from: pdf, index: 0) {
                        self.pageImage = image
                        loadExistingPanels()
                        self.isLoading = false
                    } else { loadError = "Could not load image."; isLoading = false }
                } else { loadError = "Page not found."; isLoading = false }
            }
        } catch { loadError = error.localizedDescription; isLoading = false }
    }
    
    func loadExistingPanels() {
        if let overrides = conversionManager.panelOverrides[pdf.id]?[pageIndex] {
            self.panels = overrides.map { $0.boundingBox }
        }
    }
    
    func resizeImageForAI(image: UIImage, targetSize: CGFloat) -> UIImage {
        let size = image.size
        let ratio = min(targetSize / size.width, targetSize / size.height)
        let newSize = CGSize(width: size.width * ratio, height: size.height * ratio)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: newSize, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
    }
    
    func addNewPanel() { panels.append(CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)); selectedPanelIndex = panels.count - 1 }
    func deleteSelectedPanel() { guard let index = selectedPanelIndex else { return }; panels.remove(at: index); selectedPanelIndex = nil }
    func clearAllPanels() { panels.removeAll(); selectedPanelIndex = nil }
    
    func saveAndClose() {
        let finalPanels = panels.map { PanelExtractor.Panel(boundingBox: $0) }
        Task { await conversionManager.savePanelOverrides(for: pdf.id, pageIndex: pageIndex, panels: finalPanels); dismiss() }
    }
}

// MARK: - Box Component (With Smooth Dragging)
struct DraggablePanelBox: View {
    @Binding var rect: CGRect
    let isSelected: Bool
    let containerSize: CGSize
    let index: Int
    @State private var initialRect: CGRect? = nil
    
    var screenRect: CGRect {
        CGRect(x: rect.origin.x * containerSize.width, y: rect.origin.y * containerSize.height, width: rect.width * containerSize.width, height: rect.height * containerSize.height)
    }
    
    var body: some View {
        ZStack(alignment: .topLeading) {
            // Box Border
            Rectangle().stroke(isSelected ? Color.yellow : Color.blue.opacity(0.8), lineWidth: isSelected ? 3 : 2)
                .background(Color.blue.opacity(0.05))
                .offset(x: screenRect.origin.x, y: screenRect.origin.y)
                .frame(width: screenRect.width, height: screenRect.height)
                .gesture(DragGesture()
                    .onChanged { value in
                        if isSelected {
                            // Smooth Drag Logic
                            if initialRect == nil { initialRect = rect }
                            guard let startRect = initialRect else { return }
                            let dx = value.translation.width / containerSize.width
                            let dy = value.translation.height / containerSize.height
                            let newX = startRect.origin.x + dx
                            let newY = startRect.origin.y + dy
                            
                            // Clamp to screen edges
                            rect.origin.x = min(max(newX, -0.1), 1.0 - rect.width + 0.1)
                            rect.origin.y = min(max(newY, -0.1), 1.0 - rect.height + 0.1)
                        }
                    }
                    .onEnded { _ in initialRect = nil }
                )
            
            // Resize Handle
            if isSelected {
                Image(systemName: "arrow.up.left.and.arrow.down.right.circle.fill")
                    .foregroundColor(.yellow).background(Circle().fill(.black)).font(.title2)
                    .offset(x: screenRect.maxX - 10, y: screenRect.maxY - 10)
                    .gesture(DragGesture()
                        .onChanged { value in
                            if initialRect == nil { initialRect = rect }
                            guard let startRect = initialRect else { return }
                            let dx = value.translation.width / containerSize.width
                            let dy = value.translation.height / containerSize.height
                            rect.size.width = max(0.05, startRect.width + dx)
                            rect.size.height = max(0.05, startRect.height + dy)
                        }
                        .onEnded { _ in initialRect = nil }
                    )
            }
            
            // Number Badge
            Text("\(index)").font(.caption2).bold().padding(6).background(Circle().fill(Color.blue)).foregroundColor(.white)
                .offset(x: screenRect.origin.x - 10, y: screenRect.origin.y - 10).shadow(radius: 2)
        }.frame(width: containerSize.width, height: containerSize.height)
    }
}
