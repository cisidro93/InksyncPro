import Foundation
import SwiftData
import UniformTypeIdentifiers
import SwiftUI
import ZIPFoundation
import PencilKit

/// Export format for sharing securely with iOS ecosystem.
struct ZettelArchiveDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.zip] }
    var zipData: Data
    
    init(zipData: Data) {
        self.zipData = zipData
    }
    
    init(configuration: ReadConfiguration) throws {
        self.zipData = Data()
    }
    
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        return FileWrapper(regularFileWithContents: zipData)
    }
}

@MainActor final class ZettelkastenExporter: Sendable {
    static let shared = ZettelkastenExporter()
    
    private init() {}
    
    /// Compiles all SDAnnotations into an Obsidian-ready Markdown archive
    func exportToMarkdownZip(annotations: [Annotation], pdfs: [ConvertedPDF]) async throws -> URL {
        // 1. On MainActor: Pre-render PKDrawing drawings to PNGs
        var drawingsMap: [UUID: Data] = [:]
        for ann in annotations {
            if let drawingData = ann.drawingData,
               let drawing = try? PKDrawing(data: drawingData),
               !drawing.bounds.isEmpty {
                // Render drawing as a transparent high-resolution image
                let image = drawing.image(from: drawing.bounds, scale: 2.0)
                if let pngData = image.pngData() {
                    drawingsMap[ann.id] = pngData
                }
            }
        }
        
        let drawings = drawingsMap
        
        let task = Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            let tempDir = fileManager.temporaryDirectory.appendingPathComponent("MindPalaceExport_\(UUID().uuidString)")
            
            try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true, attributes: nil)
            
            // Create an attachments directory inside the vault
            let attachmentsDir = tempDir.appendingPathComponent("attachments")
            try fileManager.createDirectory(at: attachmentsDir, withIntermediateDirectories: true, attributes: nil)
            
            // Write the PNG drawing attachments
            for (id, pngData) in drawings {
                let attachmentURL = attachmentsDir.appendingPathComponent("drawing_\(id.uuidString).png")
                try pngData.write(to: attachmentURL)
            }
            
            // Build series lookup dictionary to place notes inside series subdirectories
            var pdfToSeries: [UUID: (title: String, series: String?, author: String?)] = [:]
            for pdf in pdfs {
                pdfToSeries[pdf.id] = (
                    title: pdf.name,
                    series: pdf.metadata.series?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? pdf.metadata.series : nil,
                    author: pdf.metadata.author?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? pdf.metadata.author : nil
                )
            }
            
            // Group annotations by Book (pdfID)
            let groupedByBook = Dictionary(grouping: annotations) { $0.pdfID }
            
