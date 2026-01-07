import Vision
import UIKit

struct PanelExtractor {
    
    // ✅ Fix: Simple enum for settings compatibility
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
    
    // ✅ Fix: Native CodingKeys here
    struct Panel: Codable, Equatable, Identifiable {
        let id = UUID()
        let boundingBox: CGRect // Normalized 0..1
        
        enum CodingKeys: String, CodingKey {
            case boundingBox
        }
    }
    
    // MARK: - Core Logic
    
    static func detectPanels(in image: UIImage, mode: ExtractionMode = .automatic) async -> [Panel] {
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
                
                // Sensitivity
                let confidenceThreshold: Float = (mode == .aggressive) ? 0.3 : 0.85
                let minSize: CGFloat = (mode == .aggressive) ? 0.1 : 0.15
                
                let rawPanels = results
                    .filter { $0.confidence > confidenceThreshold }
                    .filter { $0.boundingBox.width > minSize && $0.boundingBox.height > minSize }
                    .map { Panel(boundingBox: $0.boundingBox) }
                
                // Use Smart Sort
                let sorted = sortPanelsByReadingOrder(rawPanels)
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
    
    private static func sortPanelsByReadingOrder(_ panels: [Panel]) -> [Panel] {
        let primarySort = panels.sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }
        var sortedRows: [[Panel]] = []
        var currentRow: [Panel] = []
        
        for panel in primarySort {
            if currentRow.isEmpty {
                currentRow.append(panel)
            } else {
                let rowAvgY = currentRow.map { $0.boundingBox.midY }.reduce(0, +) / CGFloat(currentRow.count)
                if abs(panel.boundingBox.midY - rowAvgY) < (panel.boundingBox.height * 0.5) {
                    currentRow.append(panel)
                } else {
                    sortedRows.append(currentRow)
                    currentRow = [panel]
                }
            }
        }
        if !currentRow.isEmpty { sortedRows.append(currentRow) }
        
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
        for r in (0..<rows).reversed() {
            for c in 0..<cols {
                let rect = CGRect(x: Double(c) * w, y: Double(r) * h, width: w, height: h)
                panels.append(Panel(boundingBox: rect))
            }
        }
        return panels
    }
}
