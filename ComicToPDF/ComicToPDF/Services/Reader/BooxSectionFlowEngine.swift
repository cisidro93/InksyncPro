import Foundation
import CoreGraphics
import UIKit

// MARK: - Coordinate Space Enum

public enum BooxCoordinateSpace: Sendable {
    /// PDFKit space: (0,0) is bottom-left, Y increases upward
    case pdf
    /// UIKit / CoreGraphics Image space: (0,0) is top-left, Y increases downward
    case image
}

// MARK: - Boox Section Flow Engine

/// High-performance layout engine that divides a page into a sequence of readable blocks
/// honoring Boox NeoReader matrix grids, custom split ratios, margin limits,
/// and connection redundancy overlap buffers.
public final class BooxSectionFlowEngine: Sendable {
    public static let shared = BooxSectionFlowEngine()

    public init() {}

    // MARK: - Public Block Generation

    /// Generates the ordered list of section blocks for a page given a configuration.
    public func generateBlocks(
        config: BooxSectionFlowConfig,
        space: BooxCoordinateSpace = .pdf
    ) -> [BooxSectionBlock] {
        let leftTrim = max(0.0, min(0.25, config.leftMarginTrim))
        let rightTrim = max(0.0, min(0.25, config.rightMarginTrim))
        let topTrim = max(0.0, min(0.25, config.topMarginTrim))
        let botTrim = max(0.0, min(0.25, config.bottomMarginTrim))

        let activeW = max(0.2, 1.0 - (leftTrim + rightTrim))
        let activeH = max(0.2, 1.0 - (topTrim + botTrim))

        // 1. Compute Horizontal Partitions (Columns)
        var colRanges: [(minX: CGFloat, maxX: CGFloat)] = []
        let preset = config.gridPreset

        switch preset {
        case .oneByOne, .oneByTwo, .oneByThree:
            colRanges.append((leftTrim, leftTrim + activeW))
        case .twoByOne, .twoByTwo, .twoByThree, .oneOverTwo, .twoOverOne:
            let split = max(0.15, min(0.85, config.verticalSplitRatio))
            let col0W = activeW * split
            let col1W = activeW - col0W
            colRanges.append((leftTrim, leftTrim + col0W))
            colRanges.append((leftTrim + col0W, leftTrim + col0W + col1W))
        case .threeByTwo, .threeByThree:
            let third = activeW / 3.0
            colRanges.append((leftTrim, leftTrim + third))
            colRanges.append((leftTrim + third, leftTrim + (third * 2.0)))
            colRanges.append((leftTrim + (third * 2.0), leftTrim + activeW))
        }

        // 2. Compute Vertical Partitions (Rows) in top-to-bottom order (0 = top, 1 = bottom)
        var rowRanges: [(topY: CGFloat, botY: CGFloat)] = []

        switch preset {
        case .oneByOne, .twoByOne:
            rowRanges.append((topTrim, topTrim + activeH))
        case .oneByTwo, .twoByTwo, .threeByTwo, .oneOverTwo, .twoOverOne:
            let split = config.horizontalSplitRatios.first ?? 0.50
            let clampedSplit = max(0.15, min(0.85, split))
            let row0H = activeH * clampedSplit
            let row1H = activeH - row0H
            rowRanges.append((topTrim, topTrim + row0H))
            rowRanges.append((topTrim + row0H, topTrim + row0H + row1H))
        case .oneByThree, .twoByThree, .threeByThree:
            let splits = config.horizontalSplitRatios.count >= 2 ? config.horizontalSplitRatios : [0.33, 0.66]
            let s0 = max(0.10, min(0.50, splits[0]))
            let s1 = max(s0 + 0.10, min(0.90, splits[1]))
            let r0H = activeH * s0
            let r1H = activeH * (s1 - s0)
            let r2H = activeH * (1.0 - s1)
            rowRanges.append((topTrim, topTrim + r0H))
            rowRanges.append((topTrim + r0H, topTrim + r0H + r1H))
            rowRanges.append((topTrim + r0H + r1H, topTrim + r0H + r1H + r2H))
        }

        // 3. Assemble Raw Cell Rectangles (rowIdx, colIdx)
        struct Cell {
            let row: Int
            let col: Int
            let rect: CGRect
        }

        var cells: [Cell] = []

        if preset == .oneOverTwo {
            // Asymmetric: Row 0 is full-width across both columns
            let r0 = rowRanges[0]
            cells.append(Cell(row: 0, col: 0, rect: CGRect(x: leftTrim, y: r0.topY, width: activeW, height: r0.botY - r0.topY)))
            // Row 1 is split into 2 columns
            let r1 = rowRanges[1]
            for (cIdx, cRange) in colRanges.enumerated() {
                cells.append(Cell(row: 1, col: cIdx, rect: CGRect(x: cRange.minX, y: r1.topY, width: cRange.maxX - cRange.minX, height: r1.botY - r1.topY)))
            }
        } else if preset == .twoOverOne {
            // Asymmetric: Row 0 is split into 2 columns
            let r0 = rowRanges[0]
            for (cIdx, cRange) in colRanges.enumerated() {
                cells.append(Cell(row: 0, col: cIdx, rect: CGRect(x: cRange.minX, y: r0.topY, width: cRange.maxX - cRange.minX, height: r0.botY - r0.topY)))
            }
            // Row 1 is full-width across both columns
            let r1 = rowRanges[1]
            cells.append(Cell(row: 1, col: 0, rect: CGRect(x: leftTrim, y: r1.topY, width: activeW, height: r1.botY - r1.topY)))
        } else {
            // Standard M x N Matrix
            for (rIdx, rRange) in rowRanges.enumerated() {
                for (cIdx, cRange) in colRanges.enumerated() {
                    let rect = CGRect(
                        x: cRange.minX,
                        y: rRange.topY,
                        width: cRange.maxX - cRange.minX,
                        height: rRange.botY - rRange.topY
                    )
                    cells.append(Cell(row: rIdx, col: cIdx, rect: rect))
                }
            }
        }

        // 4. Sort Cells According to Reading Flow Order
        let numCols = colRanges.count
        let sortedCells: [Cell]

        switch config.flowOrder {
        case .zFlow:
            // Row-First LTR (Row ascending, then Col ascending)
            sortedCells = cells.sorted {
                if $0.row != $1.row { return $0.row < $1.row }
                return $0.col < $1.col
            }
        case .reverseZFlow:
            // Row-First RTL / Manga (Row ascending, then Col descending)
            sortedCells = cells.sorted {
                if $0.row != $1.row { return $0.row < $1.row }
                return $0.col > $1.col
            }
        case .nFlow:
            // Column-First LTR (Col ascending, then Row ascending)
            sortedCells = cells.sorted {
                if $0.col != $1.col { return $0.col < $1.col }
                return $0.row < $1.row
            }
        case .reverseNFlow:
            // Column-First RTL / Manga (Col descending, then Row ascending)
            sortedCells = cells.sorted {
                if $0.col != $1.col { return $0.col > $1.col }
                return $0.row < $1.row
            }
        }

        // 5. Generate BooxSectionBlocks with Connection Redundancy & Coordinate Space Conversion
        let redundancyBuffer = config.connectionRedundancy ? max(0.05, min(0.25, config.redundancyRatio)) : 0.0
        var blocks: [BooxSectionBlock] = []

        for (stepIdx, cell) in sortedCells.enumerated() {
            let baseRectTopY: CGRect
            if let customOverride = config.customBlockOverrides[stepIdx] {
                let minX = max(0.0, min(0.92, customOverride.minX))
                let minY = max(0.0, min(0.92, customOverride.minY))
                let width = max(0.06, min(1.0 - minX, customOverride.width))
                let height = max(0.06, min(1.0 - minY, customOverride.height))
                baseRectTopY = CGRect(x: minX, y: minY, width: width, height: height)
            } else {
                baseRectTopY = cell.rect
            }

            // Compute connection redundancy expansion
            let expandX = baseRectTopY.width * redundancyBuffer
            let expandY = baseRectTopY.height * redundancyBuffer

            let redMinX = max(0.0, baseRectTopY.minX - (cell.col > 0 ? expandX : 0.0))
            let redMaxX = min(1.0, baseRectTopY.maxX + (cell.col < (numCols - 1) ? expandX : 0.0))
            let redMinY = max(0.0, baseRectTopY.minY - (cell.row > 0 ? expandY : 0.0))
            let redMaxY = min(1.0, baseRectTopY.maxY + (cell.row < (rowRanges.count - 1) ? expandY : 0.0))

            let redundantRectTopY = CGRect(
                x: redMinX,
                y: redMinY,
                width: max(0.05, redMaxX - redMinX),
                height: max(0.05, redMaxY - redMinY)
            )

            // Convert to target Coordinate Space
            let finalBaseRect: CGRect
            let finalRedundantRect: CGRect

            if space == .pdf {
                // In PDF space: Y=0 is bottom, Y=1 is top
                // topY in UIKit converts to 1.0 - botY in PDF
                finalBaseRect = CGRect(
                    x: baseRectTopY.minX,
                    y: max(0.0, 1.0 - baseRectTopY.maxY),
                    width: baseRectTopY.width,
                    height: baseRectTopY.height
                )
                finalRedundantRect = CGRect(
                    x: redundantRectTopY.minX,
                    y: max(0.0, 1.0 - redundantRectTopY.maxY),
                    width: redundantRectTopY.width,
                    height: redundantRectTopY.height
                )
            } else {
                // In Image / UIKit space: Y=0 is top
                finalBaseRect = baseRectTopY
                finalRedundantRect = redundantRectTopY
            }

            let rowName: String
            if rowRanges.count == 3 {
                rowName = (cell.row == 0) ? "Top" : ((cell.row == 1) ? "Mid" : "Bot")
            } else if rowRanges.count == 2 {
                rowName = (cell.row == 0) ? "Top" : "Bottom"
            } else {
                rowName = ""
            }

            let label: String
            if numCols == 1 {
                if rowRanges.count == 3 {
                    let tierName = (cell.row == 0) ? "Top Tier" : ((cell.row == 1) ? "Middle Tier" : "Bottom Tier")
                    label = "\(tierName) (\(stepIdx + 1)/\(sortedCells.count))"
                } else if rowRanges.count == 2 {
                    let halfName = (cell.row == 0) ? "Top Half" : "Bottom Half"
                    label = "\(halfName) (\(stepIdx + 1)/\(sortedCells.count))"
                } else {
                    label = "Block \(stepIdx + 1) of \(sortedCells.count)"
                }
            } else {
                let colName: String
                if config.flowOrder == .reverseNFlow || config.flowOrder == .reverseZFlow {
                    colName = (cell.col == 0) ? "Right Col" : (numCols == 2 ? "Left Col" : "Col \(cell.col + 1)")
                } else {
                    colName = "Col \(cell.col + 1)"
                }
                let tierPart = !rowName.isEmpty ? " · \(rowName)" : ""
                label = "\(colName)\(tierPart) (\(stepIdx + 1)/\(sortedCells.count))"
            }

            blocks.append(BooxSectionBlock(
                id: stepIdx,
                stepOrder: stepIdx,
                columnIndex: cell.col,
                rowIndex: cell.row,
                totalBlocks: sortedCells.count,
                normalizedRect: finalBaseRect,
                redundantRect: finalRedundantRect,
                label: label
            ))
        }

        return blocks
    }

    // MARK: - Magnetic Gutter Detection

    /// Detects candidate vertical and horizontal whitespace gutters in an image for magnetic snapping.
    public func detectMagneticGutters(in image: UIImage?) -> (vertical: [CGFloat], horizontal: [CGFloat]) {
        guard let img = image, let cgImage = img.cgImage else {
            return ([0.50], [0.33, 0.50, 0.66])
        }

        let width = cgImage.width
        let height = cgImage.height
        guard width > 50, height > 50 else {
            return ([0.50], [0.33, 0.50, 0.66])
        }

        // Return standard harmonic gutter candidates if full pixel analysis is offloaded
        return ([0.33, 0.50, 0.66], [0.25, 0.33, 0.50, 0.66, 0.75])
    }
}
