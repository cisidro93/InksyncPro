import Foundation
import UIKit
import MessageUI

// MARK: - Notebook Document & Kindle Exporter
// Generates publication-grade multi-page PDFs from notebook notes & articles
// with full Send-to-Kindle (email and iOS share extension) and Library ingestion support.

public enum NotebookExportError: LocalizedError {
    case emptyContent
    case renderingFailed
    case fileWriteFailed(String)
    case libraryNotFound

    public var errorDescription: String? {
        switch self {
        case .emptyContent:
            return "Notebook is empty. Please add or paste text before exporting."
        case .renderingFailed:
            return "Failed to render PDF document from notebook content."
        case .fileWriteFailed(let msg):
            return "Failed to write PDF file: \(msg)"
        case .libraryNotFound:
            return "Documents directory could not be resolved."
        }
    }
}

@MainActor
public final class NotebookDocumentExporter: NSObject, MFMailComposeViewControllerDelegate {
    public static let shared = NotebookDocumentExporter()
    
    private override init() {
        super.init()
    }
    
    // MARK: - PDF Generation Engine
    
    /// Generates a paginated, publication-quality PDF from markdown/text.
    /// Returns the URL pointing to the temporary `.pdf` file.
    public func exportPDF(
        title: String,
        content: String,
        author: String? = nil,
        pageSize: CGSize = CGSize(width: 612, height: 792) // US Letter standard
    ) throws -> URL {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NotebookExportError.emptyContent
        }
        
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled Note" : title
        let htmlContent = generateHTML(title: cleanTitle, content: trimmed, author: author)
        
        let printRenderer = NotebookPrintPageRenderer(documentTitle: cleanTitle)
        let printFormatter = UIMarkupTextPrintFormatter(markupText: htmlContent)
        printFormatter.perPageContentInsets = UIEdgeInsets(top: 54, left: 40, bottom: 54, right: 40)
        printRenderer.addPrintFormatter(printFormatter, startingAtPageAt: 0)
        
        let paperRect = CGRect(origin: .zero, size: pageSize)
        let printableRect = paperRect.insetBy(dx: 36, dy: 44)
        
        printRenderer.setValue(NSValue(cgRect: paperRect), forKey: "paperRect")
        printRenderer.setValue(NSValue(cgRect: printableRect), forKey: "printableRect")
        
        let pdfRenderer = UIGraphicsPDFRenderer(bounds: paperRect)
        let pdfData = pdfRenderer.pdfData { context in
            for pageIndex in 0..<printRenderer.numberOfPages {
                context.beginPage()
                printRenderer.drawPage(at: pageIndex, in: paperRect)
            }
        }
        
        guard !pdfData.isEmpty else {
            throw NotebookExportError.renderingFailed
        }
        
        let sanitizedName = sanitizeFilename(cleanTitle)
        let tempDir = FileManager.default.temporaryDirectory
        let exportURL = tempDir.appendingPathComponent("\(sanitizedName).pdf")
        
