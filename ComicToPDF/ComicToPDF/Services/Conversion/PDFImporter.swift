import PDFKit
import UIKit
import Foundation

/// PDF Import Engine: Extracts pages from PDF documents as high-resolution images
class PDFImporter {
    
    /// Import PDF and extract all pages as images
    /// - Parameters:
    ///   - url: PDF file URL
    ///   - dpi: Rendering resolution (default 300 for print quality)
    ///   - compressionQuality: JPEG compression quality
    /// - Returns: Array of UIImages, one per page
    func importPDF(url: URL, dpi: CGFloat = 300, compressionQuality: CompressionPreset = .balanced) async throws -> [UIImage] {
        guard let pdf = PDFDocument(url: url) else {
            throw ImportError.invalidPDF
        }
        
        let pageCount = pdf.pageCount
        guard pageCount > 0 else {
            throw ImportError.emptyPDF
        }
        
        var extractedImages: [UIImage] = []
        
        for pageIndex in 0..<pageCount {
            guard let page = pdf.page(at: pageIndex) else {
                // Skip corrupted pages
                continue
            }
            
            let image = renderPage(page, dpi: dpi)
            extractedImages.append(image)
        }
        
        guard !extractedImages.isEmpty else {
            throw ImportError.extractionFailed
        }
        
        return extractedImages
    }
    
    /// Extract single page thumbnail for preview
    func extractPageThumbnail(url: URL, pageIndex: Int, maxSize: CGSize = CGSize(width: 400, height: 600)) async throws -> UIImage? {
        guard let pdf = PDFDocument(url: url),
              pageIndex < pdf.pageCount,
              let page = pdf.page(at: pageIndex) else {
            return nil
        }
        
        let pageBounds = page.bounds(for: .mediaBox)
        let scale = min(maxSize.width / pageBounds.width, maxSize.height / pageBounds.height)
        let scaledSize = CGSize(width: pageBounds.width * scale, height: pageBounds.height * scale)
        
        let renderer = UIGraphicsImageRenderer(size: scaledSize)
        return renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: scaledSize))
            
            context.cgContext.translateBy(x: 0, y: scaledSize.height)
            context.cgContext.scaleBy(x: scale, y: -scale)
            
            page.draw(with: .mediaBox, to: context.cgContext)
        }
    }
    
    /// Detect if PDF has text layer (for books vs scanned images)
    func hasTextContent(url: URL, samplePageCount: Int = 5) -> Bool {
        guard let pdf = PDFDocument(url: url) else {
            return false
        }
        
        let pagesToCheck = min(samplePageCount, pdf.pageCount)
        var textFound = false
        
        for pageIndex in 0..<pagesToCheck {
            guard let page = pdf.page(at: pageIndex),
                  let text = page.string,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            
            // Check if text contains actual words (not just OCR artifacts)
            let words = text.components(separatedBy: .whitespacesAndNewlines)
                .filter { $0.count > 2 }
            
            if words.count > 10 {
                textFound = true
                break
            }
        }
        
        return textFound
    }
    
    // MARK: - Private Helpers
    
    /// Render a PDF page at specified DPI
    private func renderPage(_ page: PDFPage, dpi: CGFloat) -> UIImage {
        let pageBounds = page.bounds(for: .mediaBox)
        let scale = dpi / 72.0  // PDF default is 72 DPI
        
        let scaledSize = CGSize(
            width: pageBounds.width * scale,
            height: pageBounds.height * scale
        )
        
        let renderer = UIGraphicsImageRenderer(size: scaledSize)
        return renderer.image { context in
            // White background
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: scaledSize))
            
            // Transform coordinate system (PDF uses bottom-left origin)
            context.cgContext.translateBy(x: 0, y: scaledSize.height)
            context.cgContext.scaleBy(x: scale, y: -scale)
            
            // Render PDF page
            page.draw(with: .mediaBox, to: context.cgContext)
        }
    }
    
    // MARK: - Errors
    
    enum ImportError: LocalizedError {
        case invalidPDF
        case emptyPDF
        case extractionFailed
        case pageNotFound
        
        var errorDescription: String? {
            switch self {
            case .invalidPDF:
                return "Unable to open PDF file. The file may be corrupted or password-protected."
            case .emptyPDF:
                return "PDF contains no pages"
            case .extractionFailed:
                return "Failed to extract pages from PDF"
            case .pageNotFound:
                return "Requested page does not exist"
            }
        }
    }
}
