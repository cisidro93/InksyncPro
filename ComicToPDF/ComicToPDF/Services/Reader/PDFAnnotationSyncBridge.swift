import Foundation
import PDFKit
import PencilKit
import SwiftUI

// MARK: - Native PDF Annotation Interoperability Bridge

/// Bi-directional synchronization service bridging InkSync Pro's `AnnotationStore`
/// with native standard Adobe/ISO 32000 PDF annotations (`/Ink`, `/Highlight`, `/Text`).
final class PDFAnnotationSyncBridge: Sendable {
    
    static let shared = PDFAnnotationSyncBridge()
    
    init() {}
    
    // MARK: - Apply Inksync Annotations to Live PDFDocument
    
    /// Injects all InkSync Pro highlights, sticky notes, and vector drawings from `AnnotationStore`
    /// directly onto the live `PDFDocument` pages for active reading.
    @MainActor
    func applyStoreAnnotations(for pdfID: UUID, to document: PDFDocument) {
        let storeAnnotations = AnnotationStore.shared.annotations(for: pdfID)
        guard !storeAnnotations.isEmpty else { return }
        
        for annotation in storeAnnotations {
            guard annotation.pageIndex >= 0 && annotation.pageIndex < document.pageCount,
                  let page = document.page(at: annotation.pageIndex) else { continue }
            
            let pageBounds = page.bounds(for: .cropBox)
            
            switch annotation.kind {
            case .highlight, .underline, .strikeOut:
                let nativeType: PDFAnnotationSubtype
                let nativeTypeName: String
                switch annotation.kind {
                case .underline:
                    nativeType = .underline
                    nativeTypeName = "Underline"
                case .strikeOut:
                    nativeType = .strikeOut
                    nativeTypeName = "StrikeOut"
                default:
                    nativeType = .highlight
                    nativeTypeName = "Highlight"
                }

                // Check if this annotation is already attached to the page (prevent duplicates)
                let alreadyPresent = page.annotations.contains { native in
                    guard native.type == nativeTypeName else { return false }
                    if let text = annotation.selectedText, let c = native.contents, !text.isEmpty && c == text {
                        return true
                    }
                    if let b = annotation.bounds {
                        let expected = CGRect(
                            x: pageBounds.minX + (b.x * pageBounds.width),
                            y: pageBounds.minY + (b.y * pageBounds.height),
                            width: b.width * pageBounds.width,
                            height: b.height * pageBounds.height
                        )
                        return native.bounds.insetBy(dx: -4, dy: -4).intersects(expected)
                    }
                    return false
                }
                guard !alreadyPresent else { continue }
                
                let highlightColor: UIColor
                if let hex = annotation.colorHex, let c = UIColor(hexString: hex) {
                    highlightColor = c.withAlphaComponent(annotation.kind == .highlight ? 0.60 : 0.85)
                } else {
                    highlightColor = UIColor.systemYellow.withAlphaComponent(0.55)
                }
                
                var didAdd = false
                
                // Primary: match text exactly on page
                if let text = annotation.selectedText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let matches = page.document?.findString(text, withOptions: .caseInsensitive) ?? []
                    for match in matches where match.pages.contains(page) {
                        let lines = match.selectionsByLine()
                        let targetLines = lines.isEmpty ? [match] : lines
                        let validRects = targetLines.compactMap { $0.bounds(for: page) }.filter { $0 != .zero && $0.width > 2 && $0.height > 2 }
                        guard !validRects.isEmpty else { continue }
                        
                        let unionBox = PDFHighlightGeometryHelper.unionBounds(for: validRects)
                        let nativeHighlight = PDFAnnotation(bounds: unionBox, forType: nativeType, withProperties: nil)
                        nativeHighlight.color = highlightColor
                        nativeHighlight.contents = text
                        nativeHighlight.quadrilateralPoints = PDFHighlightGeometryHelper.createQuadPoints(for: validRects, relativeTo: unionBox)
                        page.addAnnotation(nativeHighlight)
                        didAdd = true
                        break // first matching instance on page
                    }
                }
                
                // Fallback to recorded bounds if text match didn't yield annotations
                if !didAdd {
                    let bounds: CGRect
                    if let b = annotation.bounds {
                        bounds = CGRect(
                            x: pageBounds.minX + (b.x * pageBounds.width),
                            y: pageBounds.minY + (b.y * pageBounds.height),
                            width: b.width * pageBounds.width,
                            height: b.height * pageBounds.height
                        )
                    } else {
                        bounds = CGRect(x: pageBounds.minX + 20, y: pageBounds.maxY - 100, width: pageBounds.width - 40, height: 24)
                    }
                    guard bounds.width > 2, bounds.height > 2 else { continue }
                    let nativeHighlight = PDFAnnotation(bounds: bounds, forType: nativeType, withProperties: nil)
                    nativeHighlight.color = highlightColor
                    nativeHighlight.contents = annotation.selectedText ?? annotation.noteText
                    nativeHighlight.quadrilateralPoints = PDFHighlightGeometryHelper.createQuadPoints(for: bounds)
                    page.addAnnotation(nativeHighlight)
                }
                
            case .note:
                let noteOrigin = CGPoint(x: pageBounds.minX + 30, y: pageBounds.maxY - 80)
                let noteRect = CGRect(origin: noteOrigin, size: CGSize(width: 24, height: 24))
                let nativeText = PDFAnnotation(bounds: noteRect, forType: .text, withProperties: nil)
                nativeText.color = UIColor.systemPurple
                nativeText.contents = annotation.noteText ?? annotation.selectedText ?? ""
                nativeText.iconType = .note
                page.addAnnotation(nativeText)
                
            case .ink:
                if let drawingData = annotation.drawingData,
                   let drawing = try? PKDrawing(data: drawingData) {
                    let nativeInk = PDFAnnotation(bounds: pageBounds, forType: .ink, withProperties: nil)
                    nativeInk.color = UIColor.systemBlue
                    for stroke in drawing.strokes {
                        let bezier = UIBezierPath()
                        var first = true
                        for point in stroke.path {
                            let pt = point.location
                            let pdfPt = CGPoint(x: pt.x, y: pageBounds.height - pt.y)
                            if first {
                                bezier.move(to: pdfPt)
                                first = false
                            } else {
                                bezier.addLine(to: pdfPt)
                            }
                        }
                        nativeInk.add(bezier)
                    }
                    page.addAnnotation(nativeInk)
                }
                
            case .bookmark:
                break
            }
        }
        
