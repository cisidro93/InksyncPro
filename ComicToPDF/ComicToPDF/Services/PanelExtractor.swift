import Vision
import UIKit

struct PanelExtractor {
    
    // ✅ Added Codable, Equatable, Hashable so Settings can use it
    enum ExtractionMode: String, Codable, Equatable, Hashable, CaseIterable {
        case automatic = "Automatic"
        case conservative = "Conservative"
        case aggressive = "Aggressive"
        case grid = "Grid" // Simplified for storage
    }
    
    struct Panel: Identifiable {
        let id = UUID()
        let boundingBox: CGRect
    }
    
    static func detectPanels(in image: UIImage, mode: ExtractionMode = .automatic) async -> [Panel] {
        guard let cgImage = image.cgImage else { return [] }
        
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
}
