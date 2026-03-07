import Foundation
import Vision
import UIKit

// MARK: - Models

struct PanelCandidate: Identifiable, Equatable {
    let id = UUID()
    let boundingBox: CGRect // Normalized 0..1
    let confidence: Float
    let method: DetectionMethod
    var containsText: Bool = false
    
    enum DetectionMethod: String {
        case visionRectangle
        case deepScanContour
        case textAnchor
        case fallbackGrid
    }
}

// MARK: - Protocol

protocol PanelProvider {
    /// Detects panels in a given image.
    /// - Parameters:
    ///   - image: The source image.
    ///   - context: Shared CIContext for performance.
    /// - Returns: An array of candidates.
    func detectPanels(in image: UIImage, context: CIContext) async -> [PanelCandidate]
}

// MARK: - Ensemble Orchestrator

class EnsemblePanelDetector {
    private let visionProvider = VisionPanelProvider()
    private let deepScanProvider = DeepScanPanelProvider()
    
    func detect(in image: UIImage) async -> [PanelCandidate] {
        let context = CIContext()
        
        // 1. Run Vision Baseline (Fast, Saliency-Aware, and creates Virtual Text bounds)
        var candidates = await visionProvider.detectPanels(in: image, context: context)
        
        // 2. Analyze Coverage
        // If we found very few panels or specific "Text Anchors" are missing a container, run Deep Scan Contours.
        let textAnchors = candidates.filter { $0.method == .textAnchor }
        var structuralPanels = candidates.filter { $0.method == .visionRectangle || $0.method == .deepScanContour }
        
        var requiresDeepScan = false
        
        // If vision totally failed, or the user's Adaptive Learning parameters made it too strict, try contours
        if structuralPanels.isEmpty {
            requiresDeepScan = true
        } else {
            // Check if any text anchor is "orphaned" (not inside a structural panel)
            for anchor in textAnchors {
                let isCovered = structuralPanels.contains { $0.boundingBox.contains(anchor.boundingBox) || $0.boundingBox.intersects(anchor.boundingBox) }
                if !isCovered {
                    requiresDeepScan = true
                    break
                }
            }
        }
        
        // 3. Deep Scan Fallback (Topological Contour Detection)
        if requiresDeepScan {
            Logger.shared.log("AI Ensemble: Vision coverage insufficient — triggering contour deep scan", category: "AI")
            let contourResults = await deepScanProvider.detectPanels(in: image, context: context)
            
            // Merge Strategies
            // A. Add Contour results that don't overlap existing structural panels by more than 50%
            for contour in contourResults {
                let isCovered = structuralPanels.contains { 
                    let intersection = $0.boundingBox.intersection(contour.boundingBox)
                    return (intersection.width * intersection.height) > (contour.boundingBox.width * contour.boundingBox.height * 0.5)
                }
                
                if !isCovered {
                    candidates.append(contour)
                    structuralPanels.append(contour) // Update structural list so we don't duplicate
                }
            }
        }
        
        // 4. Final Cleanup
        // Filter out raw Text Anchors that served their purpose or are explicitly covered now
        let finalPanels = candidates.filter { $0.method != .textAnchor }
        
        // Adaptive Logging (Debugging)
        Logger.shared.log("AI Ensemble: \(finalPanels.count) panels detected. \(AdaptiveLearningManager.shared.diagnosticString)", category: "AI")
        
        return finalPanels
    }
}

