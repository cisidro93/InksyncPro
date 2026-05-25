import Foundation
import UIKit
import NaturalLanguage
import SwiftData

struct CodableCGRect: Codable {
    var x, y, width, height: Double
    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    
    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    
    init(cgRect: CGRect) {
        self.x = Double(cgRect.origin.x)
        self.y = Double(cgRect.origin.y)
        self.width = Double(cgRect.width)
        self.height = Double(cgRect.height)
    }
}

struct Annotation: Codable, Identifiable {
    var id: UUID = UUID()
    var pdfID: UUID                       // links to ConvertedPDF.id
    var pageIndex: Int                    // 0-based page
    var chapterTitle: String?             // for books
    var kind: AnnotationKind
    var createdAt: Date
    var modifiedAt: Date
    var colorHex: String?                 // highlight colour
    var selectedText: String?             // the highlighted text
    var noteText: String?                 // user's note on the annotation
    var tags: [String]?                   // NLP auto-generated tags
    var bounds: CodableCGRect?            // page-relative bounds (0–1 normalized)
    // SHA-256 thumbprint of the page at annotation time. nil for pre-Phase5 annotations.
    var contentHash: String? = nil

    // ✅ Phase 3: Zettelkasten SRS (Readwise Parity)
    var reviewCount: Int = 0
    var easeFactor: Double = 2.5
    var nextReviewDate: Date? = nil

    // ✅ Phase 4: GoodNotes PencilKit Parity
    var drawingData: Data? = nil


    // ✅ Zettel Board Outlining & Linking
    var outlineColumn: String? = nil
    var outlineOrder: Int = 0
    var linkedAnnotationIDs: [String]? = []

    // ✅ Phase 6: Handwriting OCR
    var drawingOCRText: String? = nil

    enum AnnotationKind: String, Codable {
        case highlight
        case note           // text note attached to a location
        case bookmark       // page bookmark, no text selection
        case ink            // Apple Pencil freehand (PDF only)
    }
}

@Model final class SDAnnotation: Identifiable {
    @Attribute(.unique) var id: UUID
    var pdfID: UUID // This is uniquely bound or synthesized per book / PDF
    var pageIndex: Int
    var chapterTitle: String?
    var kindRaw: String
    var createdAt: Date
    var modifiedAt: Date
    var colorHex: String?
    var selectedText: String?
    var noteText: String?
    var tags: [String]?
    
    // ✅ Phase 31: Readwise Sync Extensions
    var isReadwiseImport: Bool = false
    var readwiseBookTitle: String?
    var readwiseAuthor: String?
    /// Raw color name from Readwise CSV ("yellow", "blue", "pink", "aqua")
    var readwiseColor: String?
    /// Readwise user-applied tags from the CSV Tags column
    var readwiseTags: [String]?
    /// Readwise Document-level tags
    var readwiseDocumentTags: [String]?
    /// Amazon Book ID (ASIN) for deep-linking to Kindle
    var readwiseAmazonID: String?
    /// Location type: "location", "page", "offset", "order"
    var readwiseLocationType: String?
    /// Raw location value from CSV
    var readwiseLocation: Int?
    
    // Bounding Box
    var boundsX: Double?
    var boundsY: Double?
    var boundsW: Double?
    var boundsH: Double?
    var contentHash: String? = nil
    
    // ✅ Phase 3: Zettelkasten SRS (Readwise Parity)
    var reviewCount: Int = 0
    var easeFactor: Double = 2.5
    var nextReviewDate: Date? = nil
    
    // ✅ Phase 4: GoodNotes PencilKit Parity
    @Attribute(.externalStorage) var drawingData: Data? = nil

    
    // ✅ Zettel Board Outlining & Linking
    var outlineColumn: String? = nil
    var outlineOrder: Int = 0
    var linkedAnnotationIDs: [String]? = []
    
    // ✅ Phase 6: Handwriting OCR
    var drawingOCRText: String?
    
