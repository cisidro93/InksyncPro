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

public final class PDFSpatialParser: Sendable {
    public static let shared = PDFSpatialParser()
    private init() {}

    /// Parses a PDFDocument page-by-page into spatial text blocks ordered by column reading flow.
    public func parseDocument(_ document: PDFDocument) async -> [SpatialTextBlock] {
        var blocks: [SpatialTextBlock] = []
        let pageCount = document.pageCount
        guard pageCount > 0 else { return [] }

        let medianFontSize = calculateMedianFontSize(document: document)

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
                        var parsed = parsePage(page, pageIndex: i, medianFontSize: medianFontSize)
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
                pageBlocks = await parsePageWithVisionOCR(page, pageIndex: i, medianFontSize: medianFontSize)
            }

            blocks.append(contentsOf: pageBlocks)

            if i % 5 == 0 {
                await Task.yield()
            }
        }

        return blocks
    }

    private func parsePageWithVisionOCR(_ page: PDFPage, pageIndex: Int, medianFontSize: CGFloat) async -> [SpatialTextBlock] {
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
