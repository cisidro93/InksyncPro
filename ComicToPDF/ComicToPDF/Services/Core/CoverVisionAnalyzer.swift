import Foundation
import SwiftData
import SwiftUI
import Vision
import CoreImage

/// Uses Apple's Neural Engine to execute high-performance OCR on Comic book covers locally.
final class CoverVisionAnalyzer: Sendable {
    
    /// Scans a generated cover image and returns an array of prominent text strings (Series Names)
    static func detectTitle(from url: URL) async -> String? {
        guard let ciImage = CIImage(contentsOf: url) else { return nil }
        
        let request = VNRecognizeTextRequest()
        
        // Comic titles can have uniquely stylized fonts, so we use .accurate
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        
        let handler = VNImageRequestHandler(ciImage: ciImage, options: [:])
        do {
            try handler.perform([request])
            guard let observations = request.results else { return nil }
            
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
            return bestCandidate?.capitalized
        } catch {
            Logger.shared.log("Vision AI Error: \(error.localizedDescription)", category: "AI", type: .error)
            return nil
        }
    }
}
