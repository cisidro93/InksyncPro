import Foundation
import UIKit
import Vision

// MARK: - Comic Panel Detector Engine (AI / Vision-Powered)

/// High-precision comic & manga panel edge detector using Apple's Vision framework
/// and intelligent gutter luminance analysis.
public final class ComicPanelDetectorEngine: Sendable {
    public static let shared = ComicPanelDetectorEngine()

    private init() {}

    /// Detects rectangular comic panels in the provided page image.
    /// - Parameters:
    ///   - image: The UIImage of the comic page.
    ///   - isManga: If true, sorts panels in Japanese Right-to-Left reading order.
    /// - Returns: An array of normalized CGRects (origin [0,1], size [0,1]) sorted in reading order.
    public func detectPanels(in image: UIImage, isManga: Bool = false) async -> [CGRect] {
        guard let cgImage = image.cgImage else { return [] }

        // Method 1: Apple Vision Rectangle Detection
        let visionPanels = await detectVisionRectangles(cgImage: cgImage)
        if visionPanels.count >= 2 {
            return sortPanels(visionPanels, isManga: isManga)
        }

        // Method 2: Fallback Gutter Segmentation (for borderless panels or light gutters)
        let gutterPanels = detectGutterPanels(cgImage: cgImage)
        if !gutterPanels.isEmpty {
            return sortPanels(gutterPanels, isManga: isManga)
        }

        // Fallback default: standard full-page inset or 2-panel split
        return visionPanels.isEmpty ? [CGRect(x: 0.05, y: 0.05, width: 0.90, height: 0.90)] : visionPanels
    }

    // MARK: - Vision Rectangle Detection

