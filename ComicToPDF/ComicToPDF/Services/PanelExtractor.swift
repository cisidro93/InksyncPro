import UIKit
import Vision
import CoreImage

class PanelExtractor {
    
    struct Panel {
        let image: UIImage
        let boundingBox: CGRect
        let confidence: Float
    }
    
    enum ExtractionMode {
        case automatic
        case grid(rows: Int, columns: Int)
    }
    
    static func extractPanels(from image: UIImage, mode: ExtractionMode = .automatic) async throws -> [Panel] {
        switch mode {
        case .automatic:
            return try await detectPanelsAutomatically(image)
        case .grid(let rows, let columns):
            return extractPanelsInGrid(image, rows: rows, columns: columns)
        }
    }
    
    private static func detectPanelsAutomatically(_ image: UIImage) async throws -> [Panel] {
        guard let cgImage = image.cgImage else {
            throw NSError(domain: "PanelExtractor", code: 1, 
                         userInfo: [NSLocalizedDescriptionKey: "Invalid image"])
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNDetectRectanglesRequest { request, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                
                guard let observations = request.results as? [VNRectangleObservation] else {
                    continuation.resume(returning: [])
                    return
                }
                
                var panels: [Panel] = []
                let imageSize = CGSize(width: cgImage.width, height: cgImage.height)
                
                for observation in observations {
                    let boundingBox = VNImageRectForNormalizedRect(
                        observation.boundingBox,
                        Int(imageSize.width),
                        Int(imageSize.height)
                    )
                    
                    if let panelCGImage = cgImage.cropping(to: boundingBox) {
                        let panelImage = UIImage(cgImage: panelCGImage)
                        let panel = Panel(
                            image: panelImage,
                            boundingBox: boundingBox,
                            confidence: observation.confidence
                        )
                        panels.append(panel)
                    }
                }
                
                panels.sort { lhs, rhs in
                    if abs(lhs.boundingBox.minY - rhs.boundingBox.minY) < 50 {
                        return lhs.boundingBox.minX < rhs.boundingBox.minX
                    }
                    return lhs.boundingBox.minY < rhs.boundingBox.minY
                }
                
                continuation.resume(returning: panels)
            }
            
            request.minimumAspectRatio = 0.3
            request.maximumAspectRatio = 3.0
            request.minimumSize = 0.1
            request.maximumObservations = 20
            
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
    
    private static func extractPanelsInGrid(_ image: UIImage, rows: Int, columns: Int) -> [Panel] {
        guard let cgImage = image.cgImage else { return [] }
        
        let imageWidth = CGFloat(cgImage.width)
        let imageHeight = CGFloat(cgImage.height)
        let panelWidth = imageWidth / CGFloat(columns)
        let panelHeight = imageHeight / CGFloat(rows)
        
        var panels: [Panel] = []
        
        for row in 0..<rows {
            for col in 0..<columns {
                let x = CGFloat(col) * panelWidth
                let y = CGFloat(row) * panelHeight
                let rect = CGRect(x: x, y: y, width: panelWidth, height: panelHeight)
                
                if let panelCGImage = cgImage.cropping(to: rect) {
                    let panelImage = UIImage(cgImage: panelCGImage)
                    let panel = Panel(image: panelImage, boundingBox: rect, confidence: 1.0)
                    panels.append(panel)
                }
            }
        }
        
        return panels
    }
}
