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
/// 1. An annotation has an overall bounding box (`annotation.bounds`) in page coordinates.
/// 2. The `quadrilateralPoints` property defines the exact quad shapes of the highlighted text glyphs.
/// 3. In Apple's PDFKit implementation, the `CGPoint` coordinates stored inside `quadrilateralPoints`
///    **MUST be in coordinate space relative to `annotation.bounds.origin`**. Passing absolute page
///    coordinates shifts the rendered highlight by `(bounds.origin.x, bounds.origin.y)`, projecting it
///    outside the annotation bounds and causing PDFKit to discard or clip the rendering.
/// 4. Each quadrilateral is specified by 4 points ordered in Apple's standard Z-pattern:
///    - Point 1: Top-Left  (relMinX, relMaxY)
///    - Point 2: Top-Right (relMaxX, relMaxY)
///    - Point 3: Bottom-Left (relMinX, relMinY)
///    - Point 4: Bottom-Right (relMaxX, relMinY)
public enum PDFHighlightGeometryHelper: Sendable {

    /// Computes the union bounding box across multiple line rects in page coordinates.
    public static func unionBounds(for lineBounds: [CGRect]) -> CGRect {
        let valid = lineBounds.filter { !$0.isNull && !$0.isInfinite && $0.width > 0 && $0.height > 0 }
        guard let first = valid.first else { return .zero }
        return valid.dropFirst().reduce(first) { $0.union($1) }
    }

    /// Converts line bounds in page space into an array of `NSValue(cgPoint:)`
    /// relative to `overallBounds.origin`, formatted in Apple PDFKit Z-pattern order.
    public static func createQuadPoints(for lineBounds: [CGRect], relativeTo overallBounds: CGRect) -> [NSValue] {
        var quadValues: [NSValue] = []
        for line in lineBounds {
            guard !line.isNull, !line.isInfinite, line.width > 0, line.height > 0 else { continue }
            let relMinX = line.minX - overallBounds.minX
            let relMaxX = line.maxX - overallBounds.minX
            let relMinY = line.minY - overallBounds.minY
            let relMaxY = line.maxY - overallBounds.minY

            // 1. Top-Left
            quadValues.append(NSValue(cgPoint: CGPoint(x: relMinX, y: relMaxY)))
            // 2. Top-Right
            quadValues.append(NSValue(cgPoint: CGPoint(x: relMaxX, y: relMaxY)))
            // 3. Bottom-Left
            quadValues.append(NSValue(cgPoint: CGPoint(x: relMinX, y: relMinY)))
            // 4. Bottom-Right
            quadValues.append(NSValue(cgPoint: CGPoint(x: relMaxX, y: relMinY)))
        }
        return quadValues
    }

    /// Creates quad points for a single bounding box relative to its own origin.
    public static func createQuadPoints(for bounds: CGRect) -> [NSValue] {
        guard !bounds.isNull, !bounds.isInfinite, bounds.width > 0, bounds.height > 0 else { return [] }
        return [
            NSValue(cgPoint: CGPoint(x: 0, y: bounds.height)),            // Top-Left
            NSValue(cgPoint: CGPoint(x: bounds.width, y: bounds.height)), // Top-Right
            NSValue(cgPoint: CGPoint(x: 0, y: 0)),                        // Bottom-Left
            NSValue(cgPoint: CGPoint(x: bounds.width, y: 0))             // Bottom-Right
        ]
    }
}
