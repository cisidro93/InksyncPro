import Foundation
import UIKit
import NaturalLanguage

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

enum ExportFormat {
    case markdown, plainText, csv
}

@MainActor
class AnnotationStore: ObservableObject {
    static let shared = AnnotationStore()
    
    @Published private var store: [UUID: [Annotation]] = [:]
    
    private let queue = DispatchQueue(label: "com.inksync.AnnotationStore", qos: .userInitiated)
    private nonisolated func getAnnotationsDir() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("annotations")
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }
    
    private init() {
        loadAll()
    }
    
    func annotations(for pdfID: UUID) -> [Annotation] {
        return store[pdfID] ?? []
    }
    
    func add(_ annotation: Annotation) {
        if store[annotation.pdfID] == nil {
            store[annotation.pdfID] = []
        }
        
        var newAnnotation = annotation
        
        // Pre-run lightweight NLP tagging if text exists and tags are not manually assigned
        if let text = newAnnotation.selectedText, newAnnotation.kind == .highlight, newAnnotation.tags == nil {
            newAnnotation.tags = extractNLPKeywords(from: text)
        }
        
        store[newAnnotation.pdfID]?.append(newAnnotation)
        save(pdfID: newAnnotation.pdfID)
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
        save(pdfID: annotation.pdfID)
    }
    
    func delete(id: UUID, pdfID: UUID) {
        store[pdfID]?.removeAll(where: { $0.id == id })
        save(pdfID: pdfID)
    }
    
    // MARK: - Persistence
    
    private func loadAll() {
        queue.async { [weak self] in
            guard let self = self else { return }
            do {
                let dir = self.getAnnotationsDir()
                let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                var loadedStore: [UUID: [Annotation]] = [:]
                
                for file in files where file.pathExtension == "json" {
                    if let uuid = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                       let data = try? Data(contentsOf: file),
                       let annotations = try? JSONDecoder().decode([Annotation].self, from: data) {
                        loadedStore[uuid] = annotations
                    }
                }
                
                Task { @MainActor in
                    self.store = loadedStore
                }
            } catch {
                print("Failed to load annotations: \(error)")
            }
        }
    }
    
    private func save(pdfID: UUID) {
        let pdfAnnotations = store[pdfID] ?? []
        let fileURL = getAnnotationsDir().appendingPathComponent("\(pdfID.uuidString).json")
        
        queue.async {
            do {
                if pdfAnnotations.isEmpty {
                    if FileManager.default.fileExists(atPath: fileURL.path) {
                        try FileManager.default.removeItem(at: fileURL)
                    }
                    return
                }
                
                let data = try JSONEncoder().encode(pdfAnnotations)
                try data.write(to: fileURL, options: .atomic)
            } catch {
                print("Failed to save annotations for \(pdfID): \(error)")
            }
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
