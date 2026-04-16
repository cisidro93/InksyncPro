import Foundation
import UIKit
import Combine

// ============================================================================
// DriveMonitor
// ============================================================================
// Background actor that polls linked drive reachability every 3 seconds and
// fires connect/disconnect notifications automatically.
// - Immediate probe when app comes to foreground (no 3s wait)
// - Pauses polling when app is backgrounded (battery friendly)
// - On connect: triggers LinkedLibraryScanner.syncDrive to catch new files
// ============================================================================

@MainActor
final class DriveMonitor: ObservableObject {

    static let shared = DriveMonitor()

    @Published private(set) var connectedDriveIDs: Set<UUID> = []

    private var pollingTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var drives: [AppSettingsManager.LinkedDriveEntry] = []

    private init() {
        setupLifecycleObservers()
    }

    // MARK: - Public

    func startMonitoring(drives: [AppSettingsManager.LinkedDriveEntry]) {
        self.drives = drives
        guard !drives.isEmpty else { stopPolling(); return }
        startPolling()
    }

    func stopMonitoring() {
        drives = []
        stopPolling()
    }

    // MARK: - Polling

    private func startPolling() {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.probeAll()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    // MARK: - Probe

    @discardableResult
    private func probeAll() async -> Set<UUID> {
        var nowConnected: Set<UUID> = []

        await withTaskGroup(of: (UUID, Bool).self) { group in
            for drive in drives {
                group.addTask {
                    let reachable = await BookmarkResolver.shared.isReachable(drive.volumeBookmarkData)
                    return (drive.id, reachable)
                }
            }
            for await (id, reachable) in group {
                if reachable { nowConnected.insert(id) }
            }
        }

        // Fire connect events for newly-appeared drives
        let newlyConnected = nowConnected.subtracting(connectedDriveIDs)
        for id in newlyConnected {
            Logger.shared.log("DriveMonitor: Drive \(id) connected", category: "Drive")
            NotificationCenter.default.post(name: .linkedDriveConnected, object: id)
            // Trigger background sync to catch new files added while disconnected
            if let entry = drives.first(where: { $0.id == id }) {
                Task.detached(priority: .background) {
                    await LinkedLibraryScanner.shared.syncDrive(entry)
                }
            }
        }

        // Fire disconnect events for drives that disappeared
        let newlyDisconnected = connectedDriveIDs.subtracting(nowConnected)
        for id in newlyDisconnected {
            Logger.shared.log("DriveMonitor: Drive \(id) disconnected", category: "Drive")
            NotificationCenter.default.post(name: .linkedDriveDisconnected, object: id)
        }

        connectedDriveIDs = nowConnected
        return nowConnected
    }

    func isConnected(driveID: UUID) -> Bool {
        connectedDriveIDs.contains(driveID)
    }

    // MARK: - App Lifecycle

    private func setupLifecycleObservers() {
        NotificationCenter.default
            .publisher(for: UIScene.willEnterForegroundNotification)
            .sink { [weak self] _ in
                // Immediate probe on foreground — no waiting for next 3s tick
                Task { await self?.probeAll() }
            }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: UIScene.didEnterBackgroundNotification)
            .sink { [weak self] _ in
                self?.stopPolling()
            }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: UIScene.didActivateNotification)
            .sink { [weak self] _ in
                guard let self, !self.drives.isEmpty else { return }
                self.startPolling()
            }
            .store(in: &cancellables)
    }
}
