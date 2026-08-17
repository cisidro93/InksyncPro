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
        images: [ExtractedPDFImage]
    ) async -> URL? {
        let fileManager = FileManager.default
        guard let cacheDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let targetDir = cacheDir.appendingPathComponent("ReflowPDF/\(pdfUUID)", isDirectory: true)

        do {
            try fileManager.createDirectory(at: targetDir, withIntermediateDirectories: true)
        } catch {
            return nil
        }

        let htmlFileURL = targetDir.appendingPathComponent("reflow.html")

        var bodyHTML = ""
        var currentPage = -1

        var embeddedImagePaths = Set<String>()

        for block in blocks {
            if block.pageIndex != currentPage {
                currentPage = block.pageIndex
                bodyHTML += "\n<section class=\"pdf-page-marker\" id=\"page-\(currentPage + 1)\" data-page=\"\(currentPage + 1)\">\n"
                bodyHTML += "  <div class=\"page-number-divider\">Page \(currentPage + 1)</div>\n"
                
                // Embed images belonging to this page
                let pageImages = images.filter { $0.pageIndex == currentPage }
                for img in pageImages {
                    embeddedImagePaths.insert(img.imagePath)
                    let relPath = (img.imagePath as NSString).lastPathComponent
                    bodyHTML += "  <figure class=\"pdf-figure\"><img src=\"images/\(relPath)\" alt=\"Figure Page \(currentPage + 1)\" loading=\"lazy\" /></figure>\n"
                }
                
                bodyHTML += "</section>\n"
            }

            let rectAttr = "\(Int(block.rect.origin.x)),\(Int(block.rect.origin.y)),\(Int(block.rect.size.width)),\(Int(block.rect.size.height))"
            let escapedText = escapeHTML(block.text)

            switch block.kind {
            case .title:
                bodyHTML += "<h1 data-pdf-page=\"\(currentPage + 1)\" data-pdf-rect=\"\(rectAttr)\">\(escapedText)</h1>\n"
            case .heading1:
                bodyHTML += "<h2 data-pdf-page=\"\(currentPage + 1)\" data-pdf-rect=\"\(rectAttr)\">\(escapedText)</h2>\n"
            case .heading2:
                bodyHTML += "<h3 data-pdf-page=\"\(currentPage + 1)\" data-pdf-rect=\"\(rectAttr)\">\(escapedText)</h3>\n"
            case .heading3:
                bodyHTML += "<h4 data-pdf-page=\"\(currentPage + 1)\" data-pdf-rect=\"\(rectAttr)\">\(escapedText)</h4>\n"
            case .blockquote:
                bodyHTML += "<blockquote data-pdf-page=\"\(currentPage + 1)\" data-pdf-rect=\"\(rectAttr)\">\(escapedText)</blockquote>\n"
            case .code:
                bodyHTML += "<pre><code data-pdf-page=\"\(currentPage + 1)\" data-pdf-rect=\"\(rectAttr)\">\(escapedText)</code></pre>\n"
            case .listItem:
                bodyHTML += "<ul><li data-pdf-page=\"\(currentPage + 1)\" data-pdf-rect=\"\(rectAttr)\">\(escapedText)</li></ul>\n"
            case .figureCaption:
                bodyHTML += "<figcaption data-pdf-page=\"\(currentPage + 1)\" data-pdf-rect=\"\(rectAttr)\">\(escapedText)</figcaption>\n"
            case .paragraph:
                bodyHTML += "<p data-pdf-page=\"\(currentPage + 1)\" data-pdf-rect=\"\(rectAttr)\">\(escapedText)</p>\n"
            }
        }

        // Catch any orphan images on pages without text blocks
        for img in images where !embeddedImagePaths.contains(img.imagePath) {
            let relPath = (img.imagePath as NSString).lastPathComponent
            bodyHTML += "\n<section class=\"pdf-page-marker\" id=\"page-\(img.pageIndex + 1)\" data-page=\"\(img.pageIndex + 1)\">\n"
            bodyHTML += "  <div class=\"page-number-divider\">Page \(img.pageIndex + 1)</div>\n"
            bodyHTML += "  <figure class=\"pdf-figure\"><img src=\"images/\(relPath)\" alt=\"Figure Page \(img.pageIndex + 1)\" loading=\"lazy\" /></figure>\n"
            bodyHTML += "</section>\n"
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
                .page-number-divider {
                    font-size: 11px;
                    font-weight: 700;
                    text-transform: uppercase;
                    letter-spacing: 0.08em;
                    opacity: 0.4;
                    margin: 32px 0 16px 0;
                    border-bottom: 1px solid currentColor;
                    padding-bottom: 4px;
                }
                h1, h2, h3, h4 {
                    line-height: 1.3;
                    margin-top: 1.4em;
                    margin-bottom: 0.6em;
                    font-weight: 700;
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
                    padding-left: 14px;
                    border-left: 3px solid currentColor;
                    opacity: 0.85;
                    font-style: italic;
                }
                pre {
                    background: rgba(128, 128, 128, 0.15);
                    padding: 12px;
                    border-radius: 8px;
                    overflow-x: auto;
                }
                figcaption {
                    font-size: 0.9em;
                    opacity: 0.75;
                    text-align: center;
                    margin-bottom: 1.2em;
                }
                img {
                    max-width: 100%;
                    height: auto;
                    border-radius: 8px;
                    display: block;
                    margin: 16px auto;
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
