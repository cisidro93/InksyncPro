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
                
                Button(action: clearAllPanels) {
                    Label("Clear", systemImage: "trash.slash")
                        .foregroundColor(.red)
                }
                .disabled(panels.isEmpty)
                
                Button(action: { isMagicWandActive.toggle(); selectedPanelIndex = nil }) {
                    Label("Magic Wand", systemImage: isMagicWandActive ? "wand.and.stars.inverse" : "wand.and.stars")
                        .bold()
                        .foregroundColor(isMagicWandActive ? .white : .blue)
                        .padding(6)
                        .background(isMagicWandActive ? Color.blue : Color.clear)
                        .cornerRadius(8)
                }
                .disabled(isLoading || isProcessing)
                
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
                    Color.black.opacity(0.9).edgesIgnoringSafeArea(.all)
                    
                    if let image = pageImage {
                        // 1. Calculate the exact frame where the image sits inside the view
                        let imgFrame = calculateImageFrame(image: image, inside: geo.size)
                        
                        // 2. The Container ZStack (Exactly matches Image Size)
                        ZStack(alignment: .topLeading) {
                            
                            // The Image
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(width: imgFrame.width, height: imgFrame.height)
                            
                            // The Boxes
                            ForEach(0..<panels.count, id: \.self) { index in
                                DraggablePanelBox(
                                    rect: $panels[index],
                                    isSelected: selectedPanelIndex == index,
                                    containerSize: imgFrame.size,
                                    index: index + 1
                                )
                                .onTapGesture {
                                    selectedPanelIndex = index
                                }
                            }
                        }
                        .frame(width: imgFrame.width, height: imgFrame.height)
                        .position(x: geo.frame(in: .local).midX, y: geo.frame(in: .local).midY) // Center the Container
                        .contentShape(Rectangle()) // Ensure entire area is tappable
                        .onTapGesture(coordinateSpace: .local) { location in
                            if isMagicWandActive {
                                // Calculate tap relative to the image frame
                                let normalizedPoint = CGPoint(x: location.x / imgFrame.width, y: location.y / imgFrame.height)
                                detectPanelAt(normalizedPoint: normalizedPoint)
                            } else {
                                selectedPanelIndex = nil
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
                    
                    if isProcessing {
                        VStack {
                            ProgressView()
                            Text("Scanning...").font(.caption).bold().foregroundColor(.white)
                        }
                        .padding()
                        .background(.ultraThinMaterial)
                        .cornerRadius(12)
                    }
                    
                    if isMagicWandActive && !isProcessing && pageImage != nil {
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
    
    func calculateImageFrame(image: UIImage, inside containerSize: CGSize) -> CGRect {
        let imageAspect = image.size.width / image.size.height
        let containerAspect = containerSize.width / containerSize.height
        
        var targetWidth: CGFloat
        var targetHeight: CGFloat
        
        if imageAspect > containerAspect {
            targetWidth = containerSize.width
            targetHeight = containerSize.width / imageAspect
        } else {
            targetHeight = containerSize.height
            targetWidth = containerSize.height * imageAspect
        }
        
        return CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight)
    }
    
    func detectPanelAt(normalizedPoint: CGPoint) {
        guard let image = pageImage else { return }
        
        // Safety Bounds Check
        guard normalizedPoint.x >= 0 && normalizedPoint.x <= 1 &&
              normalizedPoint.y >= 0 && normalizedPoint.y <= 1 else { return }
        
        isProcessing = true
        
        Task(priority: .userInitiated) {
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
            
            let visionPoint = CGPoint(x: normalizedPoint.x, y: 1.0 - normalizedPoint.y)
            let candidates = results.filter { $0.boundingBox.contains(visionPoint) }
            
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
                    let boxSize = 0.3
                    let fallbackRect = CGRect(
                        x: normalizedPoint.x - (boxSize/2),
                        y: normalizedPoint.y - (boxSize/2),
                        width: boxSize,
                        height: boxSize
                    )
                    // Clamp fallback
                    var constrained = fallbackRect
                    constrained.origin.x = max(0.0, min(fallbackRect.origin.x, 1.0 - boxSize))
                    constrained.origin.y = max(0.0, min(fallbackRect.origin.y, 1.0 - boxSize))
                    
                    self.panels.append(constrained)
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

// MARK: - Box Component (Fixed Coordinates)
struct DraggablePanelBox: View {
    @Binding var rect: CGRect
    let isSelected: Bool
    let containerSize: CGSize
    let index: Int
    @State private var initialRect: CGRect? = nil
    
    // ✅ FIX: Using .position requires center coordinates, not top-left
    var centerPosition: CGPoint {
        let centerX = (rect.origin.x + rect.width / 2) * containerSize.width
        let centerY = (rect.origin.y + rect.height / 2) * containerSize.height
        return CGPoint(x: centerX, y: centerY)
    }
    
    var pixelSize: CGSize {
        CGSize(width: rect.width * containerSize.width, height: rect.height * containerSize.height)
    }
    
    var body: some View {
        ZStack(alignment: .topLeading) {
            // Box Border
            Rectangle().stroke(isSelected ? Color.yellow : Color.blue.opacity(0.8), lineWidth: isSelected ? 3 : 2)
                .background(Color.blue.opacity(0.05))
                .frame(width: pixelSize.width, height: pixelSize.height)
                .gesture(DragGesture()
                    .onChanged { value in
                        if isSelected {
                            if initialRect == nil { initialRect = rect }
                            guard let startRect = initialRect else { return }
                            let dx = value.translation.width / containerSize.width
                            let dy = value.translation.height / containerSize.height
                            let newX = startRect.origin.x + dx
                            let newY = startRect.origin.y + dy
                            
                            // Clamp exactly to 0.0 - 1.0 (Stay inside image)
                            rect.origin.x = min(max(newX, 0.0), 1.0 - rect.width)
                            rect.origin.y = min(max(newY, 0.0), 1.0 - rect.height)
                        }
                    }
                    .onEnded { _ in initialRect = nil }
                )
            
            // Resize Handle (Bottom Right)
            if isSelected {
                Image(systemName: "arrow.up.left.and.arrow.down.right.circle.fill")
                    .foregroundColor(.yellow).background(Circle().fill(.black)).font(.title2)
                    .position(x: pixelSize.width, y: pixelSize.height) // Stick to bottom-right corner
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
            
            // Number Badge (Top Left)
            Text("\(index)").font(.caption2).bold().padding(6).background(Circle().fill(Color.blue)).foregroundColor(.white)
                .position(x: 0, y: 0)
                .shadow(radius: 2)
        }
        .frame(width: pixelSize.width, height: pixelSize.height)
        .position(centerPosition) // ✅ FIX: Absolute positioning from Top-Left (0,0) via ZStack alignment
    }
}
