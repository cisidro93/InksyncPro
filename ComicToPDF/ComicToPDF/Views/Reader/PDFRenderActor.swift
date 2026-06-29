import UIKit
import PDFKit

/// Background Actor to serialize PDFKit page fetching and image rendering,
/// preventing concurrent access crashes on the non-thread-safe PDFDocument.
actor PDFRenderActor {
    static let shared = PDFRenderActor()
    
    private init() {}
    
    
    private var currentDocument: PDFDocument?
    private var currentURL: URL?
    
    /// Loads a PDF document thread-safely. Returns page count.
    func loadDocument(at url: URL) -> Int {
        if currentURL == url, let doc = currentDocument {
            return doc.pageCount
        }
        
        Logger.shared.log("Loading PDF document from \(url.lastPathComponent)", category: "PDFRenderActor", type: .info)
        
        let doc = PDFDocument(url: url)
        guard let doc = doc else {
            Logger.shared.log("Failed to load PDF document from \(url.lastPathComponent). Corrupt or inaccessible file.", category: "PDFRenderActor", type: .error)
            return 0
        }
        
        self.currentDocument = doc
        self.currentURL = url
        Logger.shared.log("Successfully loaded PDF with \(doc.pageCount) pages.", category: "PDFRenderActor", type: .success)
        return doc.pageCount
    }
    
    /// Renders a specific page thread-safely.
    func renderPage(at index: Int, scale: CGFloat) -> UIImage? {
        guard let doc = currentDocument else {
            Logger.shared.log("Attempted to render page \(index) but currentDocument is nil.", category: "PDFRenderActor", type: .error)
            return nil
        }
        guard let page = doc.page(at: index) else {
            Logger.shared.log("Page index \(index) is out of bounds (total pages: \(doc.pageCount)).", category: "PDFRenderActor", type: .warning)
            return nil
        }
        let pageRect = page.bounds(for: .mediaBox)
        guard pageRect.width > 0 && pageRect.height > 0 && !pageRect.width.isNaN && !pageRect.height.isNaN && scale > 0 && !scale.isNaN else {
            Logger.shared.log("Page index \(index) has invalid/zero bounds or scale (width: \(pageRect.width), height: \(pageRect.height), scale: \(scale)).", category: "PDFRenderActor", type: .warning)
            return nil
        }
        
        let size = CGSize(width: pageRect.width * scale, height: pageRect.height * scale)
        guard size.width > 0 && size.height > 0 && !size.width.isNaN && !size.height.isNaN else {
            Logger.shared.log("Computed render size for page index \(index) is invalid: \(size).", category: "PDFRenderActor", type: .warning)
            return nil
        }
        
        return autoreleasepool {
            let renderer = UIGraphicsImageRenderer(size: size)
            return renderer.image { ctx in
                let cgCtx = ctx.cgContext
                cgCtx.setFillColor(UIColor.white.cgColor)
                cgCtx.fill(CGRect(origin: .zero, size: size))
                cgCtx.translateBy(x: 0, y: size.height)
                cgCtx.scaleBy(x: scale, y: -scale)
                page.draw(with: .mediaBox, to: cgCtx)
            }
        }
    }
    
    /// Clears the cached document to release resources.
    func clear() {
        if let url = currentURL {
            Logger.shared.log("Releasing PDF document resource for \(url.lastPathComponent)", category: "PDFRenderActor", type: .info)
        }
        self.currentDocument = nil
        self.currentURL = nil
    }
}
