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
        // Apple Vision framework defaults maximumObservations to 1!
        // We set to 64 so all comic panel frames across the page are extracted.
        rectRequest.maximumObservations = 64
        rectRequest.minimumConfidence = 0.20
        rectRequest.minimumSize = 0.04
        rectRequest.minimumAspectRatio = 0.03
        rectRequest.quadratureTolerance = 35
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
            let effConfidence = Float(min(0.25, currentConfidence))
            let effMinSize = CGFloat(min(0.04, currentMinSize))

            // Process Rects
            if let rects = rectRequest.results {
                for obs in rects {
                    // Filter out full-page outer perimeter (width & height >= 93% of entire page)
                    if obs.boundingBox.width >= 0.93 && obs.boundingBox.height >= 0.93 {
                        Logger.shared.log("AI Vision [Drop]: Page perimeter border ignored.", category: "AI_Verbose")
                        continue
                    }

                    guard obs.confidence >= effConfidence else { 
                        Logger.shared.log("AI Vision [Drop]: Panel rejected due to confidence (\(String(format: "%.2f", obs.confidence)) < \(effConfidence)).", category: "AI_Verbose")
                        continue 
                    }
                    
                    let isWideEnough = obs.boundingBox.width >= effMinSize
                    let isTallEnough = obs.boundingBox.height >= effMinSize
                    
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
                    let isWideEnough = obs.boundingBox.width >= effMinSize
                    let isTallEnough = obs.boundingBox.height >= effMinSize
                    
                    let ratio = obs.boundingBox.width / obs.boundingBox.height
                    let isValidAspect = ratio > 0.15 && ratio < 6.0
                    
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
