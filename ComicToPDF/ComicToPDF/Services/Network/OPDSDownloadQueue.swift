import Foundation
import Combine

// MARK: - OPDS Download Queue
//
// Persistent, background-URLSession download manager for OPDS book downloads.
// Uses a background URLSession so large downloads survive app backgrounding.
// Pending downloads are persisted to UserDefaults and resumed on next launch.
//
// Usage:
//   OPDSDownloadQueue.shared.enqueue(title: "Saga #1", downloadURL: url, mimeType: "application/zip", serverID: server.id)
//   // Progress: observe queue publisher
//   // Completion: ConversionManager.processImportedFiles is called automatically

// MARK: - Download Record

struct OPDSDownloadRecord: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var title: String
    var downloadURL: URL
    var mimeType: String
    var serverID: UUID?
    var taskIdentifier: Int = 0           // URLSessionDownloadTask.taskIdentifier
    var fractionCompleted: Double = 0.0   // 0...1 for progress ring
}

// MARK: - Queue Manager

@MainActor
final class OPDSDownloadQueue: NSObject, ObservableObject {

    // MARK: Singleton
    static let shared = OPDSDownloadQueue()

    // MARK: Published state
    @Published var queue: [OPDSDownloadRecord] = []

    // MARK: Private
    private let sessionID = "com.inksyncpro.opds.dl"
    private let defaultsKey = "opds_download_queue_v1"
    private var backgroundSession: URLSession!
    private var backgroundCompletionHandler: (() -> Void)?
    private var activeTasks: [Int: OPDSDownloadRecord] = [:]   // taskID → record

    // PERF M3: Throttle didWriteData MainActor hops to 4 fps (250ms).
    // URLSessionDownloadDelegate fires progress at ~50 fps on large downloads
    // which would schedule 50 MainActor crossings/sec and cause UI jitter.
    private var lastProgressUpdate: [Int: Date] = [:]   // taskID → last update time

    // MARK: Init
    override init() {
        super.init()
        let config = URLSessionConfiguration.background(withIdentifier: sessionID)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        backgroundSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        loadPersistedQueue()
    }

    // MARK: - Enqueue

    func enqueue(title: String, downloadURL: URL, mimeType: String, serverID: UUID? = nil) {
        var record = OPDSDownloadRecord(
            title: title,
            downloadURL: downloadURL,
            mimeType: mimeType,
            serverID: serverID
        )
        let task = backgroundSession.downloadTask(with: downloadURL)
        record.taskIdentifier = task.taskIdentifier
        queue.append(record)
        activeTasks[task.taskIdentifier] = record
        persistQueue()
        task.resume()
        Logger.shared.log("OPDSDownloadQueue: enqueued '\(title)'", category: "OPDS")
    }

    // MARK: - Cancel

    func cancel(id: UUID) {
        if let idx = queue.firstIndex(where: { $0.id == id }) {
            let record = queue[idx]
            backgroundSession.getAllTasks { tasks in
                tasks.first(where: { $0.taskIdentifier == record.taskIdentifier })?.cancel()
            }
            queue.remove(at: idx)
            activeTasks.removeValue(forKey: record.taskIdentifier)
            persistQueue()
        }
    }

    // MARK: - Background events (called from AppDelegate)

    func handleBackgroundEvents(completionHandler: @escaping () -> Void) {
        backgroundCompletionHandler = completionHandler
    }

    // MARK: - Persistence

    private func loadPersistedQueue() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let records = try? JSONDecoder().decode([OPDSDownloadRecord].self, from: data)
        else { return }

