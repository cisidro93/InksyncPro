import PDFKit
import UIKit
import Foundation

/// PDF Import Engine: Extracts pages from PDF documents as high-resolution images
struct PDFImporter: Sendable {
    
    /// Get total page count
    func getPageCount(url: URL) -> Int {
        guard let pdf = PDFDocument(url: url) else { return 0 }
        return pdf.pageCount
    }
    
    /// Extract a single page as an image (Memory Safe)
    func extractPage(url: URL, pageIndex: Int, dpi: CGFloat = 300) throws -> UIImage {
        // use autoreleasepool block in caller if doing tight loop
        guard let pdf = PDFDocument(url: url) else { throw ImportError.invalidPDF }
        guard let page = pdf.page(at: pageIndex) else { throw ImportError.pageNotFound }
        return renderPage(page, dpi: dpi)
    }
    
    /// Legacy: Import all (WARNING: High Memory Usage)
    func importPDF(url: URL, dpi: CGFloat = 300, compressionQuality: CompressionPreset = .balanced) async throws -> [UIImage] {
        guard let pdf = PDFDocument(url: url) else { throw ImportError.invalidPDF }
        let pageCount = pdf.pageCount
        guard pageCount > 0 else { throw ImportError.emptyPDF }
        
        var extractedImages: [UIImage] = []
        
        for pageIndex in 0..<pageCount {
            if let page = pdf.page(at: pageIndex) {
                let image = renderPage(page, dpi: dpi)
                extractedImages.append(image)
            }
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
        
        var pageBounds = page.bounds(for: .mediaBox)
        if pageBounds.width <= 0 || pageBounds.height <= 0 || pageBounds.width.isNaN || pageBounds.height.isNaN {
            pageBounds = CGRect(x: 0, y: 0, width: 400, height: 600) // Safe fallback
        }
        let scale = min(maxSize.width / pageBounds.width, maxSize.height / pageBounds.height)
        let scaledSize = CGSize(width: pageBounds.width * scale, height: pageBounds.height * scale)
        guard scaledSize.width > 0 && scaledSize.height > 0 && !scaledSize.width.isNaN && !scaledSize.height.isNaN else {
            return nil
        }
        
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.preferredRange = .standard // Forces standard sRGB color space
        let renderer = UIGraphicsImageRenderer(size: scaledSize, format: format)
        return renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: scaledSize))
            
            context.cgContext.translateBy(x: 0, y: scaledSize.height)
            context.cgContext.scaleBy(x: scale, y: -scale)
            
            page.draw(with: .mediaBox, to: context.cgContext)
        }
    }
    
    /// Detect if PDF has text layer (for books vs scanned images)
    func hasTextContent(url: URL, samplePageCount: Int = 8) -> Bool {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

        guard let pdf = PDFDocument(url: url), pdf.pageCount > 0 else {
            Logger.shared.log("PDFImporter.hasTextContent: Could not open PDF or document is empty for '\(url.lastPathComponent)'", category: "ContentType", type: .warning)
            return false
        }
        
        let total = pdf.pageCount
        var indicesToCheck: [Int] = []
        
        if total <= samplePageCount {
            indicesToCheck = Array(0..<total)
        } else {
            // Intelligent spread: check front matter, middle chapters, and body pages
            let steps = [0.05, 0.10, 0.20, 0.35, 0.50, 0.65, 0.80, 0.90]
            for step in steps {
                let idx = min(Int(Double(total) * step), total - 1)
                if !indicesToCheck.contains(idx) {
                    indicesToCheck.append(idx)
                }
            }
            // Always include page 5 or 10 if available
            if total > 5 && !indicesToCheck.contains(5) { indicesToCheck.append(5) }
            if total > 15 && !indicesToCheck.contains(15) { indicesToCheck.append(15) }
        }
        
        for pageIndex in indicesToCheck {
            guard let page = pdf.page(at: pageIndex),
                  let text = page.string,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            
            // Check if text contains actual words (not just OCR artifacts)
            let words = text.components(separatedBy: .whitespacesAndNewlines)
                .filter { $0.count > 2 }
            
            if words.count > 10 {
                Logger.shared.log("PDFImporter.hasTextContent: Text layer confirmed for '\(url.lastPathComponent)' on page \(pageIndex + 1)/\(total) with \(words.count) valid words.", category: "ContentType", type: .info)
                return true
            }
        }
        
        Logger.shared.log("PDFImporter.hasTextContent: No text layer detected for '\(url.lastPathComponent)' across sampled pages \(indicesToCheck.map { $0 + 1 }).", category: "ContentType", type: .info)
        return false
    }
    
    // MARK: - Private Helpers
    
    /// Render a PDF page at specified DPI
    private func renderPage(_ page: PDFPage, dpi: CGFloat) -> UIImage {
        var pageBounds = page.bounds(for: .mediaBox)
        if pageBounds.width <= 0 || pageBounds.height <= 0 || pageBounds.width.isNaN || pageBounds.height.isNaN {
            pageBounds = CGRect(x: 0, y: 0, width: 612, height: 792) // Letter size fallback
        }
        let scale = dpi / 72.0  // PDF default is 72 DPI
        
        var scaledSize = CGSize(
            width: pageBounds.width * scale,
            height: pageBounds.height * scale
        )
        if scaledSize.width <= 0 || scaledSize.height <= 0 || scaledSize.width.isNaN || scaledSize.height.isNaN {
            scaledSize = CGSize(width: 612 * scale, height: 792 * scale)
        }
        
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.preferredRange = .standard // Forces standard sRGB color space
        let renderer = UIGraphicsImageRenderer(size: scaledSize, format: format)
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
