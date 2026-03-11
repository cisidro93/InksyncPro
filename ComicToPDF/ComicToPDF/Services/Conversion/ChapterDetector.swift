import Foundation
import UIKit
import Vision

/// Detects chapter boundaries by scanning the top of each page using Apple Vision directly.
/// No OCR dependency — uses VNRecognizeTextRequest inline for zero-overhead detection.
class ChapterDetector {
    
    static let shared = ChapterDetector()
    
    /// Detects chapters by scanning the top 30% of each page for heading patterns.
    /// Runs on a background task — never call from the main thread.
    func detectChapters(in pdf: ConvertedPDF, languages: [String] = ["en-US"], onProgress: ((Double) -> Void)? = nil) async throws -> [Chapter] {
        guard pdf.contentType == .book || pdf.contentType == .hybrid else { return [] }
        
        let result = try await ZipUtilities.extractComic(from: pdf.url)
        let tempDir = result.workingDir
        let imageURLs = result.imageURLs
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        var detectedChapters: [Chapter] = []
        let total = Double(imageURLs.count)
        
        // Chapter heading patterns
        let patterns = [
            #"^(?i)chapter\s+\d+"#,
            #"^(?i)chapter\s+[IVXLCDM]+"#,
            #"^(?i)chapter\s+(one|two|three|four|five|six|seven|eight|nine|ten)"#,
            #"^(?i)prologue"#,
            #"^(?i)epilogue"#,
            #"^\d+\.$"#
        ]
        
        for (index, url) in imageURLs.enumerated() {
            try Task.checkCancellation()
            onProgress?(Double(index) / total)
            
            guard let image = UIImage(contentsOfFile: url.path),
                  let cgImage = image.cgImage else { continue }
            
            // Crop to top 30% for speed
            let cropRect = CGRect(x: 0, y: 0,
                                  width: CGFloat(cgImage.width),
                                  height: CGFloat(cgImage.height) * 0.3)
            guard let croppedCG = cgImage.cropping(to: cropRect) else { continue }
            
            // Run Vision text recognition inline — no external dependency
            let text = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                let request = VNRecognizeTextRequest { request, error in
                    if let error = error { continuation.resume(throwing: error); return }
                    let observations = request.results as? [VNRecognizedTextObservation] ?? []
                    let joined = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
                    continuation.resume(returning: joined)
                }
                request.recognitionLevel = .fast
                request.usesLanguageCorrection = false
                request.recognitionLanguages = languages
                
                let handler = VNImageRequestHandler(cgImage: croppedCG, options: [:])
                do { try handler.perform([request]) } catch { continuation.resume(throwing: error) }
            }
            
            let lines = text.components(separatedBy: .newlines)
            outerLoop: for line in lines.prefix(3) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                for pattern in patterns {
                    if trimmed.range(of: pattern, options: .regularExpression) != nil {
                        detectedChapters.append(Chapter(title: trimmed, pageIndex: index))
                        break outerLoop
                    }
                }
            }
        }
        
        onProgress?(1.0)
        Logger.shared.log("ChapterDetector: found \(detectedChapters.count) chapters in \(pdf.name)", category: "Editor")
        return detectedChapters
    }
}
