import Vision
import UIKit

struct PanelExtractor {
    
    enum ExtractionMode: String, Codable, Equatable, Hashable {
        case automatic
        case conservative
        case aggressive
        case grid // Special handling in UI, falls back to auto logic here if passed
        
        var title: String {
            switch self {
            case .automatic: return "Automatic"
            case .conservative: return "Conservative"
            case .aggressive: return "Aggressive"
            case .grid: return "Grid"
            }
        }
    }
    
    struct Panel: Codable, Equatable, Identifiable {
        let id = UUID()
        let boundingBox: CGRect // Normalized 0..1
        
        // Custom coding keys to skip ID
        enum CodingKeys: String, CodingKey {
            case boundingBox
        }
    }
    
    // MARK: - Core Logic
    
    static func detectPanels(in image: UIImage, mode: ExtractionMode = .automatic) async -> [Panel] {
        guard let cgImage = image.cgImage else { return [] }
        
        // Handle Grid manually if passed (though usually handled by caller settings)
        if mode == .grid {
            return generateGridPanels(rows: 2, cols: 2)
        }
        
        return await withCheckedContinuation { continuation in
            let request = VNDetectRectanglesRequest { request, error in
                guard let results = request.results as? [VNRectangleObservation] else {
                    continuation.resume(returning: [])
                    return
                }
                
                // Sensitivity Settings
                let confidenceThreshold: Float = (mode == .aggressive) ? 0.3 : 0.85
                let minSize: CGFloat = (mode == .aggressive) ? 0.1 : 0.15
                
                let rawPanels = results
                    .filter { $0.confidence > confidenceThreshold }
                    .filter { $0.boundingBox.width > minSize && $0.boundingBox.height > minSize }
                    .map { Panel(boundingBox: $0.boundingBox) }
                
                // ✅ Fix: Use Smart Row Banding Sort
                let sorted = sortPanelsByReadingOrder(rawPanels)
                continuation.resume(returning: sorted)
            }
            
            // Vision Configuration
            request.minimumConfidence = (mode == .aggressive) ? 0.1 : 0.6
            request.minimumAspectRatio = 0.1
            request.maximumAspectRatio = 5.0
            request.minimumSize = 0.1
            request.quadratureTolerance = 30 // Allow slightly non-rectangular panels
            
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try? handler.perform([request])
        }
    }
    
    // ✅ NEW: Robust Sorting Algorithm (Row Banding)
    private static func sortPanelsByReadingOrder(_ panels: [Panel]) -> [Panel] {
        // Vision coords: Y=0 is Bottom, Y=1 is Top.
        // We want Top-to-Bottom (Descending Y), then Left-to-Right (Ascending X).
        
        // 1. Sort primarily by Top Edge (Descending Y)
        let primarySort = panels.sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }
        
        var sortedRows: [[Panel]] = []
        var currentRow: [Panel] = []
        
        for panel in primarySort {
            if currentRow.isEmpty {
                currentRow.append(panel)
            } else {
                // Check if this panel belongs in the current "visual row"
                // Logic: Does it overlap vertically with the row's average Y center?
                let rowAvgY = currentRow.map { $0.boundingBox.midY }.reduce(0, +) / CGFloat(currentRow.count)
                let panelY = panel.boundingBox.midY
                let panelHeight = panel.boundingBox.height
                
                // If the panel's center is within 50% of the row's height, it's the same row.
                if abs(panelY - rowAvgY) < (panelHeight * 0.5) {
                    currentRow.append(panel)
                } else {
                    // Start new row
                    sortedRows.append(currentRow)
                    currentRow = [panel]
                }
            }
        }
        if !currentRow.isEmpty { sortedRows.append(currentRow) }
        
        // 2. Sort each row Left-to-Right (Ascending X) and flatten
        return sortedRows.flatMap { row in
            row.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
        }
    }
    
    static func extractPanels(from image: UIImage, mode: ExtractionMode) async throws -> [UIImage] {
        guard let cgImage = image.cgImage else { return [image] }
        let panels = await detectPanels(in: image, mode: mode)
        
        if panels.isEmpty { return [image] }
        
        return panels.compactMap { panel in
            let width = CGFloat(cgImage.width)
            let height = CGFloat(cgImage.height)
            let r = panel.boundingBox
            
            // Flip Y for CoreGraphics cropping (Top-Left origin)
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
    
    private static func generateGridPanels(rows: Int, cols: Int) -> [Panel] {
        var panels: [Panel] = []
        let w = 1.0 / Double(cols)
        let h = 1.0 / Double(rows)
        // Top row first (Higher Y in Vision)
        for r in (0..<rows).reversed() {
            for c in 0..<cols {
                let rect = CGRect(x: Double(c) * w, y: Double(r) * h, width: w, height: h)
                panels.append(Panel(boundingBox: rect))
            }
        }
        return panels
    }
}
