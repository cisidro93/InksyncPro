import Vision
import UIKit

struct PanelExtractor {
    
    // ✅ Updated to include Grid case
    enum ExtractionMode: Codable, Equatable, Hashable {
        case automatic
        case conservative
        case aggressive
        case grid(rows: Int, columns: Int)
        
        // Helper for UI Picker (since Associated Values break standard Pickers)
        static var allCases: [ExtractionMode] {
            [.automatic, .conservative, .aggressive, .grid(rows: 2, columns: 2)]
        }
        
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
    
    static func detectPanels(in image: UIImage, mode: ExtractionMode = .automatic) async -> [Panel] {
        guard let cgImage = image.cgImage else { return [] }
        
        if case .grid(let rows, let cols) = mode {
            return generateGridPanels(rows: rows, cols: cols)
        }
        
        return await withCheckedContinuation { continuation in
            let request = VNDetectRectanglesRequest { request, error in
                guard let results = request.results as? [VNRectangleObservation] else {
                    continuation.resume(returning: [])
                    return
                }
                
                let confidenceThreshold: Float = (mode == .aggressive) ? 0.3 : 0.6
                let panels = results
                    .filter { $0.confidence > confidenceThreshold }
                    .map { Panel(boundingBox: $0.boundingBox) }
                
                continuation.resume(returning: panels)
            }
            
            request.minimumConfidence = (mode == .aggressive) ? 0.3 : 0.6
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try? handler.perform([request])
        }
    }
    
    // Stub to fix View call
    static func extractPanels(from image: UIImage, mode: ExtractionMode) async throws -> [UIImage] {
        // Just return full image for now to pass build
        return [image]
    }
    
    private static func generateGridPanels(rows: Int, cols: Int) -> [Panel] {
        var panels: [Panel] = []
        let w = 1.0 / Double(cols)
        let h = 1.0 / Double(rows)
        for r in 0..<rows {
            for c in 0..<cols {
                let rect = CGRect(x: Double(c)*w, y: 1.0 - (Double(r+1)*h), width: w, height: h)
                panels.append(Panel(boundingBox: rect))
            }
        }
        return panels
    }
}