        Logger.shared.log("PDFAnnotationSync: Applied \(storeAnnotations.count) annotations onto active PDF document", category: "PDF")
    }

    // MARK: - Sync & Persist to Document Disk Storage
    
    /// Synchronizes all in-memory and SwiftData annotations from `AnnotationStore` directly into the live `PDFDocument`
    /// and writes the updated document back to disk.
    @MainActor
    func syncStoreToDocument(for pdfID: UUID, in document: PDFDocument, at destinationURL: URL? = nil) {
        applyStoreAnnotations(for: pdfID, to: document)
        if let targetURL = destinationURL ?? document.documentURL {
            let didAccess = targetURL.startAccessingSecurityScopedResource()
            defer { if didAccess { targetURL.stopAccessingSecurityScopedResource() } }
            document.write(to: targetURL)
            Logger.shared.log("PDFAnnotationSync: Persisted PDF with annotations to disk at \(targetURL.lastPathComponent)", category: "PDF", type: .success)
        }
    }

    // MARK: - Export Inksync Annotations to Native PDFDocument
    
    /// Writes all InkSync Pro highlights, Pencil drawings, and Adler notes into the `PDFDocument` as native ISO annotations.
    @MainActor
    func exportAnnotations(for pdfID: UUID, to document: PDFDocument) {
        let storeAnnotations = AnnotationStore.shared.annotations(for: pdfID)
        
        for annotation in storeAnnotations {
            guard annotation.pageIndex >= 0 && annotation.pageIndex < document.pageCount,
                  let page = document.page(at: annotation.pageIndex) else { continue }
            
            let pageBounds = page.bounds(for: .cropBox)
            
            switch annotation.kind {
            case .highlight, .underline, .strikeOut:
                let nativeType: PDFAnnotationSubtype
                switch annotation.kind {
                case .underline: nativeType = .underline
                case .strikeOut: nativeType = .strikeOut
                default: nativeType = .highlight
                }
                
                // Create native annotation
                let bounds: CGRect
                if let b = annotation.bounds {
                    bounds = CGRect(
                        x: pageBounds.minX + (b.x * pageBounds.width),
                        y: pageBounds.minY + (b.y * pageBounds.height),
                        width: b.width * pageBounds.width,
                        height: b.height * pageBounds.height
                    )
                } else {
                    bounds = CGRect(x: pageBounds.minX + 20, y: pageBounds.maxY - 100, width: pageBounds.width - 40, height: 24)
                }
                guard bounds.width > 2, bounds.height > 2 else { continue }
                
                let nativeHighlight = PDFAnnotation(bounds: bounds, forType: nativeType, withProperties: nil)
                if let hex = annotation.colorHex, let c = UIColor(hexString: hex) {
                    nativeHighlight.color = c.withAlphaComponent(annotation.kind == .highlight ? 0.60 : 0.85)
                } else {
                    nativeHighlight.color = UIColor.systemYellow.withAlphaComponent(0.55)
                }
                nativeHighlight.contents = annotation.selectedText ?? annotation.noteText
                nativeHighlight.quadrilateralPoints = PDFHighlightGeometryHelper.createQuadPoints(for: bounds)
                page.addAnnotation(nativeHighlight)
                
            case .note:
                // Create native /Text sticky note popup annotation
                let noteOrigin = CGPoint(x: pageBounds.minX + 30, y: pageBounds.maxY - 80)
                let noteRect = CGRect(origin: noteOrigin, size: CGSize(width: 24, height: 24))
                let nativeText = PDFAnnotation(bounds: noteRect, forType: .text, withProperties: nil)
                nativeText.color = UIColor.systemPurple
                nativeText.contents = annotation.noteText ?? annotation.selectedText ?? ""
                nativeText.iconType = .note
                page.addAnnotation(nativeText)
                
            case .ink:
                // Convert PencilKit drawing data to native vector /Ink paths
                if let drawingData = annotation.drawingData,
                   let drawing = try? PKDrawing(data: drawingData) {
                    let nativeInk = PDFAnnotation(bounds: pageBounds, forType: .ink, withProperties: nil)
                    nativeInk.color = UIColor.systemBlue
                    
                    for stroke in drawing.strokes {
                        let bezier = UIBezierPath()
                        var first = true
                        for point in stroke.path {
                            let pt = point.location
                            // Invert Y coordinate for PDF coordinate space if necessary
                            let pdfPt = CGPoint(x: pt.x, y: pageBounds.height - pt.y)
                            if first {
                                bezier.move(to: pdfPt)
                                first = false
                            } else {
                                bezier.addLine(to: pdfPt)
                            }
                        }
                        nativeInk.add(bezier)
                    }
                    page.addAnnotation(nativeInk)
                }
                
            case .bookmark:
                // Bookmarks are handled via document outline/navigation, skip page annotation
                break
            }
        }
        
        Logger.shared.log("PDFAnnotationSync: Exported \(storeAnnotations.count) annotations into native PDF document", category: "PDF")
    }

    // MARK: - Coordinate Helpers (intentionally removed quadrilateralPoints — PDFKit derives them from bounds)
    
    // MARK: - Import Native PDF Annotations into InkSync Pro
    
    /// Scans a `PDFDocument` for third-party native annotations (Acrobat, Preview, Edge)
    /// and imports them into InkSync Pro's `AnnotationStore`.
    @MainActor
    func importNativeAnnotations(from document: PDFDocument, for pdfID: UUID) -> [Annotation] {
        var imported: [Annotation] = []
        let existingIDs = Set(AnnotationStore.shared.annotations(for: pdfID).map { $0.id })
        
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            let pageBounds = page.bounds(for: .cropBox)
            
            for nativeAnn in page.annotations {
                guard let type = nativeAnn.type else { continue }
                
                // Map native annotation types
                var kind: Annotation.AnnotationKind? = nil
                switch type {
                case "Highlight":
                    kind = .highlight
                case "Underline":
                    kind = .underline
                case "StrikeOut":
                    kind = .strikeOut
                case "Text", "FreeText":
                    kind = .note
                case "Ink":
                    kind = .ink
                default:
                    break
                }
                
                guard let mappedKind = kind else { continue }
                
                let boundsNorm = CodableCGRect(
                    x: Double((nativeAnn.bounds.minX - pageBounds.minX) / max(1, pageBounds.width)),
                    y: Double((nativeAnn.bounds.minY - pageBounds.minY) / max(1, pageBounds.height)),
                    width: Double(nativeAnn.bounds.width / max(1, pageBounds.width)),
                    height: Double(nativeAnn.bounds.height / max(1, pageBounds.height))
                )
                
                let colorHex = nativeAnn.color.toHexString()
                let contentText = nativeAnn.contents ?? ""
                
                let newAnnotation = Annotation(
                    pdfID: pdfID,
                    pageIndex: pageIndex,
                    chapterTitle: "Page \(pageIndex + 1)",
                    kind: mappedKind,
                    createdAt: nativeAnn.modificationDate ?? Date(),
                    modifiedAt: Date(),
                    colorHex: colorHex,
                    selectedText: mappedKind == .highlight ? contentText : nil,
                    noteText: mappedKind == .note ? contentText : nil,
                    bounds: boundsNorm
                )
                
                if !existingIDs.contains(newAnnotation.id) {
                    AnnotationStore.shared.add(newAnnotation)
                    imported.append(newAnnotation)
                }
            }
        }
        
        Logger.shared.log("PDFAnnotationSync: Imported \(imported.count) third-party annotations from PDF", category: "PDF")
        return imported
    }
    
    // MARK: - Standalone Annotated PDF File Generation
    
    /// Generates a standalone annotated PDF file and writes it to the destination URL.
    @MainActor
    func generateAnnotatedPDF(
        from document: PDFDocument,
        for pdfID: UUID,
        saveTo destinationURL: URL
    ) throws -> URL {
        // Create an in-memory duplicate of the document to avoid mutating the active reader
        guard let data = document.dataRepresentation(),
              let exportedDoc = PDFDocument(data: data) else {
            throw PDFSyncError.documentSerializationFailed
        }
        
        self.exportAnnotations(for: pdfID, to: exportedDoc)
        
        guard exportedDoc.write(to: destinationURL) else {
            throw PDFSyncError.fileWriteFailed
        }
        
        Logger.shared.log("PDFAnnotationSync: Successfully wrote annotated PDF to \(destinationURL.path)", category: "PDF", type: .success)
        return destinationURL
    }
}

