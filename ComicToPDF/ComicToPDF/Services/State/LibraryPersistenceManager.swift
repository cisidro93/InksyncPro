import Foundation

// PERSISTENCE NOTE: SQLite (GRDB) is local-only by design.
// iCloud portability is handled via JSON export in BackupRestoreView.
// Do NOT move library.db into the iCloud Documents container.

/// Coordinates the extraction of the massive Application Memory arrays into monolithic JSON bounds without violently throttling the Main Actor's 120Hz pipeline.
class LibraryPersistenceManager {
    static let shared = LibraryPersistenceManager()
    
    private let libraryFileName = "inksync_pro_library.json"
    
    private init() {}
    
    struct LibraryIndex: Codable {
        let files: [ConvertedPDF]
        let collections: [PDFCollection]
        var panelOverrides: [UUID: [Int: [PanelExtractor.Panel]]]? = nil
        var registeredDevices: [RegisteredDevice]? = nil
        var primaryDeviceID: UUID? = nil
    }
    
    @MainActor
    func save(manager: ConversionManager) {
        let syncPDFs = manager.convertedPDFs
        let syncCols = manager.collections
        let isStructural = manager.hasStructuralChange
        manager.hasStructuralChange = false   // reset after capture

        Task.detached(priority: .background) {
            // PERF D-M2: Only sync SwiftData when the library structure changed.
            // Page-turn progress writes (the majority of debounce fires) skip this
            // expensive N-row migration entirely.
            if isStructural {
                await MigrationService.shared.syncToSwiftData(pdfs: syncPDFs, collections: syncCols)
            }
            await LibraryDatabaseService.shared.save(syncPDFs)
        }
    }

    /// SQLite-only save for progress updates. Never calls syncToSwiftData.
    @MainActor
    func saveProgressOnly(manager: ConversionManager) {
        let syncPDFs = manager.convertedPDFs
        Task.detached(priority: .background) {
            await LibraryDatabaseService.shared.save(syncPDFs)
        }
    }
    
    /// Awakens the Database structure from the filesystem memory blocks natively onto the Main Queue arrays.
    func load(manager: ConversionManager) {
        Task.detached(priority: .userInitiated) {
            do {
                let (sdPdfs, sdCols) = try await MigrationService.shared.fetchSwiftDataLegacyBridge()
                
                let legacyPDFs = sdPdfs.map { $0.toDTO() }
                let legacyCols = sdCols.map { $0.toDTO() }
                
                await MainActor.run {
                    manager.convertedPDFs = legacyPDFs
                    manager.collections = legacyCols
                    
                    if let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent(self.libraryFileName),
                       FileManager.default.fileExists(atPath: url.path),
                       let data = try? Data(contentsOf: url),
                       let index = try? JSONDecoder().decode(LibraryIndex.self, from: data) {
                        
                        if let legacyPanels = index.panelOverrides, !legacyPanels.isEmpty {
                            for (pdfID, pages) in legacyPanels {
                                for (pageIndex, visionPanels) in pages {
                                    var newModel = PageModel(pageIndex: pageIndex)
                                    var allNormalized = true
                                    newModel.panels = visionPanels.map { panel in
                                        let rect = panel.boundingBox
                                        if rect.maxX <= 1.1 && rect.maxY <= 1.1 {
                                            return NormalizedRect(x: rect.minX * 1000, y: rect.minY * 1000, width: rect.width * 1000, height: rect.height * 1000)
                                        } else {
                                            allNormalized = false
                                            return NormalizedRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
                                        }
                                    }
                                    if !newModel.panels.isEmpty && allNormalized {
                                        newModel.coordinateSystem = .normalized
                                    } else {
                                        newModel.coordinateSystem = .unknown 
                                    }
                                    PageModelStore.shared.savePageModel(newModel, for: pdfID)
                                }
                            }
                        }
                        
                        DeviceRegistry.shared.registeredDevices = index.registeredDevices ?? []
                        DeviceRegistry.shared.primaryDeviceID = index.primaryDeviceID
                        
                        try? FileManager.default.removeItem(at: url)
                    }
                }
            } catch {
                await MainActor.run {
                    Logger.shared.log("Critical Boot Error: Bridge Load Failed. \(error.localizedDescription)", category: "Library", type: .error)
                }
            }
        }
    }
    
    func createWelcomeFile() {
        let fileManager = FileManager.default
        if let docDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            let welcomeURL = docDir.appendingPathComponent("Welcome.txt")
            if !fileManager.fileExists(atPath: welcomeURL.path) {
                let content = "Welcome to Inksync Pro!\n\nThis folder is where you can access your converted files.\nTo import comics, you can drag and drop them here or use the 'Import' button in the app."
                try? content.write(to: welcomeURL, atomically: true, encoding: .utf8)
            }
        }
    }
}

