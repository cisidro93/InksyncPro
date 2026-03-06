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
                
                // 3. Saliency Request (Attention Heatmap)
                let saliencyRequest = VNGenerateAttentionBasedSaliencyImageRequest()
                try? handler.perform([saliencyRequest])
                
                // We don't need to parse the raw heatmap right now; just knowing where the human eye looks
                // could be used to heavily weight bounding boxes.
                var salientRects: [CGRect] = []
                if let saliencyResult = saliencyRequest.results?.first {
                    // Saliency observation gives us salientObjects (bounding boxes of high interest)
                    salientRects = saliencyResult.salientObjects?.map { $0.boundingBox } ?? []
                }
                
                var candidates: [PanelCandidate] = []
                
                // Adaptive Thresholds
                let currentConfidence = AdaptiveLearningManager.shared.currentBaseConfidence
                let currentMinSize = AdaptiveLearningManager.shared.currentMinimumSize
                
                // Process Rects
                if let rects = rectRequest.results {
                    for obs in rects {
                        guard obs.confidence >= Float(currentConfidence) else { continue }
                        let area = obs.boundingBox.width * obs.boundingBox.height
                        guard area >= CGFloat(currentMinSize) else { continue }
                        
                        // Saliency Check: Does this rectangle contain anything a human would look at?
                        let hasSaliency = salientRects.contains { $0.intersects(obs.boundingBox) }
                        let boostedConfidence = hasSaliency ? obs.confidence * 1.2 : obs.confidence // Boost if it holds attention
                        
                        candidates.append(PanelCandidate(
                            boundingBox: obs.boundingBox,
                            confidence: min(boostedConfidence, 1.0),
                            method: .visionRectangle
                        ))
                    }
                }
                
                // Process Text Anchors & Virtual Bounds
                if let texts = textRequest.results {
                    for obs in texts {
                        // Intelligent Text Anchors: If we find a block of text, it *must* be inside a panel.
                        if obs.boundingBox.width > 0.02 && obs.boundingBox.height > 0.01 {
                            // First, add it as a standard anchor for the Ensemble to check
                            candidates.append(PanelCandidate(
                                boundingBox: obs.boundingBox,
                                confidence: 1.0, 
                                method: .textAnchor,
                                containsText: true
                            ))
                            
                            // NEW: Spawn a "Virtual Boundary" around the text bubble.
                            // If the Ensemble fails to find a structural panel here, it will use this as a fallback panel!
                            let virtualPadding: CGFloat = 0.05
                            let virtualBounds = CGRect(
                                x: max(0, obs.boundingBox.minX - virtualPadding),
                                y: max(0, obs.boundingBox.minY - virtualPadding),
                                width: min(1, obs.boundingBox.width + (virtualPadding * 2)),
                                height: min(1, obs.boundingBox.height + (virtualPadding * 2))
                            )
                            
                            // We tag this as deepScanContour so the Orchestrator knows it's a fallback structural suggestion
                            candidates.append(PanelCandidate(
                                boundingBox: virtualBounds,
                                confidence: 0.8,
                                method: .deepScanContour,
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
