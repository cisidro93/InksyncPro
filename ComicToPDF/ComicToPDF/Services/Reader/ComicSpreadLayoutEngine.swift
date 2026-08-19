import Foundation
import CoreGraphics

// MARK: - Comic Page & Spread Models

/// Represents a single comic/manga page image with dimensions and intrinsic aspect ratio.
public struct ComicPageItem: Sendable, Identifiable, Equatable {
    public let id: Int              // Original 0-indexed page index in archive
    public let imageURL: URL
    public let aspectRatio: CGFloat // width / height
    
    public var isIntrinsicSpread: Bool {
        aspectRatio > 1.15 // Wide image spanning two physical pages
    }
    
    public init(id: Int, imageURL: URL, aspectRatio: CGFloat = 0.70) {
        self.id = id
        self.imageURL = imageURL
        self.aspectRatio = aspectRatio
    }
}

/// Represents the visual layout type of a spread.
public enum SpreadLayoutType: Sendable, Equatable {
    case singleCover(page: ComicPageItem)
    case intrinsicSpread(page: ComicPageItem)
    case dualPage(left: ComicPageItem, right: ComicPageItem)
    case singlePage(page: ComicPageItem)
}

/// Represents a calculated spread displayed in dual-page or single-page mode.
public struct ComicSpread: Sendable, Identifiable, Equatable {
    public let id: Int              // Spread index in sequence
    public let layoutType: SpreadLayoutType
    
    public var pageIndices: [Int] {
        switch layoutType {
        case .singleCover(let p), .intrinsicSpread(let p), .singlePage(let p):
            return [p.id]
        case .dualPage(let l, let r):
            return [l.id, r.id]
        }
    }
    
    public init(id: Int, layoutType: SpreadLayoutType) {
        self.id = id
        self.layoutType = layoutType
    }
}

// MARK: - Comic Spread Layout Engine

/// Calculates dual-page landscape reading spreads with first-page cover offset,
/// Manga RTL vs Western LTR page pairing, and intrinsic double-page spread detection.
public struct ComicSpreadLayoutEngine: Sendable {
    
    public static let shared = ComicSpreadLayoutEngine()
    
    public init() {}
    
    // MARK: - Layout Calculation
    
    /// Computes sequential spreads from a list of comic pages.
    public func computeSpreads(
        pages: [ComicPageItem],
        isCoverOffsetEnabled: Bool = true,
        isRTL: Bool = false
    ) -> [ComicSpread] {
        guard !pages.isEmpty else { return [] }
        
        var spreads: [ComicSpread] = []
        var spreadIndex = 0
        var pageIndex = 0
        
        // 1. First Page Cover Offset
        if isCoverOffsetEnabled && pageIndex < pages.count {
            let coverPage = pages[pageIndex]
            spreads.append(ComicSpread(id: spreadIndex, layoutType: .singleCover(page: coverPage)))
            spreadIndex += 1
            pageIndex += 1
        }
        
        // 2. Iterate remaining pages
        while pageIndex < pages.count {
            let currentPage = pages[pageIndex]
            
            // Check if current page is an intrinsic double-page spread
            if currentPage.isIntrinsicSpread {
                spreads.append(ComicSpread(id: spreadIndex, layoutType: .intrinsicSpread(page: currentPage)))
                spreadIndex += 1
                pageIndex += 1
                continue
            }
            
            // Check if a second page exists to form a dual-page spread
            if pageIndex + 1 < pages.count {
                let nextPage = pages[pageIndex + 1]
                
                // If next page is an intrinsic spread, don't pair with it
                if nextPage.isIntrinsicSpread {
                    spreads.append(ComicSpread(id: spreadIndex, layoutType: .singlePage(page: currentPage)))
                    spreadIndex += 1
                    pageIndex += 1
                    continue
                }
                
                // Pair two normal portrait pages according to reading direction
                let leftPage: ComicPageItem
                let rightPage: ComicPageItem
                
                if isRTL {
                    // Manga Mode (Right-to-Left): Earlier page on the right, subsequent on the left
                    leftPage = nextPage
                    rightPage = currentPage
                } else {
                    // Western Mode (Left-to-Right): Earlier page on the left, subsequent on the right
                    leftPage = currentPage
                    rightPage = nextPage
                }
                
                spreads.append(ComicSpread(id: spreadIndex, layoutType: .dualPage(left: leftPage, right: rightPage)))
                spreadIndex += 1
                pageIndex += 2
            } else {
                // Trailing single page
                spreads.append(ComicSpread(id: spreadIndex, layoutType: .singlePage(page: currentPage)))
                spreadIndex += 1
                pageIndex += 1
            }
        }
        
        return spreads
    }
    
    /// Finds the corresponding spread index containing the given original archive page index.
    public func spreadIndex(for originalPageIndex: Int, in spreads: [ComicSpread]) -> Int {
        for (idx, spread) in spreads.enumerated() {
            if spread.pageIndices.contains(originalPageIndex) {
                return idx
            }
        }
        return 0
    }
}
