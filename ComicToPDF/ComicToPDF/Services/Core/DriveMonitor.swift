import Foundation
import UIKit
import Combine

// ============================================================================
// DriveMonitor
// ============================================================================
// Background actor that polls linked drive reachability every 8 seconds and
// emits type-safe Combine events for connect/disconnect.
//
// Architecture:
//  - driveConnected  publisher: emits the UUID of a newly-reachable drive
//  - driveDisconnected publisher: emits the UUID of a newly-unreachable drive
//  - Consumers subscribe with .receive(on: DispatchQueue.main) as needed.
//  - On connect: auto-triggers LinkedLibraryScanner.syncDrive (background).
//  - Pauses polling when backgrounded (battery-safe).
//  - Immediate foreground probe (no 8s wait) for UX snappiness.
// ============================================================================

@MainActor
final class DriveMonitor: ObservableObject {

    static let shared = DriveMonitor()

    // ── Type-safe Combine publishers ─────────────────────────────────────────
    // Prefer these over NotificationCenter for all new subscribers.
    // Each emission carries the UUID of the affected drive.
    let driveConnected    = PassthroughSubject<UUID, Never>()
    let driveDisconnected = PassthroughSubject<UUID, Never>()

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
                // 8s poll — fast enough to detect a freshly-plugged USB drive within one cycle,
                // while remaining gentle on battery for idle iPads.
                // Immediate foreground probe (in setupLifecycleObservers) handles reconnect snappiness.
                try? await Task.sleep(for: .seconds(8))
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
        let currentDrives = self.drives
        let nowConnected = await Task.detached {
            var connected: Set<UUID> = []
            await withTaskGroup(of: (UUID, Bool).self) { group in
                for drive in currentDrives {
                    group.addTask {
                        let reachable = await BookmarkResolver.shared.isReachable(drive.volumeBookmarkData)
                        return (drive.id, reachable)
                    }
                }
                for await (id, reachable) in group {
                    if reachable { connected.insert(id) }
                }
            }
            return connected
        }.value

        // ── Emit typed connect events ─────────────────────────────────────────
        let newlyConnected = nowConnected.subtracting(connectedDriveIDs)
        for id in newlyConnected {
            Logger.shared.log("DriveMonitor: Drive \(id) connected", category: "Drive")
            // Typed publisher — consumers subscribe with their preferred scheduler.
            driveConnected.send(id)
            // Trigger background sync to catch new files added while disconnected.
            if let entry = drives.first(where: { $0.id == id }) {
                Task.detached(priority: .background) {
                    await LinkedLibraryScanner.shared.syncDrive(entry)
                }
            }
        }

        // ── Emit typed disconnect events ──────────────────────────────────────
        let newlyDisconnected = connectedDriveIDs.subtracting(nowConnected)
        for id in newlyDisconnected {
            Logger.shared.log("DriveMonitor: Drive \(id) disconnected", category: "Drive")
            driveDisconnected.send(id)
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
                // Immediate probe on foreground — no waiting for next 8s tick
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
