import SwiftUI

// MARK: - Orientation Lock Manager
// Centralised singleton so any view can lock/unlock orientation without needing AppDelegate access.
// Uses UIWindowScene.requestGeometryUpdate introduced in iOS 16.

@MainActor
final class OrientationLockManager: ObservableObject {
    static let shared = OrientationLockManager()

    @Published var isLocked: Bool = false
    @Published var lockedOrientation: UIInterfaceOrientationMask = .all

    private init() {}

    func lock(to mask: UIInterfaceOrientationMask) {
        isLocked = true
        lockedOrientation = mask
        applyLock(mask)
    }

    func unlock() {
        isLocked = false
        lockedOrientation = .all
        applyLock(.all)
    }

    func toggleLock(current orientation: UIDeviceOrientation) {
        if isLocked {
            unlock()
        } else {
            let mask: UIInterfaceOrientationMask = orientation.isLandscape ? .landscape : .portrait
            lock(to: mask)
        }
    }

    private func applyLock(_ mask: UIInterfaceOrientationMask) {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        let pref = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: mask)
        scene.requestGeometryUpdate(pref) { _ in
            // Orientation change rejected by system — acceptable silent failure
        }
        // Rotate to match if needed — use the modern instance-method API (iOS 16+)
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }
}

// MARK: - Sleep Timer Manager

@MainActor
final class SleepTimerManager: ObservableObject {
    static let shared = SleepTimerManager()

    @Published var isActive: Bool = false
    @Published var remainingSeconds: Int = 0
    @Published var didFire: Bool = false   // observed by reader to dismiss

    private var timer: Timer?
    private init() {}

    func start(minutes: Int) {
        stop()
        remainingSeconds = minutes * 60
        isActive = true
        didFire = false
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if self.remainingSeconds > 1 {
                    self.remainingSeconds -= 1
                } else {
                    self.fire()
                }
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isActive = false
        remainingSeconds = 0
    }

    private func fire() {
        stop()
        self.didFire = true
    }

    var formattedRemaining: String {
        let m = remainingSeconds / 60
        let s = remainingSeconds % 60
        return String(format: "%d:%02d", m, s)
    }
}
