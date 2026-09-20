import Foundation
import CoreGraphics

// MARK: - Boox Grid Presets

/// Grid subdivision presets matching Onyx Boox NeoReader matrix standards
/// plus InksyncPro asymmetric comic extensions.
public enum BooxGridPreset: String, CaseIterable, Codable, Sendable {
    case oneByOne = "1x1"
    case twoByOne = "2x1"
    case oneByTwo = "1x2"
    case oneByThree = "1x3"
    case twoByTwo = "2x2"
    case twoByThree = "2x3"
    case threeByTwo = "3x2"
    case threeByThree = "3x3"
    // Asymmetric Extensions
    case oneOverTwo = "1-2"
    case twoOverOne = "2-1"

    public var displayName: String {
        switch self {
        case .oneByOne: return "1x1 (Single)"
        case .twoByOne: return "2x1 (2 Cols)"
        case .oneByTwo: return "1x2 (2 Rows)"
        case .oneByThree: return "1x3 (3 Tiers)"
        case .twoByTwo: return "2x2 (4 Blocks)"
        case .twoByThree: return "2x3 (6 Blocks)"
        case .threeByTwo: return "3x2 (6 Blocks)"
        case .threeByThree: return "3x3 (9 Blocks)"
        case .oneOverTwo: return "1 over 2"
        case .twoOverOne: return "2 over 1"
        }
    }

    public var columnCount: Int {
        switch self {
        case .oneByOne, .oneByTwo, .oneByThree: return 1
        case .twoByOne, .twoByTwo, .twoByThree: return 2
        case .threeByTwo, .threeByThree: return 3
        case .oneOverTwo, .twoOverOne: return 2
        }
    }

    public var rowCount: Int {
        switch self {
        case .oneByOne, .twoByOne: return 1
        case .oneByTwo, .twoByTwo, .threeByTwo: return 2
        case .oneByThree, .twoByThree, .threeByThree: return 3
        case .oneOverTwo, .twoOverOne: return 2
        }
    }

    public var totalBlocks: Int {
        switch self {
        case .oneByOne: return 1
        case .twoByOne: return 2
        case .oneByTwo: return 2
        case .oneByThree: return 3
        case .twoByTwo: return 4
        case .twoByThree: return 6
        case .threeByTwo: return 6
        case .threeByThree: return 9
        case .oneOverTwo: return 3
        case .twoOverOne: return 3
        }
    }

    public var isAsymmetric: Bool {
        self == .oneOverTwo || self == .twoOverOne
    }
}

// MARK: - Boox Reading Flow Order

/// Traversal order matching Onyx Boox NeoReader Direction / Order icons
public enum BooxFlowOrder: String, CaseIterable, Codable, Sendable {
    /// Row-First Left-to-Right (Z-Shape)
    case zFlow = "zFlow"
    /// Row-First Right-to-Left (Reverse Z-Shape / Manga Rows)
    case reverseZFlow = "reverseZFlow"
    /// Column-First Left-to-Right (N-Shape / Academic Paper standard)
    case nFlow = "nFlow"
    /// Column-First Right-to-Left (Reverse N-Shape / Traditional Manga standard)
    case reverseNFlow = "reverseNFlow"

    public var displayName: String {
        switch self {
        case .zFlow: return "Row-First (Z)"
        case .reverseZFlow: return "Row-First RTL (⇄ Z)"
        case .nFlow: return "Column-First (N)"
        case .reverseNFlow: return "Manga RTL (⇄ N)"
        }
    }

    public var glyphSymbol: String {
        switch self {
        case .zFlow: return "arrow.right.to.line.compact"
        case .reverseZFlow: return "arrow.left.to.line.compact"
        case .nFlow: return "arrow.down.to.line.compact"
        case .reverseNFlow: return "arrow.turn.down.left"
        }
    }
}

// MARK: - Boox Section Block

