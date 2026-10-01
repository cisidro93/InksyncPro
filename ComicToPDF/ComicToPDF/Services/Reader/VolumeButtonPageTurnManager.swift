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
    private var volumeObservation: NSKeyValueObservation? = nil

    private init() {}

    public func startListening() {
        guard !isListening else { return }
        guard EBookPreferences.shared.volumeButtonsTurnPages else { return }

        // Setup hidden MPVolumeView offscreen to suppress native iOS volume HUD
        if hiddenVolumeView == nil {
            let volumeView = MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 1, height: 1))
            volumeView.alpha = 0.0001
            volumeView.clipsToBounds = true

            let allWindows = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .flatMap({ $0.windows })
            if let window = allWindows.first(where: { $0.isKeyWindow }) ?? allWindows.first {
                window.addSubview(volumeView)
                volumeView.layoutIfNeeded()
                self.hiddenVolumeView = volumeView
                self.volumeSlider = findVolumeSlider(in: volumeView)
            }
        }

        // Configure audio session to ambient + mixWithOthers so background audio (Spotify, Apple Music, podcasts) is NEVER interrupted.
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            try session.setActive(true, options: [])
            initialVolume = session.outputVolume
            // Center volume to prevent hitting 0.0 or 1.0 bounds only if user is NOT listening to music
            if !session.isOtherAudioPlaying && (initialVolume < 0.1 || initialVolume > 0.9) {
                setVolume(0.5)
                initialVolume = 0.5
            }
        } catch {
            // Non-critical audio session fallback
        }

        // Primary: Apple-standard Key-Value Observation on outputVolume
        volumeObservation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new, .old]) { [weak self] _, change in
            guard let self = self else { return }
            Task { @MainActor in
                guard let newVol = change.newValue else { return }
                let oldVol = change.oldValue ?? self.initialVolume
                self.processVolumeChange(newVolume: newVol, oldVolume: oldVol)
            }
        }

        // Secondary / Fallback: System notification
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleVolumeNotification(_:)),
            name: NSNotification.Name("AVSystemController_SystemVolumeDidChangeNotification"),
            object: nil
        )

        isListening = true
    }

    public func stopListening() {
        guard isListening else { return }
        volumeObservation?.invalidate()
        volumeObservation = nil

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

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func processVolumeChange(newVolume: Float, oldVolume: Float) {
        guard EBookPreferences.shared.volumeButtonsTurnPages else { return }
        guard abs(newVolume - oldVolume) > 0.001 else { return }

        if newVolume > oldVolume {
            HapticEngine.selection()
            onVolumeUp?()
            initialVolume = newVolume
        } else if newVolume < oldVolume {
            HapticEngine.selection()
            onVolumeDown?()
            initialVolume = newVolume
        }

        // Only re-center volume slider when other background audio is NOT playing,
        // so we never alter the user's active music/podcast listening volume!
        if !AVAudioSession.sharedInstance().isOtherAudioPlaying {
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
    }

    @objc private func handleVolumeNotification(_ notification: Notification) {
        guard let userInfo = notification.userInfo else { return }
        if let newVolume = userInfo["AVSystemController_AudioVolumeNotificationParameter"] as? Float {
            processVolumeChange(newVolume: newVolume, oldVolume: initialVolume)
        }
    }

    private func findVolumeSlider(in view: UIView) -> UISlider? {
        if let slider = view as? UISlider { return slider }
        for sub in view.subviews {
            if let slider = findVolumeSlider(in: sub) { return slider }
        }
        return nil
    }

    private func setVolume(_ value: Float) {
        volumeSlider?.setValue(value, animated: false)
    }
}
