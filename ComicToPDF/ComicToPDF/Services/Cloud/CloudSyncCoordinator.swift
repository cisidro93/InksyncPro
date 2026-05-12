import Foundation
import Combine
import UIKit

// @MainActor coordinator — all I/O dispatched to background Tasks internally.
// Triggers sync on: foreground, 30s after any save(), and willResignActive.
// Rate gate: minimum 30 seconds between sync operations.

@MainActor
final class CloudSyncCoordinator: ObservableObject {
    static let shared = CloudSyncCoordinator()

    @Published var pendingConflicts: [SyncConflict] = []
    @Published var isSyncing: Bool = false

    let serverDidAutoShutdown = PassthroughSubject<Void, Never>()

    private var lastSyncDate: Date?
    private let minimumSyncInterval: TimeInterval = 30
    private var debouncedSaveTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    private let clockManager = CloudSyncClockManager()
    private let merger = CloudSyncMerger()
    private let deviceID = DeviceIdentity.shared.deviceID

    private init() {
        setupTriggers()
    }

    private func setupTriggers() {
        // Trigger 1: Foreground
        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { [weak self] _ in
                Task { await self?.triggerSync() }
            }
            .store(in: &cancellables)

        // Trigger 2: willResignActive (save before backgrounding)
        NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
            .sink { [weak self] _ in
                Task { await self?.triggerSync() }
            }
            .store(in: &cancellables)
    }

    // Call this after any LibraryPersistenceManager.save(). Debounced 30s.
    func notifySaveOccurred() {
        debouncedSaveTask?.cancel()
        debouncedSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.triggerSync()
        }
    }

    func triggerSync() async {
        guard AppSettingsManager.shared.iCloudSyncEnabled else { return }
        guard canSync() else { return }
        guard !isSyncing else { return }

        isSyncing = true
        lastSyncDate = Date()

        await Task.detached(priority: .background) { [weak self] in
            await self?.performSync()
        }.value

        isSyncing = false
    }

    private func canSync() -> Bool {
        guard let last = lastSyncDate else { return true }
        return Date().timeIntervalSince(last) >= minimumSyncInterval
    }

    private func performSync() async {
        guard let iCloudURL = iCloudSyncURL() else {
            Logger.shared.log("CloudSyncCoordinator: iCloud container unavailable", category: "Cloud", type: .warning)
            return
        }

        let currentVector = await clockManager.currentVector()
        let localPayload = await buildLocalPayload()

        let envelope = LibrarySyncEnvelope(
            schemaVersion: 2,
            deviceID: deviceID,
            vectorClock: currentVector,
            exportedAt: Date().timeIntervalSince1970,
            records: localPayload
        )

        do {
            let data = try JSONEncoder().encode(envelope)
            let tmpURL = iCloudURL.deletingLastPathComponent().appendingPathComponent("inksync_sync.tmp.json")

            try await writeWithCoordinator(data: data, to: tmpURL)
            _ = try FileManager.default.replaceItemAt(iCloudURL, withItemAt: tmpURL)

            // Read remote and merge
            let remoteData = try await readWithCoordinator(from: iCloudURL)
            let remoteEnvelope = try JSONDecoder().decode(LibrarySyncEnvelope.self, from: remoteData)

            let result = merger.merge(
                local: localPayload,
                localVector: currentVector,
                remote: remoteEnvelope
            )

            await clockManager.merge(remoteEnvelope.vectorClock)

            if !result.conflicts.isEmpty {
                await MainActor.run { self.pendingConflicts = result.conflicts }
            }

            Logger.shared.log("CloudSyncCoordinator: Sync complete. \(result.conflicts.count) conflict(s).", category: "Cloud")

        } catch {
            Logger.shared.log("CloudSyncCoordinator: Sync failed — \(error.localizedDescription)", category: "Cloud", type: .error)
        }
    }

    func revokeAllSessions() {}

    // MARK: - iCloud File Operations

    private func iCloudSyncURL() -> URL? {
        FileManager.default
            .url(forUbiquityContainerIdentifier: nil)?
            .appendingPathComponent("Documents")
            .appendingPathComponent("inksync_sync.json")
    }

    private func writeWithCoordinator(data: Data, to url: URL) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            Task.detached(priority: .background) {
                let coordinator = NSFileCoordinator()
                var error: NSError?
                coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &error) { writeURL in
                    do {
                        try data.write(to: writeURL)
                        cont.resume()
                    } catch let e {
                        cont.resume(throwing: e)
                    }
                }
                if let e = error { cont.resume(throwing: e) }
            }
        }
    }

    private func readWithCoordinator(from url: URL) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            Task.detached(priority: .background) {
                let coordinator = NSFileCoordinator()
                var error: NSError?
                coordinator.coordinate(readingItemAt: url, options: [], error: &error) { readURL in
                    do {
                        let data = try Data(contentsOf: readURL)
                        cont.resume(returning: data)
                    } catch let e {
                        cont.resume(throwing: e)
                    }
                }
                if let e = error { cont.resume(throwing: e) }
            }
        }
    }

    private func buildLocalPayload() async -> LibrarySyncPayload {
        LibrarySyncPayload(files: [], progress: [], deletions: [])
    }
}
