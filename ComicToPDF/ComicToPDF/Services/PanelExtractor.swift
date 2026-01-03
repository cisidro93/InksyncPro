import Vision
import UIKit

class PanelExtractor {
    
    enum ExtractionMode {
        case automatic // Vision Framework
        case grid(rows: Int, cols: Int)
        case manual
    }
    
    static func extractPanels(from image: UIImage, mode: ExtractionMode) async throws -> [UIImage] {
        switch mode {
        case .automatic:
            return try await extractPanelsAutomatic(from: image)
        case .grid(let rows, let cols):
            return extractPanelsGrid(from: image, rows: rows, cols: cols)
        case .manual:
            return [image] // Stub for manual
        }
    }
    
    // MARK: - Automatic (Vision)
    
    private static func extractPanelsAutomatic(from image: UIImage) async throws -> [UIImage] {
        guard let cgImage = image.cgImage else { return [image] }
        
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNDetectRectanglesRequest { request, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                
                guard let results = request.results as? [VNRectangleObservation] else {
                    continuation.resume(returning: [image])
                    return
                }
                
                // Filter small rectangles (likely noise or text bubbles)
                let validRects = results.filter { $0.boundingBox.width > 0.3 && $0.boundingBox.height > 0.15 }
                
                // Sort by reading order (Top-Left to Bottom-Right roughly)
                // Assuming standard Western layout for now (Top-down, Left-right)
                // For Manga, we might need Right-Left option.
                // Simple heuristic: Sort by Y (top to bottom), then X (left to right) with some fuzziness.
                
                let sortedRects = validRects.sorted { r1, r2 in
                    let yDiff = abs(r1.boundingBox.origin.y - r2.boundingBox.origin.y)
                    if yDiff > 0.1 { // If significant Y difference, use Y (Remember Vision Y is flipped? No, 0,0 is bottom-left usually in specialized coords, but boundingBox is normalized)
                        // In Vision, Y=0 is bottom. So higher Y is top?
                        // "The origin is the lower-left corner of the image"
                        // So Top is Y=1.
                        // We want Top first, so DESCENDING Y.
                        return r1.boundingBox.origin.y > r2.boundingBox.origin.y
                    } else {
                        // Same row, simple left-to-right (ASCENDING X)
                        return r1.boundingBox.origin.x < r2.boundingBox.origin.x
                    }
                }
                
                var panels: [UIImage] = []
                for rect in sortedRects {
                    // Convert normalized rect to image coords
                    // Remember Vision Y is bottom-up. CoreGraphics/UIImage usually top-down? 
                    // Need to handle coordinate flip carefully.
                    
                    let w = CGFloat(cgImage.width)
                    let h = CGFloat(cgImage.height)
                    
                    let r = rect.boundingBox
                    
                    // Transform to CGImage coords (Y flipped)
                    let x = r.origin.x * w
                    let y = (1.0 - r.origin.y - r.height) * h
                    let width = r.width * w
                    let height = r.height * h
                    
                    let cropRect = CGRect(x: x, y: y, width: width, height: height)
                    
                    if let cropped = cgImage.cropping(to: cropRect) {
                        panels.append(UIImage(cgImage: cropped))
                    }
                }
                
                if panels.isEmpty { panels.append(image) }
                continuation.resume(returning: panels)
            }
            
            // Tweaks for finding panels
            request.minimumAspectRatio = 0.1
            request.maximumAspectRatio = 5.0
            request.minimumSize = 0.1
            request.quadratureTolerance = 20
            request.minimumConfidence = 0.6
            
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
    
    // MARK: - Grid
    
    private static func extractPanelsGrid(from image: UIImage, rows: Int, cols: Int) -> [UIImage] {
        guard let cgImage = image.cgImage else { return [image] }
        var panels: [UIImage] = []
        
        let w = CGFloat(cgImage.width) / CGFloat(cols)
        let h = CGFloat(cgImage.height) / CGFloat(rows)
        
        for r in 0..<rows {
            for c in 0..<cols {
                let x = CGFloat(c) * w
                let y = CGFloat(r) * h
                let rect = CGRect(x: x, y: y, width: w, height: h)
                
                if let cropped = cgImage.cropping(to: rect) {
                    panels.append(UIImage(cgImage: cropped))
                }
            }
        }
        
        return panels
    }
}
