import Foundation
import CoreGraphics

struct AdaptiveParameters: Codable, Equatable {
    var minConfidence: Float
    var minSize: CGFloat
    var tolerance: Int
    var expandRatio: CGFloat
    
    // Default "Factory" Settings
    static let defaults = AdaptiveParameters(
        minConfidence: 0.85,
        minSize: 0.15,
        tolerance: 30, // Vision Quadrature Tolerance
        expandRatio: 0.0 // No expansion by default
    )
}

class AdaptiveLearningManager: ObservableObject {
    static let shared = AdaptiveLearningManager()
    
    private let key = "AdaptivePanelSettings"
    @Published var currentSettings: AdaptiveParameters
    
    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode(AdaptiveParameters.self, from: data) {
            self.currentSettings = decoded
        } else {
            self.currentSettings = AdaptiveParameters.defaults
        }
    }
    
    func getParameters() -> AdaptiveParameters {
        return currentSettings
    }
    
    func resetToDefaults() {
        currentSettings = AdaptiveParameters.defaults
        save()
    }
    
    private func save() {
        if let encoded = try? JSONEncoder().encode(currentSettings) {
            UserDefaults.standard.set(encoded, forKey: key)
        }
    }
    
    // MARK: - Learning Logic
    
    /// Learns from the difference between what the AI "would have seen" vs what the user approved.
    /// - Parameters:
    ///   - initialPanels: The panels the AI detected (or would detect with current settings).
    ///   - userFinalPanels: The panels the user saved.
    func learn(from initialPanels: [CGRect], userFinalPanels: [CGRect]) {
        var newSettings = currentSettings
        var didChange = false
        
        // 1. Check for Missed Small Panels
        // If user added a panel that is smaller than our minSize, we need to lower the threshold.
        let smallestUserPanel = userFinalPanels.map { min($0.width * $0.height, 0.0) }.min() ?? 1.0 // Area
        // Easier: Just check min dimension
        let minUserDim = userFinalPanels.flatMap { [$0.width, $0.height] }.min() ?? 1.0
        
        if minUserDim < newSettings.minSize {
            // Learn: Lower the minSize slightly (not all the way to avoid noise)
            // Decay factor 0.9 ensures we approach it gradually
            let target = max(0.05, minUserDim * 0.95) // 5% buffer
            if target < newSettings.minSize {
                newSettings.minSize = target
                print("🧠 [Brain] Learned: Lowered minSize to \(target)")
                didChange = true
            }
        }
        
        // 2. Check for "Wobbly" (Non-Rectangular) shapes implies we might need higher tolerance.
        // This is hard to detect just from Rects.
        // Heuristic: If user edited a LOT of panels (moved them slightly), maybe our tolerance was too strict or loose.
        // Better Heuristic: Check for count mismatch.
        
        // 3. False Positives (AI found garbage)
        // If AI found MORE panels than User, and User deleted them.
        if initialPanels.count > userFinalPanels.count {
            // We might be too aggressive. Increase confidence or minSize.
            // Only increase if we are currently very low.
            if newSettings.minConfidence < 0.8 {
                newSettings.minConfidence += 0.05
                print("🧠 [Brain] Learned: Increased confidence to \(newSettings.minConfidence) (User deleted panels)")
                didChange = true
            }
        }
        
        // 4. False Negatives (AI missed panels)
        // If User has MORE panels than AI.
        if userFinalPanels.count > initialPanels.count {
            // We missed some.
            // Decrease confidence slightly to catch edge cases
             if newSettings.minConfidence > 0.4 {
                newSettings.minConfidence -= 0.05
                print("🧠 [Brain] Learned: Decreased confidence to \(newSettings.minConfidence) (User added panels)")
                didChange = true
            }
        }
        
        if didChange {
            currentSettings = newSettings
            save()
        }
    }
}
