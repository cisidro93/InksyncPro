import Foundation
import SwiftData
import SwiftUI
import Vision
import CoreImage

/// Uses Apple's Neural Engine to execute high-performance OCR on Comic book covers locally.
class CoverVisionAnalyzer {
    
    /// Scans a generated cover image and returns an array of prominent text strings (Series Names)
    static func detectTitle(from url: URL) async -> String? {
        guard let ciImage = CIImage(contentsOf: url) else { return nil }
        
        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                guard error == nil else {
                    Logger.shared.log("Vision AI Error: \(error!.localizedDescription)", category: "AI", type: .error)
                    continuation.resume(returning: nil)
                    return
                }
                
                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: nil)
                    return
                }
                
                // 1. We want the text blocks that are large (typically titles are large and centered)
                // 2. We filter out publisher names like "DC", "MARVEL", "IMAGE" if possible
                let commonGarbage = ["DC", "MARVEL", "IMAGE", "COMICS", "READ", "ISSUE", "VOL", "VOLUME", "NUMBER", "$2.99", "$3.99"]
                
                var bestCandidate: String? = nil
                var maxConfidenceSize: Float = 0
                
                for observation in observations {
                    guard let topCandidate = observation.topCandidates(1).first else { continue }
                    
                    let text = topCandidate.string.uppercased()
                    
                    // Filter out single letters or tiny words, and common garbage logos
                    if text.count > 2 && !commonGarbage.contains(where: { text.contains($0) }) {
                        // The bounding box height acts as a proxy for font size/prominence
                        let sizeScore = Float(observation.boundingBox.height) * topCandidate.confidence
                        
                        if sizeScore > maxConfidenceSize {
                            maxConfidenceSize = sizeScore
                            bestCandidate = text
                        }
                    }
                }
                
                // Return the largest, most confident word block found on the cover
                continuation.resume(returning: bestCandidate?.capitalized)
            }
            
            // Comic titles can have uniquely stylized fonts, so we use .accurate
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            
            do {
                let handler = VNImageRequestHandler(ciImage: ciImage, options: [:])
                try handler.perform([request])
            } catch {
                Logger.shared.log("Vision AI Dispatch Error: \(error.localizedDescription)", category: "AI", type: .error)
                continuation.resume(returning: nil)
            }
        }
    }
}
