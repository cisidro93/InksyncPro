import UIKit
import PDFKit

/// Optimization: User Request - Use UIGraphicsPDFRenderer for better memory management
class PDFGenerator {
    
    enum PDFError: LocalizedError {
        case outputCreationFailed
        case imageLoadFailed
        
        var errorDescription: String? {
            switch self {
            case .outputCreationFailed: return "Could not create PDF context"
            case .imageLoadFailed: return "Failed to load image for PDF"
            }
        }
    }
    
    /// Generate a PDF from a list of images using PDFDocument to preserve compression
    /// - Parameters:
    ///   - images: Ordered list of image URLs (local storage)
    ///   - outputURL: Destination URL
    ///   - progress: Progress callback
    static func generate(from images: [URL], to outputURL: URL, progress: ((Double) -> Void)? = nil) throws {
        let pdfDocument = PDFDocument()
        let total = Double(images.count)
        var current = 0.0
        
        for (index, imageURL) in images.enumerated() {
            autoreleasepool {
                guard let image = UIImage(contentsOfFile: imageURL.path),
                      let pdfPage = PDFPage(image: image) else {
                    Logger.shared.log("Skipping bad image: \(imageURL.lastPathComponent)", category: "PDF", type: .warning)
                    return
                }
                
                pdfDocument.insert(pdfPage, at: index)
                
                // Progress
                current += 1
                progress?(current / total)
            }
        }
        
        // Write the optimized PDF
        guard pdfDocument.write(to: outputURL) else {
            throw PDFError.outputCreationFailed
        }
        
        Logger.shared.log("Generated Optimized PDF with \(pdfDocument.pageCount) pages at \(outputURL.path)", category: "PDF", type: .success)
    }
}
