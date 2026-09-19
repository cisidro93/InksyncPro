import Foundation
import CoreGraphics
import PDFKit

// MARK: - PDF Smart Tier Engine

/// Engine that segments PDF pages into guided quadrant tiers and column flows
/// (inspired by Comic Guided View and optimized for academic papers and multi-column books).
@MainActor
public final class PDFSmartTierEngine {

    public static let shared = PDFSmartTierEngine()

    private var quadrantCache: [String: [PDFTierQuadrant]] = [:]

    private init() {}

    public func purgeCache() {
        quadrantCache.removeAll()
    }

    /// Generates the ordered sequence of quadrants for reading a PDF page.
    public func generateQuadrants(
        for page: PDFPage,
        pageIndex: Int,
        config: PDFTierGuideConfiguration,
        isMangaRTL: Bool = false
    ) -> [PDFTierQuadrant] {
        let cropBox = page.bounds(for: .cropBox)
        let cacheKey = "\(pageIndex)_\(cropBox.width)_\(cropBox.height)_\(config.preset.rawValue)_\(config.columnCount)_\(config.tiersPerColumn)_\(config.columnSplitRatio)_\(config.verticalOverlap)_\(isMangaRTL)"

        if let cached = quadrantCache[cacheKey] {
            return cached
        }

        let quadrants: [PDFTierQuadrant]
        switch config.preset {
        case .autoColumns:
            quadrants = generateAutoColumnQuadrants(
                page: page,
                pageIndex: pageIndex,
                cropBox: cropBox,
                config: config,
                isMangaRTL: isMangaRTL
            )
        case .singleColumn:
            quadrants = generateColumnQuadrants(
                columns: [CGRect(x: 0, y: 0, width: 1.0, height: 1.0)],
                config: config,
                isMangaRTL: isMangaRTL
            )
        case .twoColumn:
            let split = max(0.2, min(0.8, config.columnSplitRatio))
            let gutter: CGFloat = 0.02
            let col0 = CGRect(x: 0.0, y: 0.0, width: max(0.1, split - gutter), height: 1.0)
            let col1 = CGRect(x: split + gutter, y: 0.0, width: max(0.1, 1.0 - (split + gutter)), height: 1.0)
            quadrants = generateColumnQuadrants(
                columns: isMangaRTL ? [col1, col0] : [col0, col1],
                config: config,
                isMangaRTL: isMangaRTL
            )
        case .threeColumn:
            let colWidth: CGFloat = 0.31
            let gutter: CGFloat = 0.035
            let col0 = CGRect(x: 0.0, y: 0.0, width: colWidth, height: 1.0)
            let col1 = CGRect(x: colWidth + gutter, y: 0.0, width: colWidth, height: 1.0)
            let col2 = CGRect(x: (colWidth + gutter) * 2, y: 0.0, width: colWidth, height: 1.0)
            let cols = isMangaRTL ? [col2, col1, col0] : [col0, col1, col2]
            quadrants = generateColumnQuadrants(
                columns: cols,
                config: config,
                isMangaRTL: isMangaRTL
            )
        }

        quadrantCache[cacheKey] = quadrants
        return quadrants
    }

    // MARK: - Column & Tier Subdivisions

    private func generateAutoColumnQuadrants(
        page: PDFPage,
        pageIndex: Int,
        cropBox: CGRect,
        config: PDFTierGuideConfiguration,
        isMangaRTL: Bool
    ) -> [PDFTierQuadrant] {
        let layout = PDFColumnDetector.shared.detectColumns(in: page, pageIndex: pageIndex)
        if layout.isMultiColumn {
            var colRects = layout.columns.map { $0.normalizedRect }
            if isMangaRTL {
                colRects.reverse()
            }
            return generateColumnQuadrants(columns: colRects, config: config, isMangaRTL: isMangaRTL)
        } else {
            // Fallback to 1 column
            return generateColumnQuadrants(
                columns: [CGRect(x: 0, y: 0, width: 1.0, height: 1.0)],
                config: config,
                isMangaRTL: isMangaRTL
            )
        }
    }

    private func generateColumnQuadrants(
        columns: [CGRect],
        config: PDFTierGuideConfiguration,
        isMangaRTL: Bool
    ) -> [PDFTierQuadrant] {
        var results: [PDFTierQuadrant] = []
        let totalCols = columns.count
        let tiersCount = max(2, min(5, config.tiersPerColumn))
        let totalQuadrants = totalCols * tiersCount

        let topTrim = max(0.0, min(0.15, config.topMarginTrim))
        let botTrim = max(0.0, min(0.15, config.bottomMarginTrim))
        let usableHeight = max(0.5, 1.0 - (topTrim + botTrim))
        let overlap = max(0.05, min(0.30, config.verticalOverlap))

        var globalStep = 0

        for (colIndex, colBox) in columns.enumerated() {
            // Tier 0 is Top (highest Y in PDFKit coordinate space), Tier N-1 is Bottom (lowest Y)
            let rawTierHeight = usableHeight / CGFloat(tiersCount)
            let overlapHeight = rawTierHeight * overlap
            let effectiveTierHeight = min(1.0, rawTierHeight + overlapHeight)

            for tierIdx in 0..<tiersCount {
                // In PDF coordinates: Y=0 is bottom, Y=1 is top.
                // We want to read top to bottom:
                // Step 0: Highest Y
                // Step N-1: Lowest Y
                let stepFraction = CGFloat(tierIdx) / CGFloat(max(1, tiersCount - 1))
                let maxY = (1.0 - topTrim)
                let minY = botTrim

                let tierMaxY = maxY - (stepFraction * max(0, (maxY - minY - effectiveTierHeight)))
                let tierMinY = max(minY, tierMaxY - effectiveTierHeight)

                let normRect = CGRect(
                    x: max(0.0, colBox.minX),
                    y: max(0.0, tierMinY),
                    width: min(1.0, colBox.width),
                    height: min(1.0, tierMaxY - tierMinY)
                )

                let tierName: String
                if tiersCount == 2 {
                    tierName = (tierIdx == 0) ? "Top Half" : "Bottom Half"
                } else if tiersCount == 3 {
                    tierName = (tierIdx == 0) ? "Top" : ((tierIdx == 1) ? "Mid" : "Bottom")
                } else {
                    tierName = "Tier \(tierIdx + 1)/\(tiersCount)"
                }

                let label: String
                if totalCols > 1 {
                    label = "Col \(colIndex + 1) · \(tierName) (\(globalStep + 1)/\(totalQuadrants))"
                } else {
                    label = "Tier \(globalStep + 1) of \(totalQuadrants) (\(tierName))"
                }

                let quad = PDFTierQuadrant(
                    id: globalStep,
                    columnIndex: colIndex,
                    tierIndex: tierIdx,
                    totalColumns: totalCols,
                    totalTiersInColumn: tiersCount,
                    stepOrder: globalStep,
                    totalInPage: totalQuadrants,
                    normalizedRect: normRect,
                    label: label
                )

                results.append(quad)
                globalStep += 1
            }
        }

        return results
    }

    /// Converts normalized quadrant coordinates to PDF Page coordinates (CGRect).
    public func pageRect(for quadrant: PDFTierQuadrant, on page: PDFPage) -> CGRect {
        let cropBox = page.bounds(for: .cropBox)
        let norm = quadrant.normalizedRect
        return CGRect(
            x: cropBox.minX + (norm.minX * cropBox.width),
            y: cropBox.minY + (norm.minY * cropBox.height),
            width: norm.width * cropBox.width,
            height: norm.height * cropBox.height
        )
    }
}
