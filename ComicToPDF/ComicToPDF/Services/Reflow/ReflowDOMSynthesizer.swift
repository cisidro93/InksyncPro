import Foundation
import PDFKit
import UIKit

public final class ReflowDOMSynthesizer: @unchecked Sendable {
    public static let shared = ReflowDOMSynthesizer()
    private init() {}

    private static let multiSpaceRegex = try? NSRegularExpression(pattern: #"\s{2,}"#, options: [])
    private static let orderedMarkerRegex = try? NSRegularExpression(
        pattern: #"^\s*(?:\(?\d{1,3}[\.\)]|\(?[a-zA-Z][\.\)]|\(?[ivxlcdmIVXLCDM]{1,6}[\.\)])\s+"#,
        options: []
    )
    private static let unorderedMarkerRegex = try? NSRegularExpression(
        pattern: #"^[\s*•▪▫–—\-]+\s*"#,
        options: []
    )
    private static let citationRegex = try? NSRegularExpression(
        pattern: #"(?<=[a-zA-Z0-9\.\,\)])\[(\d+(?:[–\-,\s]+\d+)*)\]"#,
        options: []
    )

    private func formatBlockText(_ text: String) -> String {
        let sanitized = PDFSpatialParser.sanitizeExtractedText(text)
        var escaped = escapeHTML(sanitized)
        if let regex = Self.citationRegex {
            let nsStr = escaped as NSString
            let range = NSRange(location: 0, length: nsStr.length)
            escaped = regex.stringByReplacingMatches(in: escaped, options: [], range: range, withTemplate: "<span class=\"pdf-citation\">[$1]</span>")
        }
        return escaped
    }

    /// Synthesizes spatial text blocks and extracted images into a cached HTML5 DOM file.
    public func synthesizeHTML(
        pdfUUID: String,
        documentTitle: String,
        blocks: [SpatialTextBlock],
        images: [ExtractedPDFImage],
        isClutterFiltered: Bool = true
    ) async -> URL? {
        let fileManager = FileManager.default
        guard let cacheDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let targetDir = cacheDir.appendingPathComponent("ReflowPDF/\(pdfUUID)", isDirectory: true)

        do {
            try fileManager.createDirectory(at: targetDir, withIntermediateDirectories: true)
        } catch {
            return nil
        }

        let cacheFileName = "reflow_\(ReflowCompilationCoordinator.cacheVersion)_\(isClutterFiltered ? "clean" : "raw").html"
        let htmlFileURL = targetDir.appendingPathComponent(cacheFileName)

        var bodyHTML = ""
        bodyHTML.reserveCapacity(max(2048, blocks.count * 160))

        let blocksByPage = Dictionary(grouping: blocks, by: \.pageIndex)
        let imagesByPage = Dictionary(grouping: images, by: \.pageIndex)

        let maxPage = max(
            blocks.map { $0.pageIndex }.max() ?? -1,
            images.map { $0.pageIndex }.max() ?? -1
        )

        if maxPage >= 0 {
            var lastParagraphOfPrevPage: SpatialTextBlock? = nil
            var prevPageEndedWithHyphen = false
            let terminalPunctuation: Set<Character> = [".", "!", "?", "…", "”", "’", "\""]
            let hyphenChars: [Character] = ["-", "\u{2010}", "\u{2011}", "\u{00AD}"]

            for p in 0...maxPage {
                let pageBlocks = blocksByPage[p] ?? []
                var pageImages = imagesByPage[p] ?? []
                if pageBlocks.isEmpty && pageImages.isEmpty { continue }

                // Cross-page continuation check (BOOX NeoReader / KOReader standard):
                // If previous page ended with an unclosed paragraph or hyphenated word, and this page
                // begins with a lowercase letter, number, or clause continuation, connect the reading flow.
                var pageStartsContinuation = false
                if let prevBlock = lastParagraphOfPrevPage,
                   let firstBlock = pageBlocks.first,
                   firstBlock.kind == .paragraph {
                    let trimmedPrev = prevBlock.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    let lastChar = trimmedPrev.last ?? " "
                    let endsWithTerminal = terminalPunctuation.contains(lastChar) ||
                                          trimmedPrev.hasSuffix(".\"") ||
                                          trimmedPrev.hasSuffix("?\"") ||
                                          trimmedPrev.hasSuffix("!\"")
                    let endsWithHyphen = hyphenChars.contains(lastChar)

                    let trimmedFirst = firstBlock.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    let firstChar = trimmedFirst.first ?? " "
                    let startsWithContinuation = firstChar.isLowercase ||
                                                 firstChar == "," ||
                                                 firstChar == ";" ||
                                                 firstChar == ":" ||
                                                 firstChar == ")" ||
                                                 firstChar == "]" ||
                                                 firstChar.isNumber ||
                                                 trimmedFirst.hasPrefix("and ") ||
                                                 trimmedFirst.hasPrefix("or ") ||
                                                 trimmedFirst.hasPrefix("but ") ||
                                                 trimmedFirst.hasPrefix("that ") ||
                                                 trimmedFirst.hasPrefix("which ")

                    if (!endsWithTerminal || endsWithHyphen) && startsWithContinuation {
                        pageStartsContinuation = true
                    }
                }

                let anchorClass = pageStartsContinuation ? "page-marker-anchor subtle-continuation" : "page-marker-anchor"
                bodyHTML += "\n<section class=\"pdf-page-marker\" id=\"page-\(p + 1)\" data-page=\"\(p + 1)\" data-pdf-page=\"\(p + 1)\">\n"
                bodyHTML += "  <div class=\"\(anchorClass)\" id=\"page-anchor-\(p + 1)\" aria-hidden=\"true\" data-page-indicator=\"p. \(p + 1)\" data-pdf-page=\"\(p + 1)\"></div>\n"

                var i = 0
                while i < pageBlocks.count {
                    let block = pageBlocks[i]
                    let rectAttr = "\(Int(block.rect.origin.x)),\(Int(block.rect.origin.y)),\(Int(block.rect.size.width)),\(Int(block.rect.size.height))"
                    var rawText = block.text

                    // Cross-page de-hyphenation rejoining across the page boundary
                    let isContinuedParagraph = (i == 0 && pageStartsContinuation && block.kind == .paragraph)
                    if isContinuedParagraph && prevPageEndedWithHyphen {
                        let hyphenPrefixes: Set<String> = ["self", "cross", "well", "all", "co", "ex", "quasi", "semi", "multi", "non", "anti", "pre", "post"]
                        let prevLastWord = (lastParagraphOfPrevPage?.text ?? "")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .dropLast() // drop hyphen
                            .components(separatedBy: .whitespaces).last?.lowercased() ?? ""
                        if !hyphenPrefixes.contains(prevLastWord) {
                            rawText = rawText.trimmingCharacters(in: .whitespaces)
                        }
                    }

                    let escapedText = formatBlockText(rawText)

                    // Figure & Caption Binding (Adobe Sensei standard)
                    if block.kind == .figureCaption && !pageImages.isEmpty {
                        let img = pageImages.removeFirst()
                        let relPath = (img.imagePath as NSString).lastPathComponent
                        bodyHTML += """
                          <figure class=\"pdf-figure\" data-pdf-page=\"\(p + 1)\">
                            <img src=\"images/\(relPath)\" alt=\"Figure\" loading=\"lazy\" />
                            <figcaption data-pdf-page=\"\(p + 1)\" data-pdf-rect=\"\(rectAttr)\">\(escapedText)</figcaption>
                          </figure>\n
                        """
                        i += 1
                        continue
                    }

                    // Grouped List Item Handling (KOReader standard: avoid individual <ul> per bullet)
                    if block.kind == .listItem {
                        let isOrdered = PDFSpatialParser.isOrderedListMarker(block.text)
                        let tag = isOrdered ? "ol" : "ul"
                        let listClass = isOrdered ? "pdf-list pdf-list-ordered" : "pdf-list"

                        bodyHTML += "  <\(tag) class=\"\(listClass)\">\n"
                        while i < pageBlocks.count && pageBlocks[i].kind == .listItem {
                            let itemBlock = pageBlocks[i]
                            let itemRect = "\(Int(itemBlock.rect.origin.x)),\(Int(itemBlock.rect.origin.y)),\(Int(itemBlock.rect.size.width)),\(Int(itemBlock.rect.size.height))"
                            var itemText = itemBlock.text
                            if isOrdered {
                                if let regex = Self.orderedMarkerRegex {
                                    let nsText = itemText as NSString
                                    if let match = regex.firstMatch(in: itemText, options: [], range: NSRange(location: 0, length: min(nsText.length, 16))) {
                                        itemText = nsText.replacingCharacters(in: match.range, with: "")
                                    }
                                }
                            } else {
                                if let regex = Self.unorderedMarkerRegex {
                                    let nsText = itemText as NSString
                                    if let match = regex.firstMatch(in: itemText, options: [], range: NSRange(location: 0, length: min(nsText.length, 12))) {
                                        itemText = nsText.replacingCharacters(in: match.range, with: "")
                                    }
                                }
                            }
                            bodyHTML += "    <li data-pdf-page=\"\(p + 1)\" data-pdf-rect=\"\(itemRect)\">\(formatBlockText(itemText))</li>\n"
                            i += 1
                        }
                        bodyHTML += "  </\(tag)>\n"
                        continue
                    }

                    switch block.kind {
                    case .title:
                        bodyHTML += "  <h1 id=\"sec-\(p + 1)-\(i)\" data-pdf-page=\"\(p + 1)\" data-pdf-rect=\"\(rectAttr)\">\(escapedText)</h1>\n"
                    case .heading1:
                        bodyHTML += "  <h2 id=\"sec-\(p + 1)-\(i)\" data-pdf-page=\"\(p + 1)\" data-pdf-rect=\"\(rectAttr)\">\(escapedText)</h2>\n"
                    case .heading2:
                        bodyHTML += "  <h3 id=\"sec-\(p + 1)-\(i)\" data-pdf-page=\"\(p + 1)\" data-pdf-rect=\"\(rectAttr)\">\(escapedText)</h3>\n"
                    case .heading3:
                        bodyHTML += "  <h4 id=\"sec-\(p + 1)-\(i)\" data-pdf-page=\"\(p + 1)\" data-pdf-rect=\"\(rectAttr)\">\(escapedText)</h4>\n"
                    case .blockquote:
                        bodyHTML += "  <blockquote data-pdf-page=\"\(p + 1)\" data-pdf-rect=\"\(rectAttr)\">\(escapedText)</blockquote>\n"
                    case .code:
                        bodyHTML += "  <pre><code data-pdf-page=\"\(p + 1)\" data-pdf-rect=\"\(rectAttr)\">\(escapedText)</code></pre>\n"
                    case .listItem:
                        break // Handled above in grouped loop
                    case .figureCaption:
                        bodyHTML += "  <figcaption data-pdf-page=\"\(p + 1)\" data-pdf-rect=\"\(rectAttr)\">\(escapedText)</figcaption>\n"
                    case .table:
                        let rows = block.text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        if rows.isEmpty {
                            bodyHTML += """
                              <div class=\"pdf-table-container\">
                                <table data-pdf-page=\"\(p + 1)\" data-pdf-rect=\"\(rectAttr)\">
                                  <tr><td>\(escapedText)</td></tr>
                                </table>
                              </div>\n
                            """
                        } else {
                            bodyHTML += "  <div class=\"pdf-table-container\">\n"
                            bodyHTML += "    <table data-pdf-page=\"\(p + 1)\" data-pdf-rect=\"\(rectAttr)\">\n"
                            for (rIdx, row) in rows.enumerated() {
                                let cells: [String]
                                if row.contains("\t") {
                                    cells = row.components(separatedBy: "\t")
                                } else if row.contains("|") {
                                    cells = row.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                                } else if let regex = Self.multiSpaceRegex {
                                    let nsRow = row as NSString
                                    let matches = regex.matches(in: row, options: [], range: NSRange(location: 0, length: nsRow.length))
                                    if !matches.isEmpty {
                                        var parsedCells: [String] = []
                                        var lastEnd = 0
                                        for m in matches {
                                            let cellRange = NSRange(location: lastEnd, length: m.range.location - lastEnd)
                                            parsedCells.append(nsRow.substring(with: cellRange).trimmingCharacters(in: .whitespaces))
                                            lastEnd = m.range.location + m.range.length
                                        }
                                        parsedCells.append(nsRow.substring(from: lastEnd).trimmingCharacters(in: .whitespaces))
                                        cells = parsedCells.filter { !$0.isEmpty }
                                    } else {
                                        cells = [row]
                                    }
                                } else {
                                    cells = [row]
                                }

                                let cellTag = (rIdx == 0 && rows.count > 1) ? "th" : "td"
                                bodyHTML += "      <tr>\n"
                                for cell in cells {
                                    bodyHTML += "        <\(cellTag)>\(formatBlockText(cell))</\(cellTag)>\n"
                                }
                                bodyHTML += "      </tr>\n"
                            }
                            bodyHTML += "    </table>\n"
                            bodyHTML += "  </div>\n"
                        }
                    case .paragraph:
                        if isContinuedParagraph {
                            bodyHTML += "  <p class=\"pdf-paragraph-continuation\" data-continues-previous=\"true\" data-pdf-page=\"\(p + 1)\" data-pdf-rect=\"\(rectAttr)\">\(escapedText)</p>\n"
                        } else {
                            bodyHTML += "  <p data-pdf-page=\"\(p + 1)\" data-pdf-rect=\"\(rectAttr)\">\(escapedText)</p>\n"
                        }
                    }
                    i += 1
                }

                // Update cross-page tracking for next page
                if let lastBlock = pageBlocks.last, lastBlock.kind == .paragraph {
                    lastParagraphOfPrevPage = lastBlock
                    let trimmed = lastBlock.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    prevPageEndedWithHyphen = hyphenChars.contains(trimmed.last ?? " ")
                } else if !pageBlocks.isEmpty {
                    lastParagraphOfPrevPage = nil
                    prevPageEndedWithHyphen = false
                }

                // Render any remaining images not paired with captions
                for img in pageImages {
                    let relPath = (img.imagePath as NSString).lastPathComponent
                    bodyHTML += "  <figure class=\"pdf-figure\" data-pdf-page=\"\(p + 1)\"><img src=\"images/\(relPath)\" alt=\"Page \(p + 1)\" data-pdf-page=\"\(p + 1)\" loading=\"lazy\" /></figure>\n"
                }

                bodyHTML += "</section>\n"
            }
        }

        let htmlDocument = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no, viewport-fit=cover">
            <title>\(escapeHTML(documentTitle))</title>
            <style>
                :root {
                    color-scheme: light dark;
                }
                body {
                    margin: 0;
                    padding: 24px 20px 60px 20px;
                    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
                    font-size: 17px;
                    line-height: 1.6;
                    word-wrap: break-word;
                    word-break: break-word;
                    overflow-wrap: break-word;
                    -webkit-text-size-adjust: 100%;
                    -webkit-font-smoothing: antialiased;
                    -moz-osx-font-smoothing: grayscale;
                    text-rendering: optimizeLegibility;
                    text-align: justify;
                    text-justify: inter-word;
                    -webkit-hyphens: auto;
                    hyphens: auto;
                }
                .page-marker-anchor {
                    display: block !important;
                    height: 1px !important;
                    min-height: 1px !important;
                    margin: 28px 0 20px 0;
                    position: relative;
                    border-top: 1px dashed rgba(128, 128, 128, 0.18);
                    break-inside: avoid !important;
                    -webkit-column-break-inside: avoid !important;
                }
                .page-marker-anchor.subtle-continuation {
                    display: inline-block !important;
                    width: 0 !important;
                    height: 0 !important;
                    min-height: 0 !important;
                    margin: 0 !important;
                    padding: 0 !important;
                    border: none !important;
                }
                .page-marker-anchor.subtle-continuation::after {
                    display: none !important;
                }
                .page-marker-anchor::after {
                    content: attr(data-page-indicator);
                    position: absolute;
                    right: 0;
                    top: -8px;
                    font-size: 10px;
                    font-weight: 600;
                    color: currentColor;
                    opacity: 0.28;
                    background: inherit;
                    padding-left: 6px;
                    letter-spacing: 0.05em;
                    font-variant-numeric: tabular-nums;
                }
                h1, h2, h3, h4 {
                    line-height: 1.3;
                    margin-top: 1.4em;
                    margin-bottom: 0.6em;
                    font-weight: 700;
                    break-after: avoid !important;
                    -webkit-column-break-after: avoid !important;
                    text-wrap: balance !important;
                }
                h1 { font-size: 1.6em; }
                h2 { font-size: 1.35em; }
                h3 { font-size: 1.18em; }
                h4 { font-size: 1.05em; }
                p {
                    margin-top: 0;
                    margin-bottom: 0.35em;
                    text-indent: 1.35em;
                    text-align: justify;
                    text-justify: inter-word;
                    -webkit-hyphens: auto;
                    hyphens: auto;
                }
                h1 + p, h2 + p, h3 + p, h4 + p,
                .page-marker-anchor:not(.subtle-continuation) + p,
                blockquote + p,
                figure + p,
                .pdf-figure + p,
                table + p,
                .pdf-table-container + p,
                p.pdf-paragraph-continuation,
                [data-continues-previous="true"] {
                    text-indent: 0 !important;
                }
                p.pdf-paragraph-continuation,
                [data-continues-previous="true"] {
                    margin-top: 0 !important;
                }
                .pdf-citation {
                    white-space: nowrap !important;
                    font-size: 0.84em !important;
                    font-weight: 600 !important;
                    opacity: 0.85 !important;
                    vertical-align: super !important;
                    line-height: 0 !important;
                }
                sup, .pdf-superscript {
                    font-size: 0.75em !important;
                    vertical-align: super !important;
                    line-height: 0 !important;
                    font-weight: 600 !important;
                    opacity: 0.85 !important;
                }
                blockquote {
                    margin: 1.2em 0;
                    padding: 4px 14px;
                    border-left: 3px solid currentColor;
                    opacity: 0.85;
                    font-style: italic;
                    break-inside: avoid !important;
                    -webkit-column-break-inside: avoid !important;
                }
                pre {
                    background: rgba(128, 128, 128, 0.12);
                    padding: 12px 14px;
                    border-radius: 8px;
                    overflow-x: auto;
                    font-family: ui-monospace, Menlo, Monaco, Consolas, monospace;
                    font-size: 0.88em;
                    line-height: 1.45;
                    break-inside: avoid !important;
                    -webkit-column-break-inside: avoid !important;
                }
                code {
                    font-family: inherit;
                }
                .pdf-list {
                    margin: 0.8em 0 1.2em 0;
                    padding-left: 24px;
                }
                .pdf-list li {
                    margin-bottom: 0.4em;
                    line-height: 1.5;
                }
                .pdf-list-ordered {
                    list-style-type: decimal;
                }
                #inksync-viewport {
                    box-sizing: border-box;
                    width: 100vw;
                }
                .pdf-table-container {
                    width: 100%;
                    overflow-x: auto;
                    -webkit-overflow-scrolling: touch;
                    margin: 1.4em 0;
                    border-radius: 8px;
                    background: rgba(128, 128, 128, 0.06);
                    border: 1px solid rgba(128, 128, 128, 0.15);
                    break-inside: avoid !important;
                }
                table {
                    width: 100%;
                    border-collapse: collapse;
                    font-size: 0.9em;
                }
                th, td {
                    padding: 8px 12px;
                    border-bottom: 1px solid rgba(128, 128, 128, 0.12);
                    text-align: left;
                }
                th {
                    font-weight: 700;
                    background: rgba(128, 128, 128, 0.08);
                }
                figcaption {
                    font-size: 0.9em;
                    opacity: 0.75;
                    text-align: center;
                    margin-top: 8px;
                    margin-bottom: 1.2em;
                    font-style: italic;
                    break-inside: avoid !important;
                    -webkit-column-break-inside: avoid !important;
                }
                .pdf-page-marker {
                    display: block;
                    box-sizing: border-box;
                    width: 100%;
                }
                .pdf-figure {
                    margin: 20px 0;
                    padding: 0;
                    text-align: center;
                    break-inside: avoid !important;
                    -webkit-column-break-inside: avoid !important;
                }
                img {
                    max-width: 100%;
                    max-height: 75vh;
                    object-fit: contain;
                    border-radius: 8px;
                    display: block;
                    margin: 12px auto;
                    break-inside: avoid !important;
                    -webkit-column-break-inside: avoid !important;
                }
            </style>
        </head>
        <body>
            <div id="inksync-viewport">
                \(bodyHTML)
            </div>
        </body>
        </html>
        """

        do {
            try htmlDocument.write(to: htmlFileURL, atomically: true, encoding: .utf8)
            return htmlFileURL
        } catch {
            return nil
        }
    }

    private func escapeHTML(_ string: String) -> String {
        guard string.contains(where: { $0 == "&" || $0 == "<" || $0 == ">" || $0 == "\"" || $0 == "'" }) else {
            return string
        }
        var result = ""
        result.reserveCapacity(string.utf8.count + 16)
        for char in string {
            switch char {
            case "&": result.append("&amp;")
            case "<": result.append("&lt;")
            case ">": result.append("&gt;")
            case "\"": result.append("&quot;")
            case "'": result.append("&#39;")
            default: result.append(char)
            }
        }
        return result
    }
}
