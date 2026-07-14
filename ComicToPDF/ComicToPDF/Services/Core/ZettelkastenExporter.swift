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
}
