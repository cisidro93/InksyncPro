import Vision
import UIKit

class VisionPanelProvider: PanelProvider {
    
    func detectPanels(in image: UIImage, context: CIContext) async -> [PanelCandidate] {
        guard let cgImage = image.cgImage else { return [] }
        
        return await withCheckedContinuation { continuation in
            var requests: [VNRequest] = []
            
            // 1. Rectangle Request (Baseline)
            let rectRequest = VNDetectRectanglesRequest()
            rectRequest.minimumConfidence = 0.6
            rectRequest.minimumSize = 0.1
            rectRequest.minimumAspectRatio = 0.1 // Task 1 Requirement
            rectRequest.quadratureTolerance = 20  // Task 1 Requirement
            requests.append(rectRequest)
            
            // 2. Text Request (Anchors)
            let textRequest = VNRecognizeTextRequest()
            textRequest.recognitionLevel = .fast
            textRequest.usesLanguageCorrection = false
            requests.append(textRequest)
            
            // Run
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform(requests)
                
                var candidates: [PanelCandidate] = []
                
                // Process Rects
                if let rects = rectRequest.results {
                    for obs in rects {
                        candidates.append(PanelCandidate(
                            boundingBox: obs.boundingBox,
                            confidence: obs.confidence,
                            method: .visionRectangle
                        ))
                    }
                }
                
                // Process Text Anchors
                if let texts = textRequest.results {
                    for obs in texts {
                        // Consider a text block significant if it's not tiny noise
                        // We return these as "Text Anchor" candidates. 
                        // The Ensemble engine uses them to validte structure or trigger Deep Scan.
                        if obs.boundingBox.width > 0.02 && obs.boundingBox.height > 0.01 {
                            candidates.append(PanelCandidate(
                                boundingBox: obs.boundingBox,
                                confidence: 1.0, 
                                method: .textAnchor,
                                containsText: true
                            ))
                        }
                    }
                }
                
                continuation.resume(returning: candidates)
                
            } catch {
                print("❌ [VisionProvider] Request failed: \(error)")
                continuation.resume(returning: [])
            }
        }
    }
}