    init(from dto: Annotation) {
        self.id = dto.id
        self.pdfID = dto.pdfID
        self.pageIndex = dto.pageIndex
        self.chapterTitle = dto.chapterTitle
        self.kindRaw = dto.kind.rawValue
        self.createdAt = dto.createdAt
        self.modifiedAt = dto.modifiedAt
        self.colorHex = dto.colorHex
        self.selectedText = dto.selectedText
        self.noteText = dto.noteText
        self.tags = dto.tags
        self.boundsX = dto.bounds?.x
        self.boundsY = dto.bounds?.y
        self.boundsW = dto.bounds?.width
        self.boundsH = dto.bounds?.height
        
        self.isReadwiseImport = false
        self.reviewCount = dto.reviewCount
        self.easeFactor = dto.easeFactor
        self.nextReviewDate = dto.nextReviewDate
        self.drawingData = dto.drawingData
        self.drawingOCRText = dto.drawingOCRText
        self.outlineColumn = dto.outlineColumn
        self.outlineOrder = dto.outlineOrder
        self.linkedAnnotationIDs = dto.linkedAnnotationIDs ?? []
    }
    
    // ✅ Phase 31 Native Constructor for Readwise Importers
    // All readwise-specific parameters default to nil so non-Readwise callers
    // (e.g. StudyNotebookView creating in-app note annotations) compile unchanged.
    init(
        id: UUID,
        pdfID: String,
        pageIndex: Int,
        text: String?,
        note: String?,
        isReadwiseImport: Bool,
        readwiseBookTitle: String?,
        readwiseAuthor: String?,
        readwiseColor: String?        = nil,
        readwiseTags: [String]?       = nil,
        readwiseDocumentTags: [String]? = nil,
        readwiseAmazonID: String?     = nil,
        readwiseLocationType: String? = nil,
        readwiseLocation: Int?        = nil,
        createdAt: Date
    ) {
        self.id = id
        self.pdfID = UUID(uuidString: pdfID) ?? UUID()
        self.pageIndex = pageIndex
        self.kindRaw = "highlight"
        self.createdAt = createdAt
        self.modifiedAt = createdAt
        self.selectedText = text
        self.noteText = note.flatMap { $0.isEmpty ? nil : $0 }

        // Map Readwise color name to a real hex value used throughout the app
        let colorMap: [String: String] = [
            "yellow": "#FFD60A",
            "blue":   "#007AFF",
            "pink":   "#FF2D55",
            "aqua":   "#32ADE6",
            "orange": "#FF9F0A",
            "purple": "#BF5AF2"
        ]
        self.colorHex = colorMap[readwiseColor?.lowercased() ?? ""] ?? "#FFD60A"

        // Merge user-applied Tags + Document tags into the single tags array used by the app
        var allTags: [String] = []
        if let rt = readwiseTags  { allTags.append(contentsOf: rt) }
        if let dt = readwiseDocumentTags { allTags.append(contentsOf: dt) }
        self.tags = allTags.isEmpty ? [] : allTags

        self.isReadwiseImport    = isReadwiseImport
        self.readwiseBookTitle   = readwiseBookTitle
        self.readwiseAuthor      = readwiseAuthor
        self.readwiseColor       = readwiseColor
        self.readwiseTags        = readwiseTags
        self.readwiseDocumentTags = readwiseDocumentTags
        self.readwiseAmazonID    = readwiseAmazonID
        self.readwiseLocationType = readwiseLocationType
        self.readwiseLocation    = readwiseLocation
        self.outlineColumn = nil
        self.outlineOrder = 0
        self.linkedAnnotationIDs = []
    }
    
    func toDTO() -> Annotation {
        let kind = Annotation.AnnotationKind(rawValue: kindRaw) ?? .highlight
        var bounds: CodableCGRect? = nil
        if let x = boundsX, let y = boundsY, let w = boundsW, let h = boundsH {
            bounds = CodableCGRect(x: x, y: y, width: w, height: h)
        }
        var dto = Annotation(id: id, pdfID: pdfID, pageIndex: pageIndex, chapterTitle: chapterTitle, kind: kind, createdAt: createdAt, modifiedAt: modifiedAt, colorHex: colorHex, selectedText: selectedText, noteText: noteText, tags: tags, bounds: bounds)
        dto.reviewCount = self.reviewCount
        dto.easeFactor = self.easeFactor
        dto.nextReviewDate = self.nextReviewDate
        dto.drawingData = self.drawingData
        dto.drawingOCRText = self.drawingOCRText
        dto.outlineColumn = self.outlineColumn
        dto.outlineOrder = self.outlineOrder
        dto.linkedAnnotationIDs = self.linkedAnnotationIDs ?? []
        return dto
    }
    
