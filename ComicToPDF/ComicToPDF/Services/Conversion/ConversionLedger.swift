import Foundation
import Combine

// Actor-isolated conversion ledger.
// All public methods are actor-isolated — no DispatchQueue usage.
// Persistence: atomic JSON write via tmp-rename pattern.

actor ConversionLedger {
    static let shared = ConversionLedger()

    private var jobs: [UUID: ConversionJobRecord] = [:]
    private let persistURL: URL
    private let batchCompletionSubject = PassthroughSubject<UUID, Never>()

    nonisolated var batchCompletionPublisher: AnyPublisher<UUID, Never> {
        batchCompletionSubject.eraseToAnyPublisher()
    }

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        persistURL = appSupport.appendingPathComponent("InkSyncPro/conversion_ledger.json")
        try? FileManager.default.createDirectory(at: persistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    // MARK: - Public API

    func enqueue(fileID: UUID, fileName: String, outputFormat: String) -> UUID {
        let record = ConversionJobRecord(fileID: fileID, fileName: fileName, outputFormat: outputFormat)
        jobs[record.id] = record
        persist()
        return record.id
    }

    func markStarted(_ jobID: UUID) {
        guard var rec = jobs[jobID] else { return }
        rec.status = .running
        rec.lastAttemptAt = Date()
        rec.attemptCount += 1
        jobs[jobID] = rec
        persist()
    }

    func markSucceeded(_ jobID: UUID) {
        guard var rec = jobs[jobID] else { return }
        rec.status = .succeeded
        rec.completedAt = Date()
        jobs[jobID] = rec
        batchCompletionSubject.send(jobID)
        persist()
    }

    func markFailed(_ jobID: UUID, reason: String) {
        guard var rec = jobs[jobID] else { return }
        rec.failureReason = reason

        if let delay = ConversionJobRecord.retryDelay(forAttemptCount: rec.attemptCount) {
            rec.status = .retrying
            rec.nextRetryAt = Date().addingTimeInterval(delay)
            Logger.shared.log("ConversionLedger: Job \(rec.fileName) will retry in \(Int(delay))s (attempt \(rec.attemptCount))", category: "Converter")
        } else {
            rec.status = .abandoned
            rec.completedAt = Date()
            batchCompletionSubject.send(jobID)
            Logger.shared.log("ConversionLedger: Job \(rec.fileName) abandoned after \(rec.attemptCount) attempts — \(reason)", category: "Converter", type: .error)
        }

        jobs[jobID] = rec
        persist()
    }

    func retryFailed() {
        for key in jobs.keys {
            guard var rec = jobs[key], rec.status == .failed || rec.status == .abandoned else { continue }
            rec.status = .queued
            rec.attemptCount = 0
            rec.failureReason = nil
            rec.nextRetryAt = nil
            rec.completedAt = nil
            jobs[key] = rec
        }
        persist()
    }

    func clearCompleted() {
        jobs = jobs.filter { $0.value.status != .succeeded && $0.value.status != .abandoned }
        persist()
    }

    func allJobs() -> [ConversionJobRecord] {
        jobs.values.sorted { $0.enqueuedAt < $1.enqueuedAt }
    }

    func job(for id: UUID) -> ConversionJobRecord? {
        jobs[id]
    }

    func partialCleanup(for jobID: UUID, tempDir: URL) {
        if FileManager.default.fileExists(atPath: tempDir.path) {
            try? FileManager.default.removeItem(at: tempDir)
            Logger.shared.log("ConversionLedger: Cleaned up temp dir for job \(jobID)", category: "Converter")
        }
    }

    // MARK: - Persistence (atomic)

    private func persist() {
        let snapshot = Array(jobs.values)
        Task.detached(priority: .background) { [persistURL] in
            do {
                let data = try JSONEncoder().encode(snapshot)
                let tmpURL = persistURL.deletingLastPathComponent()
                    .appendingPathComponent("conversion_ledger.tmp.json")
                try data.write(to: tmpURL)
                _ = try FileManager.default.replaceItemAt(persistURL, withItemAt: tmpURL)
            } catch {
                Logger.shared.log("ConversionLedger: Persist failed — \(error.localizedDescription)", category: "Converter", type: .error)
            }
        }
    }

    func restore() {
        guard let data = try? Data(contentsOf: persistURL),
              let loaded = try? JSONDecoder().decode([ConversionJobRecord].self, from: data) else { return }
        for rec in loaded { jobs[rec.id] = rec }
    }
}
