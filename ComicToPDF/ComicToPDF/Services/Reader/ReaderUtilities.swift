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

    private var timerTask: Task<Void, Never>?
    private var initialBrightness: CGFloat = 1.0
    private var totalSeconds: Int = 0
    private let fadeDuration: Int = 120 // 2 minutes

    private init() {}

    func start(minutes: Int) {
        stop()
        remainingSeconds = minutes * 60
        totalSeconds = remainingSeconds
        initialBrightness = UIScreen.main.brightness
        isActive = true
        didFire = false
        
        timerTask = Task { @MainActor [weak self] in
            while true {
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    break
                }
                guard let self = self, !Task.isCancelled else { break }
                if self.remainingSeconds > 1 {
                    self.remainingSeconds -= 1
                    self.updateBrightness()
                } else {
                    self.fire()
                    break
                }
            }
        }
    }

    func stop() {
        timerTask?.cancel()
        timerTask = nil
        if isActive {
            UIScreen.main.brightness = initialBrightness
        }
        isActive = false
        remainingSeconds = 0
    }

    private func fire() {
        let original = initialBrightness
        stop()
        UIScreen.main.brightness = original
        self.didFire = true
    }

    private func updateBrightness() {
        let dimLimit = min(fadeDuration, totalSeconds)
        if remainingSeconds <= dimLimit {
            let progress = CGFloat(remainingSeconds) / CGFloat(dimLimit)
            UIScreen.main.brightness = initialBrightness * progress
        }
    }

    var formattedRemaining: String {
        let m = remainingSeconds / 60
        let s = remainingSeconds % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Clean Code Constants & Shared Components

/// Centralized reader layout and gesture constants (eliminates magic numbers)
enum ReaderLayoutConstants {
    static let brightnessZoneWidth: CGFloat = 30.0
    static let minBrightnessThreshold: CGFloat = 0.05
    static let maxBrightnessThreshold: CGFloat = 1.0
    static let defaultAnimationDuration: Double = 0.2
    static let springResponse: Double = 0.35
    static let springDamping: Double = 0.85
    static let autoSaveDebounceNanoseconds: UInt64 = 1_200_000_000
}

/// Reusable edge brightness gesture zone (DRY principle — eliminates duplicate gesture code across readers)
struct EdgeBrightnessGestureZone: View {
    @State private var lastDragTranslationY: CGFloat = 0

    var body: some View {
        HStack {
            Color.clear
                .contentShape(Rectangle())
                .frame(width: ReaderLayoutConstants.brightnessZoneWidth)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            let delta = value.translation.height - lastDragTranslationY
                            lastDragTranslationY = value.translation.height
                            let currentBrightness = UIScreen.main.brightness
                            let targetBrightness = max(
                                ReaderLayoutConstants.minBrightnessThreshold,
                                min(ReaderLayoutConstants.maxBrightnessThreshold, currentBrightness - delta * 0.001)
                            )
                            UIScreen.main.brightness = targetBrightness
                        }
                        .onEnded { _ in lastDragTranslationY = 0 }
                )
            Spacer()
        }
    }
}