            for (pdfID, bookNotes) in groupedByBook {
                let bookInfo = pdfToSeries[pdfID]
                let bookTitle = bookInfo?.title ?? bookNotes.first?.readwiseBookTitle ?? "Book_\(pdfID.uuidString.prefix(6))"
                let cleanBookTitle = bookTitle.components(separatedBy: CharacterSet.alphanumerics.inverted.subtracting(.whitespaces)).joined().replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
                
                // Determine output directory based on book's series
                let bookDirectoryURL: URL
                if let series = bookInfo?.series {
                    let cleanSeries = series.components(separatedBy: CharacterSet.alphanumerics.inverted.subtracting(.whitespaces)).joined().replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
                    bookDirectoryURL = tempDir.appendingPathComponent(cleanSeries)
                } else {
                    bookDirectoryURL = tempDir
                }
                
                try fileManager.createDirectory(at: bookDirectoryURL, withIntermediateDirectories: true, attributes: nil)
                
                // Sort notes by date older -> newer
                let sortedNotes = bookNotes.sorted { $0.createdAt < $1.createdAt }
                
                var atomicWikiLinks: [String] = []
                
                // Write Atomic Note Files
                for note in sortedNotes {
                    let pageNum = note.pageIndex + 1
                    let chapterText = note.chapterTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? note.chapterTitle! : "Page \(pageNum)"
                    let atomicTitle = "⚡ \(cleanBookTitle) - \(chapterText) - \(note.id.uuidString.prefix(6))"
                    let cleanAtomicTitle = atomicTitle.components(separatedBy: CharacterSet.alphanumerics.inverted.subtracting(.whitespaces)).joined().replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
                    
                    var atomicMarkdown = "# \(cleanAtomicTitle)\n\n"
                    atomicMarkdown += "**Source:** [[📖 \(cleanBookTitle)]]\n"
                    atomicMarkdown += "**Location:** Page \(pageNum) (Chapter: \(chapterText))\n"
                    atomicMarkdown += "**Created:** \(note.createdAt.formatted())\n\n"
                    atomicMarkdown += "---\n\n"
                    
                    if let text = note.selectedText, !text.isEmpty {
                        atomicMarkdown += "### 📖 Highlight\n> \(text.replacingOccurrences(of: "\n", with: "\n> "))\n\n"
                    }
                    
                    if let userNote = note.noteText, !userNote.isEmpty {
                        atomicMarkdown += "### ✍️ My Note\n\(userNote)\n\n"
                    }
                    
                    if let tags = note.tags, !tags.isEmpty {
                        let hashedTags = tags.map { "#\($0.replacingOccurrences(of: " ", with: "_"))" }.joined(separator: ", ")
                        atomicMarkdown += "🏷️ *Tags:* \(hashedTags)\n\n"
                    }
                    
                    if drawings[note.id] != nil {
                        atomicMarkdown += "### 🎨 Canvas Handwriting\n![[drawing_\(note.id.uuidString).png]]\n\n"
                        if let ocr = note.drawingOCRText, !ocr.isEmpty {
                            atomicMarkdown += "**OCR Transcript:** *\(ocr)*\n\n"
                        }
                    }
                    
                    atomicMarkdown += "---\n"
                    
                    let noteFileURL = bookDirectoryURL.appendingPathComponent("\(cleanAtomicTitle).md")
                    try atomicMarkdown.write(to: noteFileURL, atomically: true, encoding: .utf8)
                    
                    atomicWikiLinks.append("- [[\(cleanAtomicTitle)]]")
                }
                
                // Write Book Index Note File (Hub)
                var hubMarkdown = "# 📖 \(cleanBookTitle)\n\n"
                if let author = bookInfo?.author {
                    hubMarkdown += "**Author:** \(author)\n"
                }
                if let series = bookInfo?.series {
                    hubMarkdown += "**Series:** [[Hub - \(series)]]\n"
                }
                hubMarkdown += "**Total Notes:** \(bookNotes.count)\n"
                hubMarkdown += "**Exported:** \(Date().formatted())\n"
                hubMarkdown += "**Tags:** #zettelkasten #book-hub\n\n---\n\n"
                hubMarkdown += "## ⚡ Linked Atomic Notes\n"
                hubMarkdown += atomicWikiLinks.joined(separator: "\n") + "\n\n---\n"
                
                let hubFileURL = tempDir.appendingPathComponent("📖 \(cleanBookTitle).md")
                try hubMarkdown.write(to: hubFileURL, atomically: true, encoding: .utf8)
            }
            
            let archiveURL = fileManager.temporaryDirectory.appendingPathComponent("InksyncPro_MindPalace.zip")
            if fileManager.fileExists(atPath: archiveURL.path) {
                try fileManager.removeItem(at: archiveURL)
            }
            
            // Use ZIPFoundation to zip the directory safely
            try fileManager.zipItem(at: tempDir, to: archiveURL)
            
            // Cleanup unzipped temp
            try? fileManager.removeItem(at: tempDir)
            
