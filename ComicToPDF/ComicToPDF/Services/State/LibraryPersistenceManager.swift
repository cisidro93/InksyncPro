import Foundation

/// Coordinates the extraction of the massive Application Memory arrays into monolithic JSON bounds without violently throttling the Main Actor's 120Hz pipeline.
class LibraryPersistenceManager {
    static let shared = LibraryPersistenceManager()
    
    private let libraryFileName = "inksync_pro_library.json"
    
    private init() {}
    
    struct LibraryIndex: Codable {
        let files: [ConvertedPDF]
        let collections: [PDFCollection]
        let settings: ConversionSettings
        let history: [ConvertedPDF]
        let devices: [KindleDevice]
        var panelOverrides: [UUID: [Int: [PanelExtractor.Panel]]]? = nil
        var watchedFolders: [ConversionManager.WatchedFolder]? = nil
        var presets: [ConversionPreset]? = nil
        var registeredDevices: [RegisteredDevice]? = nil
        var primaryDeviceID: UUID? = nil
    }
    
    /// Snapshots the Façade state properties and dispatches them deep inside a background payload for asynchronous storage.
    @MainActor
    func save(manager: ConversionManager) {
        let index = LibraryIndex(
            files: [], // ✅ Deprecated: Unshackled from JSON Monolith (Handled by SwiftData Native)
            collections: [], // ✅ Deprecated: Migrated to SDPDFCollection
            settings: manager.conversionSettings,
            history: manager.sendHistory,
            devices: manager.kindleDevices,
            panelOverrides: WorkspaceSessionManager.shared.panelOverrides,
            watchedFolders: manager.watchedFolders,
            presets: manager.conversionPresets,
            registeredDevices: DeviceRegistry.shared.registeredDevices,
            primaryDeviceID: DeviceRegistry.shared.primaryDeviceID
        )
        
        let syncPDFs = manager.convertedPDFs
        let syncCols = manager.collections
        
        Task.detached(priority: .background) {
            guard let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent(self.libraryFileName) else { return }
            
            do {
                let encoded = try JSONEncoder().encode(index)
                
                // Advanced Crash Safety: Atomic Swap (Stops Null-byte corruption if the battery dies mid-save)
                let tempURL = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".tmp")
                try encoded.write(to: tempURL, options: .atomic)
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
                
            } catch {
                Logger.shared.log("LibraryPersistenceManager: Background Save Failed: \(error)", category: "Persistence", type: .error)
            }
            
            // ✅ Trigger Dual-Write Sync to SwiftData
            await MigrationService.shared.syncToSwiftData(pdfs: syncPDFs, collections: syncCols)
        }
    }
    
    /// Awakens the Database structure from the filesystem memory blocks natively onto the Main Queue arrays.
    func load(manager: ConversionManager) {
        guard let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent(self.libraryFileName) else { return }
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        
        // Unshackled from legacy filesystem array extraction, natively bridge from ModelContainer
        Task.detached(priority: .userInitiated) {
            do {
                let (sdPdfs, sdCols) = try await MigrationService.shared.fetchSwiftDataLegacyBridge()
                
                let legacyPDFs = sdPdfs.map { $0.toDTO() }
                let legacyCols = sdCols.map { $0.toDTO() }
                
                await MainActor.run {
                    manager.convertedPDFs = legacyPDFs
                    manager.collections = legacyCols
                    
                    // We only load Settings/History from JSON now
                    if let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent(self.libraryFileName),
                       FileManager.default.fileExists(atPath: url.path),
                       let data = try? Data(contentsOf: url),
                       let index = try? JSONDecoder().decode(LibraryIndex.self, from: data) {
                        
                        manager.conversionSettings = index.settings
                        manager.sendHistory = index.history
                        manager.kindleDevices = index.devices
                        WorkspaceSessionManager.shared.panelOverrides = index.panelOverrides ?? [:]
                        manager.watchedFolders = index.watchedFolders ?? []
                        manager.conversionPresets = index.presets ?? []
                        DeviceRegistry.shared.registeredDevices = index.registeredDevices ?? []
                        DeviceRegistry.shared.primaryDeviceID = index.primaryDeviceID
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
