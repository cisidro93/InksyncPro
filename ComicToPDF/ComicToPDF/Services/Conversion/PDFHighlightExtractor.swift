import PDFKit
import UIKit

final class PDFHighlightExtractor {
    static let shared = PDFHighlightExtractor()
    private init() {}
    
    func extractHighlights(from fileURL: URL, pdfID: UUID) -> [Annotation] {
        guard let document = PDFDocument(url: fileURL) else { return [] }
        var extracted: [Annotation] = []
        
        let pageCount = document.pageCount
        for pageIndex in 0..<pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            let pageAnnotations = page.annotations
            
            for ann in pageAnnotations {
                // Standard PDF highlight subtype is "/Highlight" or "Highlight"
                guard ann.subtype == "/Highlight" || ann.subtype == "Highlight" else { continue }
                
                let pageBounds = page.bounds(for: .mediaBox)
                let annBounds = ann.bounds
                
                // Normalize bounds relative to page (0.0 to 1.0)
                let normX = pageBounds.width > 0 ? Double(annBounds.origin.x / pageBounds.width) : 0.0
                let normY = pageBounds.height > 0 ? Double(annBounds.origin.y / pageBounds.height) : 0.0
                let normW = pageBounds.width > 0 ? Double(annBounds.width / pageBounds.width) : 1.0
                let normH = pageBounds.height > 0 ? Double(annBounds.height / pageBounds.height) : 1.0
                let bounds = CodableCGRect(x: normX, y: normY, width: normW, height: normH)
                
                var selectedText: String? = nil
                if let selection = page.selection(for: annBounds) {
                    selectedText = selection.string
                }
                
                let color = ann.color ?? UIColor.yellow
                let hexColor = color.toHexString()
                let noteText = ann.contents
                
                let dto = Annotation(
                    id: UUID(),
                    pdfID: pdfID,
                    pageIndex: pageIndex,
                    chapterTitle: nil,
                    kind: .highlight,
                    createdAt: Date(),
                    modifiedAt: Date(),
                    colorHex: hexColor,
                    selectedText: selectedText,
                    noteText: noteText,
                    tags: [],
                    bounds: bounds
                )
                extracted.append(dto)
            }
        }
        return extracted
    }
}

fileprivate extension UIColor {
    func toHexString() -> String {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        
        self.getRed(&r, green: &g, blue: &b, alpha: &a)
        
        let rgb: Int = (Int)(r*255)<<16 | (Int)(g*255)<<8 | (Int)(b*255)<<0
        return String(format: "#%06x", rgb)
    }
}
