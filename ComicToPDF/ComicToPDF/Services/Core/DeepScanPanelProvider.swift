import UIKit
import CoreImage
import Vision

class DeepScanPanelProvider: PanelProvider {
    
    func detectPanels(in image: UIImage, context: CIContext) async -> [PanelCandidate] {
        guard let cgImage = image.cgImage else { return [] }
        
        return await withCheckedContinuation { continuation in
            let request = VNDetectContoursRequest { request, error in
                guard let results = request.results as? [VNContoursObservation], error == nil else {
                    continuation.resume(returning: [])
                    return
                }
                
                var candidates: [PanelCandidate] = []
                
                // Adaptive Thresholds
                let currentMinSize = AdaptiveLearningManager.shared.currentMinimumSize
                
                for observation in results {
                    // Contours return a hierarchy. We want the top-level contours (the panel borders),
                    // NOT the child contours (the characters/art inside the panels).
                    let topLevelContours = observation.topLevelContours
                    
                    for contour in topLevelContours {
                        // A contour's bounding path
                        let path = contour.normalizedPath
                        let boundingBox = path.boundingBox
                        
                        // Filter out tiny noise contours
                        let area = boundingBox.width * boundingBox.height
                        guard area >= CGFloat(currentMinSize) else { continue }
                        
                        // We also don't want the contour of the *entire page* itself, if present
                        if boundingBox.width > 0.95 && boundingBox.height > 0.95 { continue }
                        
                        candidates.append(PanelCandidate(
                            boundingBox: boundingBox,
                            confidence: 0.85, // Contours are highly accurate structural representations
                            method: .deepScanContour
                        ))
                    }
                }
                
                continuation.resume(returning: candidates)
            }
            
            // CoreImage filters to prepare the image for contour tracing
            // We want hard contrast lines. Outline filter works perfectly for this.
            let ciImage = CIImage(cgImage: cgImage)
            let filter = CIFilter(name: "CIEdges")
            filter?.setValue(ciImage, forKey: kCIInputImageKey)
            filter?.setValue(10.0, forKey: "inputIntensity")
            
            guard let edgeImage = filter?.outputImage,
                  let finalCGImage = context.createCGImage(edgeImage, from: edgeImage.extent) else {
                
                // Fallback to raw image if CI fails
                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                try? handler.perform([request])
                return
            }
            
            let handler = VNImageRequestHandler(cgImage: finalCGImage, options: [:])
            do {
                // High contrast setup
                request.contrastAdjustment = 1.6
                request.detectsDarkOnLight = true // Look for dark panel borders on white gutters
                
                try handler.perform([request])
            } catch {
                print("❌ [DeepScan] Contour Request failed: \(error)")
                continuation.resume(returning: [])
            }
        }
    }
}
