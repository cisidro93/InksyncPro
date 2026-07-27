import UIKit
import SwiftUI
import SwiftData

@MainActor
final class DictionaryLookupService {
    static let shared = DictionaryLookupService()
    
    private init() {}
    
    /// Presents Apple's native system dictionary UIReferenceLibraryViewController for `term`
    /// and automatically saves the word into SwiftData if modelContext is provided.
    func lookupAndSave(
        term: String,
        contextSentence: String = "",
        bookTitle: String = "General Reading",
        bookID: String? = nil,
        modelContext: ModelContext? = nil
    ) {
        let cleanTerm = term.trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
        guard !cleanTerm.isEmpty else { return }
        
        // Auto-save into SwiftData if available
        if let modelContext = modelContext {
            saveWord(
                cleanTerm,
                contextSentence: contextSentence,
                bookTitle: bookTitle,
                bookID: bookID,
                modelContext: modelContext
            )
        }
        
        // Present Apple's system dictionary modal
        presentSystemDictionary(for: cleanTerm)
    }
    
    func presentSystemDictionary(for term: String) {
        guard let windowScene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
              let rootVC = windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
            return
        }
        
        var topVC = rootVC
        while let presented = topVC.presentedViewController {
            topVC = presented
        }
        
        let dictVC = UIReferenceLibraryViewController(term: term)
        topVC.present(dictVC, animated: true, completion: nil)
    }
    
    private func saveWord(
        _ word: String,
        contextSentence: String,
        bookTitle: String,
        bookID: String?,
        modelContext: ModelContext
    ) {
        let lowercased = word.lowercased()
        let fetchDescriptor = FetchDescriptor<SDVocabularyWord>(
            predicate: #Predicate { $0.word == lowercased || $0.word == word }
        )
        
        do {
            let existing = try modelContext.fetch(fetchDescriptor)
            if let first = existing.first {
                first.dateAdded = Date()
                if !contextSentence.isEmpty {
                    first.contextSentence = contextSentence
                }
            } else {
                let newWord = SDVocabularyWord(
                    word: word,
                    contextSentence: contextSentence,
                    bookID: bookID,
                    bookTitle: bookTitle
                )
                modelContext.insert(newWord)
            }
            try modelContext.save()
        } catch {
            print("[DictionaryLookupService] Error saving vocabulary word: \(error)")
        }
    }
}
