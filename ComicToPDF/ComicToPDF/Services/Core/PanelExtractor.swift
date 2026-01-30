import Vision
import UIKit
import simd
import CoreImage // ✅ Needed for Grayscale Filter

struct PanelExtractor {
    
    // Global Context for performance (creation is expensive)
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    enum ExtractionMode: String, Codable, Equatable, Hashable {
        case automatic
        case conservative
        case aggressive
        case neural
        case grid
        
        var title: String {
            switch self {
            case .automatic: return "Automatic"
            case .conservative: return "Conservative"
            case .aggressive: return "Aggressive"
            case .neural: return "Neural Enhanced"
            case .grid: return "Grid (2x2)"
            }
        }
    }
    
    struct Panel: Codable, Equatable, Identifiable {
        let id = UUID()
        let boundingBox: CGRect // Normalized 0..1 (Vision Origin: Bottom-Left)
        
        // Helper to convert to SIMD vector (minX, minY, maxX, maxY)
        var vector: SIMD4<Float> {
            return SIMD4<Float>(
                Float(boundingBox.minX),
                Float(boundingBox.minY),
                Float(boundingBox.maxX),
                Float(boundingBox.maxY)
            )
        }
        
        enum CodingKeys: String, CodingKey {
            case boundingBox
        }
    }
    
    // MARK: - Core Logic
    
    // ✅ Helper: Create High-Contrast Grayscale Image for better Edge Detection
    private static func preprocessForDetection(_ image: UIImage) -> CGImage? {
        guard let inputCGImage = image.cgImage else { return nil }
        let ciImage = CIImage(cgImage: inputCGImage)
        
        // 1. Grayscale (Better for sensing intensity gradients)
        guard let grayscale = CIFilter(name: "CIPhotoEffectMono", parameters: [kCIInputImageKey: ciImage])?.outputImage else {
            return inputCGImage
        }
        
        // 2. High Contrast (Make panel borders "pop")
        // Increasing contrast helps defined edges stand out against gradients
        guard let contrast = CIFilter(name: "CIColorControls", parameters: [
            kCIInputImageKey: grayscale,
            kCIInputContrastKey: 1.3 // 30% Boost
        ])?.outputImage else {
            return inputCGImage
        }
        
        // Render
        return ciContext.createCGImage(contrast, from: contrast.extent)
    }
    
