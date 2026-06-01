import Foundation
import UIKit
import Vision

class PageOCRService {
    static let shared = PageOCRService()
    
    private init() {}
    
    // Extract names from page artwork matching series cast names
    func extractNames(from image: UIImage, castNames: [String]) async -> [String] {
        guard let cgImage = image.cgImage else { return [] }
        
        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                guard error == nil, let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: [])
                    return
                }
                
                var detectedWords: Set<String> = []
                for observation in observations {
                    guard let candidate = observation.topCandidates(1).first else { continue }
                    // Clean text and split into words
                    let words = candidate.string.components(separatedBy: CharacterSet.alphanumerics.inverted)
                    for word in words {
                        let clean = word.trimmingCharacters(in: .whitespacesAndNewlines)
                        if clean.count > 2 {
                            detectedWords.insert(clean.lowercased())
                        }
                    }
                }
                
                // Filter cast names that are mentioned on page
                let matched = castNames.filter { name in
                    let parts = name.components(separatedBy: " ")
                    return parts.contains { part in
                        detectedWords.contains(part.lowercased())
                    }
                }
                
                continuation.resume(returning: matched)
            }
            
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: [])
            }
        }
    }
}
