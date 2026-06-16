import Foundation
import Combine
import SwiftUI

/// Unidirectional service manager holding the single source of truth for the library items and collections.
@MainActor
final class LibraryService: ObservableObject {
    static let shared = LibraryService()
    
    @Published var items: [ConvertedPDF] = []
    @Published var collections: [PDFCollection] = []
    
    private init() {}
    
    /// Loads the library from SwiftData repository into memory.
    func loadLibrary() async {
        do {
            let (loadedItems, loadedCollections) = try await LibraryRepository.shared.loadLibrary()
            self.items = loadedItems
            self.collections = loadedCollections
            Logger.shared.log("LibraryService: loaded \(loadedItems.count) items, \(loadedCollections.count) collections.", category: "Library")
        } catch {
            Logger.shared.log("LibraryService: failed to load library: \(error.localizedDescription)", category: "Library", type: .error)
        }
    }
    
    /// Saves the current memory state back to SwiftData repository.
    func saveLibrary(isStructural: Bool) {
        let pdfsToSync = items
        let colsToSync = collections
        Task.detached(priority: .background) {
            try? await LibraryRepository.shared.sync(pdfs: pdfsToSync, collections: colsToSync)
        }
    }
    
    /// Syncs only progress (page position) updates to the database.
    func saveProgressOnly() {
        let pdfsToSync = items
        let colsToSync = collections
        Task.detached(priority: .background) {
            try? await LibraryRepository.shared.sync(pdfs: pdfsToSync, collections: colsToSync)
        }
    }
    
    /// Post-import helper to notify that the library changed.
    func notifyImportCompleted() {
        NotificationCenter.default.post(name: .libraryNeedsRescan, object: nil)
    }
}
