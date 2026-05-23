@preconcurrency import Vision
import UIKit

class VisionPanelProvider: PanelProvider {
    
    func detectPanels(in image: UIImage, context: CIContext) async -> [PanelCandidate] {
        guard let cgImage = image.cgImage else { return [] }

        // Snapshot @MainActor-isolated adaptive thresholds before entering the
        // non-isolated cooperative pool.
        let currentConfidence = await MainActor.run { AdaptiveLearningManager.shared.currentBaseConfidence }
        let currentMinSize    = await MainActor.run { AdaptiveLearningManager.shared.currentMinimumSize }

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
        
        // Run synchronously on the cooperative background thread pool
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform(requests)
            
            // 3. Saliency Request (Attention Heatmap)
            let saliencyRequest = VNGenerateAttentionBasedSaliencyImageRequest()
            try? handler.perform([saliencyRequest])
            
            var salientRects: [CGRect] = []
            if let saliencyResult = saliencyRequest.results?.first {
                salientRects = saliencyResult.salientObjects?.map { $0.boundingBox } ?? []
            }
            
            var candidates: [PanelCandidate] = []
            
            // Process Rects
            if let rects = rectRequest.results {
                for obs in rects {
                    guard obs.confidence >= Float(currentConfidence) else { 
                        Logger.shared.log("AI Vision [Drop]: Panel rejected due to confidence (\(String(format: "%.2f", obs.confidence)) < \(currentConfidence)).", category: "AI_Verbose")
                        continue 
                    }
                    
                    let isWideEnough = obs.boundingBox.width >= CGFloat(currentMinSize)
                    let isTallEnough = obs.boundingBox.height >= CGFloat(currentMinSize)
                    
                    guard isWideEnough && isTallEnough else { 
                        Logger.shared.log("AI Vision [Drop]: Panel rejected due to microscopic bounds (w: \(String(format: "%.2f", obs.boundingBox.width)), h: \(String(format: "%.2f", obs.boundingBox.height))).", category: "AI_Verbose")
                        continue 
                    }
                    
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
                    let isWideEnough = obs.boundingBox.width >= CGFloat(currentMinSize)
                    let isTallEnough = obs.boundingBox.height >= CGFloat(currentMinSize)
                    
                    let ratio = obs.boundingBox.width / obs.boundingBox.height
                    let isValidAspect = ratio > 0.2 && ratio < 5.0
                    
                    if isWideEnough && isTallEnough && isValidAspect {
                        candidates.append(PanelCandidate(
                            boundingBox: obs.boundingBox,
                            confidence: 1.0, 
                            method: .textAnchor,
                            containsText: true
                        ))
                    } else {
                        Logger.shared.log("AI Vision [Drop]: Text anchor rejected (w: \(String(format: "%.2f", obs.boundingBox.width)), h: \(String(format: "%.2f", obs.boundingBox.height)), ratio: \(String(format: "%.2f", ratio))).", category: "AI_Verbose")
                    }
                }
            }
            
            Logger.shared.log("AI Vision: Extracted \(candidates.count) structural candidate arrays from image boundaries.", category: "AI", type: .success)
            return candidates
            
        } catch {
            print("❌ [VisionProvider] Request failed: \(error)")
            return []
        }
    }
}