            return archiveURL
        }
        return try await task.value
    }
    
    /// Compiles all SDAnnotations into a styled HTML bundle archive
    func exportToHTMLZip(annotations: [Annotation], pdfs: [ConvertedPDF]) async throws -> URL {
        var drawingsMap: [UUID: Data] = [:]
        for ann in annotations {
            if let drawingData = ann.drawingData,
               let drawing = try? PKDrawing(data: drawingData),
               !drawing.bounds.isEmpty {
                let image = drawing.image(from: drawing.bounds, scale: 2.0)
                if let pngData = image.pngData() {
                    drawingsMap[ann.id] = pngData
                }
            }
        }
        let drawings = drawingsMap
        
        let task = Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            let tempDir = fileManager.temporaryDirectory.appendingPathComponent("HTMLExport_\(UUID().uuidString)")
            try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true, attributes: nil)
            
            let cssContent = """
            body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; background: #0f1117; color: #e2e8f0; margin: 0; padding: 40px; line-height: 1.6; }
            .container { max-width: 800px; margin: 0 auto; }
            h1 { color: #f97316; font-size: 28px; border-bottom: 2px solid #334155; padding-bottom: 12px; }
            .card { background: #1e293b; border-radius: 12px; padding: 20px; margin-bottom: 20px; border: 1px solid #334155; box-shadow: 0 4px 12px rgba(0,0,0,0.3); }
            .quote { background: #0f172a; border-left: 4px solid #f97316; padding: 12px 16px; border-radius: 4px; font-style: italic; color: #cbd5e1; margin-bottom: 12px; }
            .note-text { font-size: 15px; color: #f1f5f9; margin: 8px 0; }
            .drawing { max-width: 100%; height: auto; border-radius: 8px; border: 1px solid #475569; background: #0f172a; margin-top: 12px; }
            .meta { font-size: 12px; color: #94a3b8; display: flex; justify-content: space-between; margin-top: 12px; border-top: 1px solid #334155; padding-top: 8px; }
            .tag { background: rgba(249, 115, 22, 0.15); color: #fb923c; padding: 2px 8px; border-radius: 4px; font-size: 11px; font-weight: 600; margin-right: 6px; }
            """
            
            var html = "<!DOCTYPE html><html><head><meta charset='utf-8'><title>Inksync Pro Notes Export</title><style>\(cssContent)</style></head><body><div class='container'>"
            html += "<h1>📖 Inksync Pro Knowledge Hub</h1><p>Exported \(Date().formatted())</p>"
            
            let sorted = annotations.sorted { $0.createdAt > $1.createdAt }
            for ann in sorted {
                html += "<div class='card'>"
                if let text = ann.selectedText, !text.isEmpty {
                    html += "<div class='quote'>“\(text.replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;"))”</div>"
                }
                if let noteText = ann.noteText, !noteText.isEmpty {
                    html += "<div class='note-text'>\(noteText.replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;"))</div>"
                }
                if let pngData = drawings[ann.id] {
                    let base64 = pngData.base64EncodedString()
                    html += "<img class='drawing' src='data:image/png;base64,\(base64)' alt='Canvas Drawing' />"
                }
                html += "<div class='meta'><span>Page \(ann.pageIndex + 1)</span><span>\(ann.createdAt.formatted(date: .abbreviated, time: .shortened))</span></div>"
                html += "</div>"
            }
            html += "</div></body></html>"
            
            let htmlFile = tempDir.appendingPathComponent("InksyncPro_Notes.html")
            try html.write(to: htmlFile, atomically: true, encoding: .utf8)
            
            let archiveURL = fileManager.temporaryDirectory.appendingPathComponent("InksyncPro_HTML_Notes.zip")
            if fileManager.fileExists(atPath: archiveURL.path) { try? fileManager.removeItem(at: archiveURL) }
            try fileManager.zipItem(at: tempDir, to: archiveURL)
            try? fileManager.removeItem(at: tempDir)
            return archiveURL
        }
        return try await task.value
    }
}
