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
        var structuralPanels = candidates.filter { 
            ($0.method == .visionRectangle || $0.method == .deepScanContour) &&
            ($0.boundingBox.width < 0.93 || $0.boundingBox.height < 0.93)
        }
        
        var requiresDeepScan = false
        
        // If vision found fewer than 2 panels, or specific "Text Anchors" are missing a container, run Deep Scan Contours
        if structuralPanels.count < 2 {
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
        
        // Pure Text Check: if we have a lot of text lines but no detected comic panel containers,
        // it is a text/index page. Returning empty list means the page stays intact.
        if textAnchors.count > 15 && structuralPanels.isEmpty {
            Logger.shared.log("AI Ensemble: Pure text page detected (\(textAnchors.count) text anchors, 0 structural panels). Skipping panel generation to preserve full-page text flow.", category: "AI")
            return []
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

        // Phase 1: Clean NMS Consolidation
        let finalPanels = consolidateOverlappingPanels(structuralPanelsFinal)

        // Adaptive Logging — snapshot the diagnostic string on MainActor before logging
        // since AdaptiveLearningManager is @MainActor-isolated.
        let diagnosticSnapshot = await MainActor.run { AdaptiveLearningManager.shared.diagnosticString }
        Logger.shared.log("AI Ensemble: \(finalPanels.count) composite panels detected using aggressive NMS consolidation. \(diagnosticSnapshot)", category: "AI")

        return finalPanels
    }
    
    /// Merges disjointed bounding boxes and duplicate detections using IoU and spatial containment,
    /// preventing fractured Guided View panels while preserving distinct neighboring panels.
    private func consolidateOverlappingPanels(_ candidates: [PanelCandidate]) -> [PanelCandidate] {
        var merged = [PanelCandidate]()
        
        // Filter out perimeter border boxes (>= 93% width and height)
        let validCandidates = candidates.filter {
            $0.boundingBox.width < 0.93 || $0.boundingBox.height < 0.93
        }
        
        // Sort by confidence (strongest anchors naturally define the primary row/block bounds)
        var pool = validCandidates.sorted { $0.confidence > $1.confidence }
        
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
                
                let intersectionArea = intersection.width * intersection.height
                let currentArea = currentMergedBounds.width * currentMergedBounds.height
                let candidateArea = candidate.boundingBox.width * candidate.boundingBox.height
                let minArea = min(currentArea, candidateArea)
                let unionArea = currentArea + candidateArea - intersectionArea
                
                let iou = unionArea > 0 ? (intersectionArea / unionArea) : 0.0
                let containment = minArea > 0 ? (intersectionArea / minArea) : 0.0
                let maxArea = max(currentArea, candidateArea)
                let areaRatio = maxArea > 0 ? (minArea / maxArea) : 1.0
                
                // Inset Panel Discrimination:
                // If a candidate is small (< 40% of parent area) and heavily contained inside a large panel,
                // but has strong structural confidence (e.g. vision rectangle or contour), it represents
                // a legitimate artistic "Inset Panel" (close-up/reaction inside a splash panel).
                // Preserve it as an independent panel instead of swallowing it into the parent bounds.
                let isInsetPanel = containment > 0.65 && areaRatio <= 0.40 && (candidate.confidence >= 0.50 || candidate.method == .visionRectangle || candidate.method == .deepScanContour)
                
                if !isInsetPanel && (iou > 0.40 || containment > 0.65) {
                    currentMergedBounds = currentMergedBounds.union(candidate.boundingBox)
                    currentBaseConfidence = min(1.0, currentBaseConfidence * 1.05)
                    containsTextAccumulated = containsTextAccumulated || candidate.containsText
                } else {
                    remainingPool.append(candidate)
                }
            }
            
            pool = remainingPool
            
            // Only add if it didn't balloon into the full page perimeter
            if currentMergedBounds.width < 0.93 || currentMergedBounds.height < 0.93 {
                merged.append(PanelCandidate(
                    boundingBox: currentMergedBounds,
                    confidence: currentBaseConfidence,
                    method: currentMethod,
                    containsText: containsTextAccumulated
                ))
            }
        }
        
        return merged
    }
}

