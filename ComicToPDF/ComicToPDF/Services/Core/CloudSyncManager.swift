import Foundation
import Combine
import BackgroundTasks
import UIKit

/// Manages intelligent background synchronization for the "Inbox" folder in iCloud Drive.
@MainActor
class CloudSyncManager: ObservableObject {
    static let shared = CloudSyncManager()
    
    @Published var isSyncing: Bool = false
    @Published var lastSyncDate: Date? = nil
    
    // Default inbox folder in the App's ubiquitous container
    private var inboxURL: URL? {
        guard let containerURL = FileManager.default.url(forUbiquityContainerIdentifier: nil) else {
            return nil
        }
        let folder = containerURL.appendingPathComponent("Documents/Inbox", isDirectory: true)
        
        if !FileManager.default.fileExists(atPath: folder.path) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return folder
    }
    
    private init() {
        // Load last sync date if needed
        lastSyncDate = UserDefaults.standard.object(forKey: "LastSyncDate") as? Date
    }
    
    /// Called by the BGAppRefreshTask in AppDelegate/App struct.
    func performSync() async {
        guard UserDefaults.standard.bool(forKey: "enableBackgroundSync") else { return }
        guard let inbox = inboxURL else { return }
        
        await MainActor.run { isSyncing = true }
        
        // 1. Coordinate File Reading
        // If files are currently downloading from iCloud, NSFileCoordinator ensures we wait
        let coordinator = NSFileCoordinator()
        let error: NSErrorPointer = nil
        
        var filesToProcess: [URL] = []
        
        coordinator.coordinate(readingItemAt: inbox, options: .withoutChanges, error: error) { url in
            do {
                let items = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey])
                
                // Filter only valid extensions (.cbz, .zip, .pdf)
                filesToProcess = items.filter { file in
                    ["cbz", "zip", "pdf"].contains(file.pathExtension.lowercased())
                }
            } catch {
                Logger.shared.log("CloudSync: error reading inbox — \(error.localizedDescription)", category: "Cloud", type: .error)
            }
        }
        
        guard !filesToProcess.isEmpty else {
            await MainActor.run {
                isSyncing = false
                lastSyncDate = Date()
                UserDefaults.standard.set(self.lastSyncDate, forKey: "LastSyncDate")
            }
            return
        }
        
        // 2. Fetch Default Conversion Settings
        let settings = ConversionQueueManager.shared.queue.first?.settings ?? ConversionSettings() 
        // Note: we should actually pull this from a global "AutoSyncSettings" instead, but doing best effort here.
        var autoSettings = settings
        autoSettings.outputFormat = .epub
        autoSettings.outputPipeline = .standard
        
        let finalSettings = autoSettings
        
        // 3. Setup Archive Folder to prevent double-queuing
        let archiveFolder = inbox.deletingLastPathComponent().appendingPathComponent("Archive", isDirectory: true)
        if !FileManager.default.fileExists(atPath: archiveFolder.path) {
            try? FileManager.default.createDirectory(at: archiveFolder, withIntermediateDirectories: true)
        }
        
        Logger.shared.log("CloudSync: \(filesToProcess.count) file(s) found in inbox — queuing", category: "Cloud")
        for file in filesToProcess {
            let destinationURL = archiveFolder.appendingPathComponent(file.lastPathComponent)
            
            // 🚨 COMPETITOR FIX: Enforce NSFileCoordinator writing locks on iCloud ubiquitous artifacts to block sync tearing
            let writeCoordinator = NSFileCoordinator()
            var coordinateError: NSError?
            
            writeCoordinator.coordinate(writingItemAt: file, options: .forMoving, writingItemAt: destinationURL, options: .forReplacing, error: &coordinateError) { safeSource, safeDest in
                do {
                    if FileManager.default.fileExists(atPath: safeDest.path) {
                        try FileManager.default.removeItem(at: safeDest)
                    }
                    try FileManager.default.moveItem(at: safeSource, to: safeDest)
                    
                    Task { @MainActor in
                        ConversionQueueManager.shared.enqueue(url: safeDest, settings: finalSettings, mode: .go)
                    }
                } catch {
                    Logger.shared.log("CloudSync: failed to archive \(safeSource.lastPathComponent) — \(error.localizedDescription)", category: "Cloud", type: .error)
                }
            }
            
            if let error = coordinateError {
                Logger.shared.log("CloudSync: FileCoordinator refused lock for \(file.lastPathComponent) — \(error.localizedDescription)", category: "Cloud", type: .warning)
            }
        }
        
        // Wait for conversions if needed? BGTask might kill us.
        // For a true BGTask, we trigger the queue and hope the device stays awake long enough,
        // or we use a separate URLSession background upload.
        
        await MainActor.run {
            self.isSyncing = false
            self.lastSyncDate = Date()
            UserDefaults.standard.set(self.lastSyncDate, forKey: "LastSyncDate")
        }
    }
}
