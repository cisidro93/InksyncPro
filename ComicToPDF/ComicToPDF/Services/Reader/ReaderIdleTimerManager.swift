import UIKit
import Combine

/// Authoritative Reader Display Idle Timer & Always-On Manager
///
/// Keeps the iPad/iPhone display awake during active reading sessions, specifically
/// handling iOS Low Power Mode (which defaults to a hard 30-second display sleep timeout
/// and periodically resets `isIdleTimerDisabled`).
@MainActor
final class ReaderIdleTimerManager: ObservableObject {
    static let shared = ReaderIdleTimerManager()

    private var activeReaderCount: Int = 0
    private var heartbeatTask: Task<Void, Never>? = nil
    private var observers: [NSObjectProtocol] = []

    private init() {
        setupObservers()
    }

    private func setupObservers() {
        // 1. Re-assert keep-awake immediately when Low Power Mode is toggled
        let powerObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name.NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reassertKeepAwake()
        }
        observers.append(powerObserver)

        // 2. Re-assert keep-awake when returning from Control Center or multitasking
        let activeObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reassertKeepAwake()
        }
        observers.append(activeObserver)
    }

    /// Call when a reader view appears
    func enterReader() {
        activeReaderCount += 1
        reassertKeepAwake()
        startHeartbeat()
    }

    /// Call when a reader view disappears
    func leaveReader() {
        activeReaderCount = max(0, activeReaderCount - 1)
        if activeReaderCount == 0 {
            stopHeartbeat()
            if UIApplication.shared.isIdleTimerDisabled {
                UIApplication.shared.isIdleTimerDisabled = false
            }
        } else {
            reassertKeepAwake()
        }
    }

    /// Authoritatively checks preference and updates UIApplication.shared.isIdleTimerDisabled
    func reassertKeepAwake() {
        guard activeReaderCount > 0 else { return }
        let isEnabled = EBookPreferences.shared.keepScreenAwakeWhileReading
        if isEnabled {
            if !UIApplication.shared.isIdleTimerDisabled {
                UIApplication.shared.isIdleTimerDisabled = true
            }
        } else {
            if UIApplication.shared.isIdleTimerDisabled {
                UIApplication.shared.isIdleTimerDisabled = false
            }
        }
    }

    /// Heartbeat task that runs every 12 seconds while in a reader session to continuously
    /// prevent iOS Low Power Mode watchdog from resetting the screen auto-lock.
    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 12_000_000_000) // 12 seconds
                guard let self = self, !Task.isCancelled else { break }
                if self.activeReaderCount > 0 && EBookPreferences.shared.keepScreenAwakeWhileReading {
                    if !UIApplication.shared.isIdleTimerDisabled {
                        UIApplication.shared.isIdleTimerDisabled = true
                    }
                }
            }
        }
    }

    private func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    deinit {
        for obs in observers {
            NotificationCenter.default.removeObserver(obs)
        }
    }
}
