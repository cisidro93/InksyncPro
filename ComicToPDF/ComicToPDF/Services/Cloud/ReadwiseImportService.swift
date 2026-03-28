import Foundation
import SwiftData

/// Phase 31: Native Readwise CSV Parsing Engine
/// Reads Readwise export CSVs (Highlight, Title, Author, URL, Note) into native `SDAnnotation` records.
class ReadwiseImportService {
    static let shared = ReadwiseImportService()
    
    /// Parses a standard Readwise highlights CSV and injects it securely into the active SwiftData context.
    func importReadwiseCSV(from url: URL, context: ModelContext) async throws -> Int {
        guard let data = try? Data(contentsOf: url),
              let content = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "ReadwiseImport", code: 1, userInfo: [NSLocalizedDescriptionKey: "Malformed Text-Encoding. Expected UTF-8."])
        }
        
        // Simple synchronous CSV block parser to avoid external package dependencies
        let rows = parseCSV(content)
        guard rows.count > 1 else { return 0 } // No headers or data
        
        // Sanitize headers heavily: Strip Byte-Order Marks (\uFEFF) explicitly
        let headers = rows[0].map { 
            let bomStripped = $0.replacingOccurrences(of: "\u{FEFF}", with: "")
            return bomStripped.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) 
        }
        
        Logger.shared.log("Readwise Sync: Parsed \(rows.count - 1) total rows. Found Headers: \(headers.joined(separator: ", "))", category: "Import")
        
        guard let highlightIdx = headers.firstIndex(of: "highlight") ?? headers.firstIndex(of: "highlights"),
              let titleIdx = headers.firstIndex(of: "title") ?? headers.firstIndex(of: "book title") else {
            Logger.shared.log("Readwise Sync [ERROR]: Could not find 'highlight' or 'title' columns in CSV. Raw headers: \(headers)", category: "Import", type: .error)
            throw NSError(domain: "ReadwiseImport", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid Readwise CSV Format. Missing 'highlight' or 'title' columns."])
        }
        
        let noteIdx = headers.firstIndex(of: "note") ?? headers.firstIndex(of: "notes")
        let authorIdx = headers.firstIndex(of: "author") ?? headers.firstIndex(of: "book author")
        Logger.shared.log("Readwise Sync: Column Indexes mapped successfully [Highlight: \(highlightIdx), Title: \(titleIdx)]", category: "Import", type: .success)
        
        var importedCount = 0
        
        // Background loop ingestion
        var skippedCount = 0
        for i in 1..<rows.count {
            let row = rows[i]
            if row.count <= max(highlightIdx, titleIdx) { 
                skippedCount += 1
                continue 
            }
            
            let highlightText = row[highlightIdx].trimmingCharacters(in: .whitespacesAndNewlines)
            let bookTitle = row[titleIdx].trimmingCharacters(in: .whitespacesAndNewlines)
            
            if highlightText.isEmpty || bookTitle.isEmpty { 
                skippedCount += 1
                continue 
            }
            
            let noteText = (noteIdx != nil && row.count > noteIdx!) ? row[noteIdx!].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            let author = (authorIdx != nil && row.count > authorIdx!) ? row[authorIdx!].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            
            // Generate a synthetic PDF ID acting as the aggregate bucket for this external book.
            let syntheticPDFID = "readwise_\(bookTitle.hashValue)"
            
            let annotation = SDAnnotation(
                id: UUID(),
                pdfID: syntheticPDFID,
                pageIndex: 0,
                text: highlightText,
                note: noteText.isEmpty ? nil : noteText,
                isReadwiseImport: true,
                readwiseBookTitle: bookTitle,
                readwiseAuthor: author,
                createdAt: Date()
            )
            
            context.insert(annotation)
            importedCount += 1
        }
        
        try context.save()
        Logger.shared.log("Readwise Sync: Successfully imported \(importedCount) records. Skipped \(skippedCount) malformed rows.", category: "Import", type: .success)
        return importedCount
    }
    
    /// A robust native CSV tokenizer handling quoted commas
    private func parseCSV(_ text: String) -> [[String]] {
        var result: [[String]] = []
        var currentRow: [String] = []
        var currentField = ""
        var inQuotes = false
        
        let characters = Array(text)
        var i = 0
        
        while i < characters.count {
            let char = characters[i]
            
            if char == "\"" {
                if inQuotes && i + 1 < characters.count && characters[i + 1] == "\"" {
                    // Escaped quote
                    currentField.append("\"")
                    i += 1
                } else {
                    inQuotes.toggle()
                }
            } else if char == "," && !inQuotes {
                currentRow.append(currentField)
                currentField = ""
            } else if (char == "\r" || char == "\n") && !inQuotes {
                if char == "\r" && i + 1 < characters.count && characters[i + 1] == "\n" {
                    i += 1
                }
                currentRow.append(currentField)
                result.append(currentRow)
                currentRow = []
                currentField = ""
            } else {
                currentField.append(char)
            }
            i += 1
        }
        
        if !currentField.isEmpty || !currentRow.isEmpty {
            currentRow.append(currentField)
            result.append(currentRow)
        }
        
        return result
    }
}
