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
    private var cancellables = Set<AnyCancellable>()

    private init() {
        setupObservers()
    }

    private func setupObservers() {
        // 1. Re-assert keep-awake immediately when Low Power Mode is toggled
        NotificationCenter.default.publisher(for: Notification.Name.NSProcessInfoPowerStateDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.reassertKeepAwake()
            }
            .store(in: &cancellables)

        // 2. Re-assert keep-awake when returning from Control Center or multitasking
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.reassertKeepAwake()
            }
            .store(in: &cancellables)

        // 3. Suspend keep-awake and heartbeat when entering background to preserve battery
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.stopHeartbeat()
                if UIApplication.shared.isIdleTimerDisabled {
                    UIApplication.shared.isIdleTimerDisabled = false
                }
            }
            .store(in: &cancellables)

        // 4. Resume keep-awake and heartbeat when returning to foreground if in active reader
        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                if self.activeReaderCount > 0 {
                    self.reassertKeepAwake()
                    self.startHeartbeat()
                }
            }
            .store(in: &cancellables)
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
}
