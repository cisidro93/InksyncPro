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
    ///   - mangaMode: If true, reverses page order for RTL reading
    ///   - chapters: Optional list of chapters for Table of Contents generation
    ///   - progress: Progress callback
    static func generate(from images: [URL], to outputURL: URL, mangaMode: Bool = false, chapters: [Chapter]? = nil, progress: ((Double) -> Void)? = nil) throws {
        let pdfDocument = PDFDocument()
        let total = Double(images.count)
        var current = 0.0
        
        let sourceImages = mangaMode ? images.reversed() : images
        
        for (index, imageURL) in sourceImages.enumerated() {
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
        
        // --- Table of Contents Generation ---
        if let chapters = chapters, !chapters.isEmpty && pdfDocument.pageCount > 0 {
            let outlineRoot = PDFOutline()
            var tocText = "Table of Contents\n\n"
            
            for chapter in chapters {
                // Calculate actual page index in the PDF
                // If mangaMode is true, a chapter starting at original index 5 in a 100-page book 
                // becomes page 94 (100 - 1 - 5)
                let actualIndex = mangaMode ? (images.count - 1 - chapter.pageIndex) : chapter.pageIndex
                
                // Ensure index is within valid bounds
                let safeIndex = max(0, min(actualIndex, pdfDocument.pageCount - 1))
                
                if let destinationPage = pdfDocument.page(at: safeIndex) {
                    // 1. Add to PDF Metadata Outline (for Kindle ToC Menu)
                    let outlineItem = PDFOutline(title: chapter.title)
                    outlineItem.destination = PDFDestination(page: destinationPage, at: CGPoint(x: 0, y: destinationPage.bounds(for: .mediaBox).height))
                    outlineRoot.insertChild(outlineItem, at: outlineRoot.numberOfChildren)
                    
                    // 2. Add to physical ToC text page
                    let displayPageNum = safeIndex + 1
                    tocText += "\(chapter.title)........ Page \(displayPageNum)\n"
                }
            }
            
            pdfDocument.outlineRoot = outlineRoot
            
            // Generate Physical ToC Page and insert at the very end
            if let tocPage = createTextPage(text: tocText, size: pdfDocument.page(at: 0)?.bounds(for: .mediaBox).size ?? CGSize(width: 800, height: 1200)) {
                pdfDocument.insert(tocPage, at: pdfDocument.pageCount)
                // Add ToC itself to the outline menu
                let tocOutline = PDFOutline(title: "Table of Contents")
                tocOutline.destination = PDFDestination(page: tocPage, at: CGPoint(x: 0, y: tocPage.bounds(for: .mediaBox).height))
                outlineRoot.insertChild(tocOutline, at: outlineRoot.numberOfChildren)
            }
        }
        
        
        // Write the optimized PDF
        guard pdfDocument.write(to: outputURL) else {
            throw PDFError.outputCreationFailed
        }
        
        Logger.shared.log("Generated Optimized PDF with \(pdfDocument.pageCount) pages at \(outputURL.path)", category: "PDF", type: .success)
    }
    
    /// Helper to create a physical PDF page containing text
    private static func createTextPage(text: String, size: CGSize) -> PDFPage? {
        let format = UIGraphicsPDFRendererFormat()
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size), format: format)
        
        let data = renderer.pdfData { context in
            context.beginPage()
            
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.alignment = .left
            paragraphStyle.lineSpacing = 10
            
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 24, weight: .medium),
                .foregroundColor: UIColor.black,
                .paragraphStyle: paragraphStyle
            ]
            
            let attributedText = NSAttributedString(string: text, attributes: attributes)
            
            // Add padding
            let textRect = CGRect(x: 40, y: 60, width: size.width - 80, height: size.height - 120)
            
            // Calculate title bounds to bold the first line differently
            if let firstLineBreak = text.firstIndex(of: "\n") {
                let titleEndIndex = text.distance(from: text.startIndex, to: firstLineBreak)
                let mutableAttr = NSMutableAttributedString(attributedString: attributedText)
                mutableAttr.addAttributes([.font: UIFont.systemFont(ofSize: 32, weight: .bold)], range: NSRange(location: 0, length: titleEndIndex))
                mutableAttr.draw(in: textRect)
            } else {
                attributedText.draw(in: textRect)
            }
        }
        
        if let doc = PDFDocument(data: data), let page = doc.page(at: 0) {
            return page
        }
        return nil
    }
}
