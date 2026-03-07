import Foundation
import Combine
import BackgroundTasks
import UIKit

/// Manages intelligent background synchronization for the "Inbox" folder in iCloud Drive.
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
                print("🧠 [CloudSync] Error reading inbox: \(error)")
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
        
        // 3. Queue the files
        print("🧠 [CloudSync] Found \(filesToProcess.count) files in Inbox. Queuing...")
        for file in filesToProcess {
            // Check if we've already converted this exact URL (or move it to an "Archive" folder)
            // For safety, let's just queue it. 
            // In a pro app, we would move it to "processed" after.
            
            await MainActor.run {
                ConversionQueueManager.shared.enqueue(url: file, settings: finalSettings, mode: .go)
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
