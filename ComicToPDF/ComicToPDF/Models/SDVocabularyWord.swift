import Foundation
import SwiftData

@Model final class SDVocabularyWord: Identifiable {
    @Attribute(.unique) var id: UUID
    var word: String
    var definition: String
    var contextSentence: String
    var bookID: String?
    var bookTitle: String
    var dateAdded: Date
    var masteryLevel: Int // 0 to 5 stars
    var isFavorite: Bool
    
    init(
        id: UUID = UUID(),
        word: String,
        definition: String = "",
        contextSentence: String = "",
        bookID: String? = nil,
        bookTitle: String = "General Reading",
        masteryLevel: Int = 1,
        isFavorite: Bool = false
    ) {
        self.id = id
        self.word = word.trimmingCharacters(in: .whitespacesAndNewlines)
        self.definition = definition.trimmingCharacters(in: .whitespacesAndNewlines)
        self.contextSentence = contextSentence.trimmingCharacters(in: .whitespacesAndNewlines)
        self.bookID = bookID
        self.bookTitle = bookTitle.isEmpty ? "General Reading" : bookTitle
        self.dateAdded = Date()
        self.masteryLevel = max(0, min(5, masteryLevel))
        self.isFavorite = isFavorite
    }
}
