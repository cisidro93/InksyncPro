import Foundation
import CoreGraphics
import SwiftUI

// MARK: - Adaptive Intelligence Storage

/// A lightweight, privacy-focused metric engine that learns from how a user corrects the AI.
/// It dynamically shifts the Ensemble Confidence & Size thresholds based on historic corrections.
/// Isolated to `@MainActor` so all `@AppStorage` mutations are thread-safe.
@MainActor
class AdaptiveLearningManager: ObservableObject {
    static let shared = AdaptiveLearningManager()
    
    @AppStorage("ai_metric_deletedPanels") var deletedPanelsCount: Int = 0
    @AppStorage("ai_metric_addedPanels") var addedPanelsCount: Int = 0
    @AppStorage("ai_metric_resizedPanels") var resizedPanelsCount: Int = 0
    
    // Core parameters we will mutate
    @AppStorage("ai_param_baseConfidence") var currentBaseConfidence: Double = 0.6 // Apple Vision Default
    @AppStorage("ai_param_minimumSize") var currentMinimumSize: Double = 0.1 // 10% of screen Default
    
    // MARK: - Event Hooks
    
    func recordUserDeletedPanel(size: CGSize) {
        deletedPanelsCount += 1
        evaluateHeuristics()
    }
    
    func recordUserAddedPanel(size: CGSize) {
        addedPanelsCount += 1
        evaluateHeuristics()
    }
    
    func recordUserResizedPanel() {
        resizedPanelsCount += 1
        // Resizing is common; only shift heuristics if adding/deleting is out of balance.
    }
    
    // MARK: - The AI Brain
    
    /// Called every time the user corrects the AI to slowly mutate the Vision configuration
    private func evaluateHeuristics() {
        // SCENARIO 1: The user keeps DELETING panels.
        // Diagnosis: The AI is being too aggressive. It's grabbing gutters or noise.
        // Action: Raise the confidence threshold required to pass, and raise the minimum size limit.
        if deletedPanelsCount > 20 && deletedPanelsCount > (addedPanelsCount * 2) {
            Logger.shared.log("AI: User is over-deleting. Raising confidence to \(String(format: "%.2f", min(currentBaseConfidence + 0.05, 0.8)))", category: "AI")
            if currentBaseConfidence < 0.8 { currentBaseConfidence += 0.05 }
            if currentMinimumSize  < 0.15  { currentMinimumSize  += 0.01 }
            resetEpoch()
        }
        
        // SCENARIO 2: The user keeps ADDING panels manually.
        // Diagnosis: The AI is being too blind. It's missing small or faded panels.
        // Action: Lower the confidence threshold, and lower the minimum size.
        else if addedPanelsCount > 20 && addedPanelsCount > (deletedPanelsCount * 2) {
            Logger.shared.log("AI: User is under-detecting. Lowering confidence to \(String(format: "%.2f", max(currentBaseConfidence - 0.05, 0.3)))", category: "AI")
            if currentBaseConfidence > 0.3 { currentBaseConfidence -= 0.05 }
            if currentMinimumSize  > 0.04  { currentMinimumSize  -= 0.01 }
            resetEpoch()
        }
    }
    
    func resetToFactorySettings() {
        currentBaseConfidence = 0.6
        currentMinimumSize = 0.1
        resetEpoch()
        Logger.shared.log("AI: Factory reset — confidence 0.60, minSize 10%", category: "AI", type: .warning)
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
    
    // MARK: - Import / Export File Methods
    
    struct EngineStateDTO: Codable {
        let baseConfidence: Double
        let minimumSize: Double
        let deletedPanels: Int
        let addedPanels: Int
        let resizedPanels: Int
    }
    
    func exportState() -> Data? {
        let state = EngineStateDTO(
            baseConfidence: currentBaseConfidence,
            minimumSize: currentMinimumSize,
            deletedPanels: deletedPanelsCount,
            addedPanels: addedPanelsCount,
            resizedPanels: resizedPanelsCount
        )
        return try? JSONEncoder().encode(state)
    }
    
    enum ImportResult {
        case success
        case identical
    }
    
    func importState(from data: Data) throws -> ImportResult {
        let state = try JSONDecoder().decode(EngineStateDTO.self, from: data)
        
        let isIdentical = state.baseConfidence == self.currentBaseConfidence &&
                          state.minimumSize == self.currentMinimumSize &&
                          state.deletedPanels == self.deletedPanelsCount &&
                          state.addedPanels == self.addedPanelsCount &&
                          state.resizedPanels == self.resizedPanelsCount
                          
        if isIdentical { return .identical }

        currentBaseConfidence = state.baseConfidence
        currentMinimumSize = state.minimumSize
        deletedPanelsCount = state.deletedPanels
        addedPanelsCount = state.addedPanels
        resizedPanelsCount = state.resizedPanels
        Logger.shared.log("AI: Successfully imported Engine State. Conf:\(state.baseConfidence), MinSize:\(state.minimumSize)", category: "AI", type: .success)
        return .success
    }
}
