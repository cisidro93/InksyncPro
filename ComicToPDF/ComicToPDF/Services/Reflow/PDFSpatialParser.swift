import Foundation
import PDFKit
import UIKit

public struct SpatialTextBlock: Identifiable, Sendable {
    public let id: UUID
    public let pageIndex: Int
    public let rect: CGRect
    public let text: String
    public let kind: BlockKind
    public let fontName: String?
    public let fontSize: CGFloat
    public let isBold: Bool
    public let isItalic: Bool

    public enum BlockKind: String, Sendable {
        case title
        case heading1
        case heading2
        case heading3
        case paragraph
        case blockquote
        case code
        case listItem
        case figureCaption
    }

    public init(
        id: UUID = UUID(),
        pageIndex: Int,
        rect: CGRect,
        text: String,
        kind: BlockKind,
        fontName: String?,
        fontSize: CGFloat,
        isBold: Bool,
        isItalic: Bool
    ) {
        self.id = id
        self.pageIndex = pageIndex
        self.rect = rect
        self.text = text
        self.kind = kind
        self.fontName = fontName
        self.fontSize = fontSize
        self.isBold = isBold
        self.isItalic = isItalic
    }
}

public actor PDFSpatialParser {
    public static let shared = PDFSpatialParser()
    private init() {}

    /// Parses a PDFDocument page-by-page into spatial text blocks ordered by column reading flow.
    public func parseDocument(_ document: PDFDocument) async -> [SpatialTextBlock] {
        var blocks: [SpatialTextBlock] = []
        let pageCount = document.pageCount

        let medianFontSize = await calculateMedianFontSize(document: document)

        for i in 0..<pageCount {
            guard let page = document.page(at: i) else { continue }
            let pageBlocks = parsePage(page, pageIndex: i, medianFontSize: medianFontSize)
            blocks.append(contentsOf: pageBlocks)
        }

        return blocks
    }

    private func calculateMedianFontSize(document: PDFDocument) async -> CGFloat {
        var fontSizes: [CGFloat] = []
        let samplePages = min(document.pageCount, 10)

        for i in 0..<samplePages {
            guard let page = document.page(at: i) else { continue }
            let string = page.string ?? ""
            guard !string.isEmpty else { continue }
            let bounds = page.bounds(for: .mediaBox)

            if let selections = page.selection(for: bounds)?.selectionsByLine() {
                for sel in selections {
                    if let attrStr = sel.attributedString, attrStr.length > 0,
                       let font = attrStr.attribute(.font, at: 0, effectiveRange: nil) as? UIFont {
                        fontSizes.append(font.pointSize)
                    }
                }
            }
        }

        guard !fontSizes.isEmpty else { return 14.0 }
        let sorted = fontSizes.sorted()
        return sorted[sorted.count / 2]
    }

    private func parsePage(_ page: PDFPage, pageIndex: Int, medianFontSize: CGFloat) -> [SpatialTextBlock] {
        let pageBounds = page.bounds(for: .mediaBox)
        let headerThreshold = pageBounds.height * 0.93 // Ignore top 7%
        let footerThreshold = pageBounds.height * 0.05 // Ignore bottom 5%

        guard let pageSelection = page.selection(for: pageBounds) else { return [] }
        let lineSelections = pageSelection.selectionsByLine()

        struct LineInfo: LineInfoProtocol {
            let rect: CGRect
            let text: String
            let fontSize: CGFloat
            let fontName: String
            let isBold: Bool
            let isItalic: Bool
        }

        var lines: [LineInfo] = []

        for lineSel in lineSelections {
            let lineBounds = lineSel.bounds(for: page)
            let text = lineSel.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { continue }

            // Filter header running titles & footer page numbers
            if lineBounds.maxY > headerThreshold || lineBounds.minY < footerThreshold {
                if text.count < 6 || CharacterSet.decimalDigits.isSuperset(of: CharacterSet(charactersIn: text)) {
                    continue
                }
            }

            var fontSize: CGFloat = medianFontSize
            var fontName: String = "Helvetica"
            var isBold = false
            var isItalic = false

            if let attrStr = lineSel.attributedString, attrStr.length > 0,
               let font = attrStr.attribute(.font, at: 0, effectiveRange: nil) as? UIFont {
                fontSize = font.pointSize
                fontName = font.fontName
                let traits = font.fontDescriptor.symbolicTraits
                isBold = traits.contains(.traitBold) || fontName.localizedCaseInsensitiveContains("bold")
                isItalic = traits.contains(.traitItalic) || fontName.localizedCaseInsensitiveContains("italic")
            }

            lines.append(LineInfo(rect: lineBounds, text: text, fontSize: fontSize, fontName: fontName, isBold: isBold, isItalic: isItalic))
        }

        // XY-Cut Column Segmentation: Cluster lines into columns
        let sortedColumns = clusterLinesIntoColumns(lines: lines, pageWidth: pageBounds.width)

        var blocks: [SpatialTextBlock] = []

        for columnLines in sortedColumns {
            var currentText = ""
            var currentRect: CGRect = .null
            var maxFontSize: CGFloat = medianFontSize
            var blockIsBold = false
            var blockIsItalic = false
            var lastLineMaxY: CGFloat = -1

            for line in columnLines {
                let isNewParagraph: Bool
                if lastLineMaxY < 0 {
                    isNewParagraph = false
                } else {
                    let verticalGap = abs(lastLineMaxY - line.rect.maxY)
                    isNewParagraph = verticalGap > (line.fontSize * 1.6)
                }

                if isNewParagraph && !currentText.isEmpty {
                    let kind = classifyBlockKind(fontSize: maxFontSize, medianSize: medianFontSize, text: currentText, isBold: blockIsBold)
                    blocks.append(SpatialTextBlock(
                        pageIndex: pageIndex,
                        rect: currentRect,
                        text: currentText,
                        kind: kind,
                        fontName: "system",
                        fontSize: maxFontSize,
                        isBold: blockIsBold,
                        isItalic: blockIsItalic
                    ))
                    currentText = line.text
                    currentRect = line.rect
                    maxFontSize = line.fontSize
                    blockIsBold = line.isBold
                    blockIsItalic = line.isItalic
                } else {
                    if currentText.isEmpty {
                        currentText = line.text
                        currentRect = line.rect
                    } else {
                        if currentText.hasSuffix("-") {
                            currentText = String(currentText.dropLast()) + line.text
                        } else {
                            currentText += " " + line.text
                        }
                        currentRect = currentRect.union(line.rect)
                    }
                    maxFontSize = max(maxFontSize, line.fontSize)
                    blockIsBold = blockIsBold || line.isBold
                    blockIsItalic = blockIsItalic || line.isItalic
                }
                lastLineMaxY = line.rect.minY
            }

            if !currentText.isEmpty {
                let kind = classifyBlockKind(fontSize: maxFontSize, medianSize: medianFontSize, text: currentText, isBold: blockIsBold)
                blocks.append(SpatialTextBlock(
                    pageIndex: pageIndex,
                    rect: currentRect,
                    text: currentText,
                    kind: kind,
                    fontName: "system",
                    fontSize: maxFontSize,
                    isBold: blockIsBold,
                    isItalic: blockIsItalic
                ))
            }
        }

        return blocks
    }

    private func clusterLinesIntoColumns<T: LineInfoProtocol>(lines: [T], pageWidth: CGFloat) -> [[T]] {
        guard !lines.isEmpty else { return [] }

        let midX = pageWidth / 2.0
        let leftLines = lines.filter { $0.rect.midX < midX }.sorted(by: { $0.rect.maxY > $1.rect.maxY })
        let rightLines = lines.filter { $0.rect.midX >= midX }.sorted(by: { $0.rect.maxY > $1.rect.maxY })

        let total = lines.count
        if leftLines.count > Int(Double(total) * 0.25) && rightLines.count > Int(Double(total) * 0.25) {
            return [leftLines, rightLines]
        } else {
            let sorted = lines.sorted(by: { $0.rect.maxY > $1.rect.maxY })
            return [sorted]
        }
    }

    private func classifyBlockKind(fontSize: CGFloat, medianSize: CGFloat, text: String, isBold: Bool) -> SpatialTextBlock.BlockKind {
        let ratio = fontSize / max(1.0, medianSize)
        if ratio >= 1.8 {
            return .title
        } else if ratio >= 1.4 {
            return .heading1
        } else if ratio >= 1.2 || (isBold && ratio >= 1.1) {
            return .heading2
        } else if isBold && text.count < 80 {
            return .heading3
        } else if text.hasPrefix("•") || text.hasPrefix("-") || text.hasPrefix("1.") {
            return .listItem
        } else if text.hasPrefix("Figure ") || text.hasPrefix("Fig. ") || text.hasPrefix("Table ") {
            return .figureCaption
        } else {
            return .paragraph
        }
    }
}

private protocol LineInfoProtocol {
    var rect: CGRect { get }
}
