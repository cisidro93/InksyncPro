//
//  HighlightExportService.swift
//  InksyncPro
//
//  Exports Book Highlights & Annotations into Markdown and Readwise-compatible CSV
//

import Foundation
import UIKit

@MainActor
final class HighlightExportService {
    static let shared = HighlightExportService()
    
    private init() {}
    
    /// Generates Markdown formatted highlights document
    func exportToMarkdown(bookTitle: String, author: String?, annotations: [SDAnnotation]) -> String {
        var md = "# Highlights from \(bookTitle)\n"
        if let author = author, !author.isEmpty {
            md += "*by \(author)*\n\n"
        } else {
            md += "\n"
        }
        
        let sorted = annotations.sorted {
            if $0.pageIndex != $1.pageIndex {
                return $0.pageIndex < $1.pageIndex
            }
            return $0.createdAt < $1.createdAt
        }
        
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        
        for ann in sorted {
            if let text = ann.selectedText, !text.isEmpty {
                md += "> \"\(text)\"\n\n"
            }
            
            var metaParts: [String] = []
            metaParts.append("Page \(ann.pageIndex + 1)")
            if let chapter = ann.chapterTitle, !chapter.isEmpty {
                metaParts.append(chapter)
            }
            metaParts.append(formatter.string(from: ann.createdAt))
            
            md += "— *\(metaParts.joined(separator: " • "))*\n"
            
            if let note = ann.noteText, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                md += "\n**Note:** \(note)\n"
            }
            
            if let symbol = ann.marginaliaSymbolRaw, !symbol.isEmpty {
                md += "\n**Marginalia:** \(symbol)\n"
            }
            
            md += "\n---\n\n"
        }
        
        return md
    }
    
    /// Generates Readwise-compatible CSV formatted highlights
    func exportToReadwiseCSV(bookTitle: String, author: String?, annotations: [SDAnnotation]) -> String {
        // Readwise Standard Columns: Highlight,Book Title,Book Author,Location,Date,Note
        var csv = "Highlight,Book Title,Book Author,Location,Date,Note\n"
        
        let formatter = ISO8601DateFormatter()
        let safeBookTitle = escapeCSV(bookTitle)
        let safeAuthor = escapeCSV(author ?? "Unknown")
        
        for ann in annotations {
            let quote = escapeCSV(ann.selectedText ?? "")
            let location = "Page \(ann.pageIndex + 1)"
            let date = formatter.string(from: ann.createdAt)
            let note = escapeCSV(ann.noteText ?? "")
            
            csv += "\(quote),\(safeBookTitle),\(safeAuthor),\(location),\(date),\(note)\n"
        }
        
        return csv
    }
    
    private func escapeCSV(_ text: String) -> String {
        let clean = text.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(clean)\""
    }
}
