//
//  PDFHighlightGeometryHelper.swift
//  ComicToPDF
//
//  Created for InkSync Pro.
//  Point-Free Swift 6 & Apple PDFKit ISO 32000-1 coordinate standard.
//

import Foundation
import PDFKit
import UIKit

/// Mathematically precise coordinate calculations for native PDFKit highlight annotations.
///
/// ### Coordinate Space Architecture:
/// In ISO 32000-1 and Apple's PDFKit:
/// 1. An annotation has an overall bounding box (`annotation.bounds`) in PDF page coordinates
///    (origin (0, 0) at the bottom-left corner of the page).
/// 2. The `quadrilateralPoints` property defines the exact quad shapes of the marked-up text glyphs.
/// 3. In Apple's PDFKit implementation, the `CGPoint` coordinates stored inside `quadrilateralPoints`
///    **MUST be in absolute PDF page coordinates** (the same coordinate space as `annotation.bounds`).
///    Subtracting the bounds origin causes PDFKit to project the quadrilaterals down to (0, 0) at the
///    bottom margin of the page, completely outside the annotation bounds, which causes PDFKit to
///    clip the markup to zero visible pixels (rendering it invisible).
/// 4. Each quadrilateral is specified by 4 points ordered in Apple's standard Z-pattern:
///    - Point 1: Top-Left     (minX, maxY)
///    - Point 2: Top-Right    (maxX, maxY)
///    - Point 3: Bottom-Left  (minX, minY)
///    - Point 4: Bottom-Right (maxX, minY)
public enum PDFHighlightGeometryHelper: Sendable {

    /// Computes the union bounding box across multiple line rects in page coordinates.
    public static func unionBounds(for lineBounds: [CGRect]) -> CGRect {
        let valid = lineBounds.filter { !$0.isNull && !$0.isInfinite && $0.width > 0 && $0.height > 0 }
        guard let first = valid.first else { return .zero }
        return valid.dropFirst().reduce(first) { $0.union($1) }
    }

    /// Converts line bounds in page space into an array of `NSValue(cgPoint:)`
    /// formatted in Apple PDFKit Z-pattern order in native PDF page space coordinates.
    public static func createQuadPoints(for lineBounds: [CGRect]) -> [NSValue] {
        var quadValues: [NSValue] = []
        for line in lineBounds {
            guard !line.isNull, !line.isInfinite, line.width > 0, line.height > 0 else { continue }

            // Standard Apple PDFKit Z-pattern in PDF page space:
            // 1. Top-Left
            quadValues.append(NSValue(cgPoint: CGPoint(x: line.minX, y: line.maxY)))
            // 2. Top-Right
            quadValues.append(NSValue(cgPoint: CGPoint(x: line.maxX, y: line.maxY)))
            // 3. Bottom-Left
            quadValues.append(NSValue(cgPoint: CGPoint(x: line.minX, y: line.minY)))
            // 4. Bottom-Right
            quadValues.append(NSValue(cgPoint: CGPoint(x: line.maxX, y: line.minY)))
        }
        return quadValues
    }

    /// Backwards-compatible overload for callers passing `relativeTo:`.
    /// Note: Apple PDFKit requires page-space quad points; `overallBounds` is preserved
    /// for API compatibility while guaranteeing accurate page-space coordinate rendering.
    public static func createQuadPoints(for lineBounds: [CGRect], relativeTo overallBounds: CGRect) -> [NSValue] {
        return createQuadPoints(for: lineBounds)
    }

    /// Creates quad points for a single bounding box in PDF page space.
    public static func createQuadPoints(for bounds: CGRect) -> [NSValue] {
        guard !bounds.isNull, !bounds.isInfinite, bounds.width > 0, bounds.height > 0 else { return [] }
        return [
            NSValue(cgPoint: CGPoint(x: bounds.minX, y: bounds.maxY)), // Top-Left
            NSValue(cgPoint: CGPoint(x: bounds.maxX, y: bounds.maxY)), // Top-Right
            NSValue(cgPoint: CGPoint(x: bounds.minX, y: bounds.minY)), // Bottom-Left
            NSValue(cgPoint: CGPoint(x: bounds.maxX, y: bounds.minY))  // Bottom-Right
        ]
    }
}
