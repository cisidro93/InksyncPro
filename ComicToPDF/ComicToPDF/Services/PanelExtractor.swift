import Vision
import UIKit

struct PanelExtractor {
    
    enum ExtractionMode: Codable, Equatable, Hashable {
        case automatic
        case conservative
        case aggressive
        case grid(rows: Int, columns: Int)
        
        static let grid2x2 = ExtractionMode.grid(rows: 2, columns: 2)
        
        var title: String {
            switch self {
            case .automatic: return "Automatic"
            case .conservative: return "Conservative"
            case .aggressive: return "Aggressive"
            case .grid: return "Grid"
            }
        }
    }
    
    struct Panel: Identifiable {
        let id = UUID()
        let boundingBox: CGRect
    }
    
    // MARK: - Core Logic
    
    // 1. Detect where the panels are
    static func detectPanels(in image: UIImage, mode: ExtractionMode = .automatic) async -> [Panel] {
        guard let cgImage = image.cgImage else { return [] }
        
        // Handle Grid Mode manually (math, not vision)
        if case .grid(let rows, let cols) = mode {
            return generateGridPanels(rows: rows, cols: cols)
        }
        
        return await withCheckedContinuation { continuation in
            let request = VNDetectRectanglesRequest { request, error in
                guard let results = request.results as? [VNRectangleObservation] else {
                    continuation.resume(returning: [])
                    return
                }
                
                // Set Sensitivity based on mode
                let confidenceThreshold: Float = (mode == .aggressive) ? 0.3 : 0.85
                
                let panels = results
                    .filter { $0.confidence > confidenceThreshold }
                    .map { Panel(boundingBox: $0.boundingBox) }
                
                // IMPORTANT: Vision returns Y-axis flipped (0 is bottom).
                // We must sort them Top-to-Bottom, then Left-to-Right for reading order.
                let sortedPanels = panels.sorted { (p1, p2) -> Bool in
                    // In Vision, Higher Y is Top.
                    // If Y is significantly different (> 20% height), sort vertical
                    if abs(p1.boundingBox.midY - p2.boundingBox.midY) > 0.2 {
                        return p1.boundingBox.midY > p2.boundingBox.midY // Top first
                    }
                    // Otherwise sort horizontal
                    return p1.boundingBox.minX < p2.boundingBox.minX // Left first
                }
                
                continuation.resume(returning: sortedPanels)
            }
            
            // Vision Settings
            request.minimumConfidence = (mode == .aggressive) ? 0.3 : 0.6
            request.minimumAspectRatio = 0.1
            request.maximumAspectRatio = 5.0
            request.minimumSize = 0.15 // Ignore tiny specs
            
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try? handler.perform([request])
        }
    }
    
    // 2. Actually slice the image
    static func extractPanels(from image: UIImage, mode: ExtractionMode) async throws -> [UIImage] {
        guard let cgImage = image.cgImage else { return [image] }
        
        let panels = await detectPanels(in: image, mode: mode)
        
        if panels.isEmpty { return [image] } // Fallback to full page
        
        return panels.compactMap { panel in
            // Convert Vision Rect (0..1) to Image Coordinates (Pixels)
            // Vision Origin is Bottom-Left. CoreGraphics is Top-Left. We must flip Y.
            let width = CGFloat(cgImage.width)
            let height = CGFloat(cgImage.height)
            
            let r = panel.boundingBox
            // Flip Y for cropping
            let cropRect = CGRect(
                x: r.minX * width,
                y: (1.0 - r.maxY) * height, // 1 - maxY is the top in CG coords
                width: r.width * width,
                height: r.height * height
            )
            
            guard let croppedCG = cgImage.cropping(to: cropRect) else { return nil }
            return UIImage(cgImage: croppedCG)
        }
    }
    
    private static func generateGridPanels(rows: Int, cols: Int) -> [Panel] {
        var panels: [Panel] = []
        let w = 1.0 / Double(cols)
        let h = 1.0 / Double(rows)
        // Grid logic is simple math
        // Note: Vision coordinates (0,0 is bottom-left)
        for r in (0..<rows).reversed() { // Top row first (Higher Y)
            for c in 0..<cols { // Left col first
                let rect = CGRect(
                    x: Double(c) * w,
                    y: Double(r) * h,
                    width: w,
                    height: h
                )
                panels.append(Panel(boundingBox: rect))
            }
        }
        return panels
    }
}
