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
    private static let sharedContext = CIContext(options: [.useSoftwareRenderer: false])
    
    func detect(in image: UIImage) async -> [PanelCandidate] {
        let context = Self.sharedContext
        
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
        let structuralPanelsFinal = candidates.filter { $0.method != .textAnchor }

        // Phase 1: Aggressive Consolidation
        let finalPanels = consolidateOverlappingPanels(structuralPanelsFinal)

        // Adaptive Logging — snapshot the diagnostic string on MainActor before logging
        // since AdaptiveLearningManager is @MainActor-isolated.
        let diagnosticSnapshot = await MainActor.run { AdaptiveLearningManager.shared.diagnosticString }
        Logger.shared.log("AI Ensemble: \(finalPanels.count) composite panels detected using aggressive NMS consolidation. \(diagnosticSnapshot)", category: "AI")

        return finalPanels
    }
    
    /// Aggressively merges disjointed bounding boxes that geometrically intersect by more than 30% of their area, preventing fractured Guided View panels.
    private func consolidateOverlappingPanels(_ candidates: [PanelCandidate]) -> [PanelCandidate] {
        var merged = [PanelCandidate]()
        
        // Sort by confidence (strongest anchors naturally define the primary row/block bounds)
        var pool = candidates.sorted { $0.confidence > $1.confidence }
        
        while !pool.isEmpty {
            let anchor = pool.removeFirst()
            var currentMergedBounds = anchor.boundingBox
            var currentBaseConfidence = anchor.confidence
            let currentMethod = anchor.method
            var containsTextAccumulated = anchor.containsText
            
            var remainingPool = [PanelCandidate]()
            
            for candidate in pool {
                let intersection = currentMergedBounds.intersection(candidate.boundingBox)
                if intersection.isNull {
                    remainingPool.append(candidate)
                    continue
                }
                
                // Calculate percentage of area overlap strictly relative to the smaller bounding box fragment
                let intersectionArea = intersection.width * intersection.height
                let minArea = min(currentMergedBounds.width * currentMergedBounds.height, candidate.boundingBox.width * candidate.boundingBox.height)
                
                // Critical NMS Fusion: If fragments share 30% spatial volume, they are guaranteed to belong to the same parent panel.
                if minArea > 0 && intersectionArea > (minArea * 0.3) {
                    currentMergedBounds = currentMergedBounds.union(candidate.boundingBox)
                    // Mutate the parent parameters to reflect the absorption
                    currentBaseConfidence = min(1.0, currentBaseConfidence * 1.05)
                    containsTextAccumulated = containsTextAccumulated || candidate.containsText
                } else {
                    remainingPool.append(candidate)
                }
            }
            
            pool = remainingPool
            
            merged.append(PanelCandidate(
                boundingBox: currentMergedBounds,
                confidence: currentBaseConfidence,
                method: currentMethod,
                containsText: containsTextAccumulated
            ))
        }
        
        return merged
    }
}

