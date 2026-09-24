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
        var booxConfig = config.asBooxConfig()
        if isMangaRTL {
            booxConfig.flowOrder = .reverseNFlow
        }
        let blocks = BooxSectionFlowEngine.shared.generateBlocks(config: booxConfig, space: .pdf)
        return blocks.map { b in
            PDFTierQuadrant(
                id: b.id,
                columnIndex: b.columnIndex,
                tierIndex: b.rowIndex,
                totalColumns: booxConfig.gridPreset.columnCount,
                totalTiersInColumn: booxConfig.gridPreset.rowCount,
                stepOrder: b.stepOrder,
                totalInPage: b.totalBlocks,
                normalizedRect: booxConfig.connectionRedundancy ? b.redundantRect : b.normalizedRect,
                label: b.label
            )
        }
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
            let leftTrim = max(0.0, min(0.25, config.leftMarginTrim))
            let rightTrim = max(0.0, min(0.25, config.rightMarginTrim))
            let activeW = max(0.2, 1.0 - (leftTrim + rightTrim))
            return generateColumnQuadrants(
                columns: [CGRect(x: leftTrim, y: 0.0, width: activeW, height: 1.0)],
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

        let topTrim = max(0.0, min(0.25, config.topMarginTrim))
        let botTrim = max(0.0, min(0.25, config.bottomMarginTrim))
        let usableHeight = max(0.5, 1.0 - (topTrim + botTrim))
        let overlap = max(0.05, min(0.30, config.verticalOverlap))

        // Precompute tier rectangles for each column
        // Tier 0 is Top (highest Y in PDFKit coordinate space), Tier N-1 is Bottom (lowest Y)
        let rawTierHeight = usableHeight / CGFloat(tiersCount)
        let overlapHeight = rawTierHeight * overlap
        let effectiveTierHeight = min(1.0, rawTierHeight + overlapHeight)

        var columnTierRects: [[CGRect]] = []
        for colBox in columns {
            var colTiers: [CGRect] = []
            for tierIdx in 0..<tiersCount {
                let stepFraction = CGFloat(tierIdx) / CGFloat(max(1, tiersCount - 1))
                let maxY = (1.0 - topTrim)
                let minY = botTrim

                let tierMaxY = maxY - (stepFraction * max(0.0, (maxY - minY - effectiveTierHeight)))
                let tierMinY = max(minY, tierMaxY - effectiveTierHeight)

                let normRect = CGRect(
                    x: max(0.0, colBox.minX),
                    y: max(0.0, tierMinY),
                    width: min(1.0, colBox.width),
                    height: max(0.05, tierMaxY - tierMinY)
                )
                colTiers.append(normRect)
            }
            columnTierRects.append(colTiers)
        }

        func tierName(for idx: Int, count: Int) -> String {
            if count == 2 {
                return (idx == 0) ? "Top Half" : "Bottom Half"
            } else if count == 3 {
                return (idx == 0) ? "Top" : ((idx == 1) ? "Mid" : "Bottom")
            } else {
                return "Tier \(idx + 1)/\(count)"
            }
        }

        var globalStep = 0

        if config.flowOrder == .rowFirst && totalCols > 1 {
            // Row-First (Z-Flow): Traverse across columns row by row
            for tierIdx in 0..<tiersCount {
                for (colIndex, _) in columns.enumerated() {
                    let normRect = columnTierRects[colIndex][tierIdx]
                    let tName = tierName(for: tierIdx, count: tiersCount)
                    let colLabel = isMangaRTL ? (colIndex == 0 ? "Right Col" : "Left Col") : "Col \(colIndex + 1)"
                    let label = "\(colLabel) · \(tName) (\(globalStep + 1)/\(totalQuadrants))"

                    results.append(PDFTierQuadrant(
                        id: globalStep,
                        columnIndex: colIndex,
                        tierIndex: tierIdx,
                        totalColumns: totalCols,
                        totalTiersInColumn: tiersCount,
                        stepOrder: globalStep,
                        totalInPage: totalQuadrants,
                        normalizedRect: normRect,
                        label: label
                    ))
                    globalStep += 1
                }
            }
        } else {
            // Column-First (N-Flow or Manga RTL): Traverse down each column top-to-bottom
            for (colIndex, _) in columns.enumerated() {
                for tierIdx in 0..<tiersCount {
                    let normRect = columnTierRects[colIndex][tierIdx]
                    let tName = tierName(for: tierIdx, count: tiersCount)
                    let label: String
                    if totalCols > 1 {
                        let colLabel = isMangaRTL ? (colIndex == 0 ? "Right Col" : "Left Col") : "Col \(colIndex + 1)"
                        label = "\(colLabel) · \(tName) (\(globalStep + 1)/\(totalQuadrants))"
                    } else {
                        label = "Tier \(globalStep + 1) of \(totalQuadrants) (\(tName))"
                    }

                    results.append(PDFTierQuadrant(
                        id: globalStep,
                        columnIndex: colIndex,
                        tierIndex: tierIdx,
                        totalColumns: totalCols,
                        totalTiersInColumn: tiersCount,
                        stepOrder: globalStep,
                        totalInPage: totalQuadrants,
                        normalizedRect: normRect,
                        label: label
                    ))
                    globalStep += 1
                }
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
