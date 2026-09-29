import Foundation
import PDFKit
import UIKit
import Vision

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
        case table
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

@MainActor
public final class PDFSpatialParser {
    public static let shared = PDFSpatialParser()
    private init() {}

    /// Parses a PDFDocument page-by-page into spatial text blocks ordered by column reading flow.
    public func parseDocument(_ document: PDFDocument) async -> [SpatialTextBlock] {
        var blocks: [SpatialTextBlock] = []
        let pageCount = document.pageCount
        guard pageCount > 0 else { return [] }

        let medianFontSize = calculateMedianFontSize(document: document)
        let skipClutter = EBookPreferences.shared.pdfReflowSmartClutterRemoval

        // Pre-scan first 10 pages to determine if document has digital text
        var hasDigitalText = false
        for i in 0..<min(pageCount, 10) {
            if let page = document.page(at: i),
               let str = page.string,
               !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                hasDigitalText = true
                break
            }
        }

        for i in 0..<pageCount {
            if Task.isCancelled { break }
            guard let page = document.page(at: i) else { continue }

            let pageString = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            var pageBlocks: [SpatialTextBlock] = autoreleasepool {
                if hasDigitalText {
                    if !pageString.isEmpty {
                        var parsed = parsePage(page, pageIndex: i, medianFontSize: medianFontSize, skipClutter: skipClutter)
                        // If all lines were filtered as headers/footers but text actually exists, create fallback block
                        if parsed.isEmpty {
                            let pageBounds = page.bounds(for: .mediaBox)
                            parsed.append(SpatialTextBlock(
                                pageIndex: i,
                                rect: pageBounds,
                                text: pageString,
                                kind: .paragraph,
                                fontName: "System",
                                fontSize: medianFontSize,
                                isBold: false,
                                isItalic: false
                            ))
                        }
                        return parsed
                    } else {
                        // Digital document page with no text is an illustration or blank page: skip OCR
                        return []
                    }
                } else {
                    // Document is scanned; OCR will be performed asynchronously below if needed
                    return []
                }
            }

            // For fully scanned documents (no digital text anywhere), run throttled fast Vision OCR
            if !hasDigitalText && pageBlocks.isEmpty {
                pageBlocks = await parsePageWithVisionOCR(page, pageIndex: i, medianFontSize: medianFontSize, skipClutter: skipClutter)
            }

            blocks.append(contentsOf: pageBlocks)

            if i % 3 == 0 {
                await Task.yield()
            }
        }

