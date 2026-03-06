import Foundation
import CoreGraphics
import SwiftUI

// MARK: - Adaptive Intelligence Storage

/// A lightweight, privacy-focused metric engine that learns from how a user corrects the AI.
/// It dynamically shifts the Ensemble Confidence & Size thresholds based on historic corrections.
class AdaptiveLearningManager: ObservableObject {
    static let shared = AdaptiveLearningManager()
    
    @AppStorage("ai_metric_deletedPanels") private var deletedPanelsCount: Int = 0
    @AppStorage("ai_metric_addedPanels") private var addedPanelsCount: Int = 0
    @AppStorage("ai_metric_resizedPanels") private var resizedPanelsCount: Int = 0
    
    // Core parameters we will mutate
    @AppStorage("ai_param_baseConfidence") var currentBaseConfidence: Double = 0.6 // Apple Vision Default
    @AppStorage("ai_param_minimumSize") var currentMinimumSize: Double = 0.1 // 10% of screen Default
    
    // MARK: - Event Hooks
    
    func recordUserDeletedPanel(size: CGSize) {
        DispatchQueue.main.async {
            self.deletedPanelsCount += 1
            self.evaluateHeuristics()
        }
    }
    
    func recordUserAddedPanel(size: CGSize) {
        DispatchQueue.main.async {
            self.addedPanelsCount += 1
            self.evaluateHeuristics()
        }
    }
    
    func recordUserResizedPanel() {
        DispatchQueue.main.async {
            self.resizedPanelsCount += 1
            // Resizing is common; we only shift heuristics if adding/deleting is completely out of balance.
        }
    }
    
    // MARK: - The AI Brain
    
    /// Called every time the user corrects the AI to slowly mutate the Vision configuration
    private func evaluateHeuristics() {
        // SCENARIO 1: The user keeps DELETING panels.
        // Diagnosis: The AI is being too aggressive. It's grabbing gutters or noise.
        // Action: Raise the confidence threshold required to pass, and raise the minimum size limit.
        if deletedPanelsCount > 20 && deletedPanelsCount > (addedPanelsCount * 2) {
            print("🧠 [Adaptive Intelligence] User is deleting a lot. Increasing strictness.")
            
            // Push confidence up slightly, maxing at 0.8
            if currentBaseConfidence < 0.8 {
                currentBaseConfidence += 0.05
            }
            
            // Push minimum size up slightly, maxing at 0.15 (15% of screen)
            if currentMinimumSize < 0.15 {
                currentMinimumSize += 0.01
            }
            
            // Reset the counters to prevent endless scalar growth, we learn in "epochs" of 20
            resetEpoch()
        }
        
        // SCENARIO 2: The user keeps ADDING panels manually.
        // Diagnosis: The AI is being too blind. It's missing small or faded panels.
        // Action: Lower the confidence threshold, and lower the minimum size.
        else if addedPanelsCount > 20 && addedPanelsCount > (deletedPanelsCount * 2) {
            print("🧠 [Adaptive Intelligence] User is adding a lot. Lowering strictness.")
            
            // Push confidence down, bottoming out at 0.3 (Very aggressive)
            if currentBaseConfidence > 0.3 {
                currentBaseConfidence -= 0.05
            }
            
            // Push minimum size down, bottoming out at 0.04 (4% of screen)
            if currentMinimumSize > 0.04 {
                currentMinimumSize -= 0.01
            }
            
            resetEpoch()
        }
    }
    
    func resetToFactorySettings() {
        DispatchQueue.main.async {
            self.currentBaseConfidence = 0.6
            self.currentMinimumSize = 0.1
            self.resetEpoch()
            print("🧠 [Adaptive Intelligence] Factory Reset. Memory wiped.")
        }
    }
    
    private func resetEpoch() {
        deletedPanelsCount = 0
        addedPanelsCount = 0
        resizedPanelsCount = 0
    }
    
    // MARK: - Current State Access
    
    var currentSettings: (minConfidence: Double, minSize: Double) {
        return (minConfidence: currentBaseConfidence, minSize: currentMinimumSize)
    }
    
    var diagnosticString: String {
        return "Confidence: \(String(format: "%.2f", currentBaseConfidence)) | Min Size: \(String(format: "%.0f", currentMinimumSize * 100))%"
    }
}