    static func detectPanels(in image: UIImage, mode: ExtractionMode = .automatic, mangaMode: Bool = false) async -> [Panel] {
        if mode == .grid {
            return generateGridPanels(rows: 2, cols: 2)
        }
        
        // ✅ STEP 1: Preprocess Image (High Contrast Grayscale)
        // This helps pinpoint panels by looking at gradient shifts, as requested.
        // We fallback to original if conversion fails.
        let processingStart = Date()
        let cgImage = preprocessForDetection(image) ?? image.cgImage
        guard let finalCGImage = cgImage else { return [] }
        
        // 1. Run Detection Requests (Rectangles + optional Saliency)
        return await withCheckedContinuation { continuation in
            var requests: [VNRequest] = []
            
            // A. Rectangle Request
            let rectRequest = VNDetectRectanglesRequest()
            // Configure Rect Request based on mode
            let settings = AdaptiveLearningManager.shared.getParameters()
            
            switch mode {
            case .aggressive:
                rectRequest.minimumConfidence = 0.1
                rectRequest.minimumSize = 0.1
            case .conservative:
                rectRequest.minimumConfidence = 0.85
                rectRequest.minimumSize = 0.15
            case .automatic, .neural:
                rectRequest.minimumConfidence = settings.minConfidence
                rectRequest.minimumSize = Float(settings.minSize)
            default:
                rectRequest.minimumConfidence = 0.6
                rectRequest.minimumSize = 0.1
            }
            rectRequest.minimumAspectRatio = 0.1
            rectRequest.maximumAspectRatio = 5.0
            rectRequest.quadratureTolerance = 30 // Fixed: Was incorrectly assigning Revision1
            
            requests.append(rectRequest)
            
            // B. Saliency Request (Neural) if automatic or neural
            var saliencyRequest: VNGenerateObjectnessBasedSaliencyImageRequest?
            var textRequest: VNRecognizeTextRequest? // ✅ NEW
            
            if mode == .automatic || mode == .neural {
                let sRequest = VNGenerateObjectnessBasedSaliencyImageRequest()
                sRequest.revision = VNGenerateObjectnessBasedSaliencyImageRequestRevision1
                requests.append(sRequest)
                saliencyRequest = sRequest
                
                // ✅ NEW: Text Request
                let tRequest = VNRecognizeTextRequest()
                tRequest.recognitionLevel = .fast // Fast is sufficient for bounding boxes
                tRequest.usesLanguageCorrection = false
                requests.append(tRequest)
                textRequest = tRequest
            }
            
            // Run Handler (Using the Grayscale Image 🧠)
            let handler = VNImageRequestHandler(cgImage: finalCGImage, options: [:])
            do {
                try handler.perform(requests)
                
                // 2. Process Results
                
                // Get Rectangles
                let rawRects = (rectRequest.results ?? [])
                    .filter { $0.confidence > rectRequest.minimumConfidence }
                    .map { $0.boundingBox }
                
                var finalPanels: [CGRect] = rawRects
                
                // Get Saliency & Fuse
                if let sResults = saliencyRequest?.results?.first as? VNSaliencyImageObservation,
                   (mode == .automatic || mode == .neural) {
                    
                    // Extract interesting objects from Saliency Heatmap
                    let salientObjects = sResults.salientObjects?.map { $0.boundingBox } ?? []
                    
                    // FUSION LOGIC:
                    // 1. Validate Rects: If a rect has NO overlap with any salient object, it might be noise (unless conservative).
                    // 2. Discovery: If a salient object is large enough and implies a panel missed by Rects, add it.
                    
                    var fused: [CGRect] = []
                    
                    // A. Validate Existing Rects
                    for rect in rawRects {
                        // Check overlap with any salient object
                        let hasSupport = salientObjects.contains { $0.intersects(rect) }
                        if hasSupport || mode != .neural { // In pure Neural mode, be stricter? No, safe fallback.
                            fused.append(rect)
                        }
                    }
                    
                    // B. Add Missing Saliency Regions
                    for salient in salientObjects {
                        // Ignore if it's already covered by a known rect
                        let isCovered = fused.contains { $0.intersection(salient).width * $0.intersection(salient).height > (salient.width * salient.height * 0.5) }
                        
                        if !isCovered {
                            // Ensure it's big enough to be a panel
                            if salient.width > 0.15 && salient.height > 0.15 {
                                fused.append(salient)
                            }
                        }
                    }
                    
                    finalPanels = fused
                }
                
                // ✅ NEW: Text Guard (Speech Bubble Awareness)
                // If text is detected near the edge of a panel, expand the panel to include it.
                if let textResults = textRequest?.results as? [VNRecognizedTextObservation], !textResults.isEmpty {
                    var guardedPanels: [CGRect] = []
                    
                    for var panel in finalPanels {
                        for textObs in textResults {
                            let textRect = textObs.boundingBox
                            
                            // Check if text is INSIDE or INTERSECTS or is VERY CLOSE to the panel
                            // Expansion logic: If text overlaps, union it.
                            // If text is within 2% margin, snap it in.
                            
                            let expandedPanel = panel.insetBy(dx: -0.02, dy: -0.02) // Look slightly outside
                            if expandedPanel.intersects(textRect) {
                                panel = panel.union(textRect)
                            }
                        }
                        guardedPanels.append(panel)
                    }
                    finalPanels = guardedPanels
                }
                
                // 3. Create Panels & Sort
                let panels = finalPanels.map { Panel(boundingBox: $0) }
                let sorted = clusterAndSortPanels(panels, mangaMode: mangaMode)
                continuation.resume(returning: sorted)
                
            } catch {
                print("Vision Request Failed: \(error)")
                continuation.resume(returning: [])
            }
        }
    }
    
    // ✅ NEW: Recursive Row Clustering Algorithm
    // This is much more stable than simple sorting because it handles staggered grids correctly.
    private static func clusterAndSortPanels(_ panels: [Panel], mangaMode: Bool) -> [Panel] {
        // 1. Start with everything sorted by Top edge (Highest Y first)
        var pool = panels.sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }
        var sortedRows: [[Panel]] = []
        
