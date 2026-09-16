import Foundation
import UIKit
import MediaPlayer
import AVFoundation

// MARK: - VolumeButtonPageTurnManager
//
// Hands-free hardware page turning system for iPhone (one-handed reading)
// and iPad (desk / stand propped reading).
// Intercepts physical Volume Up / Down button events and turns pages without
// triggering the disruptive system volume overlay HUD.

@MainActor
public final class VolumeButtonPageTurnManager: ObservableObject {
    public static let shared = VolumeButtonPageTurnManager()

    public var onVolumeUp: (() -> Void)? = nil
    public var onVolumeDown: (() -> Void)? = nil

    private var hiddenVolumeView: MPVolumeView?
    private var volumeSlider: UISlider?
    private var isListening: Bool = false
    private var initialVolume: Float = 0.5
    private var resetTask: Task<Void, Never>? = nil

    private init() {}

    public func startListening() {
        guard !isListening else { return }
        guard EBookPreferences.shared.volumeButtonsTurnPages else { return }

        // Setup hidden MPVolumeView offscreen to suppress native iOS volume HUD
        if hiddenVolumeView == nil {
            let volumeView = MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 1, height: 1))
            volumeView.alpha = 0.0001
            volumeView.clipsToBounds = true

            // Locate the internal UISlider within MPVolumeView
            for subview in volumeView.subviews {
                if let slider = subview as? UISlider {
                    self.volumeSlider = slider
                    break
                }
            }

            if let window = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .flatMap({ $0.windows })
                .first(where: { $0.isKeyWindow }) {
                window.addSubview(volumeView)
                self.hiddenVolumeView = volumeView
            }
        }

        // Configure audio session
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            initialVolume = AVAudioSession.sharedInstance().outputVolume
            // Center volume to prevent hitting 0.0 or 1.0 min/max bounds
            if initialVolume < 0.1 || initialVolume > 0.9 {
                setVolume(0.5)
                initialVolume = 0.5
            }
        } catch {
            // Non-critical audio session fallback
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleVolumeChanged(_:)),
            name: NSNotification.Name("AVSystemController_SystemVolumeDidChangeNotification"),
            object: nil
        )

        isListening = true
    }

    public func stopListening() {
        guard isListening else { return }
        NotificationCenter.default.removeObserver(
            self,
            name: NSNotification.Name("AVSystemController_SystemVolumeDidChangeNotification"),
            object: nil
        )
        resetTask?.cancel()
        resetTask = nil

        hiddenVolumeView?.removeFromSuperview()
        hiddenVolumeView = nil
        volumeSlider = nil
        isListening = false
    }

    @objc private func handleVolumeChanged(_ notification: Notification) {
        guard EBookPreferences.shared.volumeButtonsTurnPages else { return }
        guard let userInfo = notification.userInfo else { return }

        let reason = userInfo["AVSystemController_AudioVolumeChangeReasonNotificationParameter"] as? String
        guard reason == "ExplicitVolumeChange" else { return }

        guard let newVolume = userInfo["AVSystemController_AudioVolumeNotificationParameter"] as? Float else { return }

        if newVolume > initialVolume {
            HapticEngine.selection()
            onVolumeUp?()
            initialVolume = newVolume
        } else if newVolume < initialVolume {
            HapticEngine.selection()
            onVolumeDown?()
            initialVolume = newVolume
        }

        // If approaching volume bounds (0.0 or 1.0), immediately re-center to prevent hardware clipping
        if newVolume < 0.15 || newVolume > 0.85 {
            setVolume(0.5)
            initialVolume = 0.5
        } else {
            // Re-center volume after short delay to allow continuous page turns
            resetTask?.cancel()
            resetTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled else { return }
                self.setVolume(0.5)
                self.initialVolume = 0.5
            }
        }
    }

    private func setVolume(_ value: Float) {
        volumeSlider?.setValue(value, animated: false)
    }
}
