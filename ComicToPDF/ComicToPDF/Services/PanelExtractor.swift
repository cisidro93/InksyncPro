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
    
    static func detectPanels(in image: UIImage, mode: ExtractionMode = .automatic) async -> [Panel] {
        // ✅ Fix: Removed unused 'cgImage' warning
        guard image.cgImage != nil else { return [] }
        
        if case .grid(let rows, let cols) = mode {
            return generateGridPanels(rows: rows, cols: cols)
        }
        
        // Vision logic stub
        return [Panel(boundingBox: CGRect(x: 0, y: 0, width: 1, height: 1))]
    }
    
    static func extractPanels(from image: UIImage, mode: ExtractionMode) async throws -> [UIImage] {
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
