import Foundation
import SwiftData

@Model final class SDManuscriptProject {
    @Attribute(.unique) var id: UUID
    var title: String
    var targetWordCount: Int
    var deadline: Date?
    var createdAt: Date
    var modifiedAt: Date
    
    @Relationship(deleteRule: .cascade, inverse: \SDManuscriptDocument.project)
    var documents: [SDManuscriptDocument] = []
    
    init(id: UUID = UUID(), title: String, targetWordCount: Int = 0, deadline: Date? = nil) {
        self.id = id
        self.title = title
        self.targetWordCount = targetWordCount
        self.deadline = deadline
        self.createdAt = Date()
        self.modifiedAt = Date()
    }
    
    var currentWordCount: Int {
        documents.reduce(0) { total, doc in
            let words = doc.contentMarkdown
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
            return total + words.count
        }
    }
    
    var progressPercentage: Double {
        guard targetWordCount > 0 else { return 0 }
        return min(1.0, Double(currentWordCount) / Double(targetWordCount))
    }
}

@Model final class SDManuscriptDocument {
    @Attribute(.unique) var id: UUID
    var title: String
    var contentMarkdown: String
    var orderIndex: Int
    var createdAt: Date
    var modifiedAt: Date
    
    // Links back to project
    var project: SDManuscriptProject?
    
    // An array of Zettelkasten Note UUIDs that are referenced or attached to this document
    var attachedNoteIDs: [String] = []
    
    init(id: UUID = UUID(), title: String, contentMarkdown: String = "", orderIndex: Int = 0) {
        self.id = id
        self.title = title
        self.contentMarkdown = contentMarkdown
        self.orderIndex = orderIndex
        self.createdAt = Date()
        self.modifiedAt = Date()
    }
    
    var wordCount: Int {
        contentMarkdown
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .count
    }

    /// Extract NEO-style flow placeholders e.g. `[CHECK: ...]`, `[TODO: ...]`, or `[? ...]`
    var flowPlaceholders: [String] {
        let pattern = #"(?i)\[(?:CHECK|TODO|\?):?\s*([^\]]+)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let text = contentMarkdown
        let matches = regex.matches(in: text, options: [], range: NSRange(text.startIndex..<text.endIndex, in: text))
        return matches.compactMap { match in
            guard let range = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Smart typography automation (converts `--` to `—`, `...` to `…`)
    static func applySmartTypography(to text: String) -> String {
        var result = text
        if result.contains("--") {
            result = result.replacingOccurrences(of: "--", with: "—")
        }
        if result.contains("...") {
            result = result.replacingOccurrences(of: "...", with: "…")
        }
        return result
    }

    /// Replaces or removes a flow placeholder in the document markdown.
    func resolvePlaceholder(_ query: String, replacement: String = "") {
        let pattern = #"(?i)\[(?:CHECK|TODO|\?):?\s*"# + NSRegularExpression.escapedPattern(for: query) + #"\]"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
            let range = NSRange(contentMarkdown.startIndex..<contentMarkdown.endIndex, in: contentMarkdown)
            contentMarkdown = regex.stringByReplacingMatches(in: contentMarkdown, options: [], range: range, withTemplate: replacement)
            modifiedAt = Date()
        }
    }
}

// MARK: - Holding Tray (Save for Later & Discards)
public enum HoldingTrayCategory: String, Codable, CaseIterable, Sendable {
    case savedForLater = "Saved for Later"
    case discarded = "Discarded"
}

@Model final class SDHoldingTrayItem {
    @Attribute(.unique) var id: UUID
    var text: String
    var categoryRaw: String
    var sourceTitle: String
    var wordCount: Int
    var createdAt: Date
    var modifiedAt: Date
    var projectID: UUID?
    var documentID: UUID?

    var category: HoldingTrayCategory {
        get { HoldingTrayCategory(rawValue: categoryRaw) ?? .savedForLater }
        set { categoryRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        text: String,
        category: HoldingTrayCategory = .savedForLater,
        sourceTitle: String = "Untitled",
        projectID: UUID? = nil,
        documentID: UUID? = nil
    ) {
        self.id = id
        self.text = text
        self.categoryRaw = category.rawValue
        self.sourceTitle = sourceTitle
        self.wordCount = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count
        self.createdAt = Date()
        self.modifiedAt = Date()
        self.projectID = projectID
        self.documentID = documentID
    }
}