// MARK: - Errors & Extensions

public enum PDFSyncError: LocalizedError, Sendable {
    case documentSerializationFailed
    case fileWriteFailed
    
    public var errorDescription: String? {
        switch self {
        case .documentSerializationFailed:
            return "Failed to serialize the PDF document into memory."
        case .fileWriteFailed:
            return "Failed to write the annotated PDF document to disk."
        }
    }
}

private extension UIColor {
    convenience init?(hexString: String) {
        let clean = hexString.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        guard Scanner(string: clean).scanHexInt64(&int) else { return nil }
        let r, g, b, a: CGFloat
        switch clean.count {
        case 3: // RGB (12-bit)
            (r, g, b, a) = (CGFloat((int >> 8) * 17) / 255, CGFloat((int >> 4 & 0xF) * 17) / 255, CGFloat((int & 0xF) * 17) / 255, 1)
        case 6: // RGB (24-bit)
            (r, g, b, a) = (CGFloat((int >> 16) & 0xFF) / 255, CGFloat((int >> 8) & 0xFF) / 255, CGFloat(int & 0xFF) / 255, 1)
        case 8: // ARGB (32-bit)
            (r, g, b, a) = (CGFloat((int >> 16) & 0xFF) / 255, CGFloat((int >> 8) & 0xFF) / 255, CGFloat(int & 0xFF) / 255, CGFloat((int >> 24) & 0xFF) / 255)
        default:
            return nil
        }
        self.init(red: r, green: g, blue: b, alpha: a)
    }

    func toHexString() -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard getRed(&r, green: &g, blue: &b, alpha: &a) else {
            var white: CGFloat = 0
            if getWhite(&white, alpha: &a) {
                let rgb = Int(white * 255)
                return String(format: "#%02x%02x%02x", rgb, rgb, rgb)
            }
            return "#FFD600"
        }
        return String(format: "#%02x%02x%02x", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}
