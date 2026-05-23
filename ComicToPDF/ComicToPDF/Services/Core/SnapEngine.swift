
import Foundation
import UIKit
import CoreGraphics
import Accelerate

// MARK: - Snap Models

struct SnapGuide: Identifiable, Equatable {
    let id = UUID()
    let value: CGFloat // Normalized 0-1000
    let type: GuideType
    let strength: Float // 0..1 (Confidence)
    
    enum GuideType {
        case vertical
        case horizontal
    }
}

struct SnapResult {
    let original: CGFloat
    let snapped: CGFloat
    let guide: SnapGuide?
}

// MARK: - Snap Engine

final class SnapEngine: Sendable {
    static let shared = SnapEngine()
    
    // Config
    private let snapThreshold: CGFloat = 15.0 // User Requirement
    private let processingSize = CGSize(width: 512, height: 512) // Low res for analysis speed
    
    // MARK: - Gutter Detection
    
    func detectGutters(in image: UIImage) async -> [SnapGuide] {
        // 1. Downsample & Grayscale
        guard let cgImage = image.cgImage else { return [] }
        
        // We'll perform a Projection Profile analysis (XY Cut algorithm base)
        // This finds continuous runs of similar color (white/black channels).
        
        let width = 512
        let height = Int(CGFloat(width) * (image.size.height / image.size.width))
        
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width, // 1 byte per pixel (Grayscale)
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return [] }
        
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        guard let buffer = context.data else { return [] }
        let pixelBuffer = buffer.bindMemory(to: UInt8.self, capacity: width * height)
        
        // 2. Compute Projections
        var rowSums = [Int](repeating: 0, count: height)
        var colSums = [Int](repeating: 0, count: width)
        
        // Iterate (This comes out to ~250k pixels, iterating is fast enough ~1-2ms on device)
        for y in 0..<height {
            for x in 0..<width {
                let pixel = pixelBuffer[y * width + x]
                // We are looking for GUTTERS. Gutters are usually bright white or dark black.
                // Let's count "Extreme" pixels.
                // If pixel > 240 (White) or pixel < 15 (Black), it adds to the score.
                if pixel > 240 || pixel < 15 {
                    rowSums[y] += 1
                    colSums[x] += 1
                }
            }
        }
        
        // 3. Find Peaks/Plateaus
        // A gutter is a row/col where the sum is nearly equal to the width/height (Full line of white/black)
        
        let vGuides = findPeaks(data: colSums, maxValue: height, axisSize: CGFloat(width), type: .vertical)
        let hGuides = findPeaks(data: rowSums, maxValue: width, axisSize: CGFloat(height), type: .horizontal)
        
