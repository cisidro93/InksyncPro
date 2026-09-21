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
    private var targetFireDate: Date?

    private init() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleBackground()
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleForeground()
        }
    }

    func start(minutes: Int) {
        stop()
        remainingSeconds = minutes * 60
        totalSeconds = remainingSeconds
        targetFireDate = Date().addingTimeInterval(Double(remainingSeconds))
        initialBrightness = UIScreen.main.brightness
        isActive = true
        didFire = false
        
        startTickingLoop()
    }

    private func startTickingLoop() {
        timerTask?.cancel()
        timerTask = Task { @MainActor [weak self] in
            while true {
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    break
                }
                guard let self = self, !Task.isCancelled else { break }
                if let target = self.targetFireDate {
                    let diff = Int(target.timeIntervalSinceNow)
                    if diff > 1 {
                        self.remainingSeconds = diff
                        self.updateBrightness()
                    } else {
                        self.fire()
                        break
                    }
                } else {
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
    }

    private func handleBackground() {
        // Suspend the 1-second Task.sleep loop so the CPU can power down completely
        timerTask?.cancel()
        timerTask = nil
    }

    private func handleForeground() {
        guard isActive, let target = targetFireDate else { return }
        let diff = Int(target.timeIntervalSinceNow)
        if diff <= 0 {
            fire()
        } else {
            remainingSeconds = diff
            updateBrightness()
            startTickingLoop()
        }
    }

    func stop() {
        timerTask?.cancel()
        timerTask = nil
        targetFireDate = nil
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
        if remainingSeconds <= dimLimit && dimLimit > 0 {
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
    static let brightnessZoneWidth: CGFloat = 38.0
    static let minBrightnessThreshold: CGFloat = 0.05
    static let maxBrightnessThreshold: CGFloat = 1.0
    static let defaultAnimationDuration: Double = 0.2
    static let springResponse: Double = 0.35
    static let springDamping: Double = 0.85
    static let autoSaveDebounceNanoseconds: UInt64 = 1_200_000_000
}

/// Reusable edge brightness gesture zone (DRY principle — eliminates duplicate gesture code across readers)
/// Features one-thumb vertical drag on iPhone & iPad bezel with a floating frosted-glass HUD
struct EdgeBrightnessGestureZone: View {
    @State private var lastDragTranslationY: CGFloat = 0
    @State private var showHUD: Bool = false
    @State private var currentLevel: CGFloat = UIScreen.main.brightness
    @State private var dismissTask: Task<Void, Never>? = nil

    var body: some View {
        ZStack(alignment: .leading) {
            HStack {
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: ReaderLayoutConstants.brightnessZoneWidth)
                    .allowsHitTesting(true)
                    .gesture(
                        DragGesture(minimumDistance: 14)
                            .onChanged { value in
                                let delta = value.translation.height - lastDragTranslationY
                                lastDragTranslationY = value.translation.height
                                let currentBrightness = UIScreen.main.brightness
                                let targetBrightness = max(
                                    ReaderLayoutConstants.minBrightnessThreshold,
                                    min(ReaderLayoutConstants.maxBrightnessThreshold, currentBrightness - delta * 0.002)
                                )
                                UIScreen.main.brightness = targetBrightness
                                currentLevel = targetBrightness

                                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                    showHUD = true
                                }

                                dismissTask?.cancel()
                                dismissTask = Task { @MainActor in
                                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                                        showHUD = false
                                    }
                                }
                            }
                            .onEnded { _ in
                                lastDragTranslationY = 0
                            }
                    )
                Spacer()
            }

            if showHUD {
                HStack {
                    VStack(spacing: 8) {
                        Image(systemName: currentLevel < 0.3 ? "sun.min.fill" : (currentLevel < 0.7 ? "sun.max.fill" : "sun.max.trianglebadge.exclamationmark.fill"))
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Color.yellow)

                        GeometryReader { geo in
                            ZStack(alignment: .bottom) {
                                Capsule()
                                    .fill(Color.white.opacity(0.18))
                                    .frame(width: 4)

                                Capsule()
                                    .fill(Color.yellow)
                                    .frame(width: 4, height: max(2, geo.size.height * currentLevel))
                            }
                        }
                        .frame(width: 4, height: 64)

                        Text("\(Int(currentLevel * 100))%")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
                    .padding(.leading, 16)
                    .transition(.move(edge: .leading).combined(with: .opacity))

                    Spacer()
                }
                .allowsHitTesting(false)
                .zIndex(99)
            }
        }
        .ignoresSafeArea()
    }
}