        return blocks
    }

    private func parsePageWithVisionOCR(_ page: PDFPage, pageIndex: Int, medianFontSize: CGFloat, skipClutter: Bool = true) async -> [SpatialTextBlock] {
        let pageBounds = page.bounds(for: .mediaBox)
        guard pageBounds.width > 0 && pageBounds.height > 0 else { return [] }

        // Downscale to max dimension 1024pt to avoid runaway Neural Engine / GPU allocations
        let maxDimension: CGFloat = 1024.0
        let aspect = pageBounds.width / pageBounds.height
        let targetSize: CGSize
        if pageBounds.width > pageBounds.height {
            let width = min(pageBounds.width, maxDimension)
            targetSize = CGSize(width: width, height: width / aspect)
        } else {
            let height = min(pageBounds.height, maxDimension)
            targetSize = CGSize(width: height * aspect, height: height)
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true

        let pageImage = autoreleasepool { () -> UIImage in
            let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
            return renderer.image { ctx in
                UIColor.white.set()
                ctx.fill(CGRect(origin: .zero, size: targetSize))
                let cgCtx = ctx.cgContext
                cgCtx.translateBy(x: 0.0, y: targetSize.height)
                cgCtx.scaleBy(x: targetSize.width / pageBounds.width, y: -targetSize.height / pageBounds.height)
                page.draw(with: .mediaBox, to: cgCtx)
            }
        }

        guard let cgImage = pageImage.cgImage else { return [] }

        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                guard error == nil, let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: [])
                    return
                }

                var ocrBlocks: [SpatialTextBlock] = []
                for obs in observations {
                    guard let candidate = obs.topCandidates(1).first, !candidate.string.isEmpty else { continue }

                    let boundingBox = obs.boundingBox
                    let rect = CGRect(
                        x: boundingBox.origin.x * pageBounds.width,
                        y: (1.0 - boundingBox.origin.y - boundingBox.height) * pageBounds.height,
                        width: boundingBox.width * pageBounds.width,
                        height: boundingBox.height * pageBounds.height
                    )

                    let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }

                    if skipClutter && SmartSpeechTextSanitizer.shared.isPageNumberOrClutter(
                        text: text,
                        boundsInPage: rect,
                        pageSize: pageBounds.size
                    ) {
                        continue
                    }

                    let isTitle = rect.height > medianFontSize * 1.5 || (text.count < 60 && text.allSatisfy { $0.isUppercase || $0.isWhitespace || $0.isPunctuation })
                    let kind: SpatialTextBlock.BlockKind = isTitle ? .heading2 : .paragraph

                    ocrBlocks.append(SpatialTextBlock(
                        pageIndex: pageIndex,
                        rect: rect,
                        text: text,
                        kind: kind,
                        fontName: "System",
                        fontSize: rect.height,
                        isBold: isTitle,
                        isItalic: false
                    ))
                }
                continuation.resume(returning: ocrBlocks)
            }

            request.recognitionLevel = .fast
            request.usesLanguageCorrection = false

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: [])
            }
        }
    }

    private func calculateMedianFontSize(document: PDFDocument) -> CGFloat {
        var fontSizes: [CGFloat] = []
        let samplePages = min(document.pageCount, 6)

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
                        if fontSizes.count >= 40 {
                            break
                        }
                    }
                }
            }
            if fontSizes.count >= 40 {
                break
            }
        }

        guard !fontSizes.isEmpty else { return 14.0 }
        let sorted = fontSizes.sorted()
        return sorted[sorted.count / 2]
    }

    private func parsePage(_ page: PDFPage, pageIndex: Int, medianFontSize: CGFloat, skipClutter: Bool = true) -> [SpatialTextBlock] {
        let pageBounds = page.bounds(for: .mediaBox)
        guard let pageSelection = page.selection(for: pageBounds) else { return [] }
        let lineSelections = pageSelection.selectionsByLine()

        struct LineInfo: LineInfoProtocol {
            let rect: CGRect
            let text: String
            let fontSize: CGFloat
            let fontName: String
            let isBold: Bool
            let isItalic: Bool

            var isMonospace: Bool {
                let name = fontName.lowercased()
                return name.contains("courier") || name.contains("menlo") || name.contains("monaco") ||
                       name.contains("consolas") || name.contains("sourcecodepro") || name.contains("mono")
            }
        }

        var lines: [LineInfo] = []

        for lineSel in lineSelections {
            let lineBounds = lineSel.bounds(for: page)
            let text = lineSel.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { continue }

            // Intelligent clutter filter: strip running headers, footers, standalone page numbers, and separator artifacts
            if skipClutter && SmartSpeechTextSanitizer.shared.isPageNumberOrClutter(
                text: text,
                boundsInPage: lineBounds,
                pageSize: pageBounds.size
            ) {
                continue
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

        // Multi-Band XY-Cut Segmentation: Spanned headers first, followed by multi-column clusters
        let sortedBandsAndColumns = clusterLinesIntoBandsAndColumns(lines: lines, pageWidth: pageBounds.width)

        var blocks: [SpatialTextBlock] = []

        for columnLines in sortedBandsAndColumns {
            guard !columnLines.isEmpty else { continue }
            let columnMinX = columnLines.map { $0.rect.minX }.min() ?? 0
            let stitchedBlocks = stitchLinesIntoBlocks(
                lines: columnLines,
                pageIndex: pageIndex,
                medianFontSize: medianFontSize,
                columnMinX: columnMinX
            )
            blocks.append(contentsOf: stitchedBlocks)
        }

        return blocks
    }

    private nonisolated static let listMarkerRegex = try? NSRegularExpression(
        pattern: #"^\s*(?:\(?\d{1,3}[\.\)]|\(?[a-zA-Z][\.\)]|\(?[ivxlcdmIVXLCDM]{1,6}[\.\)])\s+"#,
        options: []
    )

    /// Identifies whether a text string begins with a recognized list marker (bullet or numbered/lettered item).
    public nonisolated static func isListMarker(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }

        let bulletChars: Set<Character> = ["•", "▪", "▫", "◦", "⁃", "‣", "–", "—"]
        if let first = trimmed.first, bulletChars.contains(first) {
            return true
        }

        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            return true
        }

        if let regex = listMarkerRegex {
            let range = NSRange(location: 0, length: min(trimmed.utf16.count, 12))
            return regex.firstMatch(in: trimmed, options: [], range: range) != nil
        }

        return false
    }

    /// Identifies whether a list marker is numeric or alphabetic (ordered list).
    public nonisolated static func isOrderedListMarker(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let regex = listMarkerRegex else { return false }
        let range = NSRange(location: 0, length: min(trimmed.utf16.count, 12))
        return regex.firstMatch(in: trimmed, options: [], range: range) != nil
    }

    /// Segments lines into bands: Spanned full-width blocks (Title, Abstract, wide Figures/Tables)
    /// and Multi-Column clusters (Column 1, Column 2, Column 3), preserving true reading flow.
    private func clusterLinesIntoBandsAndColumns<T: LineInfoProtocol>(lines: [T], pageWidth: CGFloat) -> [[T]] {
        guard !lines.isEmpty else { return [] }

        // Sort all lines primarily by maxY descending (top of page to bottom of page in PDF coordinates)
        let sorted = lines.sorted { $0.rect.maxY > $1.rect.maxY }

        let leftThreshold = pageWidth * 0.46
        let rightThreshold = pageWidth * 0.54

        let leftColCount = lines.filter { $0.rect.maxX < rightThreshold && $0.rect.width < (pageWidth * 0.52) }.count
        let rightColCount = lines.filter { $0.rect.minX > leftThreshold && $0.rect.width < (pageWidth * 0.52) }.count

        let isMultiColumnDocument = leftColCount >= max(3, Int(Double(lines.count) * 0.18)) &&
                                    rightColCount >= max(3, Int(Double(lines.count) * 0.18))

        // If single-column document, preserve strict top-to-bottom reading order with zero fragmentation
        guard isMultiColumnDocument else {
            return [sorted]
        }

        // Helper: Determine if a line spans horizontally across columns
        func isLineSpanned(_ line: T) -> Bool {
            let widthRatio = line.rect.width / max(1.0, pageWidth)
            let isWide = widthRatio > 0.55
            let isCenteredWide = abs(line.rect.midX - (pageWidth / 2.0)) < (pageWidth * 0.14) && widthRatio > 0.38
            return isWide || isCenteredWide
        }

        // Multi-Band XY-Cut: Segment sorted lines into alternating Spanned and Columnar bands
        var bands: [(isSpanned: Bool, lines: [T])] = []
        var currentIsSpanned: Bool? = nil
        var currentBandLines: [T] = []

        for line in sorted {
            let lineSpanned = isLineSpanned(line)
            if let current = currentIsSpanned {
                if current == lineSpanned {
                    currentBandLines.append(line)
                } else {
                    bands.append((isSpanned: current, lines: currentBandLines))
                    currentIsSpanned = lineSpanned
                    currentBandLines = [line]
                }
            } else {
                currentIsSpanned = lineSpanned
                currentBandLines = [line]
            }
        }

        if let current = currentIsSpanned, !currentBandLines.isEmpty {
            bands.append((isSpanned: current, lines: currentBandLines))
        }

        var result: [[T]] = []

        for band in bands {
            if band.isSpanned {
                result.append(band.lines)
            } else {
                let bandLines = band.lines
                let total = bandLines.count

                let midX = pageWidth / 2.0
                let leftLines = bandLines.filter { $0.rect.midX < midX }.sorted { $0.rect.maxY > $1.rect.maxY }
                let rightLines = bandLines.filter { $0.rect.midX >= midX }.sorted { $0.rect.maxY > $1.rect.maxY }

                let minPerCol = max(2, Int(Double(total) * 0.18))
                if leftLines.count >= minPerCol && rightLines.count >= minPerCol {
                    // 3-Column sub-detection
                    let col1Boundary = pageWidth * 0.38
                    let col2Boundary = pageWidth * 0.65
                    let col1 = bandLines.filter { $0.rect.midX < col1Boundary }.sorted { $0.rect.maxY > $1.rect.maxY }
                    let col2 = bandLines.filter { $0.rect.midX >= col1Boundary && $0.rect.midX < col2Boundary }.sorted { $0.rect.maxY > $1.rect.maxY }
                    let col3 = bandLines.filter { $0.rect.midX >= col2Boundary }.sorted { $0.rect.maxY > $1.rect.maxY }

                    let min3Col = max(2, Int(Double(total) * 0.15))
                    if col1.count >= min3Col && col2.count >= min3Col && col3.count >= min3Col {
                        result.append(col1)
                        result.append(col2)
                        result.append(col3)
                    } else {
                        result.append(leftLines)
                        result.append(rightLines)
                    }
                } else {
                    result.append(bandLines)
                }
            }
        }

        return result
    }

    /// Stitches sequential lines in a column into cohesive paragraphs, code blocks, lists, and headings.
    /// Incorporates K2pdfopt's proven rules for hyphen de-duplication, indentation, and punctuation-aware paragraph continuation.
    private func stitchLinesIntoBlocks(
        lines: [some LineInfoProtocol],
        pageIndex: Int,
        medianFontSize: CGFloat,
        columnMinX: CGFloat
    ) -> [SpatialTextBlock] {
        var blocks: [SpatialTextBlock] = []
        guard !lines.isEmpty else { return [] }

        var currentText = ""
        var currentRect: CGRect = .null
        var maxFontSize: CGFloat = medianFontSize
        var blockIsBold = false
        var blockIsItalic = false
        var blockIsMonospace = false
        var lastLine: (any LineInfoProtocol)? = nil

        let terminalPunctuation: Set<Character> = [".", "!", "?", "…", "”", "’", "\""]

        for line in lines {
            let isNewParagraph: Bool

            if let prev = lastLine {
                let verticalGap = abs(prev.rect.minY - line.rect.maxY)
                let trimmedPrev = prev.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let lastChar = trimmedPrev.last ?? " "
                let prevEndsWithPunctuation = terminalPunctuation.contains(lastChar) ||
                                              trimmedPrev.hasSuffix(".\"") ||
                                              trimmedPrev.hasSuffix("?\"") ||
                                              trimmedPrev.hasSuffix("!\"")

                let hasIndent = (line.rect.minX - columnMinX) >= 12.0
                let isLargeGap = verticalGap > (line.fontSize * 1.55)
                let isBullet = Self.isListMarker(line.text)
                let isHeaderSize = line.fontSize >= medianFontSize * 1.25 || (line.isBold && line.text.count < 70)
                let isMonospaceChange = line.isMonospace != blockIsMonospace

                if isBullet || isHeaderSize || isMonospaceChange {
                    isNewParagraph = true
                } else if prevEndsWithPunctuation && (hasIndent || isLargeGap || line.text.first?.isUppercase == true) {
                    isNewParagraph = true
                } else if isLargeGap && verticalGap > (line.fontSize * 2.2) {
                    isNewParagraph = true
                } else {
                    isNewParagraph = false
                }
            } else {
                isNewParagraph = false
            }

            if isNewParagraph && !currentText.isEmpty {
                let kind = classifyBlockKind(
                    fontSize: maxFontSize,
                    medianSize: medianFontSize,
                    text: currentText,
                    isBold: blockIsBold,
                    isMonospace: blockIsMonospace,
                    isIndented: (currentRect.minX - columnMinX) >= 20.0
                )
                blocks.append(SpatialTextBlock(
                    pageIndex: pageIndex,
                    rect: currentRect,
                    text: currentText,
                    kind: kind,
                    fontName: blockIsMonospace ? "Menlo" : "system",
                    fontSize: maxFontSize,
                    isBold: blockIsBold,
                    isItalic: blockIsItalic
                ))

                currentText = line.text
                currentRect = line.rect
                maxFontSize = line.fontSize
                blockIsBold = line.isBold
                blockIsItalic = line.isItalic
                blockIsMonospace = line.isMonospace
            } else {
                if currentText.isEmpty {
                    currentText = line.text
                    currentRect = line.rect
                    maxFontSize = line.fontSize
                    blockIsBold = line.isBold
                    blockIsItalic = line.isItalic
                    blockIsMonospace = line.isMonospace
                } else {
                    // Hyphenation rejoining (K2pdfopt standard)
                    if currentText.hasSuffix("-") {
                        let withoutHyphen = String(currentText.dropLast())
                        if let firstChar = line.text.first, firstChar.isLowercase, let lastChar = withoutHyphen.last, lastChar.isLetter {
                            currentText = withoutHyphen + line.text
                        } else {
                            currentText = currentText + " " + line.text
                        }
                    } else {
                        currentText += " " + line.text
                    }
                    currentRect = currentRect.union(line.rect)
                    maxFontSize = max(maxFontSize, line.fontSize)
                    blockIsBold = blockIsBold || line.isBold
                    blockIsItalic = blockIsItalic || line.isItalic
                    blockIsMonospace = blockIsMonospace || line.isMonospace
                }
            }

            lastLine = line
        }

        if !currentText.isEmpty {
            let kind = classifyBlockKind(
                fontSize: maxFontSize,
                medianSize: medianFontSize,
                text: currentText,
                isBold: blockIsBold,
                isMonospace: blockIsMonospace,
                isIndented: (currentRect.minX - columnMinX) >= 20.0
            )
            blocks.append(SpatialTextBlock(
                pageIndex: pageIndex,
                rect: currentRect,
                text: currentText,
                kind: kind,
                fontName: blockIsMonospace ? "Menlo" : "system",
                fontSize: maxFontSize,
                isBold: blockIsBold,
                isItalic: blockIsItalic
            ))
        }

        return blocks
    }

    private func classifyBlockKind(
        fontSize: CGFloat,
        medianSize: CGFloat,
        text: String,
        isBold: Bool,
        isMonospace: Bool = false,
        isIndented: Bool = false
    ) -> SpatialTextBlock.BlockKind {
        if isMonospace {
            return .code
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let ratio = fontSize / max(1.0, medianSize)

        // Check for tables
        if trimmed.hasPrefix("Table ") || trimmed.hasPrefix("TABLE ") {
            let lines = trimmed.components(separatedBy: .newlines)
            if lines.count >= 2 {
                return .table
            } else {
                return .figureCaption
            }
        } else if trimmed.contains("\n") {
            let lines = trimmed.components(separatedBy: .newlines)
            let columnarLines = lines.filter { $0.contains("\t") || $0.contains("|") }
            if columnarLines.count >= 2 {
                return .table
            }
        }

        // Check for list items
        if Self.isListMarker(trimmed) {
            return .listItem
        }

        // Check for figure captions
        if trimmed.hasPrefix("Figure ") || trimmed.hasPrefix("Fig. ") || trimmed.hasPrefix("Plate ") {
            return .figureCaption
        }

        // Check for blockquotes (indented paragraphs)
        if isIndented && trimmed.count > 40 {
            return .blockquote
        }

        // Headings: Guard against normal bold sentences being classified as headings
        let endsWithTerminalPunctuation = trimmed.hasSuffix(".") || trimmed.hasSuffix("?") || trimmed.hasSuffix("!")
        let isLikelyBodySentence = endsWithTerminalPunctuation && trimmed.count > 40 && ratio < 1.30

        if !isLikelyBodySentence {
            if ratio >= 1.7 {
                return .title
            } else if ratio >= 1.35 {
                return .heading1
            } else if ratio >= 1.18 || (isBold && ratio >= 1.08 && trimmed.count < 90) {
                return .heading2
            } else if isBold && trimmed.count < 80 {
                return .heading3
            }
        }

        return .paragraph
    }
}

private protocol LineInfoProtocol: Sendable {
    var rect: CGRect { get }
    var text: String { get }
    var fontSize: CGFloat { get }
    var fontName: String { get }
    var isBold: Bool { get }
    var isItalic: Bool { get }
    var isMonospace: Bool { get }
}
