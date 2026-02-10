import Foundation
import UIKit
import Vision

class ChapterDetector {
    
    static let shared = ChapterDetector()
    
    private let ocrEngine = OCREngine.shared
    
    /// Detects chapters by scanning the top portion of each page for headings.
    /// This is an expensive operation, so it should be run in a background task.
    func detectChapters(in pdf: ConvertedPDF, languages: [String] = ["en-US"], onProgress: ((Double) -> Void)? = nil) async throws -> [Chapter] {
        guard pdf.contentType == .book || pdf.contentType == .hybrid else { return [] }
        
        // 1. Extract Images (This might be slow for large books)
        // Ideally we would stream, but for now we extract to temp.
        let result = try await ZipUtilities.extractComic(from: pdf.url)
        let tempDir = result.workingDir
        let imageURLs = result.imageURLs
        
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        var detectedChapters: [Chapter] = []
        let total = Double(imageURLs.count)
        
        // Regex Patterns for Chapters
        // "Chapter 1", "CHAPTER ONE", "1.", "Prologue", "Epilogue"
        // We look for these at the START of the recognized text.
        let patterns = [
            #"^(?i)chapter\s+\d+"#,             // Chapter 1
            #"^(?i)chapter\s+[IVXLCDM]+"#,      // Chapter IV
            #"^(?i)chapter\s+(one|two|three|four|five|six|seven|eight|nine|ten)"#, // Chapter One
            #"^(?i)prologue"#,
            #"^(?i)epilogue"#,
            #"^\d+\.$"#                        // 1. (on its own line)
        ]
        
        for (index, url) in imageURLs.enumerated() {
            // Check cancellation? (Using Task.checkCancellation in loop)
            try Task.checkCancellation()
            
            // Progress Update
            onProgress?(Double(index) / total)
            
            // Optimization: Only check the top 30% of the image to save memory/time
            guard let image = UIImage(contentsOfFile: url.path) else { continue }
            
            // Crop detailed? No, just OCR the whole image but with Region of Interest?
            // Vision allows setting ROI.
            // Let's use a helper in OCREngine or just crop the UIImage.
            // Cropping UIImage is safer.
            
            let topHeight = image.size.height * 0.3
            let cropRect = CGRect(x: 0, y: 0, width: image.size.width, height: topHeight)
            
            guard let cgImage = image.cgImage?.cropping(to: cropRect) else { continue }
            let croppedImage = UIImage(cgImage: cgImage)
            
            // Fast OCR
            let text = try await ocrEngine.recognizeText(from: croppedImage, level: .fast, languages: languages)
            let lines = text.components(separatedBy: .newlines)
            
            // Check first few lines for match
            for line in lines.prefix(3) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                
                var found = false
                for pattern in patterns {
                    if trimmed.range(of: pattern, options: .regularExpression) != nil {
                        // Found a chapter!
                        let chapter = Chapter(title: trimmed, pageIndex: index)
                        detectedChapters.append(chapter)
                        found = true
                        break
                    }
                }
                if found { break }
            }
        }
        
        onProgress?(1.0)
        return detectedChapters
    }
}