        return vGuides + hGuides
    }
    
    private func findPeaks(data: [Int], maxValue: Int, axisSize: CGFloat, type: SnapGuide.GuideType) -> [SnapGuide] {
        var guides: [SnapGuide] = []
        let threshold = Double(maxValue) * 0.85 // 85% of the line must be "Gutter Color"
        
        // Find runs of indices passing threshold
        var currentRunStart: Int?
        
        for (index, count) in data.enumerated() {
            if Double(count) >= threshold {
                if currentRunStart == nil {
                    currentRunStart = index
                }
            } else {
                if let start = currentRunStart {
                    // End of run
                    let end = index - 1
                    let center = CGFloat(start + end) / 2.0
                    
                    // Normalize to 0-1000
                    let normalizedValue = (center / axisSize) * 1000.0
                    
                    // Filter edge cases (don't snap to very edges 0 or 1000)
                    if normalizedValue > 10 && normalizedValue < 990 {
                        guides.append(SnapGuide(value: normalizedValue, type: type, strength: 1.0))
                    }
                    currentRunStart = nil
                }
            }
        }
        
        // Cap trailing run
        if let start = currentRunStart {
            let end = data.count - 1
            let center = CGFloat(start + end) / 2.0
            let normalizedValue = (center / axisSize) * 1000.0
            if normalizedValue > 10 && normalizedValue < 990 {
                guides.append(SnapGuide(value: normalizedValue, type: type, strength: 1.0))
            }
        }
        
        return guides
    }
    
    // MARK: - Snapping Logic
    
    // Snaps a value to the closest guide within threshold
    // Also considers "Sibling" edges if provided
    func snap(value: CGFloat, type: SnapGuide.GuideType, guides: [SnapGuide], siblingValues: [CGFloat] = []) -> SnapResult {
        
        var bestSnap: CGFloat = value
        var minDistance: CGFloat = snapThreshold
        var snappedGuide: SnapGuide?
        
        // 1. Check Detected Gutters
        for guide in guides where guide.type == type {
            let dist = abs(value - guide.value)
            if dist < minDistance {
                minDistance = dist
                bestSnap = guide.value
                snappedGuide = guide
            }
        }
        
        // 2. Check Siblings (Dynamic Guides)
        for sibling in siblingValues {
            let dist = abs(value - sibling)
            if dist < minDistance {
                minDistance = dist
                bestSnap = sibling
                // Create ephemeral guide for visualization
                snappedGuide = SnapGuide(value: sibling, type: type, strength: 0.8)
            }
        }
        
        return SnapResult(original: value, snapped: bestSnap, guide: snappedGuide)
    }
    
    func snapRect(_ rect: NormalizedRect, guides: [SnapGuide], otherPanels: [NormalizedRect]) -> (NormalizedRect, [SnapGuide]) {
        // Collect Sibling Edges
        var vSiblings: [CGFloat] = []
        var hSiblings: [CGFloat] = []
        
        for panel in otherPanels {
            vSiblings.append(panel.minX)
            vSiblings.append(panel.maxX)
            hSiblings.append(panel.minY)
            hSiblings.append(panel.maxY)
        }
        
        var activeGuides: [SnapGuide] = []
        
        // Snap X (Left/Right) - *Usually snap positions, but rect is Origin/Size*
        // We snap the edges.
        
        let minXRes = snap(value: rect.origin.x, type: .vertical, guides: guides, siblingValues: vSiblings)
        if let g = minXRes.guide { activeGuides.append(g) }
        
        let maxXRes = snap(value: rect.maxX, type: .vertical, guides: guides, siblingValues: vSiblings)
        if let g = maxXRes.guide { activeGuides.append(g) }
        
        let minYRes = snap(value: rect.origin.y, type: .horizontal, guides: guides, siblingValues: hSiblings)
        if let g = minYRes.guide { activeGuides.append(g) }
        
        let maxYRes = snap(value: rect.maxY, type: .horizontal, guides: guides, siblingValues: hSiblings)
        if let g = maxYRes.guide { activeGuides.append(g) }
        
        // Reconstruct Rect
        // Prioritize: If width/height changed significantly, we might want to maintain size?
        // Standard behavior: Snap edges independently (resize).
        // OR: If moving (drag), snap origin but keep size.
        // Needs context: "Resize" vs "Move". 
        // We'll assume RESIZE logic for independent edge snapping (Canvas usually).
        // But for MOVE, we snap origin and adjust maxX implicitly?
        
        // Let's implement independent edge snapping for the "Resize" tool and "Anchor" tool.
        // For "Edit" (Move), we'll do Move Snap logic later.
        
        // Construct new Rect from snapped edges
        let newX = minXRes.snapped
        let newMaxX = maxXRes.snapped
        let newY = minYRes.snapped
        let newMaxY = maxYRes.snapped
        
        // Ensure valid
        if newMaxX > newX && newMaxY > newY {
            // Update active guides based on what actually snapped
            var finalGuides: [SnapGuide] = []
            if abs(newX - rect.origin.x) > 0.1, let g = minXRes.guide { finalGuides.append(g) }
            if abs(newMaxX - rect.maxX) > 0.1, let g = maxXRes.guide { finalGuides.append(g) }
            if abs(newY - rect.origin.y) > 0.1, let g = minYRes.guide { finalGuides.append(g) }
            if abs(newMaxY - rect.maxY) > 0.1, let g = maxYRes.guide { finalGuides.append(g) }
            
            return (NormalizedRect(x: newX, y: newY, width: newMaxX - newX, height: newMaxY - newY), finalGuides)
        }
        
        return (rect, [])
    }
    
    // ✅ Logic for Moving (Preserves Size)
    func snapMove(_ rect: NormalizedRect, guides: [SnapGuide], otherPanels: [NormalizedRect]) -> (NormalizedRect, [SnapGuide]) {
        // Collect Sibling Edges
        var vSiblings: [CGFloat] = []
        var hSiblings: [CGFloat] = []
        
        for panel in otherPanels {
            vSiblings.append(panel.minX)
            vSiblings.append(panel.maxX)
            hSiblings.append(panel.minY)
            hSiblings.append(panel.maxY)
        }
        
        var activeGuides: [SnapGuide] = []
        
        // 1. Horizontal Snapping (X)
        // Check Left Edge
        let leftSnap = snap(value: rect.origin.x, type: .vertical, guides: guides, siblingValues: vSiblings)
        // Check Right Edge
        let rightSnap = snap(value: rect.maxX, type: .vertical, guides: guides, siblingValues: vSiblings)
        
        var newX = rect.origin.x
        
        // Prioritize the closest snap
        let leftDist = abs(leftSnap.snapped - rect.origin.x)
        let rightDist = abs(rightSnap.snapped - rect.maxX)
        
        if leftDist < snapThreshold && leftDist <= rightDist {
            newX = leftSnap.snapped
            if let g = leftSnap.guide { activeGuides.append(g) }
        } else if rightDist < snapThreshold {
            newX = rightSnap.snapped - rect.width
            if let g = rightSnap.guide { activeGuides.append(g) }
        }
        
        // 2. Vertical Snapping (Y)
        let topSnap = snap(value: rect.origin.y, type: .horizontal, guides: guides, siblingValues: hSiblings)
        let bottomSnap = snap(value: rect.maxY, type: .horizontal, guides: guides, siblingValues: hSiblings)
        
        var newY = rect.origin.y
        
        let topDist = abs(topSnap.snapped - rect.origin.y)
        let bottomDist = abs(bottomSnap.snapped - rect.maxY)
        
        if topDist < snapThreshold && topDist <= bottomDist {
            newY = topSnap.snapped
            if let g = topSnap.guide { activeGuides.append(g) }
        } else if bottomDist < snapThreshold {
            newY = bottomSnap.snapped - rect.height
            if let g = bottomSnap.guide { activeGuides.append(g) }
        }
        
        return (NormalizedRect(x: newX, y: newY, width: rect.width, height: rect.height), activeGuides)
    }
}
