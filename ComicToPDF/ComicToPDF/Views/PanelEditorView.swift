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
    // We no longer need imageSize state, it's calculated dynamically
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
                    Color.black.opacity(0.9).edgesIgnoringSafeArea(.all)
                    
                    if let image = pageImage {
                        // ✅ FIX: Calculate the exact frame of the image fits inside the view
                        let imgFrame = calculateImageFrame(image: image, inside: geo.size)
                        
                        // ✅ FIX: Create a container exactly the size of the image
                        ZStack(alignment: .topLeading) {
                            // 1. The Image
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(width: imgFrame.width, height: imgFrame.height)
                            
                            // 2. The Boxes (Now share the exact same coordinate space)
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
                        .position(x: geo.frame(in: .local).midX, y: geo.frame(in: .local).midY)
                        // ✅ FIX: Tap gesture is on the image container, ensuring correct coordinates
                        .onTapGesture(coordinateSpace: .local) { location in
                            if isMagicWandActive {
                                // Normalize point based on the container size
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
    
    // ✅ NEW HELPER: Calculates the actual rendered frame of the image "Aspect Fit"
    func calculateImageFrame(image: UIImage, inside containerSize: CGSize) -> CGRect {
        let imageAspect = image.size.width / image.size.height
        let containerAspect = containerSize.width / containerSize.height
        
        var targetWidth: CGFloat
        var targetHeight: CGFloat
        
        if imageAspect > containerAspect {
            // Image is wider than container (fit to width)
            targetWidth = containerSize.width
            targetHeight = containerSize.width / imageAspect
        } else {
            // Image is taller than container (fit to height)
            targetHeight = containerSize.height
            targetWidth = containerSize.height * imageAspect
        }
        
        // We don't need X/Y offsets because we center the ZStack container itself
        return CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight)
    }
    
    // ✅ UPDATED: Takes a pre-normalized point
    func detectPanelAt(normalizedPoint: CGPoint) {
        guard let image = pageImage else { return }
        
        // Check bounds
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
            
            // Vision coordinates are flipped (Y=0 is bottom)
            let visionPoint = CGPoint(x: normalizedPoint.x, y: 1.0 - normalizedPoint.y)
            
            let candidates = results.filter { observation in
                observation.boundingBox.contains(visionPoint)
            }
            
            // Pick smallest rect containing point
            let bestMatch = candidates.sorted {
                ($0.boundingBox.width * $0.boundingBox.height) < ($1.boundingBox.width * $1.boundingBox.height)
            }.first
            
            await MainActor.run {
                if let match = bestMatch {
                    // Convert back to SwiftUI coordinates (Flip Y again)
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
                    // Fallback: Place box centered on tap
                    let boxSize = 0.3
                    let fallbackRect = CGRect(
                        x: normalizedPoint.x - (boxSize/2),
                        y: normalizedPoint.y - (boxSize/2),
                        width: boxSize,
                        height: boxSize
                    )
                    // Ensure fallback is within bounds
                    var constrainedRect = fallbackRect
                    constrainedRect.origin.x = max(0.0, min(fallbackRect.origin.x, 1.0 - boxSize))
                    constrainedRect.origin.y = max(0.0, min(fallbackRect.origin.y, 1.0 - boxSize))
                    
                    self.panels.append(constrainedRect)
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
                            if initialRect == nil { initialRect = rect }
                            guard let startRect = initialRect else { return }
                            let dx = value.translation.width / containerSize.width
                            let dy = value.translation.height / containerSize.height
                            let newX = startRect.origin.x + dx
                            let newY = startRect.origin.y + dy
                            
                            // ✅ FIX: Clamp exactly to image edges (0.0 to 1.0)
                            rect.origin.x = min(max(newX, 0.0), 1.0 - rect.width)
                            rect.origin.y = min(max(newY, 0.0), 1.0 - rect.height)
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
