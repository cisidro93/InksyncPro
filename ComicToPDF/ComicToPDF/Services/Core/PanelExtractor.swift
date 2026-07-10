import Vision
import UIKit
import simd
import CoreImage // ✅ Needed for Grayscale Filter

struct PanelExtractor {
    
    // Global Context for performance (creation is expensive)
    private static nonisolated(unsafe) let ciContext = CIContext(options: [.useSoftwareRenderer: false])

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
        
        let detector = EnsemblePanelDetector()
        let candidates: [PanelCandidate]
        
        // Determine Strategy
        // For now, Automatic/Neural/Aggressive trigger the full Ensemble.
        // Conservative triggers just the Vision base (Task 1) via the Ensemble but we could tune it.
        // For simplicity, we use Ensemble for all dynamic modes, as it's adaptive.
        
        if mode == .conservative {
            // Bypass Deep Scan for conservative
            let context = CIContext()
            candidates = await VisionPanelProvider().detectPanels(in: image, context: context)
        } else {
            // Full Ensemble
            candidates = await detector.detect(in: image)
        }
        
        // Convert to shared Panel model
        let panels = candidates.map { Panel(boundingBox: $0.boundingBox) }
        
        // Sort
        return clusterAndSortPanels(panels, mangaMode: mangaMode)
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
        guard image.cgImage != nil else { return [image] }
        
        return panels.compactMap { panel in
            cropImage(image, to: panel.boundingBox)
        }
    }
    
    // ✅ Helper for Single Crop (Used by CBZ Export)
    static func cropImage(_ image: UIImage, to normalizedRect: CGRect) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        
        guard !normalizedRect.minX.isNaN && !normalizedRect.minX.isInfinite &&
              !normalizedRect.minY.isNaN && !normalizedRect.minY.isInfinite &&
              !normalizedRect.width.isNaN && !normalizedRect.width.isInfinite &&
              !normalizedRect.height.isNaN && !normalizedRect.height.isInfinite &&
              normalizedRect.width > 0 && normalizedRect.height > 0 else {
            return nil
        }
        
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