        // Restore only items that don't already have a live task.
        // Background tasks survive relaunches via the background session;
        // we just need to re-populate the activeTasks map.
        backgroundSession.getAllTasks { [weak self] tasks in
            guard let self else { return }
            let liveIDs = Set(tasks.map { $0.taskIdentifier })
            Task { @MainActor [weak self] in
                guard let self else { return }
                for record in records {
                    if liveIDs.contains(record.taskIdentifier) {
                        // Task still alive — just track it
                        self.queue.append(record)
                        self.activeTasks[record.taskIdentifier] = record
                    } else {
                        // Task died (app was force-killed mid-download) — re-queue
                        self.enqueue(
                            title: record.title,
                            downloadURL: record.downloadURL,
                            mimeType: record.mimeType,
                            serverID: record.serverID
                        )
                    }
                }
            }
        }
    }

    private func persistQueue() {
        if let data = try? JSONEncoder().encode(queue) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}

// MARK: - URLSessionDownloadDelegate

extension OPDSDownloadQueue: URLSessionDownloadDelegate {

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let taskID = Optional(downloadTask.taskIdentifier) else { return }

        // Copy from ephemeral location to a stable temp path synchronously,
        // because URLSession deletes the file at location as soon as this method returns.
        let tempDir = FileManager.default.temporaryDirectory
        let tempFileURL = tempDir.appendingPathComponent(UUID().uuidString + ".tmp")
        do {
            try FileManager.default.copyItem(at: location, to: tempFileURL)
        } catch {
            Logger.shared.log("OPDSDownloadQueue: failed to copy download to stable temp URL — \(error)", category: "OPDS", type: .error)
        }

        Task { @MainActor [weak self] in
            guard let self, let record = self.activeTasks[taskID] else {
                try? FileManager.default.removeItem(at: tempFileURL)
                return
            }

            // Move from stable temp location to final destination
            let ext = record.mimeType.contains("pdf") ? "pdf"
                : record.mimeType.contains("epub") ? "epub"
                : "cbz"
            let safe = record.title
                .components(separatedBy: .init(charactersIn: "/:*?\"<>|\\"))
                .joined(separator: "_")
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(safe).\(ext)")
            try? FileManager.default.removeItem(at: dest)
            do {
                try FileManager.default.moveItem(at: tempFileURL, to: dest)
            } catch {
                Logger.shared.log("OPDSDownloadQueue: move failed — \(error)", category: "OPDS", type: .error)
                try? FileManager.default.removeItem(at: tempFileURL)
                self.removeRecord(taskID: taskID)
                return
            }

            Logger.shared.log("OPDSDownloadQueue: '\(record.title)' finished → \(dest.lastPathComponent)", category: "OPDS")

            // Notify the app to import. ContentView/ModernLibraryView observe this
            // and call conversionManager.processImportedFiles(urls:).
            NotificationCenter.default.post(
                name: NSNotification.Name("OPDSDownloadCompleted"),
                object: nil,
                userInfo: ["fileURL": dest, "title": record.title]
            )

            self.removeRecord(taskID: taskID)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        let taskID = downloadTask.taskIdentifier
        let now = Date()
        // PERF M3: Only hop to MainActor at most every 250ms (4 fps)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let last = self.lastProgressUpdate[taskID] ?? .distantPast
            guard now.timeIntervalSince(last) >= 0.25 else { return }
            self.lastProgressUpdate[taskID] = now
            guard let idx = self.queue.firstIndex(where: { $0.taskIdentifier == taskID }) else { return }
            self.queue[idx].fractionCompleted = fraction
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.backgroundCompletionHandler?()
            self.backgroundCompletionHandler = nil
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        let taskID = task.taskIdentifier
        Task { @MainActor [weak self] in
            guard let self, let record = self.activeTasks[taskID] else { return }
            Logger.shared.log("OPDSDownloadQueue: '\(record.title)' failed — \(error.localizedDescription)", category: "OPDS", type: .error)
            self.removeRecord(taskID: taskID)
        }
    }

    // MARK: - Private helpers

    @MainActor
    private func removeRecord(taskID: Int) {
        activeTasks.removeValue(forKey: taskID)
        queue.removeAll { $0.taskIdentifier == taskID }
        persistQueue()
    }
}
