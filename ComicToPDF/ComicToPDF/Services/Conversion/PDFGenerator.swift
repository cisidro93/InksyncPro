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
        let total = Double(images.count)
        var current = 0.0
        
        let sourceImages = mangaMode ? images.reversed() : images
        
        // Crown Jewel: Target dimensions for Kindle Fixed Layout (1200x1800)
        let targetSize = CGSize(width: 1200, height: 1800)
        let format = UIGraphicsPDFRendererFormat()
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: targetSize), format: format)
        
        // Track generated ToC pages
        var tocText = "Table of Contents\n\n"
        var hasValidChapters = false
        
        try renderer.writePDF(to: outputURL) { context in
            for (index, imageURL) in sourceImages.enumerated() {
                autoreleasepool {
                    guard let image = UIImage(contentsOfFile: imageURL.path) else {
                        Logger.shared.log("Skipping bad image: \(imageURL.lastPathComponent)", category: "PDF", type: .warning)
                        return
                    }
                    
                    context.beginPage()
                    
                    // Aspect Fit Calculation
                    let imgSize = image.size
                    let hRatio = targetSize.width / imgSize.width
                    let vRatio = targetSize.height / imgSize.height
                    let scale = min(hRatio, vRatio)
                    
                    let drawnSize = CGSize(width: imgSize.width * scale, height: imgSize.height * scale)
                    let origin = CGPoint(
                        x: (targetSize.width - drawnSize.width) / 2.0,
                        y: (targetSize.height - drawnSize.height) / 2.0
                    )
                    
                    // Draw white background
                    UIColor.white.setFill()
                    context.fill(context.pdfContextBounds)
                    
                    image.draw(in: CGRect(origin: origin, size: drawnSize))
                    
                    // Progress
                    current += 1
                    progress?(current / total)
                }
            }
            
            // --- Table of Contents Text Page Generation ---
            if let chapterList = chapters, !chapterList.isEmpty, images.count > 0 {
                hasValidChapters = true
                for chapter in chapterList {
                    let actualIndex = mangaMode ? (images.count - 1 - chapter.pageIndex) : chapter.pageIndex
                    let safeIndex = max(0, min(actualIndex, images.count - 1))
                    let displayPageNum = safeIndex + 1
                    tocText += "\(chapter.title)........ Page \(displayPageNum)\n"
                }
                
                context.beginPage()
                
                // Draw physical ToC text
                UIColor.white.setFill()
                context.fill(context.pdfContextBounds)
                
                let paragraphStyle = NSMutableParagraphStyle()
                paragraphStyle.alignment = .left
                paragraphStyle.lineSpacing = 10
                
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 24, weight: .medium),
                    .foregroundColor: UIColor.black,
                    .paragraphStyle: paragraphStyle
                ]
                
                let attributedText = NSAttributedString(string: tocText, attributes: attributes)
                let textRect = CGRect(x: 40, y: 60, width: targetSize.width - 80, height: targetSize.height - 120)
                
                if let firstLineBreak = tocText.firstIndex(of: "\n") {
                    let titleEndIndex = tocText.distance(from: tocText.startIndex, to: firstLineBreak)
                    let mutableAttr = NSMutableAttributedString(attributedString: attributedText)
                    mutableAttr.addAttributes([.font: UIFont.systemFont(ofSize: 32, weight: .bold)], range: NSRange(location: 0, length: titleEndIndex))
                    mutableAttr.draw(in: textRect)
                } else {
                    attributedText.draw(in: textRect)
                }
            }
        }
        
        // --- Table of Contents Outline Injection ---
        // Inject outline metadata AFTER the file is flushed to disk to prevent RAM bloat
        // Loading an existing PDF via URL is heavily optimized by PDFKit vs manually building thousands of pages
        if hasValidChapters, let chapterList = chapters, let pdfDocument = PDFDocument(url: outputURL) {
            let outlineRoot = PDFOutline()
            for chapter in chapterList {
                let actualIndex = mangaMode ? (images.count - 1 - chapter.pageIndex) : chapter.pageIndex
                let safeIndex = max(0, min(actualIndex, pdfDocument.pageCount - 1))
                
                if let destinationPage = pdfDocument.page(at: safeIndex) {
                    let outlineItem = PDFOutline()
                    outlineItem.label = chapter.title
                    outlineItem.destination = PDFDestination(page: destinationPage, at: CGPoint(x: 0, y: destinationPage.bounds(for: .mediaBox).height))
                    outlineRoot.insertChild(outlineItem, at: outlineRoot.numberOfChildren)
                }
            }
            
            // Add Physical ToC to Outline
            if let tocPage = pdfDocument.page(at: pdfDocument.pageCount - 1) {
                let tocOutline = PDFOutline()
                tocOutline.label = "Table of Contents"
                tocOutline.destination = PDFDestination(page: tocPage, at: CGPoint(x: 0, y: tocPage.bounds(for: .mediaBox).height))
                outlineRoot.insertChild(tocOutline, at: outlineRoot.numberOfChildren)
            }
            
            pdfDocument.outlineRoot = outlineRoot
            pdfDocument.write(to: outputURL)
        }
        
        Logger.shared.log("Generated Optimized PDF at \(outputURL.path)", category: "PDF", type: .success)
    }
}
