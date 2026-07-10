import SwiftUI

@MainActor
class Haptics {
    static let shared = Haptics()
    
    private init() {}
    
    private var shouldPlayHaptic: Bool {
        let essential = UserDefaults.standard.bool(forKey: "essentialReaderMode")
        let hapticsEnabled = UserDefaults.standard.object(forKey: "isHapticsEnabled") as? Bool ?? true
        return !essential && hapticsEnabled
    }
    
    func playImpact(style: UIImpactFeedbackGenerator.FeedbackStyle = .medium) {
        guard shouldPlayHaptic else { return }
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.prepare()
        generator.impactOccurred()
    }
    
    func playNotification(type: UINotificationFeedbackGenerator.FeedbackType) {
        guard shouldPlayHaptic else { return }
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(type)
    }
    
    func playSelection() {
        guard shouldPlayHaptic else { return }
        let generator = UISelectionFeedbackGenerator()
        generator.prepare()
        generator.selectionChanged()
    }
}
