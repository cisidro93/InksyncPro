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
        
        let headers = rows[0].map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let highlightIdx = headers.firstIndex(of: "highlight") ?? headers.firstIndex(of: "highlights"),
              let titleIdx = headers.firstIndex(of: "title") ?? headers.firstIndex(of: "book title") else {
            throw NSError(domain: "ReadwiseImport", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid Readwise CSV Format. Missing 'highlight' or 'title' columns."])
        }
        
        let noteIdx = headers.firstIndex(of: "note") ?? headers.firstIndex(of: "notes")
        let authorIdx = headers.firstIndex(of: "author") ?? headers.firstIndex(of: "book author")
        
        var importedCount = 0
        
        // Background loop ingestion
        for i in 1..<rows.count {
            let row = rows[i]
            if row.count <= max(highlightIdx, titleIdx) { continue }
            
            let highlightText = row[highlightIdx].trimmingCharacters(in: .whitespacesAndNewlines)
            let bookTitle = row[titleIdx].trimmingCharacters(in: .whitespacesAndNewlines)
            if highlightText.isEmpty || bookTitle.isEmpty { continue }
            
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