    private func detectVisionRectangles(cgImage: CGImage) async -> [CGRect] {
        // Query personalized thresholds and learned framing padding from AdaptiveLearningManager
        let currentConfidence = await MainActor.run { AdaptiveLearningManager.shared.currentBaseConfidence }
        let currentMinSize = await MainActor.run { AdaptiveLearningManager.shared.currentMinimumSize }
        let padding = await MainActor.run { AdaptiveLearningManager.shared.preferredMarginPadding }

        return await withCheckedContinuation { continuation in
            let request = VNDetectRectanglesRequest { request, error in
                guard error == nil, let observations = request.results as? [VNRectangleObservation], !observations.isEmpty else {
                    continuation.resume(returning: [])
                    return
                }

                var rects: [CGRect] = []
                for obs in observations {
                    // Vision coordinates: origin is bottom-left, Y increases upward.
                    // UIKit/SwiftUI coordinates: origin is top-left, Y increases downward.
                    let normalizedX = obs.boundingBox.origin.x
                    let normalizedY = 1.0 - (obs.boundingBox.origin.y + obs.boundingBox.size.height)
                    let normalizedW = obs.boundingBox.size.width
                    let normalizedH = obs.boundingBox.size.height

                    // Filter out microscopic frames or full-bleed page borders
                    guard normalizedW >= CGFloat(currentMinSize * 0.8), normalizedH >= CGFloat(currentMinSize * 0.6),
                          !(normalizedW > 0.97 && normalizedH > 0.97) else { continue }

                    // Apply personalized learned framing margins
                    let padX = normalizedW * CGFloat(padding)
                    let padY = normalizedH * CGFloat(padding)

                    let clampedX = max(0.0, min(1.0, normalizedX - padX))
                    let clampedY = max(0.0, min(1.0, normalizedY - padY))

                    let rect = CGRect(
                        x: clampedX,
                        y: clampedY,
                        width: min(1.0 - clampedX, normalizedW + (padX * 2)),
                        height: min(1.0 - clampedY, normalizedH + (padY * 2))
                    )
                    rects.append(rect)
                }

                // Filter heavily overlapping rects (e.g. inner dialogue borders inside a panel)
                let nonOverlapping = self.filterOverlappingRects(rects)
                continuation.resume(returning: nonOverlapping)
            }

            request.minimumAspectRatio = 0.2
            request.maximumAspectRatio = 5.0
            request.minimumSize = Float(min(0.20, max(0.04, currentMinSize)))
            request.minimumConfidence = Float(min(0.85, max(0.25, currentConfidence)))
            request.quadratureTolerance = 15.0
            request.maximumObservations = 24

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: [])
            }
        }
    }

    // MARK: - Gutter Luminance Segmentation Fallback

    private func detectGutterPanels(cgImage: CGImage) -> [CGRect] {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 200, height > 200 else { return [] }

        // Downsample to low-res thumbnail for fast row/column scan
        let targetW = 120
        let targetH = 160
        guard let context = CGContext(
            data: nil,
            width: targetW,
            height: targetH,
            bitsPerComponent: 8,
            bytesPerRow: targetW,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return [] }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetW, height: targetH))
        guard let pixelData = context.data else { return [] }
        let ptr = pixelData.bindMemory(to: UInt8.self, capacity: targetW * targetH)

        // Find horizontal gutters (rows with high brightness and low variance)
        var rowAverages = [Double](repeating: 0, count: targetH)
        for y in 0..<targetH {
            var sum = 0
            for x in 0..<targetW {
                sum += Int(ptr[y * targetW + x])
            }
            rowAverages[y] = Double(sum) / Double(targetW)
        }

        // Detect horizontal cut lines (gutters are typically near-white > 235 or near-black < 25)
        var horizontalCuts: [Double] = [0.05]
        var inGutter = false
        for y in 10..<(targetH - 10) {
            let lum = rowAverages[y]
            let isGutterRow = lum > 230 || lum < 25
            if isGutterRow && !inGutter {
                inGutter = true
                let normalizedY = Double(y) / Double(targetH)
                horizontalCuts.append(normalizedY)
            } else if !isGutterRow {
                inGutter = false
            }
        }
        horizontalCuts.append(0.95)

        // Form tiered horizontal strips
        var panels: [CGRect] = []
        for i in 0..<(horizontalCuts.count - 1) {
            let top = horizontalCuts[i]
            let bottom = horizontalCuts[i + 1]
            let h = bottom - top
            if h >= 0.12 {
                panels.append(CGRect(x: 0.05, y: top, width: 0.90, height: h))
            }
        }

        return panels
    }

    // MARK: - Overlap Filter

    private func filterOverlappingRects(_ rects: [CGRect]) -> [CGRect] {
        var clean: [CGRect] = []
        let sortedByArea = rects.sorted { ($0.width * $0.height) > ($1.width * $1.height) }

        for rect in sortedByArea {
            let isInsideExisting = clean.contains { existing in
                let intersection = existing.intersection(rect)
                let intersectionArea = intersection.width * intersection.height
                let rectArea = rect.width * rect.height
                return (intersectionArea / rectArea) > 0.65
            }
            if !isInsideExisting {
                clean.append(rect)
            }
        }

        return clean
    }

    // MARK: - Recursive Spatial Subdivision (Layout Tree / XY-Cut Reading Order)

    /// Sorts detected panels using Recursive Spatial Subdivision (Layout Tree / XY-Cut),
    /// which accurately orders complex comic and manga pages with full-height side panels,
    /// L-shaped columns, and staggered multi-tier layouts.
    private func sortPanels(_ rects: [CGRect], isManga: Bool) -> [CGRect] {
        guard rects.count > 1 else { return rects }
        return recursiveXYCutSort(rects, isManga: isManga)
    }

    private func recursiveXYCutSort(_ rects: [CGRect], isManga: Bool) -> [CGRect] {
        guard rects.count > 1 else { return rects }

        // 1. Check for a clean Horizontal Gutter that divides the set into Top and Bottom subsets
        if let (topSet, bottomSet) = findHorizontalSplit(rects) {
            return recursiveXYCutSort(topSet, isManga: isManga) + recursiveXYCutSort(bottomSet, isManga: isManga)
        }

        // 2. Check for a clean Vertical Gutter that divides the set into Left and Right subsets
        if let (leftSet, rightSet) = findVerticalSplit(rects) {
            if isManga {
                // Manga reads Right-to-Left
                return recursiveXYCutSort(rightSet, isManga: isManga) + recursiveXYCutSort(leftSet, isManga: isManga)
            } else {
                // Western reads Left-to-Right
                return recursiveXYCutSort(leftSet, isManga: isManga) + recursiveXYCutSort(rightSet, isManga: isManga)
            }
        }

        // 3. Fallback: If panels are interlocking or staggered with no clean straight divider,
        // use SIMD-tier proximity vertical sorting with horizontal tie-breaking.
        return fallbackTierSort(rects, isManga: isManga)
    }

    private func findHorizontalSplit(_ rects: [CGRect]) -> ([CGRect], [CGRect])? {
        let sorted = rects.sorted { $0.maxY < $1.maxY }
        let tolerance: CGFloat = 0.015

        var maxTopY: CGFloat = sorted[0].maxY
        for i in 0..<(sorted.count - 1) {
            maxTopY = max(maxTopY, sorted[i].maxY)
            let remainingMinY = sorted[(i + 1)...].map(\.minY).min() ?? 0.0
            if remainingMinY >= (maxTopY - tolerance) {
                let topSet = Array(sorted[0...i])
                let bottomSet = Array(sorted[(i + 1)...])
                return (topSet, bottomSet)
            }
        }
        return nil
    }

    private func findVerticalSplit(_ rects: [CGRect]) -> ([CGRect], [CGRect])? {
        let sorted = rects.sorted { $0.maxX < $1.maxX }
        let tolerance: CGFloat = 0.015

        var maxLeftX: CGFloat = sorted[0].maxX
        for i in 0..<(sorted.count - 1) {
            maxLeftX = max(maxLeftX, sorted[i].maxX)
            let remainingMinX = sorted[(i + 1)...].map(\.minX).min() ?? 0.0
            if remainingMinX >= (maxLeftX - tolerance) {
                let leftSet = Array(sorted[0...i])
                let rightSet = Array(sorted[(i + 1)...])
                return (leftSet, rightSet)
            }
        }
        return nil
    }

    private func fallbackTierSort(_ rects: [CGRect], isManga: Bool) -> [CGRect] {
        let tierThreshold = 0.10
        return rects.sorted { a, b in
            let aCenterY = a.midY
            let bCenterY = b.midY

            if abs(aCenterY - bCenterY) > tierThreshold {
                return aCenterY < bCenterY
            } else {
                return isManga ? (a.maxX > b.maxX) : (a.minX < b.minX)
            }
        }
    }
}
