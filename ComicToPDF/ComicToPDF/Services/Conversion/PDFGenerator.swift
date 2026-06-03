import UIKit
import PDFKit

/// Optimization: User Request - Use UIGraphicsPDFRenderer for better memory management
struct PDFGenerator: Sendable {
    
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
    static func generate(from images: [URL], to outputURL: URL, mangaMode: Bool = false, chapters: [Chapter]? = nil, settings: ConversionSettings, coverOverrideData: Data? = nil, progress: (@Sendable (Double) -> Void)? = nil) throws {
        let total = Double(images.count)
        var current = 0.0
        
        let sourceImages = mangaMode ? images.reversed() : images
        
        // Format is initialized, but bounds will be set per-page dynamically
        let format = UIGraphicsPDFRendererFormat()
        let renderer = UIGraphicsPDFRenderer(bounds: .zero, format: format)
        
        var hasValidChapters = false
        var fallbackTargetSize = settings.targetDeviceProfile.resolution ?? CGSize(width: 1200, height: 1800)
        var tocLinks: [(rect: CGRect, targetPage: Int)] = []
        
        try renderer.writePDF(to: outputURL) { context in
            for (index, imageURL) in sourceImages.enumerated() {
                autoreleasepool {
                    let image: UIImage?
                    if index == 0, let overrideImage = coverOverrideData, let uiImage = UIImage(data: overrideImage) {
                        image = uiImage
                    } else {
                        image = UIImage(contentsOfFile: imageURL.path)
                    }
                    
                    guard let safeImage = image else {
                        Logger.shared.log("Skipping bad image: \(imageURL.lastPathComponent)", category: "PDF", type: .warning)
                        return
                    }
                    
                    // Apply E-Ink Filtering and Scaling
                    let targetProfile = settings.targetDeviceProfile
                    let applyEInkFilter = settings.imageEnhancement.grayscale
                    let cropMargins = settings.trimMargins
                    let reduceMoire = settings.imageEnhancement.reduceMoire
                    let dither = settings.imageEnhancement.ditheringEnabled
                    
                    let optimizedImage = EInkOptimizer.shared.processImage(
                        safeImage,
                        for: targetProfile,
                        applyGrayscale: applyEInkFilter,
                        cropMargins: cropMargins,
                        reduceMoire: reduceMoire,
                        dither: dither,
                        marginOffset: settings.bindingMarginOffset,
                        marginSide: settings.bindingMarginSide,
                        isOddPage: index % 2 == 0
                    )
                    
                    let targetSize = targetProfile.resolution ?? optimizedImage.size
                    fallbackTargetSize = targetSize
                    let pageRect = CGRect(origin: .zero, size: targetSize)
                    
                    context.beginPage(withBounds: pageRect, pageInfo: [:])
                    
                    // Add Internal Anchor for Hyperlinking
                    let displayPageNum = index + 1
                    if let url = URL(string: "page://\(displayPageNum)") {
                        context.setURL(url, for: pageRect)
                    }
                    
                    // Aspect Fit Calculation
                    let imgSize = optimizedImage.size
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
                    context.fill(pageRect)
                    
                    // ✅ Fix (KCC Optimization): 
                    // UIGraphicsPDFRenderer defaults to JPEG wrappers for UIImages which bloats 
                    // B&W manga from 200MB to 800MB+. We forcefully coerce the image to PNG Data first.
                    if let pngData = optimizedImage.pngData(), let pngImage = UIImage(data: pngData) {
                        pngImage.draw(in: CGRect(origin: origin, size: drawnSize))
                    } else {
                        // Fallback
                        optimizedImage.draw(in: CGRect(origin: origin, size: drawnSize))
                    }
                    
                    // Progress
                    current += 1
                    progress?(current / total)
                }
            }
            
            // --- Table of Contents Text Page Generation ---
            if let chapterList = chapters, !chapterList.isEmpty, images.count > 0 {
                hasValidChapters = true
                
                let tocPageRect = CGRect(origin: .zero, size: fallbackTargetSize)
                context.beginPage(withBounds: tocPageRect, pageInfo: [:])
                
                // Draw physical ToC text
                UIColor.white.setFill()
                context.fill(tocPageRect)
                
                let paragraphStyle = NSMutableParagraphStyle()
                paragraphStyle.alignment = .left
                paragraphStyle.lineSpacing = 16
                
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 24, weight: .medium),
                    .foregroundColor: UIColor.black,
                    .paragraphStyle: paragraphStyle
                ]
                
                let titleAttributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 40, weight: .bold),
                    .foregroundColor: UIColor.black,
                    .paragraphStyle: paragraphStyle
                ]
                
                var currentY: CGFloat = 60
                let marginX: CGFloat = 60
                let textWidth = fallbackTargetSize.width - (marginX * 2)
                
                // Draw Header
                let titleString = NSAttributedString(string: "Table of Contents\n\n", attributes: titleAttributes)
                let titleRect = CGRect(x: marginX, y: currentY, width: textWidth, height: 100)
                titleString.draw(in: titleRect)
                currentY += 100
                
                // Draw Entries & Register Links
                for chapter in chapterList {
                    let actualIndex = mangaMode ? (images.count - 1 - chapter.pageIndex) : chapter.pageIndex
                    let safeIndex = max(0, min(actualIndex, images.count - 1))
                    let displayPageNum = safeIndex + 1
                    
                    let lineText = "\(chapter.title)........ Page \(displayPageNum)"
                    let lineAttr = NSAttributedString(string: lineText, attributes: attributes)
                    
                    // Measure line height roughly
                    let boundingBox = lineAttr.boundingRect(with: CGSize(width: textWidth, height: .greatestFiniteMagnitude), options: .usesLineFragmentOrigin, context: nil)
                    let lineRect = CGRect(x: marginX, y: currentY, width: textWidth, height: boundingBox.height)
                    
                    lineAttr.draw(in: lineRect)
                    
                    // Register interactive bounding box
                    tocLinks.append((rect: lineRect, targetPage: displayPageNum))
                    currentY += boundingBox.height + paragraphStyle.lineSpacing
                }
            }
        }
        
        // --- Table of Contents Outline Injection ---
        // 🚨 COMPETITOR HARDENING FIX: Cap PDFKit injection at 150MB to prevent Jetsam crashes on Omnibus files.
        let fileAttributes = try? FileManager.default.attributesOfItem(atPath: outputURL.path)
        let rawFileSize = fileAttributes?[.size] as? Int64 ?? 0
        let isSafeSize = rawFileSize <= (150 * 1024 * 1024)
        
        if hasValidChapters, let chapterList = chapters {
            if !isSafeSize {
                Logger.shared.log("⚠️ Skipping PDF ToC Injection: File exceeds safe memory bounds (\(rawFileSize / 1024 / 1024)MB).", category: "PDF", type: .warning)
            } else {
                ConcurrencyLocks.pdfLock.withLock {
                    guard let pdfDocument = PDFDocument(url: outputURL) else { return }
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
                        
                        // 🔗 Inject Tap Link Annotations into the ToC Page
                        for link in tocLinks {
                            // PDF coordinates are flipped (Origin at bottom-left)
                            let pdfY = tocPage.bounds(for: .mediaBox).height - link.rect.maxY
                            let annotationRect = CGRect(x: link.rect.minX, y: pdfY, width: link.rect.width, height: link.rect.height)
                            
                            // Create an invisible hyperlink annotation
                            let linkAnnotation = PDFAnnotation(bounds: annotationRect, forType: .link, withProperties: nil)
                            
                            // Point annotation to target page
                            if let targetPDFPage = pdfDocument.page(at: link.targetPage - 1) {
                                let destination = PDFDestination(page: targetPDFPage, at: CGPoint(x: 0, y: targetPDFPage.bounds(for: .mediaBox).height))
                                linkAnnotation.action = PDFActionGoTo(destination: destination)
                                tocPage.addAnnotation(linkAnnotation)
                            }
                        }
                    }
                    
                    pdfDocument.outlineRoot = outlineRoot
                    let tempURL = outputURL.deletingPathExtension().appendingPathExtension("tmp.pdf")
                    if pdfDocument.write(to: tempURL) {
                        try? FileManager.default.removeItem(at: outputURL)
                        try? FileManager.default.moveItem(at: tempURL, to: outputURL)
                    } else {
                        Logger.shared.log("Failed to write PDF with outlines, file size might be 0 bytes.", category: "PDF", type: .error)
                    }
                }
            }   
        } // Close outer `if hasValidChapters`
        
        Logger.shared.log("Generated Optimized PDF at \(outputURL.path)", category: "PDF", type: .success)
    }
}
