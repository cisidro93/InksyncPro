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
    
    /// Generate a PDF from a list of images using UIGraphicsPDFRenderer
    /// - Parameters:
    ///   - images: Ordered list of image URLs (local storage)
    ///   - outputURL: Destination URL
    ///   - progress: Progress callback
    static func generate(from images: [URL], to outputURL: URL, progress: ((Double) -> Void)? = nil) throws {
        
        // Define PDF Metadata
        let rendererFormat = UIGraphicsPDFRendererFormat()
        let renderer = UIGraphicsPDFRenderer(bounds: .zero, format: rendererFormat) // Bounds .zero = dynamic page size
        
        let total = Double(images.count)
        var current = 0.0
        
        try renderer.writePDF(to: outputURL) { context in
            for (_, imageURL) in images.enumerated() {
                autoreleasepool {
                    guard let image = UIImage(contentsOfFile: imageURL.path) else {
                        Logger.shared.log("Skipping bad image: \(imageURL.lastPathComponent)", category: "PDF", type: .warning)
                        return
                    }
                    
                    let pageRect = CGRect(origin: .zero, size: image.size)
                    
                    // Begin Page with detected size
                    context.beginPage(withBounds: pageRect, pageInfo: [:])
                    
                    // Draw
                    image.draw(in: pageRect)
                    
                    // Progress
                    current += 1
                    progress?(current / total)
                }
            }
        }
        Logger.shared.log("Generated PDF with \(images.count) pages at \(outputURL.path)", category: "PDF", type: .success)
    }
}
