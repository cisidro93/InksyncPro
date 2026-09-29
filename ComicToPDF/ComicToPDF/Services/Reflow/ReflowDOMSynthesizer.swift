import Foundation
import PDFKit
import UIKit

public final class ReflowDOMSynthesizer: @unchecked Sendable {
    public static let shared = ReflowDOMSynthesizer()
    private init() {}

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

        let cacheFileName = "reflow_v3_\(isClutterFiltered ? "clean" : "raw").html"
        let htmlFileURL = targetDir.appendingPathComponent(cacheFileName)

        var bodyHTML = ""
        let maxPage = max(
            blocks.map { $0.pageIndex }.max() ?? -1,
            images.map { $0.pageIndex }.max() ?? -1
        )

        if maxPage >= 0 {
            for p in 0...maxPage {
                let pageBlocks = blocks.filter { $0.pageIndex == p }
                var pageImages = images.filter { $0.pageIndex == p }
                if pageBlocks.isEmpty && pageImages.isEmpty { continue }

                bodyHTML += "\n<section class=\"pdf-page-marker\" id=\"page-\(p + 1)\" data-page=\"\(p + 1)\">\n"
                if p > 0 {
                    bodyHTML += "  <div class=\"page-marker-anchor\" aria-hidden=\"true\" data-page-indicator=\"p. \(p + 1)\"></div>\n"
                }

                var i = 0
                while i < pageBlocks.count {
                    let block = pageBlocks[i]
                    let rectAttr = "\(Int(block.rect.origin.x)),\(Int(block.rect.origin.y)),\(Int(block.rect.size.width)),\(Int(block.rect.size.height))"
                    let escapedText = escapeHTML(block.text)

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
                                if let stripped = itemText.range(of: #"^\s*(?:\(?\d{1,3}[\.\)]|\(?[a-zA-Z][\.\)]|\(?[ivxlcdmIVXLCDM]{1,6}[\.\)])\s+"#, options: .regularExpression) {
                                    itemText.removeSubrange(stripped)
                                }
                            } else {
                                if let stripped = itemText.range(of: #"^[\s*•▪▫–—\-]+\s*"#, options: .regularExpression) {
                                    itemText.removeSubrange(stripped)
                                }
                            }
                            bodyHTML += "    <li data-pdf-page=\"\(p + 1)\" data-pdf-rect=\"\(itemRect)\">\(escapeHTML(itemText))</li>\n"
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
                                } else {
                                    let cellRegex = try? NSRegularExpression(pattern: #"\s{2,}"#, options: [])
                                    if let regex = cellRegex {
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
                                }

                                let cellTag = (rIdx == 0 && rows.count > 1) ? "th" : "td"
                                bodyHTML += "      <tr>\n"
                                for cell in cells {
                                    bodyHTML += "        <\(cellTag)>\(escapeHTML(cell))</\(cellTag)>\n"
                                }
                                bodyHTML += "      </tr>\n"
                            }
                            bodyHTML += "    </table>\n"
                            bodyHTML += "  </div>\n"
                        }
                    case .paragraph:
                        bodyHTML += "  <p data-pdf-page=\"\(p + 1)\" data-pdf-rect=\"\(rectAttr)\">\(escapedText)</p>\n"
                    }
                    i += 1
                }

                // Render any remaining images not paired with captions
                for img in pageImages {
                    let relPath = (img.imagePath as NSString).lastPathComponent
                    bodyHTML += "  <figure class=\"pdf-figure\"><img src=\"images/\(relPath)\" alt=\"Page \(p + 1)\" loading=\"lazy\" /></figure>\n"
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
                    -webkit-text-size-adjust: 100%;
                }
                .page-marker-anchor {
                    height: 1px;
                    margin: 28px 0 20px 0;
                    position: relative;
                    border-top: 1px dashed rgba(128, 128, 128, 0.18);
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
                }
                h1 { font-size: 1.6em; }
                h2 { font-size: 1.35em; }
                h3 { font-size: 1.18em; }
                h4 { font-size: 1.05em; }
                p {
                    margin-top: 0;
                    margin-bottom: 1.1em;
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
                    box-sizing: border-box !important;
                    width: 100% !important;
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
        return string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
