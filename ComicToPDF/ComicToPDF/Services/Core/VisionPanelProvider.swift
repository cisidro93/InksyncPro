import Vision
import UIKit

class VisionPanelProvider: PanelProvider {
    
    func detectPanels(in image: UIImage, context: CIContext) async -> [PanelCandidate] {
        guard let cgImage = image.cgImage else { return [] }
        
        return await withCheckedContinuation { continuation in
            autoreleasepool {
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
                        guard obs.confidence >= Float(currentConfidence) else { 
                            Logger.shared.log("AI Vision [Drop]: Panel rejected due to confidence (\(String(format: "%.2f", obs.confidence)) < \(currentConfidence)).", category: "AI_Verbose")
                            continue 
                        }
                        
                        // Fix: Using Fractional Side Bounds instead of absolute Area.
                        let isWideEnough = obs.boundingBox.width >= CGFloat(currentMinSize)
                        let isTallEnough = obs.boundingBox.height >= CGFloat(currentMinSize)
                        
                        guard isWideEnough && isTallEnough else { 
                            Logger.shared.log("AI Vision [Drop]: Panel rejected due to microscopic bounds (w: \(String(format: "%.2f", obs.boundingBox.width)), h: \(String(format: "%.2f", obs.boundingBox.height))).", category: "AI_Verbose")
                            continue 
                        }
                        
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
                        }
                    }
                }
                
                Logger.shared.log("AI Vision: Extracted \(candidates.count) structural candidate arrays from image boundaries.", category: "AI", type: .success)
                continuation.resume(returning: candidates)
                
            } catch {
                print("❌ [VisionProvider] Request failed: \(error)")
                continuation.resume(returning: [])
            }
            }
        }
    }
}