/// Represents a single navigable block on a page in normalized (0.0 ... 1.0) coordinates.
public struct BooxSectionBlock: Identifiable, Sendable, Equatable {
    public let id: Int
    public let stepOrder: Int
    public let columnIndex: Int
    public let rowIndex: Int
    public let totalBlocks: Int
    /// Base normalized bounds relative to page cropBox (0,0 is bottom-left in PDF, top-left in UIKit image space)
    public let normalizedRect: CGRect
    /// Normalized bounds including Connection Redundancy overlap buffer
    public let redundantRect: CGRect
    public let label: String

    public init(
        id: Int,
        stepOrder: Int,
        columnIndex: Int,
        rowIndex: Int,
        totalBlocks: Int,
        normalizedRect: CGRect,
        redundantRect: CGRect,
        label: String
    ) {
        self.id = id
        self.stepOrder = stepOrder
        self.columnIndex = columnIndex
        self.rowIndex = rowIndex
        self.totalBlocks = totalBlocks
        self.normalizedRect = normalizedRect
        self.redundantRect = redundantRect
        self.label = label
    }
}

// MARK: - Boox Section Flow Configuration

/// Complete configuration for Boox NeoReader page segmentation and navigation.
public struct BooxSectionFlowConfig: Codable, Equatable, Sendable {
    public var gridPreset: BooxGridPreset
    public var flowOrder: BooxFlowOrder
    public var isSpreadMode: Bool

    /// Vertical split ratio for 2-column layouts (0.15 ... 0.85, default 0.50)
    public var verticalSplitRatio: CGFloat

    /// Horizontal split ratios for row divisions (0.10 ... 0.90)
    /// Single row split for 2-row presets (e.g. [0.50]), two splits for 3-row presets (e.g. [0.33, 0.66])
    public var horizontalSplitRatios: [CGFloat]

    /// Outer page limits margin crop trims (0.0 ... 0.25)
    public var topMarginTrim: CGFloat
    public var bottomMarginTrim: CGFloat
    public var leftMarginTrim: CGFloat
    public var rightMarginTrim: CGFloat

    /// Auto crop page margin after pagination toggle
    public var autoCropAfterPagination: Bool

    /// Connection Redundancy for text splitting avoidance toggle
    public var connectionRedundancy: Bool

    /// Redundancy overlap buffer fraction (0.05 ... 0.30, default 0.15)
    public var redundancyRatio: CGFloat

    public init(
        gridPreset: BooxGridPreset = .twoByTwo,
        flowOrder: BooxFlowOrder = .nFlow,
        isSpreadMode: Bool = false,
        verticalSplitRatio: CGFloat = 0.50,
        horizontalSplitRatios: [CGFloat] = [0.50],
        topMarginTrim: CGFloat = 0.0,
        bottomMarginTrim: CGFloat = 0.0,
        leftMarginTrim: CGFloat = 0.0,
        rightMarginTrim: CGFloat = 0.0,
        autoCropAfterPagination: Bool = false,
        connectionRedundancy: Bool = true,
        redundancyRatio: CGFloat = 0.15
    ) {
        self.gridPreset = gridPreset
        self.flowOrder = flowOrder
        self.isSpreadMode = isSpreadMode
        self.verticalSplitRatio = verticalSplitRatio
        self.horizontalSplitRatios = horizontalSplitRatios
        self.topMarginTrim = topMarginTrim
        self.bottomMarginTrim = bottomMarginTrim
        self.leftMarginTrim = leftMarginTrim
        self.rightMarginTrim = rightMarginTrim
        self.autoCropAfterPagination = autoCropAfterPagination
        self.connectionRedundancy = connectionRedundancy
        self.redundancyRatio = redundancyRatio
    }

    public static let standardTwoByTwo = BooxSectionFlowConfig(gridPreset: .twoByTwo, flowOrder: .nFlow)
    public static let standardTwoByThree = BooxSectionFlowConfig(gridPreset: .twoByThree, flowOrder: .nFlow, horizontalSplitRatios: [0.33, 0.66])
    public static let standardManga = BooxSectionFlowConfig(gridPreset: .twoByTwo, flowOrder: .reverseNFlow)
}
