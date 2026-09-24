import Foundation
import CoreGraphics

// MARK: - PDF Smart Tier Models

/// Represents a discrete focused viewport segment (quadrant / tier) within a PDF page.
public struct PDFTierQuadrant: Identifiable, Equatable, Sendable {
    public let id: Int
    public let columnIndex: Int        // 0-indexed column
    public let tierIndex: Int          // 0-indexed tier within the column
    public let totalColumns: Int
    public let totalTiersInColumn: Int
    public let stepOrder: Int          // Overall sequence order (0, 1, 2...)
    public let totalInPage: Int
    public let normalizedRect: CGRect  // (0...1) normalized coordinates in PDF Page cropBox space
    public let label: String           // e.g. "Col 1 · Top (1/6)" or "Tier 2 of 3"

    public init(
        id: Int,
        columnIndex: Int,
        tierIndex: Int,
        totalColumns: Int,
        totalTiersInColumn: Int,
        stepOrder: Int,
        totalInPage: Int,
        normalizedRect: CGRect,
        label: String
    ) {
        self.id = id
        self.columnIndex = columnIndex
        self.tierIndex = tierIndex
        self.totalColumns = totalColumns
        self.totalTiersInColumn = totalTiersInColumn
        self.stepOrder = stepOrder
        self.totalInPage = totalInPage
        self.normalizedRect = normalizedRect
        self.label = label
    }
}

/// Section Reading Flow Order (Boox NeoReader Standard)
public enum PDFReadingFlowOrder: String, CaseIterable, Identifiable, Codable, Sendable {
    case columnFirst = "columnFirst" // Column-by-Column (N-Flow): Col 1 Top->Bot, then Col 2 Top->Bot
    case rowFirst    = "rowFirst"    // Row-by-Row (Z-Flow): Top-Left -> Top-Right -> Mid-Left -> Mid-Right
    case mangaRTL    = "mangaRTL"    // Manga RTL: Right Col Top->Bot, then Left Col Top->Bot

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .columnFirst: return "Column-First (N)"
        case .rowFirst:    return "Row-First (Z)"
        case .mangaRTL:    return "Manga RTL"
        }
    }

    public var icon: String {
        switch self {
        case .columnFirst: return "arrow.down.to.line.compact"
        case .rowFirst:    return "arrow.right.to.line.compact"
        case .mangaRTL:    return "arrow.left.to.line.compact"
        }
    }
}

/// Guided View layout presets for PDF documents.
public enum PDFTierLayoutPreset: String, CaseIterable, Identifiable, Codable, Sendable {
    case twoColumn    = "twoColumn"    // Academic / Paper (2 Columns: Left Top-to-Bot, Right Top-to-Bot)
    case singleColumn = "singleColumn" // Single Column (3 Tiers: Top, Mid, Bot)
    case threeColumn  = "threeColumn"  // Magazine / Multi-column (3 Columns)
    case autoColumns  = "autoColumns"  // Auto AI Column Gutter Detection + Tiers

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .twoColumn:    return "2 Columns"
        case .singleColumn: return "1 Column"
        case .threeColumn:  return "3 Columns"
        case .autoColumns:  return "Auto AI"
        }
    }

    public var icon: String {
        switch self {
        case .twoColumn:    return "rectangle.split.2x1"
        case .singleColumn: return "rectangle"
        case .threeColumn:  return "rectangle.split.3x1"
        case .autoColumns:  return "sparkles.rectangle.stack"
        }
    }

    public var subtitle: String {
        switch self {
        case .twoColumn:    return "Left column top-to-bottom, then right column"
        case .singleColumn: return "Top, middle, and bottom tiers down the page"
        case .threeColumn:  return "3 columns flowed sequentially"
        case .autoColumns:  return "Automatically analyzes page text gutters"
        }
    }
}

/// Stores user's quick reference guides, page limits, and parameters for Smart Tiers across a document.
public struct PDFTierGuideConfiguration: Codable, Equatable, Sendable {
    public var preset: PDFTierLayoutPreset
    public var columnCount: Int         // 1, 2, or 3
    public var tiersPerColumn: Int       // 2, 3, or 4
    public var columnSplitRatio: CGFloat // 0.2 ... 0.8 (default 0.5 for equal 2-col)
    public var verticalOverlap: CGFloat  // 0.05 ... 0.25 (default 0.15 = 15% overlap)
    public var topMarginTrim: CGFloat    // 0.0 ... 0.20 (exclude running headers)
    public var bottomMarginTrim: CGFloat // 0.0 ... 0.20 (exclude footers/page numbers)
    public var leftMarginTrim: CGFloat   // 0.0 ... 0.20 (exclude left outer margins)
    public var rightMarginTrim: CGFloat  // 0.0 ... 0.20 (exclude right outer margins)
    public var flowOrder: PDFReadingFlowOrder // Column-First, Row-First, or Manga RTL

