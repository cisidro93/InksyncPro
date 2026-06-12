import Foundation
import PencilKit
import Vision
import UIKit

/// Performs high-performance, local offline handwriting recognition on PencilKit drawings.
/// Works asynchronously off the main thread to ensure smooth user interactions.
final class HandwritingOCRManager: Sendable {
    static let shared = HandwritingOCRManager()
    
    private init() {}
    
    /// Recognizes handwritten text inside a `PKDrawing`.
    /// - Parameter drawing: The PencilKit drawing to analyze.
    /// - Returns: A String containing the recognized text lines, or nil if recognition failed.
    func recognizeHandwriting(in drawing: PKDrawing) async -> String? {
        guard !drawing.bounds.isEmpty else { return "" }
        
        // Renders the drawing strokes. Scale 2.0 provides good detail without excessive memory usage.
        // PKDrawing.image(from:scale:) is thread-safe on iOS 13+ and runs off the main thread successfully.
        let image = drawing.image(from: drawing.bounds, scale: 2.0)
        guard let cgImage = image.cgImage else { return nil }
        
        let request = VNRecognizeTextRequest()
        
        // Best settings for local handwriting recognition
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        
        #if os(iOS)
        if #available(iOS 16.0, *) {
            request.recognitionLanguages = ["en-US"]
        }
        #endif
        
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
            guard let observations = request.results else { return "" }
            
            // Collect lines of text, ordered top-to-bottom, left-to-right by default from Vision.
            let lines = observations.compactMap { observation in
                observation.topCandidates(1).first?.string
            }
            
            return lines.joined(separator: "\n")
        } catch {
            Logger.shared.log("Handwriting OCR request perform failed: \(error.localizedDescription)", category: "OCR", type: .error)
            return nil
        }
    }
}
