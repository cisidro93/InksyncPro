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
        
        // 1. Run Vision Baseline (Fast, Accurate for standard panels)
        var candidates = await visionProvider.detectPanels(in: image, context: context)
        
        // 2. Analyze Coverage
        // If we found very few panels or specific "Text Anchors" are missing a container, run Deep Scan.
        let textAnchors = candidates.filter { $0.method == .textAnchor }
        let structuralPanels = candidates.filter { $0.method == .visionRectangle }
        
        var requiresDeepScan = false
        
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
        
        // 3. Deep Scan Fallback (Slower, but catches weird shapes)
        if requiresDeepScan {
            print("🧠 [Ensemble] Triggering Deep Scan Fallback...")
            let deepScanResults = await deepScanProvider.detectPanels(in: image, context: context)
            
            // Merge Strategies
            // A. Add Deep Scan results that don't overlap existing structural panels
            for ds in deepScanResults {
                let isCovered = structuralPanels.contains { 
                    let intersection = $0.boundingBox.intersection(ds.boundingBox)
                    return (intersection.width * intersection.height) > (ds.boundingBox.width * ds.boundingBox.height * 0.5)
                }
                
                if !isCovered {
                    candidates.append(ds)
                }
            }
        }
        
        // 4. Final Cleanup
        // Filter out raw Text Anchors that served their purpose or are explicitly covered now
        let finalPanels = candidates.filter { $0.method != .textAnchor }
        
        return finalPanels
    }
}
```
