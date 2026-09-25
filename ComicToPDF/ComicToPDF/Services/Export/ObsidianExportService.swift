//
//  ObsidianExportService.swift
//  InksyncPro
//
//  Dedicated Obsidian Vault Export Engine
//  Converts Zettelkasten Knowledge Nodes, Cornell Notes, and Highlights
//  into an Obsidian-compatible Markdown vault with YAML frontmatter, [[WikiLinks]],
//  tags, and an interactive _Index.md root map.
//

import Foundation
import SwiftData
import ZIPFoundation
import PencilKit
import UIKit

@MainActor
public final class ObsidianExportService {
    public static let shared = ObsidianExportService()
    
    private init() {}
    
    /// Compiles all annotations and study cards into a complete Obsidian Vault ZIP archive
    public func exportVault(annotations: [SDAnnotation], pdfs: [SDConvertedPDF]) async throws -> URL {
        // Pre-render any attached Apple Pencil drawings to transparent PNGs
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
        
        let capturedDrawings = drawingsMap
        
        // Map DTOs to cross actor isolation safely
        let annDTOs = annotations.map { $0.toDTO() }
        let pdfDTOs = pdfs.map { $0.toDTO() }
        
        return try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let vaultDir = fm.temporaryDirectory.appendingPathComponent("InksyncPro_Obsidian_Vault_\(UUID().uuidString)")
            try fm.createDirectory(at: vaultDir, withIntermediateDirectories: true)
            
            // 1. Create attachments directory for drawings & figures
            let attachmentsDir = vaultDir.appendingPathComponent("attachments")
            try fm.createDirectory(at: attachmentsDir, withIntermediateDirectories: true)
            for (id, pngData) in capturedDrawings {
                let fileURL = attachmentsDir.appendingPathComponent("drawing_\(id.uuidString).png")
                try pngData.write(to: fileURL)
            }
            
            // 2. Map books and series
            var pdfMap: [UUID: (name: String, series: String?, author: String?)] = [:]
            for pdf in pdfDTOs {
                pdfMap[pdf.id] = (
                    name: pdf.name,
                    series: pdf.metadata.series?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? pdf.metadata.series : nil,
                    author: pdf.metadata.author?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? pdf.metadata.author : nil
                )
            }
            
            // 3. Build Index Root File (_Index.md)
            var indexContent = """
            ---
            title: "InksyncPro Vault Index"
            type: "MOC"
            created: "\(ISO8601DateFormatter().string(from: Date()))"
            tags: [MOC, Index, InksyncPro]
            ---
            
            # InksyncPro Digital Atelier — Knowledge Graph Index
            
            Welcome to your unified Zettelkasten study archive.
            
            ## Books & Sources
            
            """
            
            let grouped = Dictionary(grouping: annDTOs) { $0.pdfID }
            var allNodeWikiLinks: [String] = []
            
            for (pdfID, notes) in grouped {
                let book = pdfMap[pdfID]
                let bookTitle = book?.name ?? notes.first?.readwiseBookTitle ?? "Book_\(pdfID.uuidString.prefix(6))"
                let safeFolderTitle = bookTitle.components(separatedBy: CharacterSet.alphanumerics.inverted.subtracting(.whitespaces)).joined().replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
                
                let targetFolder: URL
                if let series = book?.series {
                    let safeSeries = series.components(separatedBy: CharacterSet.alphanumerics.inverted.subtracting(.whitespaces)).joined().replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
                    targetFolder = vaultDir.appendingPathComponent(safeSeries)
                } else {
                    targetFolder = vaultDir.appendingPathComponent(safeFolderTitle)
                }
                
                try fm.createDirectory(at: targetFolder, withIntermediateDirectories: true)
                indexContent += "### \(bookTitle)\n"
                
                for note in notes {
                    let nodeTitle: String = {
                        if let customTitle = note.readwiseBookTitle, !customTitle.isEmpty {
                            return "\(customTitle) — p\(note.pageIndex + 1)"
                        }
                        if let quote = note.selectedText, !quote.isEmpty {
                            let prefix = String(quote.prefix(32)).components(separatedBy: CharacterSet.alphanumerics.inverted.subtracting(.whitespaces)).joined().trimmingCharacters(in: .whitespacesAndNewlines)
                            return prefix.isEmpty ? "Note_p\(note.pageIndex + 1)_\(note.id.uuidString.prefix(4))" : "\(prefix) (p\(note.pageIndex + 1))"
                        }
                        return "Note_p\(note.pageIndex + 1)_\(note.id.uuidString.prefix(4))"
                    }()
                    
                    let safeFilename = "\(nodeTitle).md"
                    let fileURL = targetFolder.appendingPathComponent(safeFilename)
                    
                    var noteContent = """
                    ---
                    id: "\(note.id.uuidString)"
                    title: "\(nodeTitle)"
                    book: "\(bookTitle)"
                    page: \(note.pageIndex + 1)
                    date: "\(ISO8601DateFormatter().string(from: note.createdAt))"
                    tags: \(note.tags ?? ["literature-note"])
                    ---
                    
                    # \(nodeTitle)
                    
                    """
                    
                    if let quote = note.selectedText, !quote.isEmpty {
                        noteContent += "> \(quote)\n\n"
                    }
                    
                    if let thoughts = note.noteText, !thoughts.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        noteContent += "## Thoughts & Insights\n\n\(thoughts)\n\n"
                    }
                    
                    if let ocr = note.drawingOCRText, !ocr.isEmpty {
                        noteContent += "## Handwritten Notes (OCR)\n\n\(ocr)\n\n"
                    }
                    
                    if capturedDrawings[note.id] != nil {
                        noteContent += "## Sketch / Ink\n\n![[attachments/drawing_\(note.id.uuidString).png]]\n\n"
                    }
                    
                    noteContent += "## References\n- Source: [[_Index|\(bookTitle)]], Page \(note.pageIndex + 1)\n"
                    
                    try noteContent.write(to: fileURL, atomically: true, encoding: .utf8)
                    
                    let wikiLink = "[[\(nodeTitle)]]"
                    allNodeWikiLinks.append(wikiLink)
                    indexContent += "- \(wikiLink)\n"
                }
                
                indexContent += "\n"
            }
            
            // Write Index file
            let indexURL = vaultDir.appendingPathComponent("_Index.md")
            try indexContent.write(to: indexURL, atomically: true, encoding: .utf8)
            
            // 4. Archive entire folder as a ZIP file
            let zipURL = fm.temporaryDirectory.appendingPathComponent("Obsidian_Vault_\(UUID().uuidString).zip")
            try? fm.removeItem(at: zipURL)
            try fm.zipItem(at: vaultDir, to: zipURL, shouldKeepParent: false)
            
            // Clean up raw unzipped temp directory
            try? fm.removeItem(at: vaultDir)
            
            return zipURL
        }.value
    }
}
