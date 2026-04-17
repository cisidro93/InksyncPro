import Foundation
import Combine

/// Manages a persistent queue of files staged for WiFi transfer.
/// Annotated @MainActor so all published state mutations happen on the main actor
/// directly — no DispatchQueue.main.async hops needed.
@MainActor
class TransferQueueManager: ObservableObject {
    static let shared = TransferQueueManager()

    /// The list of files currently staged for transfer.
    @Published private(set) var stagedFiles: [ConvertedPDF] = []

    /// Total bytes currently staged in the queue.
    @Published private(set) var totalStagedBytes: Int64 = 0

    private init() {}

    /// Adds a file to the transfer queue if it isn't already staged.
    func stageFile(_ pdf: ConvertedPDF) {
        guard !stagedFiles.contains(where: { $0.id == pdf.id }) else { return }
        stagedFiles.append(pdf)
        recalculateQueueSize()
    }

    /// Removes a file from the transfer queue.
    func unstageFile(_ pdf: ConvertedPDF) {
        stagedFiles.removeAll(where: { $0.id == pdf.id })
        recalculateQueueSize()
    }

    /// Checks if a file is currently in the transfer queue.
    func isStaged(_ pdf: ConvertedPDF) -> Bool {
        stagedFiles.contains(where: { $0.id == pdf.id })
    }

    /// Thread-safe snapshot for nonisolated callers (e.g. WiFiServer network handlers).
    /// Uses DispatchQueue.main.sync when called from a background thread, which is always
    /// the case for WiFiServer's NWConnection handlers. Falls back to assumeIsolated if
    /// already on the main thread to avoid a deadlock.
    nonisolated func stagedFilesSnapshot() -> [ConvertedPDF] {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { stagedFiles }
        }
        return DispatchQueue.main.sync { stagedFiles }
    }

    /// Clears the entire transfer queue.
    func clearQueue() {
        stagedFiles.removeAll()
        totalStagedBytes = 0
    }

    /// Returns a formatted string representing the total size of staged files.
    func formattedTotalSize() -> String {
        let mb = Double(totalStagedBytes) / 1_048_576.0
        if mb >= 1000 {
            return String(format: "%.1f GB", mb / 1024.0)
        }
        return String(format: "%.1f MB", mb)
    }

    private func recalculateQueueSize() {
        totalStagedBytes = stagedFiles.reduce(0) { $0 + $1.fileSize }
    }
}
