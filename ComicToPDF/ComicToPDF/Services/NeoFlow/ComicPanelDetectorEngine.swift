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
        await withCheckedContinuation { continuation in
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
                    guard normalizedW >= 0.15, normalizedH >= 0.10,
                          !(normalizedW > 0.97 && normalizedH > 0.97) else { continue }

                    let rect = CGRect(
                        x: max(0.0, min(1.0, normalizedX)),
                        y: max(0.0, min(1.0, normalizedY)),
                        width: min(1.0, normalizedW),
                        height: min(1.0, normalizedH)
                    )
                    rects.append(rect)
                }

                // Filter heavily overlapping rects (e.g. inner dialogue borders inside a panel)
                let nonOverlapping = self.filterOverlappingRects(rects)
                continuation.resume(returning: nonOverlapping)
            }

            request.minimumAspectRatio = 0.2
            request.maximumAspectRatio = 5.0
            request.minimumSize = 0.12
            request.minimumConfidence = 0.65
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

    // MARK: - Topological Reading Order Sort

    private func sortPanels(_ rects: [CGRect], isManga: Bool) -> [CGRect] {
        // Group into vertical tiers based on center Y proximity
        let tierThreshold = 0.10

        return rects.sorted { a, b in
            let aCenterY = a.midY
            let bCenterY = b.midY

            if abs(aCenterY - bCenterY) > tierThreshold {
                // Different vertical tiers: Top always precedes bottom
                return aCenterY < bCenterY
            } else {
                // Same tier:
                // Western: Left to right (a.minX < b.minX)
                // Manga: Right to left (a.maxX > b.maxX)
                if isManga {
                    return a.maxX > b.maxX
                } else {
                    return a.minX < b.minX
                }
            }
        }
    }
}
