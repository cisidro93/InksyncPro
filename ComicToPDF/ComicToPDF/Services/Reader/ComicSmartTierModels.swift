import Foundation
import CoreGraphics

// MARK: - Comic Smart Tier Models

/// Represents a discrete focused viewport segment (tier or quadrant) within a Comic or Manga page.
public struct ComicTierQuadrant: Identifiable, Equatable, Sendable {
    public let id: Int
    public let columnIndex: Int        // 0-indexed column (reading order)
    public let tierIndex: Int          // 0-indexed tier within the column (0 = Top)
    public let totalColumns: Int
    public let totalTiersInColumn: Int
    public let stepOrder: Int          // Overall sequence order (0, 1, 2...)
    public let totalInPage: Int
    public let normalizedRect: CGRect  // (0...1) normalized coordinates in Vision space (bottom-left origin)
    public let label: String           // e.g. "Top Tier (1/3)" or "Right Col · Top (1/4)"

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

/// Guided View layout presets for Comic & Manga reading.
public enum ComicTierLayoutPreset: String, CaseIterable, Identifiable, Codable, Sendable {
    case threeTier  = "threeTier"   // 3 Tiers (Top, Middle, Bottom)
    case twoHalves  = "twoHalves"   // 2 Halves (Top Half, Bottom Half)
    case yonkoma    = "yonkoma"     // 4-Panel Yonkoma / 2-Column (2x2 grid)
    case fourTier   = "fourTier"    // 4 Dense Tiers (Franco-Belgian / European albums)
    case autoGutter = "autoGutter"  // Auto Horizontal Gutter Detection + Smart Tiers

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .threeTier:  return "3 Tiers"
        case .twoHalves:  return "2 Halves"
        case .yonkoma:    return "4-Panel Yonkoma"
        case .fourTier:   return "4 Tiers"
        case .autoGutter: return "Auto Gutter"
        }
    }

    public var icon: String {
        switch self {
        case .threeTier:  return "rectangle.split.3x1"
        case .twoHalves:  return "rectangle.split.2x1"
        case .yonkoma:    return "square.grid.2x2"
        case .fourTier:   return "rectangle.grid.1x2"
        case .autoGutter: return "sparkles.rectangle.stack"
        }
    }

    public var subtitle: String {
        switch self {
        case .threeTier:  return "Top, middle, and bottom tiers down the page"
        case .twoHalves:  return "Top half and bottom half with safe overlap"
        case .yonkoma:    return "2 columns × 2 tiers with Manga RTL or Western flow"
        case .fourTier:   return "4 dense tiers for classic or European albums"
        case .autoGutter: return "Detects panel gutters, falls back to smart tiers"
        }
    }
}

/// Stores user's quick reference guides and parameters for Smart Tiers across a comic book.
public struct ComicTierGuideConfiguration: Codable, Equatable, Sendable {
    public var preset: ComicTierLayoutPreset
    public var tierCount: Int          // 2, 3, or 4
    public var columnCount: Int        // 1 or 2
    public var overlap: Double         // 0.05 ... 0.30 (default 0.15 = 15% overlap)
    public var columnSplitRatio: Double // 0.35 ... 0.65 (default 0.50 for equal split)
    public var topMarginTrim: Double   // 0.0 ... 0.10
    public var bottomMarginTrim: Double // 0.0 ... 0.10

    public init(
        preset: ComicTierLayoutPreset = .threeTier,
        tierCount: Int = 3,
        columnCount: Int = 1,
        overlap: Double = 0.15,
        columnSplitRatio: Double = 0.50,
        topMarginTrim: Double = 0.0,
        bottomMarginTrim: Double = 0.0
    ) {
        self.preset = preset
        self.tierCount = tierCount
        self.columnCount = columnCount
        self.overlap = overlap
        self.columnSplitRatio = columnSplitRatio
        self.topMarginTrim = topMarginTrim
        self.bottomMarginTrim = bottomMarginTrim
    }

    public static let standardThreeTier = ComicTierGuideConfiguration(
        preset: .threeTier,
        tierCount: 3,
        columnCount: 1,
        overlap: 0.15,
        columnSplitRatio: 0.50,
        topMarginTrim: 0.0,
        bottomMarginTrim: 0.0
    )

    public static let standardTwoHalves = ComicTierGuideConfiguration(
        preset: .twoHalves,
        tierCount: 2,
        columnCount: 1,
        overlap: 0.18,
        columnSplitRatio: 0.50,
        topMarginTrim: 0.0,
        bottomMarginTrim: 0.0
    )

    public static let standardYonkoma = ComicTierGuideConfiguration(
        preset: .yonkoma,
        tierCount: 2,
        columnCount: 2,
        overlap: 0.12,
        columnSplitRatio: 0.50,
        topMarginTrim: 0.0,
        bottomMarginTrim: 0.0
    )

    public static let standardFourTier = ComicTierGuideConfiguration(
        preset: .fourTier,
        tierCount: 4,
        columnCount: 1,
        overlap: 0.12,
        columnSplitRatio: 0.50,
        topMarginTrim: 0.0,
        bottomMarginTrim: 0.0
    )

    public static let standardAutoGutter = ComicTierGuideConfiguration(
        preset: .autoGutter,
        tierCount: 3,
        columnCount: 1,
        overlap: 0.15,
        columnSplitRatio: 0.50,
        topMarginTrim: 0.0,
        bottomMarginTrim: 0.0
    )
}
