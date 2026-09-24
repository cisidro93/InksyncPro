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
        request.maximumImageDimension = 1024
        
        let finalImage: CGImage
        if var edgeImage = filter?.outputImage {
            // Morphological Opening (Erosion followed by Dilation):
            // Severs thin 1-2px speech bubble tails or ink bleeds that cross gutters,
            // preventing two adjacent panels from merging into a single contour.
            if let erode = CIFilter(name: "CIMorphologyMinimum", parameters: [
                kCIInputImageKey: edgeImage,
                kCIInputRadiusKey: 1.5
            ]), let eroded = erode.outputImage,
               let dilate = CIFilter(name: "CIMorphologyMaximum", parameters: [
                kCIInputImageKey: eroded,
                kCIInputRadiusKey: 1.5
            ]), let opened = dilate.outputImage {
                edgeImage = opened
            }

            if let finalCGImage = context.createCGImage(edgeImage, from: edgeImage.extent) {
                finalImage = finalCGImage
                // High contrast setup: CIEdges generates bright white edges on a black background
                request.contrastAdjustment = 1.6
                request.detectsDarkOnLight = false // Look for luminous bright edge contours on dark canvas
            } else {
                finalImage = cgImage
                request.detectsDarkOnLight = true
            }
        } else {
            // Fallback to raw image if CI fails (dark borders on light gutters)
            finalImage = cgImage
            request.detectsDarkOnLight = true
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
            let minSide = CGFloat(min(0.06, currentMinSize))
            
            for contour in allContours {
                let path = contour.normalizedPath
                let boundingBox = path.boundingBox
                
                // Filter out tiny noise contours
                guard boundingBox.width >= minSide && boundingBox.height >= minSide else { continue }
                
                // Filter out outer page boundary
                if boundingBox.width >= 0.93 && boundingBox.height >= 0.93 { continue }
                
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
