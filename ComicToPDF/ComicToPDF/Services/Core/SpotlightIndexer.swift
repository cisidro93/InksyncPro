import Foundation
import CoreSpotlight
import MobileCoreServices
import UIKit

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
    static let openBookActivityType = "com.inksyncpro.openBook"
    static let openAnnotationActivityType = "com.inksyncpro.openAnnotation"

    private let index = CSSearchableIndex.default()

    private init() {}

    // MARK: - Library Indexing

    /// Index the entire library — call after import or metadata changes.
    /// PERF D-C2: Previously called pdfs.map { makeBookItem($0) } on @MainActor,
    /// which allocated N ConvertedPDF copies AND decoded every coverImageData
    /// blob into UIImage before handing off to the background task.
    /// Now only lightweight value tuples are captured — no DTO copies, no image
    /// decoding on the main thread. Cover thumbnails are omitted from bulk indexing
    /// (Spotlight doesn't surface them for .content-type items).
    func indexLibrary(pdfs: [ConvertedPDF]) {
        // Capture only primitive values — zero heap allocation on MainActor
        let tuples = pdfs.map { (id: $0.id, name: $0.name, series: $0.metadata.series, type: $0.contentType.rawValue) }
        Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
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
            do {
                try await self.index.indexSearchableItems(items)
            } catch {
                Logger.shared.log("Spotlight: failed to index library — \(error)", category: "Spotlight", type: .error)
            }
        }
    }

    /// Index (or re-index) a single book — call after metadata edit.
    func indexBook(_ pdf: ConvertedPDF) {
        let item = makeBookItem(pdf)
        Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            try? await self.index.indexSearchableItems([item])
        }
    }

    /// Remove a single book from the index — call on delete.
    func deindexBook(_ pdfID: UUID) {
        Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            try? await self.index.deleteSearchableItems(withIdentifiers: ["book-\(pdfID.uuidString)"])
        }
    }

    // MARK: - Annotation Indexing

    func indexAnnotation(_ annotation: SDAnnotation) {
        let hasSelectedText = !(annotation.selectedText ?? "").isEmpty
        let hasNoteText = !(annotation.noteText ?? "").isEmpty
        let hasOCRText = !(annotation.drawingOCRText ?? "").isEmpty
        guard hasSelectedText || hasNoteText || hasOCRText else { return }
        
        let item = makeAnnotationItem(annotation)
        Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            try? await self.index.indexSearchableItems([item])
        }
    }

    func deindexAnnotation(_ annotationID: UUID) {
        Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            try? await self.index.deleteSearchableItems(withIdentifiers: ["ann-\(annotationID.uuidString)"])
        }
    }

    /// Nuke the entire index — useful for settings reset.
    func clearAll() {
        Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            try? await self.index.deleteAllSearchableItems()
        }
    }

    // MARK: - Item Builders

    private func makeBookItem(_ pdf: ConvertedPDF) -> CSSearchableItem {
        let attrs = CSSearchableItemAttributeSet(contentType: .content)
        attrs.title = pdf.name
        attrs.contentDescription = [
            pdf.metadata.series,
            pdf.metadata.publisher,
            pdf.metadata.issueNumber.map { "Issue #\($0)" }
        ].compactMap { $0 }.joined(separator: " · ")
        attrs.keywords = [
            pdf.contentType.rawValue,
            pdf.metadata.series,
            pdf.metadata.publisher,
            pdf.metadata.isManga == true ? "manga" : nil
        ].compactMap { $0 }
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
}
