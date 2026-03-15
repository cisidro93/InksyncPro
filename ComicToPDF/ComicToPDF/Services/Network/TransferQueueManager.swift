import Foundation
import Combine

/// Manages a persistent queue of files staged for WiFi transfer.
/// This allows the user to navigate through multiple folders in the Library
/// and selectively add items to a master transfer list before initiating
/// a Hybrid P2P LocalSend or Fallback Web Server transfer.
class TransferQueueManager: ObservableObject {
    static let shared = TransferQueueManager()
    
    /// The list of files currently staged for transfer.
    @Published private(set) var stagedFiles: [ConvertedPDF] = []
    
    /// Total bytes currently staged in the queue.
    @Published private(set) var totalStagedBytes: Int64 = 0
    
    private init() {}
    
    /// Adds a file to the transfer queue if it isn't already staged.
    func stageFile(_ pdf: ConvertedPDF) {
        DispatchQueue.main.async {
            guard !self.stagedFiles.contains(where: { $0.id == pdf.id }) else { return }
            self.stagedFiles.append(pdf)
            self.recalculateQueueSize()
        }
    }
    
    /// Removes a file from the transfer queue.
    func unstageFile(_ pdf: ConvertedPDF) {
        DispatchQueue.main.async {
            self.stagedFiles.removeAll(where: { $0.id == pdf.id })
            self.recalculateQueueSize()
        }
    }
    
    /// Checks if a file is currently in the transfer queue.
    func isStaged(_ pdf: ConvertedPDF) -> Bool {
        return stagedFiles.contains(where: { $0.id == pdf.id })
    }
    
    /// Clears the entire transfer queue.
    func clearQueue() {
        DispatchQueue.main.async {
            self.stagedFiles.removeAll()
            self.totalStagedBytes = 0
        }
    }
    
    /// Returns a formatted string representing the total size of staged files.
    func formattedTotalSize() -> String {
        let mb = Double(totalStagedBytes) / 1024.0 / 1024.0
        return String(format: "%.1f MB", mb)
    }
    
    private func recalculateQueueSize() {
        totalStagedBytes = stagedFiles.reduce(0) { $0 + $1.fileSize }
    }
}
