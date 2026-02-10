import Foundation
import Vision
import UIKit

/// Handles Optical Character Recognition using Apple's Vision framework
class OCREngine {
    
    static let shared = OCREngine()
    
    enum RecognitionLevel {
        case accurate
        case fast
        
        var visionLevel: VNRequestTextRecognitionLevel {
            switch self {
            case .accurate: return .accurate
            case .fast: return .fast
            }
        }
    }
    
    /// Extracts text from a UIImage
    /// - Parameters:
    ///   - image: The source image
    ///   - level: Recognition accuracy (accurate vs fast)
    ///   - languages: Language codes (e.g. ["en-US"])
    /// - Returns: Extracted text as a single string (joined by newlines)
    func recognizeText(from image: UIImage, level: RecognitionLevel = .accurate, languages: [String] = ["en-US"]) async throws -> String {
        guard let cgImage = image.cgImage else {
            throw NSError(domain: "OCREngine", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid Image Data"])
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            // Create Request
            let request = VNRecognizeTextRequest { request, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                
                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: "")
                    return
                }
                
                // Extract top candidate for each observation
                let text = observations.compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
                
                continuation.resume(returning: text)
            }
            
            // Configure Request
            request.recognitionLevel = level.visionLevel
            request.usesLanguageCorrection = true
            request.recognitionLanguages = languages
            
            // Perform Request
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