    func update(from dto: Annotation) {
        self.pageIndex = dto.pageIndex
        self.chapterTitle = dto.chapterTitle
        self.kindRaw = dto.kind.rawValue
        self.modifiedAt = dto.modifiedAt
        self.colorHex = dto.colorHex
        self.selectedText = dto.selectedText
        self.noteText = dto.noteText
        self.tags = dto.tags
        self.boundsX = dto.bounds?.x
        self.boundsY = dto.bounds?.y
        self.boundsW = dto.bounds?.width
        self.boundsH = dto.bounds?.height
        
        self.reviewCount = dto.reviewCount
        self.easeFactor = dto.easeFactor
        self.nextReviewDate = dto.nextReviewDate
        self.drawingData = dto.drawingData
        self.drawingOCRText = dto.drawingOCRText
        self.outlineColumn = dto.outlineColumn
        self.outlineOrder = dto.outlineOrder
        self.linkedAnnotationIDs = dto.linkedAnnotationIDs ?? []
    }
}

enum ExportFormat {
    case markdown, plainText, csv
}

@MainActor
class AnnotationStore: ObservableObject {
    static let shared = AnnotationStore()
    
    @Published private var store: [UUID: [Annotation]] = [:]
    /// O(1) lookup by annotation ID — eliminates flatMap scans in hot paths.
    private var idIndex: [UUID: Annotation] = [:]
    private var modelContext: ModelContext?

    // Maps SHA-256 page content hash → [annotation IDs] for cross-format lookup.
    private var hashIndex: [String: [String]] = [:]
    
    private init() {}
    
    func initialize(with context: ModelContext) {
        self.modelContext = context
        Logger.shared.log("AnnotationStore initialized with ModelContext", category: "Annotations", type: .info)
        loadAll()
    }
    
    func annotations(for pdfID: UUID) -> [Annotation] {
        return store[pdfID] ?? []
    }
    
    var allAnnotations: [Annotation] {
        return store.values.flatMap { $0 }
    }

    // Returns all annotations whose page content hash matches (cross-format lookup).
    // O(k) where k = number of annotations sharing that hash (typically 1).
    func annotations(forContentHash hash: String) -> [Annotation] {
        guard let ids = hashIndex[hash] else { return [] }
        return ids.compactMap { UUID(uuidString: $0).flatMap { idIndex[$0] } }
    }

    // Associates a SHA-256 page content hash with an annotation (call at annotation creation time).
    func setContentHash(_ hash: String, for annotationID: UUID) {
        hashIndex[hash, default: []].append(annotationID.uuidString)
        for key in store.keys {
            if let idx = store[key]?.firstIndex(where: { $0.id == annotationID }) {
                store[key]?[idx].contentHash = hash
            }
        }
    }
    
