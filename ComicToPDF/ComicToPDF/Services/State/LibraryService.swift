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
    
    /// Runs background smart grouping on SwiftData, then reloads the items to update the UI.
    func runSmartGrouping() async {
        do {
            // 1. Sync current memory state to background DB
            let pdfsToSync = items
            let colsToSync = collections
            try await LibraryRepository.shared.sync(pdfs: pdfsToSync, collections: colsToSync)
            
            // 2. Perform background smart grouping
            _ = try await LibraryRepository.shared.performSmartGrouping()
            
            // 3. Rollback main context to force SwiftData @Query to reload from SQLite
            await MainActor.run {
                InksyncProApp.sharedModelContainer.mainContext.rollback()
            }
            
            // 4. Reload from SwiftData to memory to update UI
            await loadLibrary()
        } catch {
            Logger.shared.log("LibraryService: smart grouping failed: \(error.localizedDescription)", category: "Library", type: .error)
        }
    }
    
    /// Post-import helper to notify that the library changed.
    func notifyImportCompleted() {
        NotificationCenter.default.post(name: .libraryNeedsRescan, object: nil)
    }
}
