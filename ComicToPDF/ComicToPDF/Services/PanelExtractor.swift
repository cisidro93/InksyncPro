import Vision
import UIKit

struct PanelExtractor {
    
    enum ExtractionMode: String, Codable, Equatable, Hashable {
        case automatic
        case conservative
        case aggressive
        case grid
        
        var title: String {
            switch self {
            case .automatic: return "Automatic"
            case .conservative: return "Conservative"
            case .aggressive: return "Aggressive"
            case .grid: return "Grid (2x2)"
            }
        }
    }
    
    struct Panel: Codable, Equatable, Identifiable {
        let id = UUID()
        let boundingBox: CGRect // Normalized 0..1 (Vision Origin: Bottom-Left)
        
        enum CodingKeys: String, CodingKey {
            case boundingBox
        }
    }
    
    // MARK: - Core Logic
    
    static func detectPanels(in image: UIImage, mode: ExtractionMode = .automatic, mangaMode: Bool = false) async -> [Panel] {
        guard let cgImage = image.cgImage else { return [] }
        
        if mode == .grid {
            return generateGridPanels(rows: 2, cols: 2)
        }
        
        return await withCheckedContinuation { continuation in
            let request = VNDetectRectanglesRequest { request, error in
                guard let results = request.results as? [VNRectangleObservation] else {
                    continuation.resume(returning: [])
                    return
                }
                
                let confidenceThreshold: Float = (mode == .aggressive) ? 0.3 : 0.85
                let minSize: CGFloat = (mode == .aggressive) ? 0.1 : 0.15
                
                let rawPanels = results
                    .filter { $0.confidence > confidenceThreshold }
                    .filter { $0.boundingBox.width > minSize && $0.boundingBox.height > minSize }
                    .map { Panel(boundingBox: $0.boundingBox) }
                
                // ✅ Fix: Use Recursive Row Clustering
                let sorted = clusterAndSortPanels(rawPanels, mangaMode: mangaMode)
                continuation.resume(returning: sorted)
            }
            
            request.minimumConfidence = (mode == .aggressive) ? 0.1 : 0.6
            request.minimumAspectRatio = 0.1
            request.maximumAspectRatio = 5.0
            request.minimumSize = 0.1
            request.quadratureTolerance = 30
            
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try? handler.perform([request])
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
            
            for candidate in pool {
                if isSameRow(anchor, candidate) {
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
    
    private static func isSameRow(_ p1: Panel, _ p2: Panel) -> Bool {
        // Vision Coords: Y=0 is Bottom.
        let yMin1 = p1.boundingBox.minY
        let yMax1 = p1.boundingBox.maxY
        let yMin2 = p2.boundingBox.minY
        let yMax2 = p2.boundingBox.maxY
        
        // Calculate Intersection of Y ranges
        let intersectionMin = max(yMin1, yMin2)
        let intersectionMax = min(yMax1, yMax2)
        let intersectionHeight = max(0, intersectionMax - intersectionMin)
        
        // If the intersection covers > 50% of the shorter panel's height, they are on the same row.
        let minHeight = min(p1.boundingBox.height, p2.boundingBox.height)
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
            let width = CGFloat(cgImage.width)
            let height = CGFloat(cgImage.height)
            let r = panel.boundingBox
            
            let cropRect = CGRect(
                x: r.minX * width,
                y: (1.0 - r.maxY) * height,
                width: r.width * width,
                height: r.height * height
            )
            
            guard let cropped = cgImage.cropping(to: cropRect) else { return nil }
            return UIImage(cgImage: cropped)
        }
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
