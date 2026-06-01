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
        let doc = PDFDocument(url: url)
        self.currentDocument = doc
        self.currentURL = url
        return doc?.pageCount ?? 0
    }
    
    /// Renders a specific page thread-safely.
    func renderPage(at index: Int, scale: CGFloat) -> UIImage? {
        guard let doc = currentDocument else { return nil }
        guard let page = doc.page(at: index) else { return nil }
        let pageRect = page.bounds(for: .mediaBox)
        guard pageRect.width > 0, pageRect.height > 0 else { return nil }
        
        let size = CGSize(width: pageRect.width * scale, height: pageRect.height * scale)
        
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
        self.currentDocument = nil
        self.currentURL = nil
    }
}