    public init(
        preset: PDFTierLayoutPreset = .twoColumn,
        columnCount: Int = 2,
        tiersPerColumn: Int = 3,
        columnSplitRatio: CGFloat = 0.5,
        verticalOverlap: CGFloat = 0.15,
        topMarginTrim: CGFloat = 0.04,
        bottomMarginTrim: CGFloat = 0.04,
        leftMarginTrim: CGFloat = 0.0,
        rightMarginTrim: CGFloat = 0.0,
        flowOrder: PDFReadingFlowOrder = .columnFirst
    ) {
        self.preset = preset
        self.columnCount = columnCount
        self.tiersPerColumn = tiersPerColumn
        self.columnSplitRatio = columnSplitRatio
        self.verticalOverlap = verticalOverlap
        self.topMarginTrim = topMarginTrim
        self.bottomMarginTrim = bottomMarginTrim
        self.leftMarginTrim = leftMarginTrim
        self.rightMarginTrim = rightMarginTrim
        self.flowOrder = flowOrder
    }

    public static let standardTwoColumn = PDFTierGuideConfiguration(
        preset: .twoColumn,
        columnCount: 2,
        tiersPerColumn: 3,
        columnSplitRatio: 0.5,
        verticalOverlap: 0.15,
        topMarginTrim: 0.04,
        bottomMarginTrim: 0.04,
        leftMarginTrim: 0.0,
        rightMarginTrim: 0.0,
        flowOrder: .columnFirst
    )

    public static let standardSingleColumn = PDFTierGuideConfiguration(
        preset: .singleColumn,
        columnCount: 1,
        tiersPerColumn: 3,
        columnSplitRatio: 0.5,
        verticalOverlap: 0.15,
        topMarginTrim: 0.03,
        bottomMarginTrim: 0.03,
        leftMarginTrim: 0.0,
        rightMarginTrim: 0.0,
        flowOrder: .columnFirst
    )

    public static let standardAuto = PDFTierGuideConfiguration(
        preset: .autoColumns,
        columnCount: 2,
        tiersPerColumn: 3,
        columnSplitRatio: 0.5,
        verticalOverlap: 0.15,
        topMarginTrim: 0.04,
        bottomMarginTrim: 0.04,
        leftMarginTrim: 0.0,
        rightMarginTrim: 0.0,
        flowOrder: .columnFirst
    )
}

// MARK: - Boox Bridge Synchronization

extension PDFTierGuideConfiguration {
    public func asBooxConfig() -> BooxSectionFlowConfig {
        let preset: BooxGridPreset
        switch (columnCount, tiersPerColumn) {
        case (1, 1): preset = .oneByOne
        case (1, 2): preset = .oneByTwo
        case (1, 3): preset = .oneByThree
        case (2, 1): preset = .twoByOne
        case (2, 2): preset = .twoByTwo
        case (2, 3): preset = .twoByThree
        case (3, 2): preset = .threeByTwo
        case (3, 3): preset = .threeByThree
        default:
            preset = columnCount == 1 ? .oneByThree : (columnCount == 3 ? .threeByThree : .twoByThree)
        }

        let booxFlow: BooxFlowOrder
        switch flowOrder {
        case .columnFirst: booxFlow = .nFlow
        case .rowFirst: booxFlow = .zFlow
        case .mangaRTL: booxFlow = .reverseNFlow
        }

        let hSplits: [CGFloat] = tiersPerColumn == 3 ? [0.33, 0.66] : [0.50]

        return BooxSectionFlowConfig(
            gridPreset: preset,
            flowOrder: booxFlow,
            isSpreadMode: false,
            verticalSplitRatio: columnSplitRatio,
            horizontalSplitRatios: hSplits,
            topMarginTrim: topMarginTrim,
            bottomMarginTrim: bottomMarginTrim,
            leftMarginTrim: leftMarginTrim,
            rightMarginTrim: rightMarginTrim,
            autoCropAfterPagination: false,
            connectionRedundancy: verticalOverlap > 0.01,
            redundancyRatio: verticalOverlap,
            customBlockOverrides: [:]
        )
    }
}

