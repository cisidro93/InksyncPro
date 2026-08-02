import Foundation
import Combine
import SwiftUI

/// Background iCloud Drive Document Synchronization Manager
///
/// Features:
/// - Mirrors library files (.cbz, .epub, .pdf) to iCloud Ubiquity container
/// - Monitors incoming iCloud Drive documents from other devices
/// - Handles background uploading and downloading with status feedback
@MainActor
final class iCloudFileSyncManager: ObservableObject {
    static let shared = iCloudFileSyncManager()

    @AppStorage("enableiCloudDocumentSync") var isSyncEnabled: Bool = false
    @Published var isSyncing: Bool = false
    @Published var syncStatusText: String = "iCloud Sync Idle"
    @Published var lastSyncDate: Date? = nil

    private var query: NSMetadataQuery?

    private init() {
        setupQuery()
    }

    /// Check if iCloud Ubiquity container is available on this device.
    var isUbiquityAvailable: Bool {
        FileManager.default.ubiquityIdentityToken != nil
    }

    /// Get the active iCloud Documents directory.
    var iCloudDocumentsURL: URL? {
        guard isUbiquityAvailable else { return nil }
        guard let container = FileManager.default.url(forUbiquityContainerID: nil) else { return nil }
        let docs = container.appendingPathComponent("Documents", isDirectory: true)
        if !FileManager.default.fileExists(atPath: docs.path) {
            try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        }
        return docs
    }

    /// Mirror local library items to iCloud Drive container.
    func syncLibraryItems(_ items: [ConvertedPDF]) async {
        guard isSyncEnabled, let cloudDir = iCloudDocumentsURL else { return }
        isSyncing = true
        syncStatusText = "Syncing with iCloud..."

        var syncedCount = 0
        for item in items {
            let localURL = item.url
            guard FileManager.default.fileExists(atPath: localURL.path) else { continue }
            let destURL = cloudDir.appendingPathComponent(localURL.lastPathComponent)

            if !FileManager.default.fileExists(atPath: destURL.path) {
                do {
                    try FileManager.default.copyItem(at: localURL, to: destURL)
                    syncedCount += 1
                } catch {
                    Logger.shared.log("iCloudFileSyncManager: Mirror failed for \(localURL.lastPathComponent): \(error.localizedDescription)", category: "Cloud", type: .error)
                }
            }
        }

        isSyncing = false
        lastSyncDate = Date()
        syncStatusText = syncedCount > 0 ? "Synced \(syncedCount) new files to iCloud" : "iCloud Up to Date"
    }

    /// Download a cloud-stored file to local cache if not yet downloaded.
    func startDownloadingUbiquitousItem(at url: URL) {
        do {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
            syncStatusText = "Downloading \(url.lastPathComponent) from iCloud..."
        } catch {
            Logger.shared.log("iCloudFileSyncManager: Download request failed: \(error.localizedDescription)", category: "Cloud", type: .error)
        }
    }

    // MARK: - iCloud Directory Monitoring

    private func setupQuery() {
        guard isUbiquityAvailable else { return }
        let q = NSMetadataQuery()
        q.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        q.predicate = NSPredicate(format: "%K LIKE '*'", NSMetadataItemFSNameKey)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(metadataQueryDidUpdate(_:)),
            name: .NSMetadataQueryDidUpdate,
            object: q
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(metadataQueryDidFinishGathering(_:)),
            name: .NSMetadataQueryDidFinishGathering,
            object: q
        )

        q.start()
        self.query = q
    }

    @objc private func metadataQueryDidUpdate(_ notification: Notification) {
        Task { @MainActor in
            self.processMetadataResults()
        }
    }

    @objc private func metadataQueryDidFinishGathering(_ notification: Notification) {
        Task { @MainActor in
            self.processMetadataResults()
        }
    }

    private func processMetadataResults() {
        guard let query = query else { return }
        query.disableUpdates()
        defer { query.enableUpdates() }

        var cloudFiles: [URL] = []
        for item in query.results {
            if let metadataItem = item as? NSMetadataItem,
               let url = metadataItem.value(forAttribute: NSMetadataItemURLKey) as? URL {
                cloudFiles.append(url)
            }
        }

        if !cloudFiles.isEmpty {
            syncStatusText = "\(cloudFiles.count) cloud items available"
        }
    }
}
