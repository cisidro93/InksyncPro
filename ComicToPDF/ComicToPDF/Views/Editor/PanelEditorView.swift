import SwiftUI
import Vision

struct PanelEditorView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @Environment(\.dismiss) var dismiss
    
    let pdf: ConvertedPDF
    let pageIndex: Int
    
    // ✅ NEW: Optional input image
    var initialImage: UIImage? = nil
    
    // Local State
    @State private var pageImage: UIImage?
    @State private var isLoading = true
    @State private var panels: [CGRect] = []
    @State private var selectedPanelIndex: Int?
    @State private var isProcessing = false
    @State private var loadError: String?
    
    // UI State
    @State private var isMagicWandActive = false
    
    var body: some View {
        VStack(spacing: 0) {
            // MARK: - Top Toolbar
            HStack(spacing: 8) {
                Text("Page \(pageIndex + 1)")
                    .font(.headline)
                    .layoutPriority(1)
                
                Spacer()
                
                // Clear All
                Button(action: clearAllPanels) {
                    Image(systemName: "trash.slash")
                        .foregroundColor(.red)
                        .padding(8)
                        .background(Color.red.opacity(0.1))
                        .clipShape(Circle())
                }
                .disabled(panels.isEmpty)
                
                // Magic Wand Toggle
                Button(action: { isMagicWandActive.toggle(); selectedPanelIndex = nil }) {
                    HStack(spacing: 4) {
                        Image(systemName: isMagicWandActive ? "wand.and.stars.inverse" : "wand.and.stars")
                        Text("Magic Wand")
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .bold()
                    .foregroundColor(isMagicWandActive ? .white : .blue)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(isMagicWandActive ? Color.blue : Color.clear)
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.blue, lineWidth: 1)
                    )
                }
                .disabled(isLoading || isProcessing)
                
                // Add Manual Box
                Button(action: addNewPanel) {
                    Image(systemName: "plus.rectangle.on.rectangle")
                        .padding(8)
                        .background(Color.blue.opacity(0.1))
                        .clipShape(Circle())
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
                        let imgFrame = calculateImageFrame(image: image, inside: geo.size)
                        
                        // Image Container
                        ZStack(alignment: .topLeading) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(width: imgFrame.width, height: imgFrame.height)
                            
                            // Boxes
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
                        // Coordinate Space for Dragging
                        .coordinateSpace(name: "ImageCanvas")
                        .contentShape(Rectangle())
                        .onTapGesture(coordinateSpace: .local) { location in
                            if isMagicWandActive {
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
                        VStack(spacing: 15) {
                            ProgressView()
                                .scaleEffect(1.5)
                            Text("Opening Editor...")
                                .font(.headline)
                                .foregroundColor(.white)
                        }
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
                }
            }
            
            // MARK: - Bottom Toolbar
            HStack {
                Button(role: .destructive, action: deleteSelectedPanel) {
                    Image(systemName: "trash")
                        .foregroundColor(selectedPanelIndex == nil ? .gray : .red)
                        .padding(10)
                }
                .disabled(selectedPanelIndex == nil)
                
                Spacer()
                
                if isMagicWandActive {
                    Text("Tap image to detect")
                        .font(.caption)
                        .bold()
                        .foregroundColor(.blue)
                        .padding(.horizontal)
                        .transition(.opacity)
                } else if let idx = selectedPanelIndex {
                    Text("Panel #\(idx + 1) Selected")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Button(action: saveAndClose) {
                    Text("Save")
                        .bold()
                        .frame(width: 80)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isLoading)
            }
            .padding()
            .background(Color(UIColor.secondarySystemBackground))
        }
        .task {
            // ✅ THE FIX: Check for passed image first
            if let passedImage = initialImage {
                print("⚡️ Using passed image. Skipping unzip.")
                self.pageImage = passedImage
                self.isLoading = false
                // Just load the panels, don't re-load the image
                loadExistingPanels()
            } else {
                // Fallback for ConvertView (Old Way)
                conversionManager.cleanupMemory()
                try? await Task.sleep(nanoseconds: 500_000_000)
                await loadPageSafe()
            }
        }
        .onDisappear {
            // Only end session if we didn't pass an image (implies we managed it internally)
            // Or always end session? If we passed an image, we didn't start a session in ConversionManager
            // so calling endSession() (which clears temp files) might be too aggressive if we are just closing the editor
            // but keeping the PageManagerView session open.
            // PageManagerView handles its own cleanup via viewModel.cleanup().
            // conversionManager.endSession() typically clears the "surgical extraction" temp folder.
            // If we are in "Passed Image" mode, we didn't use surgical extraction.
            // But let's leave it safe: only if we loaded via safe load?
            // Actually, conversionManager.endSession() clears 'activeExtractionTask'.
            // It's probably safe to call it either way.
            conversionManager.cleanupMemory()
            conversionManager.endSession()
        }
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

// MARK: - Box Component
struct DraggablePanelBox: View {
    @Binding var rect: CGRect
    let isSelected: Bool
    let containerSize: CGSize
    let index: Int
    @State private var initialRect: CGRect? = nil
    
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
            Rectangle().stroke(isSelected ? Color.yellow : Color.blue.opacity(0.8), lineWidth: isSelected ? 3 : 2)
                .background(Color.blue.opacity(0.05))
                .frame(width: pixelSize.width, height: pixelSize.height)
                .gesture(DragGesture(coordinateSpace: .named("ImageCanvas"))
                    .onChanged { value in
                        if isSelected {
                            if initialRect == nil { initialRect = rect }
                            guard let startRect = initialRect else { return }
                            let dx = value.translation.width / containerSize.width
                            let dy = value.translation.height / containerSize.height
                            let newX = startRect.origin.x + dx
                            let newY = startRect.origin.y + dy
                            rect.origin.x = min(max(newX, 0.0), 1.0 - rect.width)
                            rect.origin.y = min(max(newY, 0.0), 1.0 - rect.height)
                        }
                    }
                    .onEnded { _ in initialRect = nil }
                )
            
            if isSelected {
                Image(systemName: "arrow.up.left.and.arrow.down.right.circle.fill")
                    .foregroundColor(.yellow).background(Circle().fill(.black)).font(.title2)
                    .position(x: pixelSize.width, y: pixelSize.height)
                    .gesture(DragGesture(coordinateSpace: .named("ImageCanvas"))
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
            
            Text("\(index)").font(.caption2).bold().padding(6).background(Circle().fill(Color.blue)).foregroundColor(.white)
                .position(x: 0, y: 0).shadow(radius: 2)
        }
        .frame(width: pixelSize.width, height: pixelSize.height)
        .position(centerPosition)
    }
}
