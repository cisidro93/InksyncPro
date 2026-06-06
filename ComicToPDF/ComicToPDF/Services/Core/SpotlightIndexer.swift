import Foundation
@preconcurrency import CoreSpotlight
import MobileCoreServices
import UIKit
import PDFKit
import Vision

/// Indexes InksyncPro library items and annotations into iOS Spotlight so users
/// can find books and highlights without opening the app.
///
/// Usage:
///   SpotlightIndexer.shared.indexLibrary(pdfs: conversionManager.convertedPDFs)
///   SpotlightIndexer.shared.indexAnnotation(annotation)
@MainActor
final class SpotlightIndexer {
    static let shared = SpotlightIndexer()

    // Activity type used for deep-linking from Spotlight results
    nonisolated static let openBookActivityType = "com.inksyncpro.openBook"
    nonisolated static let openAnnotationActivityType = "com.inksyncpro.openAnnotation"

    private let index = CSSearchableIndex.default()

    private init() {}

    // MARK: - Library Indexing

    /// Index the entire library — call after import or metadata changes.
    func indexLibrary(pdfs: [ConvertedPDF]) {
        let tuples = pdfs.map { (id: $0.id, name: $0.name, series: $0.metadata.series, type: $0.contentType.rawValue) }
        let items: [CSSearchableItem] = tuples.map { t in
            let attrs = CSSearchableItemAttributeSet(contentType: .content)
            attrs.title = t.name
            attrs.contentDescription = t.series
            attrs.keywords = [t.type]
            attrs.identifier = t.id.uuidString
            return CSSearchableItem(
                uniqueIdentifier: "book-\(t.id.uuidString)",
                domainIdentifier: "com.inksyncpro.library",
                attributeSet: attrs
            )
        }
        self.index.indexSearchableItems(items) { @Sendable error in
            if let error = error {
                Logger.shared.log("Spotlight: failed to index library — \(error)", category: "Spotlight", type: .error)
            }
        }
    }

    /// Index (or re-index) a single book — call after metadata edit.
    func indexBook(_ pdf: ConvertedPDF) {
        let item = makeBookItem(pdf)
        self.index.indexSearchableItems([item]) { @Sendable error in
            if let error = error {
                Logger.shared.log("Spotlight: failed to index book item — \(error)", category: "Spotlight", type: .error)
            }
        }
        indexBookPages(pdf)
    }

    /// Remove a single book from the index — call on delete.
    func deindexBook(_ pdfID: UUID) {
        self.index.deleteSearchableItems(withIdentifiers: ["book-\(pdfID.uuidString)"], completionHandler: nil)
        self.index.deleteSearchableItems(withDomainIdentifiers: ["com.inksyncpro.pages-\(pdfID.uuidString)"], completionHandler: nil)
    }

    // MARK: - Annotation Indexing

    func indexAnnotation(_ annotation: SDAnnotation) {
        let hasSelectedText = !(annotation.selectedText ?? "").isEmpty
        let hasNoteText = !(annotation.noteText ?? "").isEmpty
        let hasOCRText = !(annotation.drawingOCRText ?? "").isEmpty
        guard hasSelectedText || hasNoteText || hasOCRText else { return }
        
        let item = makeAnnotationItem(annotation)
        self.index.indexSearchableItems([item], completionHandler: nil)
    }

    func deindexAnnotation(_ annotationID: UUID) {
        self.index.deleteSearchableItems(withIdentifiers: ["ann-\(annotationID.uuidString)"], completionHandler: nil)
    }

    /// Nuke the entire index — useful for settings reset.
    func clearAll() {
        self.index.deleteAllSearchableItems(completionHandler: nil)
    }

    // MARK: - Item Builders

    private func makeBookItem(_ pdf: ConvertedPDF) -> CSSearchableItem {
        let attrs = CSSearchableItemAttributeSet(contentType: .content)
        attrs.title = pdf.name
        
        // Use summary if available, otherwise fallback to series, publisher, etc.
        if let summary = pdf.metadata.summary, !summary.isEmpty {
            attrs.contentDescription = summary
        } else {
            attrs.contentDescription = [
                pdf.metadata.series,
                pdf.metadata.publisher,
                pdf.metadata.issueNumber.map { "Issue #\($0)" }
            ].compactMap { $0 }.joined(separator: " · ")
        }
        
        attrs.authorNames = [pdf.metadata.author, pdf.metadata.writer].compactMap { $0 }
        attrs.publishers = [pdf.metadata.publisher].compactMap { $0 }
        attrs.genre = pdf.contentType.rawValue
        
        var keywords = [
            pdf.contentType.rawValue,
            pdf.metadata.series,
            pdf.metadata.publisher,
            pdf.metadata.volume.map { "Volume \($0)" },
            pdf.metadata.penciller,
            pdf.metadata.isManga == true ? "manga" : nil
        ].compactMap { $0 }
        keywords.append(contentsOf: pdf.metadata.tags)
        attrs.keywords = keywords
        
        attrs.identifier = pdf.id.uuidString
        // Thumbnail from cover file if available
        if let data = pdf.coverImageData,
           let img = UIImage(data: data) {
            attrs.thumbnailData = img.jpegData(compressionQuality: 0.6)
        }
        // NSUserActivity for deep-linking
        let activity = NSUserActivity(activityType: SpotlightIndexer.openBookActivityType)
        activity.title = pdf.name
        activity.userInfo = ["pdfID": pdf.id.uuidString]
        activity.isEligibleForSearch = true
        activity.isEligibleForHandoff = false
        attrs.relatedUniqueIdentifier = pdf.id.uuidString

        return CSSearchableItem(
            uniqueIdentifier: "book-\(pdf.id.uuidString)",
            domainIdentifier: "com.inksyncpro.library",
            attributeSet: attrs
        )
    }

