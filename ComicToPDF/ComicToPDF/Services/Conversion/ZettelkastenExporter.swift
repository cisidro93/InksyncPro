import Foundation
import SwiftData
import UniformTypeIdentifiers
import SwiftUI
import ZIPFoundation

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

actor ZettelkastenExporter {
    static let shared = ZettelkastenExporter()
    
    /// Compiles all SDAnnotations into an Obsidian-ready Markdown archive
    func exportToMarkdownZip(annotations: [SDAnnotation], pdfs: [SDConvertedPDF]) async throws -> URL {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent("MindPalaceExport_\(UUID().uuidString)")
        
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true, attributes: nil)
        
        let grouped = Dictionary(grouping: annotations) { ann -> String in
            // Fallback to Readwise title or exact UUID mapping to pdf.name
            if let title = ann.readwiseBookTitle { return title }
            if let matchingPDF = pdfs.first(where: { $0.id == ann.pdfID }) {
                return matchingPDF.name
            }
            return "Book_\(ann.pdfID.uuidString.prefix(6))"
        }
        
        for (bookTitle, notes) in grouped {
            var markdown = "# 📖 [[\(bookTitle)]]\n\n"
            markdown += "**Exported from InksyncPro Zettelkasten**\n"
            markdown += "**Tags:** #zettelkasten #manga_highlight #inksyncpro\n\n---\n\n"
            
            // Sort notes by date older -> newer
            let sortedNotes = notes.sorted { $0.modifiedAt < $1.modifiedAt }
            
            for note in sortedNotes {
                markdown += "### ⚡ Atomic Note\n\n"
                if let text = note.selectedText, !text.isEmpty {
                    markdown += "> \(text.replacingOccurrences(of: "\n", with: "\n> "))\n\n"
                }
                if let userNote = note.noteText, !userNote.isEmpty {
                    markdown += "**Note:** \(userNote)\n\n"
                }
                
                // Add NLP Tags
                if let tags = note.tags, !tags.isEmpty {
                    let hashedTags = tags.map { "#\($0.replacingOccurrences(of: " ", with: "_"))" }.joined(separator: ", ")
                    markdown += "🏷️ *Tags:* \(hashedTags)\n\n"
                }
                
                markdown += "---\n\n"
            }
            
            // Clean filename
            let safeTitle = bookTitle.components(separatedBy: .illegalCharacters).joined().replacingOccurrences(of: "/", with: "-")
            let fileURL = tempDir.appendingPathComponent("\(safeTitle).md")
            try markdown.write(to: fileURL, atomically: true, encoding: .utf8)
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
}
