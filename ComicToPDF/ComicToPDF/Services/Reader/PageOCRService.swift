import Foundation
import UIKit
import Vision

struct TextBlock: Sendable, Codable, Equatable, Identifiable {
    var id: UUID
    let text: String
    let boundingBox: CGRect // Vision coordinate space (normalized, bottom-origin)
    
    init(id: UUID = UUID(), text: String, boundingBox: CGRect) {
        self.id = id
        self.text = text
        self.boundingBox = boundingBox
    }
}

final class PageOCRService: Sendable {
    static let shared = PageOCRService()
    
    private init() {}
    
    // Extract names from page artwork matching series cast names
    func extractNames(from image: UIImage, castNames: [String]) async -> [String] {
        guard let cgImage = image.cgImage else { return [] }
        
        return await withCheckedContinuation { continuation in
            // resumed flag ensures the continuation is only ever called once.
            // VNImageRequestHandler.perform() is synchronous: it either calls the
            // completion handler then returns normally, OR throws without calling it.
            // The flag guards against any edge-case double-resume that would otherwise
            // cause a "Fatal error: SWIFT TASK CONTINUATION MISUSE" crash.
            var resumed = false
            func finish(_ result: [String]) {
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: result)
            }
            
            let request = VNRecognizeTextRequest { request, error in
                guard error == nil, let observations = request.results as? [VNRecognizedTextObservation] else {
                    finish([])
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
                
                finish(matched)
            }
            
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                // perform() only throws when it cannot start the request — the
                // completion block will NOT have been called yet in this path.
                finish([])
            }
        }
    }
    
    // Perform layout-level OCR, returning text blocks with their bounding boxes
    func performOCR(on image: UIImage) async -> [TextBlock] {
        guard let cgImage = image.cgImage else { return [] }
        guard !Task.isCancelled else { return [] }
        
        return await withCheckedContinuation { continuation in
            var resumed = false
            func finish(_ result: [TextBlock]) {
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: result)
            }
            
            let request = VNRecognizeTextRequest { request, error in
                guard error == nil, let observations = request.results as? [VNRecognizedTextObservation] else {
                    finish([])
                    return
                }
                
                var blocks: [TextBlock] = []
                for observation in observations {
                    guard let candidate = observation.topCandidates(1).first else { continue }
                    let block = TextBlock(
                        text: candidate.string,
                        boundingBox: observation.boundingBox
                    )
                    blocks.append(block)
                }
                finish(blocks)
            }
            
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["en-US"]
            
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                finish([])
            }
        }
    }
}
