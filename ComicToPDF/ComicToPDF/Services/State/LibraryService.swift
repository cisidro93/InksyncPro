import Foundation
import Combine
import SwiftUI

/// Unidirectional service manager holding the single source of truth for the library items and collections.
@MainActor
final class LibraryService: ObservableObject {
    static let shared = LibraryService()
    
    @Published var items: [ConvertedPDF] = []
    @Published var collections: [PDFCollection] = []
    @Published var virtualOmnibuses: [VirtualOmnibus] = []
    
    private init() {}
    
    /// Loads the library from SwiftData repository into memory.
    func loadLibrary() async {
        do {
            let (loadedItems, loadedCollections) = try await LibraryRepository.shared.loadLibrary()
            self.items = loadedItems
            self.collections = loadedCollections
            self.virtualOmnibuses = await LibraryDatabaseService.shared.loadVirtualOmnibuses()
            Logger.shared.log("LibraryService: loaded \(loadedItems.count) items, \(loadedCollections.count) collections, \(self.virtualOmnibuses.count) virtual omnibuses.", category: "Library")
            self.syncAllRemoteVirtualOmnibuses()
            
            // Spawn background task for re-anchoring, ghost pruning, and self-healing.
            Task {
                do {
                    let didChange = try await LibraryRepository.shared.performSelfHealingAndCleanup()
                    if didChange {
                        await loadLibrary()
                    }
                } catch {
                    Logger.shared.log("LibraryService: background self-healing failed: \(error.localizedDescription)", category: "Library", type: .error)
                }
            }
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
            
            // Organize flat library files under series subdirectories retroactively
            if let manager = ConversionManager.shared {
                await PhysicalFileSystemRouter.shared.migrateFlatFilesToSeriesDirectories(manager: manager)
            }
        } catch {
            Logger.shared.log("LibraryService: smart grouping failed: \(error.localizedDescription)", category: "Library", type: .error)
        }
    }
    
    
    /// Saves the virtual omnibuses array to the local database.
    func saveVirtualOmnibuses() {
        let omnibuses = self.virtualOmnibuses
        Logger.shared.log("🔍 [Flight Recorder] 📦 [Virtual Volume] Saving \(omnibuses.count) virtual volumes to database", category: "Debug")
        Task.detached(priority: .background) {
            await LibraryDatabaseService.shared.saveVirtualOmnibuses(omnibuses)
        }
    }
    
    /// Post-import helper to notify that the library changed.
    func notifyImportCompleted() {
        NotificationCenter.default.post(name: .libraryNeedsRescan, object: nil)
    }
    
    /// Synchronizes a specific virtual omnibus with its remote source (CBL or CSV).
    func syncRemoteVirtualOmnibus(_ omnibus: VirtualOmnibus) async {
        guard let urlString = omnibus.remoteSyncURL,
              let url = URL(string: urlString) else { return }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            
            // Save to temp file to reuse existing parser logic
            let tempDir = FileManager.default.temporaryDirectory
            let tempURL = tempDir.appendingPathComponent(UUID().uuidString).appendingPathExtension(url.pathExtension)
            try data.write(to: tempURL)
            defer { try? FileManager.default.removeItem(at: tempURL) }
            
            let requests: [RequestedComicItem]
            if url.pathExtension.lowercased() == "cbl" {
                requests = try SmartListImporter.shared.parseCBL(from: tempURL)
            } else {
                let cleanName = url.deletingPathExtension().lastPathComponent
                requests = try SmartListImporter.shared.parseCSVList(from: tempURL, defaultSeriesName: cleanName)
            }
            
            let customAliases = AppSettingsManager.shared.conversionSettings.customAliases
            let libraryPDFs = self.items
            
            let resolutions = await SmartListImporter.shared.resolveList(requests, against: libraryPDFs, customAliases: customAliases)
            
            // Extract the matched/suggested file IDs in the precise parsed order
            let matchedIDs = resolutions.compactMap { resolved -> UUID? in
                switch resolved.resolution {
                case .matched(let pdf): return pdf.id
                case .suggested(let pdf): return pdf.id
                case .missing: return nil
                }
            }
            
            // Perform UI and DB update on the Main Thread
            await MainActor.run {
                if let idx = self.virtualOmnibuses.firstIndex(where: { $0.id == omnibus.id }) {
                    var updated = self.virtualOmnibuses[idx]
                    updated.fileIDs = matchedIDs
                    updated.lastSyncedAt = Date()
                    updated.modifiedAt = Date()
                    self.virtualOmnibuses[idx] = updated
                    self.saveVirtualOmnibuses()
                    Logger.shared.log("LibraryService: synced remote virtual omnibus '\(updated.name)' with \(matchedIDs.count) resolved files.", category: "Library")
                }
            }
        } catch {
            Logger.shared.log("LibraryService: remote sync failed for '\(omnibus.name)' — \(error.localizedDescription)", category: "Library", type: .error)
        }
    }
    
    /// Synchronizes all virtual omnibuses that have remote sync URLs.
    func syncAllRemoteVirtualOmnibuses() {
        let targets = self.virtualOmnibuses.filter { $0.remoteSyncURL != nil && !$0.remoteSyncURL!.isEmpty }
        guard !targets.isEmpty else { return }
        
        Task {
            for target in targets {
                await syncRemoteVirtualOmnibus(target)
            }
        }
    }
}