    private func makeAnnotationItem(_ ann: SDAnnotation) -> CSSearchableItem {
        let attrs = CSSearchableItemAttributeSet(contentType: .text)
        
        let title: String
        let desc: String
        
        if ann.kindRaw == "note" {
            let noteContent = ann.noteText ?? ""
            let ocrContent = ann.drawingOCRText ?? ""
            
            if !noteContent.isEmpty && !ocrContent.isEmpty {
                title = "Note & Sketch in " + (ann.readwiseBookTitle ?? "Book")
                desc = "\(noteContent)\nSketch: \(ocrContent)"
            } else if !ocrContent.isEmpty {
                title = "Handwritten Sketch in " + (ann.readwiseBookTitle ?? "Book")
                desc = ocrContent
            } else {
                title = "Text Note in " + (ann.readwiseBookTitle ?? "Book")
                desc = noteContent
            }
        } else if ann.kindRaw == "ink" {
            title = "Scribble on Page \(ann.pageIndex + 1)"
            desc = ann.drawingOCRText ?? "Handwritten drawing"
        } else {
            title = String((ann.selectedText ?? "").prefix(80))
            desc = ann.noteText ?? "Highlight"
        }
        
        attrs.title = title
        attrs.contentDescription = desc
        attrs.keywords = ann.tags ?? []
        let activity = NSUserActivity(activityType: SpotlightIndexer.openAnnotationActivityType)
        activity.userInfo = ["annotationID": ann.id.uuidString]
        attrs.relatedUniqueIdentifier = "ann-\(ann.id.uuidString)"
        return CSSearchableItem(
            uniqueIdentifier: "ann-\(ann.id.uuidString)",
            domainIdentifier: "com.inksyncpro.annotations",
            attributeSet: attrs
        )
    }

    /// Indexes pages of a PDF/Book (runs asynchronously on a background task)
    func indexBookPages(_ pdf: ConvertedPDF) {
        let pdfID = pdf.id
        let url = pdf.url
        let pdfName = pdf.name
        let series = pdf.metadata.series
        
        Task.detached(priority: .background) {
            // Check if file is a local PDF and exists
            guard url.isFileURL, FileManager.default.fileExists(atPath: url.path) else { return }
            
            // Lock and load via PDFRenderActor or directly using CGPDFDocument/PDFDocument
            // Since PDFDocument is thread-safe for reading text strings, we can load it here.
            guard let doc = PDFDocument(url: url) else { return }
            
            var items: [CSSearchableItem] = []
            
            // Limit indexing to the first 15 pages maximum.
            // Full-book OCR and text extraction on 200+ page comic books causes the CGPDFService
            // to cache every page and hit its Jetsam memory limit, resulting in silent OOM kills.
            let maxPages = min(doc.pageCount, 15)
            
            for pageIndex in 0..<maxPages {
                guard let page = doc.page(at: pageIndex) else { continue }
                var pageText = page.string ?? ""
                
                // Scanned PDF/Comic fallback to Vision OCR
                if pageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // Render page & run OCR
                    pageText = await self.runVisionOCR(on: page)
                }
                
                let trimmed = pageText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                
                let attrs = CSSearchableItemAttributeSet(contentType: .text)
                attrs.title = "\(pdfName) — Page \(pageIndex + 1)"
                attrs.contentDescription = String(trimmed.prefix(200))
                attrs.textContent = trimmed
                attrs.keywords = [pdfName, "page \(pageIndex + 1)", series].compactMap { $0 }
                attrs.relatedUniqueIdentifier = pdfID.uuidString
                
                // Associate with NSUserActivity for deep linking to this page
                let activity = NSUserActivity(activityType: SpotlightIndexer.openBookActivityType)
                activity.userInfo = ["pdfID": pdfID.uuidString, "pageIndex": pageIndex]
                attrs.relatedUniqueIdentifier = pdfID.uuidString
                
                let item = CSSearchableItem(
                    uniqueIdentifier: "book-\(pdfID.uuidString)-page-\(pageIndex)",
                    domainIdentifier: "com.inksyncpro.pages-\(pdfID.uuidString)",
                    attributeSet: attrs
                )
                items.append(item)
            }
            
            if !items.isEmpty {
                do {
                    try await CSSearchableIndex.default().indexSearchableItems(items)
                    Logger.shared.log("Spotlight: Indexed \(items.count) pages for \(pdfName)", category: "Spotlight", type: .success)
                } catch {
                    Logger.shared.log("Spotlight: failed to index pages — \(error)", category: "Spotlight", type: .error)
                }
            }
        }
    }
    
    /// Helper to render a PDF page and perform fast text recognition
    nonisolated private func runVisionOCR(on page: PDFPage) async -> String {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0 && bounds.height > 0 else { return "" }
        
        let size = CGSize(width: bounds.width, height: bounds.height)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1.0
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { ctx in
            let cgCtx = ctx.cgContext
            cgCtx.setFillColor(UIColor.white.cgColor)
            cgCtx.fill(CGRect(origin: .zero, size: size))
            cgCtx.translateBy(x: 0, y: size.height)
            cgCtx.scaleBy(x: 1.0, y: -1.0)
            page.draw(with: .mediaBox, to: cgCtx)
        }
        
        guard let cgImage = image.cgImage else { return "" }
        
        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                guard error == nil,
                      let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: "")
                    return
                }
                let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: lines.joined(separator: " "))
            }
            request.recognitionLevel = .fast
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try? handler.perform([request])
        }
    }
}
