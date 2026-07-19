import UIKit
import CoreImage
import Vision

class DeepScanPanelProvider: PanelProvider {
    
    func detectPanels(in image: UIImage, context: CIContext) async -> [PanelCandidate] {
        guard let cgImage = image.cgImage else { return [] }
        
        // Snapshot @MainActor-isolated adaptive thresholds before running the non-isolated block
        let currentMinSize = await MainActor.run { AdaptiveLearningManager.shared.currentMinimumSize }
        
        // CoreImage filters to prepare the image for contour tracing
        // We want hard contrast lines. Outline filter works perfectly for this.
        let ciImage = CIImage(cgImage: cgImage)
        let filter = CIFilter(name: "CIEdges")
        filter?.setValue(ciImage, forKey: kCIInputImageKey)
        filter?.setValue(10.0, forKey: "inputIntensity")
        
        let request = VNDetectContoursRequest()
        
        let finalImage: CGImage
        if let edgeImage = filter?.outputImage,
           let finalCGImage = context.createCGImage(edgeImage, from: edgeImage.extent) {
            finalImage = finalCGImage
            // High contrast setup
            request.contrastAdjustment = 1.6
            request.detectsDarkOnLight = true // Look for dark panel borders on white gutters
        } else {
            // Fallback to raw image if CI fails
            finalImage = cgImage
        }
        
        let handler = VNImageRequestHandler(cgImage: finalImage, options: [:])
        do {
            try handler.perform([request])
            guard let results = request.results else { return [] }
            
            var allContours: [VNContour] = []
            func collectContours(_ contours: [VNContour]) {
                for contour in contours {
                    allContours.append(contour)
                    collectContours(contour.childContours)
                }
            }
            
            for observation in results {
                collectContours(observation.topLevelContours)
            }
            
            var candidates: [PanelCandidate] = []
            let minSide = CGFloat(currentMinSize)
            
            for contour in allContours {
                let path = contour.normalizedPath
                let boundingBox = path.boundingBox
                
                // Filter out tiny noise contours
                guard boundingBox.width >= minSide && boundingBox.height >= minSide else { continue }
                
                // We also don't want the contour of the *entire page* itself, if present
                if boundingBox.width > 0.95 && boundingBox.height > 0.95 { continue }
                
                candidates.append(PanelCandidate(
                    boundingBox: boundingBox,
                    confidence: 0.85, // Contours are highly accurate structural representations
                    method: .deepScanContour
                ))
            }
            return candidates
        } catch {
            print("❌ [DeepScan] Contour Request failed: \(error)")
            return []
        }
    }
}
