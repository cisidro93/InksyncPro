import Foundation
import SwiftUI
import Combine

/// Tracks the progress and results of background `ConversionManager.importFilesAsSeries` jobs.
/// This prevents the UI from locking up during massive Multi-Folder imports.
class ImportMonitorManager: ObservableObject {
    static let shared = ImportMonitorManager()
    
    @Published private(set) var isImporting: Bool = false
    @Published private(set) var totalFilesToProcess: Int = 0
    @Published private(set) var filesProcessed: Int = 0
    @Published private(set) var filesFailed: Int = 0
    
    // Unrestricted Background Processing Survival Token
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    // Publisher fires with the batch UUID when all jobs in a queue reach terminal state.
    let batchCompletionPublisher = PassthroughSubject<UUID, Never>()

    
    private init() {}
    
    @MainActor
    func startImport(totalCount: Int) {
        self.isImporting = true
        self.totalFilesToProcess = totalCount
        self.filesProcessed = 0
        self.filesFailed = 0
        
        // Grab a survival token from iOS Springboard to prevent the watchdog from killing the thread when minimized
        if self.backgroundTask == .invalid {
            self.backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "ImportMonitor") {
                UIApplication.shared.endBackgroundTask(self.backgroundTask)
                self.backgroundTask = .invalid
            }
        }
    }
    
    @MainActor
    func incrementSuccess() {
        self.filesProcessed += 1
    }
    
    @MainActor
    func incrementFailure() {
        self.filesProcessed += 1
        self.filesFailed += 1
    }
    
    @MainActor
    func completeImport() {
        self.isImporting = false
        
        let _ = totalFilesToProcess - filesFailed
        
        // Release the survival token back to iOS to allow natural sleeping
        if self.backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(self.backgroundTask)
            self.backgroundTask = .invalid
        }
    }
    
    var progress: Double {
        guard totalFilesToProcess > 0 else { return 0 }
        return Double(filesProcessed) / Double(totalFilesToProcess)
    }
}
