import UIKit

/// Lightweight wrapper around UIKit haptic generators.
/// All methods are safe to call from any thread.
enum HapticEngine {

    private static var cachedIsEnabled: Bool = {
        updateCache()
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            updateCache()
        }
        return _cachedIsEnabled
    }()

    private static var _cachedIsEnabled = true

    private static func updateCache() {
        let essential = UserDefaults.standard.bool(forKey: "essentialReaderMode")
        let hapticsEnabled = UserDefaults.standard.object(forKey: "isHapticsEnabled") as? Bool ?? true
        _cachedIsEnabled = !essential && hapticsEnabled
    }

    private static var shouldPlayHaptic: Bool {
        _ = cachedIsEnabled // force initialisation
        return _cachedIsEnabled
    }

    // MARK: - Impact

    /// Light tap — tabs, toggles, minor selections.
    static func light() {
        guard shouldPlayHaptic else { return }
        DispatchQueue.main.async {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    /// Medium tap — confirming an action, button presses.
    static func medium() {
        guard shouldPlayHaptic else { return }
        DispatchQueue.main.async {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
    }

    /// Heavy tap — destructive actions, drag completions.
    static func heavy() {
        guard shouldPlayHaptic else { return }
        DispatchQueue.main.async {
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        }
    }

    // MARK: - Notification

    /// Import complete, save success.
    static func success() {
        guard shouldPlayHaptic else { return }
        DispatchQueue.main.async {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    /// Import failed, validation error.
    static func error() {
        guard shouldPlayHaptic else { return }
        DispatchQueue.main.async {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }

    /// Warning, destructive preview.
    static func warning() {
        guard shouldPlayHaptic else { return }
        DispatchQueue.main.async {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
    }

    // MARK: - Selection

    /// Picker / segmented control change.
    static func selection() {
        guard shouldPlayHaptic else { return }
        DispatchQueue.main.async {
            UISelectionFeedbackGenerator().selectionChanged()
        }
    }
}