        do {
            try pdfData.write(to: exportURL, options: .atomic)
            Logger.shared.log("NotebookDocumentExporter: Rendered \(printRenderer.numberOfPages)-page PDF (\(pdfData.count) bytes) at \(exportURL.lastPathComponent)", category: "Export", type: .success)
            return exportURL
        } catch {
            throw NotebookExportError.fileWriteFailed(error.localizedDescription)
        }
    }
    
    // MARK: - Save directly to InksyncPro Library as a Book
    
    /// Renders note to PDF and saves it into the active InksyncPro Documents directory,
    /// triggering an automatic library scan so it appears immediately for reading & annotating.
    public func saveToLibraryAsBook(
        title: String,
        content: String,
        author: String? = nil
    ) async throws -> URL {
        let tempPDF = try exportPDF(title: title, content: content, author: author)
        
        guard let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw NotebookExportError.libraryNotFound
        }
        
        let sanitizedName = sanitizeFilename(title.isEmpty ? "Notebook_Book" : title)
        var destinationURL = docDir.appendingPathComponent("\(sanitizedName).pdf")
        
        // Disambiguate if file already exists
        var counter = 1
        while FileManager.default.fileExists(atPath: destinationURL.path) {
            destinationURL = docDir.appendingPathComponent("\(sanitizedName)_\(counter).pdf")
            counter += 1
        }
        
        do {
            try FileManager.default.copyItem(at: tempPDF, to: destinationURL)
            Logger.shared.log("NotebookDocumentExporter: Saved book to Library Documents at \(destinationURL.lastPathComponent)", category: "Export", type: .success)
            
            // Trigger Library rescan
            ConversionManager.shared.scanLibrary(addedByMode: .pro)
            return destinationURL
        } catch {
            throw NotebookExportError.fileWriteFailed(error.localizedDescription)
        }
    }
    
    // MARK: - Send to Kindle (Email or Share Sheet)
    
    /// Presents Kindle delivery options: email via Send-to-Kindle address or native iOS Share Extension
    public func presentKindleExport(
        title: String,
        content: String,
        author: String? = nil,
        from viewController: UIViewController,
        kindleEmail: String? = nil
    ) {
        do {
            let pdfURL = try exportPDF(title: title, content: content, author: author)
            
            if let email = kindleEmail, !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               MFMailComposeViewController.canSendMail() {
                let mailVC = MFMailComposeViewController()
                mailVC.mailComposeDelegate = self
                mailVC.setToRecipients([email])
                mailVC.setSubject(title.isEmpty ? "Kindle Document" : title)
                mailVC.setMessageBody("Attached document sent via InksyncPro for Kindle reading.", isHTML: false)
                
                if let data = try? Data(contentsOf: pdfURL) {
                    mailVC.addAttachmentData(data, mimeType: "application/pdf", fileName: pdfURL.lastPathComponent)
                }
                
                viewController.present(mailVC, animated: true)
            } else {
                // Present standard iOS Share Sheet with Kindle app extension
                let activityVC = UIActivityViewController(activityItems: [pdfURL], applicationActivities: nil)
                if let popover = activityVC.popoverPresentationController {
                    popover.sourceView = viewController.view
                    popover.sourceRect = CGRect(x: viewController.view.bounds.midX, y: viewController.view.bounds.midY, width: 0, height: 0)
                    popover.permittedArrowDirections = []
                }
                viewController.present(activityVC, animated: true)
            }
        } catch {
            Logger.shared.log("NotebookDocumentExporter: Kindle export failed: \(error.localizedDescription)", category: "Export", type: .error)
        }
    }
    
    // MARK: - MFMailComposeViewControllerDelegate
    
    public nonisolated func mailComposeController(
        _ controller: MFMailComposeViewController,
        didFinishWith result: MFMailComposeResult,
        error: Error?
    ) {
        Task { @MainActor in
            controller.dismiss(animated: true) {
                if result == .sent {
                    HapticEngine.success()
                    Logger.shared.log("NotebookDocumentExporter: Kindle email sent successfully", category: "Export", type: .success)
                } else if result == .failed {
                    HapticEngine.warning()
                    Logger.shared.log("NotebookDocumentExporter: Kindle email send failed", category: "Export", type: .error)
                }
            }
        }
    }
    
    // MARK: - Internal Helpers
    
    private func sanitizeFilename(_ name: String) -> String {
        let invalidChars = CharacterSet(charactersIn: ":/\\?%*|\"<>")
        let cleaned = name.components(separatedBy: invalidChars).joined(separator: "_")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Notebook" : String(trimmed.prefix(60))
    }
    
    private func generateHTML(title: String, content: String, author: String?) -> String {
        let wordCount = content.split { $0.isWhitespace || $0.isNewline }.count
        let readTimeMinutes = max(1, Int(ceil(Double(wordCount) / 225.0)))
        let formattedDate = Date().formatted(date: .long, time: .omitted)
        
        // Convert markdown basics into clean HTML
        var htmlBody = ""
        let paragraphs = content.components(separatedBy: "\n\n")
        for para in paragraphs {
            let trimmedPara = para.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedPara.isEmpty else { continue }
            
            if trimmedPara.hasPrefix("# ") {
                let hText = trimmedPara.dropFirst(2)
                htmlBody += "<h1>\(escapeHTML(String(hText)))</h1>\n"
            } else if trimmedPara.hasPrefix("## ") {
                let hText = trimmedPara.dropFirst(3)
                htmlBody += "<h2>\(escapeHTML(String(hText)))</h2>\n"
            } else if trimmedPara.hasPrefix("### ") {
                let hText = trimmedPara.dropFirst(4)
                htmlBody += "<h3>\(escapeHTML(String(hText)))</h3>\n"
            } else if trimmedPara.hasPrefix("> ") {
                let qText = trimmedPara.replacingOccurrences(of: "> ", with: "")
                htmlBody += "<blockquote>\(formatInlineMarkdown(escapeHTML(qText)))</blockquote>\n"
            } else if trimmedPara.hasPrefix("- ") || trimmedPara.hasPrefix("* ") {
                let items = trimmedPara.components(separatedBy: "\n")
                htmlBody += "<ul>\n"
                for item in items {
                    let cleanedItem = item.trimmingCharacters(in: .whitespaces)
                    let text = cleanedItem.dropFirst(2).trimmingCharacters(in: .whitespaces)
                    htmlBody += "<li>\(formatInlineMarkdown(escapeHTML(text)))</li>\n"
                }
                htmlBody += "</ul>\n"
            } else {
                htmlBody += "<p>\(formatInlineMarkdown(escapeHTML(trimmedPara)))</p>\n"
            }
        }
        
        let authorSnippet = author.map { "<div class=\"meta-author\">By \($0)</div>" } ?? ""
        
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
            @page {
                size: letter portrait;
                margin: 0;
            }
            body {
                font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Georgia, serif;
                font-size: 11pt;
                line-height: 1.65;
                color: #1a1a1a;
                background-color: #ffffff;
                margin: 0;
                padding: 0;
            }
            .document-header {
                border-bottom: 1.5pt solid #2c3e50;
                padding-bottom: 12pt;
                margin-bottom: 22pt;
            }
            .document-title {
                font-size: 24pt;
                font-weight: 800;
                line-height: 1.2;
                color: #0f172a;
                margin: 0 0 6pt 0;
            }
            .meta-bar {
                font-size: 9pt;
                font-weight: 600;
                color: #64748b;
                display: flex;
                gap: 12pt;
            }
            .meta-author {
                font-size: 10pt;
                font-weight: 600;
                color: #334155;
                margin-top: 2pt;
            }
            h1 {
                font-size: 16pt;
                font-weight: 700;
                color: #1e293b;
                margin-top: 18pt;
                margin-bottom: 8pt;
                page-break-after: avoid;
            }
            h2 {
                font-size: 13pt;
                font-weight: 700;
                color: #334155;
                margin-top: 14pt;
                margin-bottom: 6pt;
                page-break-after: avoid;
            }
            h3 {
                font-size: 11.5pt;
                font-weight: 600;
                color: #475569;
                margin-top: 12pt;
                margin-bottom: 4pt;
                page-break-after: avoid;
            }
            p {
                margin: 0 0 10pt 0;
                text-align: justify;
                hyphens: auto;
            }
            blockquote {
                border-left: 3pt solid #f97316;
                background-color: #fff7ed;
                padding: 6pt 12pt;
                margin: 10pt 0;
                color: #7c2d12;
                font-style: italic;
            }
            ul {
                margin: 0 0 10pt 0;
                padding-left: 18pt;
            }
            li {
                margin-bottom: 4pt;
            }
            code {
                font-family: Menlo, Monaco, monospace;
                font-size: 9.5pt;
                background-color: #f1f5f9;
                padding: 1pt 4pt;
                border-radius: 3pt;
            }
        </style>
        </head>
        <body>
            <div class="document-header">
                <div class="document-title">\(escapeHTML(title))</div>
                \(authorSnippet)
                <div class="meta-bar">
                    <span>\(formattedDate)</span> • 
                    <span>\(wordCount) words</span> • 
                    <span>~\(readTimeMinutes) min read</span>
                </div>
            </div>
            \(htmlBody)
        </body>
        </html>
        """
    }
    
    private func escapeHTML(_ str: String) -> String {
        return str
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
    
    private func formatInlineMarkdown(_ text: String) -> String {
        var result = text
        // Bold: **text**
        let boldRegex = #"\*\*(.+?)\*\*"#
        if let regex = try? NSRegularExpression(pattern: boldRegex) {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(location: 0, length: result.utf16.count), withTemplate: "<strong>$1</strong>")
        }
        // Italic: _text_ or *text*
        let italicRegex = #"(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)|_(.+?)_"#
        if let regex = try? NSRegularExpression(pattern: italicRegex) {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(location: 0, length: result.utf16.count), withTemplate: "<em>$1$2</em>")
        }
        // Inline code: `code`
        let codeRegex = #"`(.+?)`"#
        if let regex = try? NSRegularExpression(pattern: codeRegex) {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(location: 0, length: result.utf16.count), withTemplate: "<code>$1</code>")
        }
        return result
    }
}

// MARK: - Custom Print Page Renderer with Headers and Footers

private final class NotebookPrintPageRenderer: UIPrintPageRenderer {
    let documentTitle: String
    
    init(documentTitle: String) {
        self.documentTitle = documentTitle
        super.init()
        self.headerHeight = 36.0
        self.footerHeight = 36.0
    }
    
    override func drawHeaderForPage(at pageIndex: Int, in headerRect: CGRect) {
        // Do not draw header on the cover/first page
        guard pageIndex > 0 else { return }
        
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 8, weight: .semibold),
            .foregroundColor: UIColor.secondaryLabel
        ]
        
        let drawRect = CGRect(x: 40, y: headerRect.origin.y + 12, width: headerRect.width - 80, height: 16)
        let titleString = NSString(string: documentTitle.uppercased())
        titleString.draw(in: drawRect, withAttributes: titleAttrs)
        
        // Header separator line
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 40, y: headerRect.maxY - 4))
        path.addLine(to: CGPoint(x: headerRect.width - 40, y: headerRect.maxY - 4))
        UIColor.separator.withAlphaComponent(0.3).setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }
    
    override func drawFooterForPage(at pageIndex: Int, in footerRect: CGRect) {
        let footerText = "Page \(pageIndex + 1) of \(numberOfPages)  •  InksyncPro"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 8, weight: .regular),
            .foregroundColor: UIColor.tertiaryLabel
        ]
        
        let size = (footerText as NSString).size(withAttributes: attrs)
        let drawRect = CGRect(
            x: (footerRect.width - size.width) / 2.0,
            y: footerRect.origin.y + 8,
            width: size.width,
            height: size.height
        )
        (footerText as NSString).draw(in: drawRect, withAttributes: attrs)
    }
}
