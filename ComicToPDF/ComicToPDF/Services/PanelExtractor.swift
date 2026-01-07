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
        let boundingBox: CGRect // Normalized 0..1
        
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
                
                let sorted = sortPanelsByReadingOrder(rawPanels, mangaMode: mangaMode)
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
    
    // ✅ NEW: Helper to crop specific panels (Manual Override Support)
    static func cropPanels(from image: UIImage, panels: [Panel]) async throws -> [UIImage] {
        guard let cgImage = image.cgImage else { return [image] }
        
        return panels.compactMap { panel in
            let width = CGFloat(cgImage.width)
            let height = CGFloat(cgImage.height)
            let r = panel.boundingBox
            
            // Flip Y for CoreGraphics (Top-Left origin) vs Vision (Bottom-Left origin)
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
    
    // Legacy helper (wraps detection + cropping)
    static func extractPanels(from image: UIImage, mode: ExtractionMode, mangaMode: Bool = false) async throws -> [UIImage] {
        let panels = await detectPanels(in: image, mode: mode, mangaMode: mangaMode)
        if panels.isEmpty { return [image] }
        return try await cropPanels(from: image, panels: panels)
    }
    
    private static func sortPanelsByReadingOrder(_ panels: [Panel], mangaMode: Bool) -> [Panel] {
        return panels.sorted { p1, p2 in
            let y1 = p1.boundingBox.midY
            let y2 = p2.boundingBox.midY
            
            // Fuzzy Sort (15% threshold)
            let yDiff = abs(y1 - y2)
            let threshold: CGFloat = 0.15
            
            if yDiff < threshold {
                if mangaMode {
                    return p1.boundingBox.minX > p2.boundingBox.minX // Right to Left
                } else {
                    return p1.boundingBox.minX < p2.boundingBox.minX // Left to Right
                }
            } else {
                return y1 > y2 // Top to Bottom
            }
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
