import Foundation
import SwiftUI
import Combine

/// Tracks the progress and results of background `ConversionManager.importFilesAsSeries` jobs.
/// Isolated to `@MainActor` so all `@Published` mutations are thread-safe without
/// requiring individual `@MainActor` annotations on each method.
@MainActor
final class ImportMonitorManager: ObservableObject {
    static let shared = ImportMonitorManager()

    @Published private(set) var isImporting: Bool = false
    @Published private(set) var totalFilesToProcess: Int = 0
    @Published private(set) var filesProcessed: Int = 0
    @Published private(set) var filesFailed: Int = 0
    @Published private(set) var isCancelled: Bool = false

    // Survival token — keeps the import alive when the app is backgrounded.
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    // Fires with a batch UUID when an import run reaches terminal state.
    // Subscribers can use this to trigger post-import housekeeping.
    let batchCompletionPublisher = PassthroughSubject<UUID, Never>()

    private init() {}

    // MARK: - Lifecycle

    func startImport(totalCount: Int) {
        isImporting = true
        totalFilesToProcess = totalCount
        filesProcessed = 0
        filesFailed = 0
        isCancelled = false

        if backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "ImportMonitor") { [weak self] in
                guard let self else { return }
                UIApplication.shared.endBackgroundTask(self.backgroundTask)
                self.backgroundTask = .invalid
            }
        }
    }

    func incrementSuccess() {
        filesProcessed += 1
    }

    func incrementFailure() {
        filesProcessed += 1
        filesFailed += 1
    }

    func completeImport(batchID: UUID = UUID()) {
        isImporting = false
        let successCount = totalFilesToProcess - filesFailed
        Logger.shared.log(
            "Import complete — \(successCount) succeeded, \(filesFailed) failed.",
            category: "Import",
            type: successCount > 0 ? .success : .warning
        )

        // Fire the batch completion publisher so any waiting subscribers are notified.
        batchCompletionPublisher.send(batchID)

        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }
    
    func cancelImport() {
        isCancelled = true
        Logger.shared.log("Import cancelled by user.", category: "Import", type: .warning)
    }

    // MARK: - Derived State

    var progress: Double {
        guard totalFilesToProcess > 0 else { return 0 }
        return Double(filesProcessed) / Double(totalFilesToProcess)
    }
}

