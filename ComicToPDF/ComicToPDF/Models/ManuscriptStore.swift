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
            let text = doc.contentMarkdown
            let words = text.split { $0.isWhitespace || $0.isPunctuation }
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
        let words = contentMarkdown.split { $0.isWhitespace || $0.isPunctuation }
        return words.count
    }
}