    func add(_ annotation: Annotation) {
        // Deduplication guard — prevents double-insert from accidental rapid taps
        guard store[annotation.pdfID]?.contains(where: { $0.id == annotation.id }) != true else { return }

        store[annotation.pdfID, default: []].append(annotation)
        idIndex[annotation.id] = annotation

        // Insert into SwiftData immediately so the record exists before NLP runs.
        // Tags will be backfilled asynchronously below.
        if let context = modelContext {
            context.insert(SDAnnotation(from: annotation))
            do {
                try context.save()
            } catch {
                Logger.shared.log("Annotation insert FAILED: \(error.localizedDescription)", category: "Annotations", type: .error)
            }
        }

        // ✅ PERF: Skip NLP for Readwise imports (they already carry CSV tags) and
        // for annotations with no text content.
        guard let text = annotation.selectedText, !text.isEmpty,
              annotation.kind == .highlight,
              annotation.tags == nil else { return }

        // Execute heavy NLP Lexical Tagging asynchronously to prevent Main Thread 120Hz lockups
        Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            let tags = await self.extractNLPKeywords(from: text)
            await MainActor.run {
                // Update in-memory store and idIndex
                if let idx = self.store[annotation.pdfID]?.firstIndex(where: { $0.id == annotation.id }) {
                    self.store[annotation.pdfID]?[idx].tags = tags
                    self.idIndex[annotation.id]?.tags = tags
                }
                // Backfill tags on the already-saved SwiftData record
                if let context = self.modelContext {
                    var descriptor = FetchDescriptor<SDAnnotation>(
                        predicate: #Predicate { $0.id == annotation.id }
                    )
                    descriptor.fetchLimit = 1
                    if let target = try? context.fetch(descriptor).first {
                        target.tags = tags
                        try? context.save()
                        Logger.shared.log("NLP tags backfilled (id=\(annotation.id), count=\(tags.count))", category: "Annotations", type: .success)
                    }
                }
            }
        }
    }
    
    /// Executes Apple's deep lexical and entity extraction algorithms to surface contextual tags (Nonisolated to execute safely off-actor)
    nonisolated func extractNLPKeywords(from text: String) async -> [String] {
        let tagger = NLTagger(tagSchemes: [.lexicalClass, .nameType])
        tagger.string = text
        
        let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .joinNames]
        let allowedTags: [NLTag] = [.noun, .organizationName, .placeName, .personalName]
        
        var extractedTags = Set<String>()
        
        // First Pass: Deep Name Types (Entities)
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType, options: options) { tag, tokenRange in
            if let tag = tag, allowedTags.contains(tag) {
                let word = String(text[tokenRange]).lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                if word.count > 2 { extractedTags.insert(word) }
            }
            return true
        }
        
        // Second Pass: Standard Nouns
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass, options: options) { tag, tokenRange in
            if let tag = tag, allowedTags.contains(tag) {
                let word = String(text[tokenRange]).lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                if word.count > 2 { extractedTags.insert(word) }
            }
            return true
        }
        
        return Array(extractedTags).prefix(10).map { String($0) }
    }
    
    func update(_ annotation: Annotation) {
        guard let index = store[annotation.pdfID]?.firstIndex(where: { $0.id == annotation.id }) else {
            Logger.shared.log("update: annotation \(annotation.id) not found in store", category: "Annotations", type: .warning)
            return
        }
        var updated = annotation
        updated.modifiedAt = Date()
        store[annotation.pdfID]?[index] = updated
        idIndex[annotation.id] = updated
        
        if let context = modelContext {
            // O(1) predicated fetch instead of loading entire table
            var descriptor = FetchDescriptor<SDAnnotation>(
                predicate: #Predicate { $0.id == annotation.id }
            )
            descriptor.fetchLimit = 1
            if let target = try? context.fetch(descriptor).first {
                target.update(from: updated)
                do {
                    try context.save()
                    Logger.shared.log("Annotation updated (id=\(annotation.id), page=\(annotation.pageIndex))", category: "Annotations", type: .info)
                } catch {
                    Logger.shared.log("Annotation update save FAILED: \(error.localizedDescription)", category: "Annotations", type: .error)
                }
            }
        }
    }
    
    func delete(id: UUID, pdfID: UUID) {
        store[pdfID]?.removeAll(where: { $0.id == id })
        idIndex.removeValue(forKey: id)
        Logger.shared.log("Annotation deleted (id=\(id), pdfID=\(pdfID))", category: "Annotations", type: .info)
        
        if let context = modelContext {
            // O(1) predicated fetch instead of loading entire table
            var descriptor = FetchDescriptor<SDAnnotation>(
                predicate: #Predicate { $0.id == id }
            )
            descriptor.fetchLimit = 1
            if let target = try? context.fetch(descriptor).first {
                context.delete(target)
                do {
                    try context.save()
                } catch {
                    Logger.shared.log("Annotation delete save FAILED: \(error.localizedDescription)", category: "Annotations", type: .error)
                }
            }
        }
    }
    
    // MARK: - SwiftData Persistence
    
    private func loadAll() {
        guard let context = modelContext else { return }
        do {
            let descriptor = FetchDescriptor<SDAnnotation>()
            let allAnnotations = try context.fetch(descriptor)
            
            var loadedStore: [UUID: [Annotation]] = [:]
            var loadedIndex: [UUID: Annotation] = [:]
            for sd in allAnnotations {
                let dto = sd.toDTO()
                loadedStore[dto.pdfID, default: []].append(dto)
                loadedIndex[dto.id] = dto
            }
            
            self.store = loadedStore
            self.idIndex = loadedIndex
            let totalBooks = loadedStore.keys.count
            let totalAnnotations = loadedStore.values.reduce(0) { $0 + $1.count }
            Logger.shared.log("AnnotationStore loaded: \(totalAnnotations) annotation(s) across \(totalBooks) book(s)", category: "Annotations", type: .success)
        } catch {
            Logger.shared.log("AnnotationStore loadAll FAILED: \(error.localizedDescription)", category: "Annotations", type: .error)
        }
    }
    
    // MARK: - Export
    
    func export(for pdfID: UUID, documentTitle: String, format: ExportFormat) -> URL? {
        let items = (store[pdfID] ?? []).sorted { $0.pageIndex < $1.pageIndex }
        guard !items.isEmpty else { return nil }
        
        var content = ""
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        
        switch format {
        case .markdown:
            content += "# Highlights & Notes — \(documentTitle)\n\n"
            var currentGroup = -1
            
            for item in items {
                // Group by page or chapter
                if item.pageIndex != currentGroup {
                    currentGroup = item.pageIndex
                    let groupTitle = item.chapterTitle ?? "Page \(item.pageIndex + 1)"
                    content += "## \(groupTitle)\n"
                }
                
                if item.kind == .bookmark {
                    content += "📌 Bookmark\n\n"
                } else {
                    if let text = item.selectedText, !text.isEmpty {
                        content += "> \"\(text)\"\n"
                    }
                    if let note = item.noteText, !note.isEmpty {
                        content += "Note: \(note)\n"
                    }
                    content += "\n"
                }
            }
            
        case .plainText:
            content += "Highlights & Notes — \(documentTitle)\n\n"
            for item in items {
                let location = item.chapterTitle ?? "Page \(item.pageIndex + 1)"
                content += "[\(location)]\n"
                if item.kind == .bookmark {
                    content += "📌 Bookmark\n\n"
                } else {
                    if let text = item.selectedText { content += "\"\(text)\"\n" }
                    if let note = item.noteText { content += "Note: \(note)\n" }
                    content += "\n"
                }
            }
            
        case .csv:
            content += "page,type,selected_text,note,color,created_at\n"
            for item in items {
                let pageStr = "\(item.pageIndex + 1)"
                let typeStr = item.kind.rawValue
                let textStr = (item.selectedText ?? "").replacingOccurrences(of: "\"", with: "\"\"")
                let noteStr = (item.noteText ?? "").replacingOccurrences(of: "\"", with: "\"\"")
                let colorStr = item.colorHex ?? ""
                let dateStr = formatter.string(from: item.createdAt)
                
                content += "\"\(pageStr)\",\"\(typeStr)\",\"\(textStr)\",\"\(noteStr)\",\"\(colorStr)\",\"\(dateStr)\"\n"
            }
        }
        
        let ext: String
        switch format {
        case .markdown: ext = "md"
        case .plainText: ext = "txt"
        case .csv: ext = "csv"
        }
        
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(documentTitle) Annotations.\(ext)")
        do {
            try content.write(to: tempURL, atomically: true, encoding: .utf8)
            Logger.shared.log("AnnotationStore exported \(items.count) annotation(s) for '\(documentTitle)' as .\(ext)", category: "Annotations", type: .success)
            return tempURL
        } catch {
            Logger.shared.log("AnnotationStore export FAILED for '\(documentTitle)': \(error.localizedDescription)", category: "Annotations", type: .error)
            return nil
        }
    }
}
