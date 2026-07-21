import UIKit
import PDFKit

/// Background Actor to serialize PDFKit page fetching and image rendering,
/// preventing concurrent access crashes on the non-thread-safe PDFDocument.
actor PDFRenderActor {
    static let shared = PDFRenderActor()
    
    private init() {}
    
    private var currentDocument: PDFDocument?
    private var currentURL: URL?
    private var accessingResource = false
    
    /// Loads a PDF document thread-safely. Returns page count.
    /// - Parameter externalAccessing: If true, the caller already holds security scope access.
    func loadDocument(at url: URL, externalAccessing: Bool = false) -> Int {
        if currentURL == url, let doc = currentDocument {
            return doc.pageCount
        }
        
        if accessingResource, let oldURL = currentURL {
            oldURL.stopAccessingSecurityScopedResource()
            accessingResource = false
        }
        
        Logger.shared.log("Loading PDF document from \(url.lastPathComponent)", category: "PDFRenderActor", type: .info)
        
        let accessing = externalAccessing ? false : url.startAccessingSecurityScopedResource()
        let doc = PDFDocument(url: url)
        guard let doc = doc else {
            if accessing { url.stopAccessingSecurityScopedResource() }
            Logger.shared.log("Failed to load PDF document from \(url.lastPathComponent). Corrupt or inaccessible file.", category: "PDFRenderActor", type: .error)
            return 0
        }
        
        self.currentDocument = doc
        self.currentURL = url
        self.accessingResource = accessing
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
        
        // Cap max pixel dimension at 2048 to prevent memory spikes
        var size = CGSize(width: pageRect.width * scale, height: pageRect.height * scale)
        let maxDim: CGFloat = 2048.0
        if size.width > maxDim || size.height > maxDim {
            let aspect = size.width / size.height
            if aspect > 1.0 {
                size = CGSize(width: maxDim, height: maxDim / aspect)
            } else {
                size = CGSize(width: maxDim * aspect, height: maxDim)
            }
        }
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
                let actualScaleX = size.width / pageRect.width
                let actualScaleY = size.height / pageRect.height
                cgCtx.scaleBy(x: actualScaleX, y: -actualScaleY)
                page.draw(with: .mediaBox, to: cgCtx)
            }
        }
    }
    
    /// Clears the cached document to release resources.
    func clear() {
        if let url = currentURL {
            Logger.shared.log("Releasing PDF document resource for \(url.lastPathComponent)", category: "PDFRenderActor", type: .info)
            if accessingResource {
                url.stopAccessingSecurityScopedResource()
            }
        }
        self.currentDocument = nil
        self.currentURL = nil
        self.accessingResource = false
    }
}
