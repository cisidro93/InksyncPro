import UIKit

/// Lightweight wrapper around UIKit haptic generators.
/// All methods are safe to call from any thread.
enum HapticEngine {

    // MARK: - Impact

    /// Light tap — tabs, toggles, minor selections.
    static func light() {
        DispatchQueue.main.async {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    /// Medium tap — confirming an action, button presses.
    static func medium() {
        DispatchQueue.main.async {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
    }

    /// Heavy tap — destructive actions, drag completions.
    static func heavy() {
        DispatchQueue.main.async {
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        }
    }

    // MARK: - Notification

    /// Import complete, save success.
    static func success() {
        DispatchQueue.main.async {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    /// Import failed, validation error.
    static func error() {
        DispatchQueue.main.async {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }

    /// Warning, destructive preview.
    static func warning() {
        DispatchQueue.main.async {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
    }

    // MARK: - Selection

    /// Picker / segmented control change.
    static func selection() {
        DispatchQueue.main.async {
            UISelectionFeedbackGenerator().selectionChanged()
        }
    }
}
