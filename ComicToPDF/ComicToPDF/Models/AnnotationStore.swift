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

    enum AnnotationKind: String, Codable {
        case highlight
        case note           // text note attached to a location
        case bookmark       // page bookmark, no text selection
        case ink            // Apple Pencil freehand (PDF only)
    }
}

@Model final class SDAnnotation: Identifiable {
    @Attribute(.unique) var id: UUID
    var pdfID: UUID
    var pageIndex: Int
    var chapterTitle: String?
    var kindRaw: String
    var createdAt: Date
    var modifiedAt: Date
    var colorHex: String?
    var selectedText: String?
    var noteText: String?
    var tags: [String]?
    
    var boundsX: Double?
    var boundsY: Double?
    var boundsW: Double?
    var boundsH: Double?
    
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
    }
    
    func toDTO() -> Annotation {
        let kind = Annotation.AnnotationKind(rawValue: kindRaw) ?? .highlight
        var bounds: CodableCGRect? = nil
        if let x = boundsX, let y = boundsY, let w = boundsW, let h = boundsH {
            bounds = CodableCGRect(x: x, y: y, width: w, height: h)
        }
        return Annotation(id: id, pdfID: pdfID, pageIndex: pageIndex, chapterTitle: chapterTitle, kind: kind, createdAt: createdAt, modifiedAt: modifiedAt, colorHex: colorHex, selectedText: selectedText, noteText: noteText, tags: tags, bounds: bounds)
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
    }
}

enum ExportFormat {
    case markdown, plainText, csv
}

@MainActor
class AnnotationStore: ObservableObject {
    static let shared = AnnotationStore()
    
    @Published private var store: [UUID: [Annotation]] = [:]
    private var modelContext: ModelContext?
    
    private init() {}
    
    func initialize(with context: ModelContext) {
        self.modelContext = context
        loadAll()
    }
    
    func annotations(for pdfID: UUID) -> [Annotation] {
        return store[pdfID] ?? []
    }
    
    func add(_ annotation: Annotation) {
        var newAnnotation = annotation
        
        // Pre-run lightweight NLP tagging
        if let text = newAnnotation.selectedText, newAnnotation.kind == .highlight, newAnnotation.tags == nil {
            newAnnotation.tags = extractNLPKeywords(from: text)
        }
        
        store[newAnnotation.pdfID, default: []].append(newAnnotation)
        
        if let context = modelContext {
            let sdModel = SDAnnotation(from: newAnnotation)
            context.insert(sdModel)
            try? context.save()
        }
    }
    
    /// Executes Apple's deep lexical and entity extraction algorithms to surface contextual tags
    private func extractNLPKeywords(from text: String) -> [String] {
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
        guard let index = store[annotation.pdfID]?.firstIndex(where: { $0.id == annotation.id }) else { return }
        var updated = annotation
        updated.modifiedAt = Date()
        store[annotation.pdfID]?[index] = updated
        
        if let context = modelContext {
            let idString = annotation.id.uuidString
            // Fetch the specific SDAnnotation
            var fetchDescriptor = FetchDescriptor<SDAnnotation>()
            // Simplest way to find specific ID since UUID predicate in SwiftData has quirks
            if let allAnnotations = try? context.fetch(fetchDescriptor),
               let target = allAnnotations.first(where: { $0.id == annotation.id }) {
                target.update(from: updated)
                try? context.save()
            }
        }
    }
    
    func delete(id: UUID, pdfID: UUID) {
        store[pdfID]?.removeAll(where: { $0.id == id })
        
        if let context = modelContext {
            var fetchDescriptor = FetchDescriptor<SDAnnotation>()
            if let allAnnotations = try? context.fetch(fetchDescriptor),
               let target = allAnnotations.first(where: { $0.id == id }) {
                context.delete(target)
                try? context.save()
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
            for sd in allAnnotations {
                let dto = sd.toDTO()
                loadedStore[dto.pdfID, default: []].append(dto)
            }
            
            self.store = loadedStore
        } catch {
            print("Failed to load SDAnnotations: \(error)")
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
            return tempURL
        } catch {
            print("Failed to write export file: \(error)")
            return nil
        }
    }
}