        while !pool.isEmpty {
            // Take the highest remaining panel as the "Anchor" for a new row
            let anchor = pool.removeFirst()
            var currentRow: [Panel] = [anchor]
            
            // 2. Find all other panels that overlap vertically with this anchor
            // Logic: Do they share at least 50% vertical overlap?
            var remainingPool: [Panel] = []
            
            // Pre-calculate anchor vector once
            let anchorVec = anchor.vector
            
            for candidate in pool {
                // Use SIMD accelerated overlap check
                if isSameRow(anchorVec, candidate.vector) {
                    currentRow.append(candidate)
                } else {
                    remainingPool.append(candidate)
                }
            }
            pool = remainingPool
            
            // 3. Sort this specific row horizontally
            if mangaMode {
                // Right-to-Left: Higher X comes first
                currentRow.sort { $0.boundingBox.minX > $1.boundingBox.minX }
            } else {
                // Left-to-Right: Lower X comes first
                currentRow.sort { $0.boundingBox.minX < $1.boundingBox.minX }
            }
            
            sortedRows.append(currentRow)
        }
        
        // Flatten the rows back into a single list
        return sortedRows.flatMap { $0 }
    }
    
    // Accelerated Row Check using SIMD
    // Vector Format: (minX, minY, maxX, maxY)
    // Indices: x=0, y=1, z=2, w=3
    private static func isSameRow(_ v1: SIMD4<Float>, _ v2: SIMD4<Float>) -> Bool {
        // Vision Coords: Y=0 is Bottom.
        // Y range is [y, w] (since y=minY, w=maxY)
        
        let yMin1 = v1.y
        let yMax1 = v1.w
        let yMin2 = v2.y
        let yMax2 = v2.w
        
        // Calculate Intersection of Y ranges
        let intersectionMin = max(yMin1, yMin2)
        let intersectionMax = min(yMax1, yMax2)
        let intersectionHeight = max(0, intersectionMax - intersectionMin)
        
        // Heights of original panels
        // Height = maxY - minY = w - y
        let h1 = yMax1 - yMin1
        let h2 = yMax2 - yMin2
        
        // If the intersection covers > 50% of the shorter panel's height, they are on the same row.
        let minHeight = min(h1, h2)
        return intersectionHeight > (minHeight * 0.5)
    }
    
    static func extractPanelRects(from image: UIImage, mode: ExtractionMode) async throws -> [CGRect] {
        let panels = await detectPanels(in: image, mode: mode)
        return panels.map { $0.boundingBox }
    }
    
    // MARK: - Helpers
    
    static func cropPanels(from image: UIImage, panels: [Panel]) async throws -> [UIImage] {
        guard let cgImage = image.cgImage else { return [image] }
        
        return panels.compactMap { panel in
            cropImage(image, to: panel.boundingBox)
        }
    }
    
    // ✅ Helper for Single Crop (Used by CBZ Export)
    static func cropImage(_ image: UIImage, to normalizedRect: CGRect) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        
        let cropRect = CGRect(
            x: normalizedRect.minX * width,
            y: (1.0 - normalizedRect.maxY) * height,
            width: normalizedRect.width * width,
            height: normalizedRect.height * height
        )
        
        guard let cropped = cgImage.cropping(to: cropRect) else { return nil }
        return UIImage(cgImage: cropped)
    }
    
    static func extractPanels(from image: UIImage, mode: ExtractionMode, mangaMode: Bool = false) async throws -> [UIImage] {
        let panels = await detectPanels(in: image, mode: mode, mangaMode: mangaMode)
        if panels.isEmpty { return [image] }
        return try await cropPanels(from: image, panels: panels)
    }
    
    private static func generateGridPanels(rows: Int, cols: Int) -> [Panel] {
        var panels: [Panel] = []
        let w = 1.0 / Double(cols)
        let h = 1.0 / Double(rows)
        for r in (0..<rows).reversed() {
            for c in 0..<cols {
                let rect = CGRect(x: Double(c) * w, y: Double(r) * h, width: w, height: h)
                panels.append(Panel(boundingBox: rect))
            }
        }
        return panels
    }
}
