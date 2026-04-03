import Foundation
import SwiftData
import CryptoKit

/// Phase 31: Native Readwise CSV Parsing Engine
/// Reads Readwise export CSVs (Highlight, Title, Author, URL, Note) into native `SDAnnotation` records.
class ReadwiseImportService {
    static let shared = ReadwiseImportService()
    
    /// Parses a standard Readwise highlights CSV and injects it securely into the active SwiftData context.
    func importReadwiseCSV(from url: URL, context: ModelContext) async throws -> Int {
        guard let data = try? Data(contentsOf: url) else {
            throw NSError(domain: "ReadwiseImport", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to access file data."])
        }
        
        // Broadly support Windows and Mac encodings natively exported by browsers
        var content = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? String(data: data, encoding: .windowsCP1252) ?? ""
        if content.hasPrefix("\u{FEFF}") { content.removeFirst() }
        
        guard !content.isEmpty else {
            throw NSError(domain: "ReadwiseImport", code: 1, userInfo: [NSLocalizedDescriptionKey: "Malformed Text-Encoding or Empty File."])
        }
        
        // Simple synchronous CSV block parser to avoid external package dependencies
        let rows = parseCSV(content)
        guard rows.count > 1 else { return 0 } // No headers or data
        
        // Sanitize headers heavily: Strip stray Quotes explicitly
        let headers = rows[0].map { 
            let sanitized = $0.replacingOccurrences(of: "\"", with: "")
                              .trimmingCharacters(in: .whitespacesAndNewlines)
            return sanitized.lowercased()
        }
        
        Logger.shared.log("Readwise Sync: Parsed \(rows.count - 1) total rows. Found Headers: \(headers.joined(separator: ", "))", category: "Import")
        
        // Attempt to find column by multiple standardized alias strings
        let mappedHighlightIdx = headers.firstIndex(of: "highlight") ?? headers.firstIndex(of: "highlights") ?? headers.firstIndex(of: "text")
        let mappedTitleIdx = headers.firstIndex(of: "title") ?? headers.firstIndex(of: "book title")
        
        guard let highlightIdx = mappedHighlightIdx, let titleIdx = mappedTitleIdx else {
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
            
            // Generate a deterministic 16-byte UUID from the book title using MD5 hashing
            // This guarantees all 900 individual highlights for matching book titles are aggregated into the SAME virtual book
            let hash = Insecure.MD5.hash(data: Data(bookTitle.utf8))
            let syntheticPDFID = hash.withUnsafeBytes { ptr -> UUID in
                let bytes = ptr.bindMemory(to: UInt8.self).baseAddress!
                return UUID(uuid: (
                    bytes[0], bytes[1], bytes[2], bytes[3],
                    bytes[4], bytes[5], bytes[6], bytes[7],
                    bytes[8], bytes[9], bytes[10], bytes[11],
                    bytes[12], bytes[13], bytes[14], bytes[15]
                ))
            }
            
            let annotation = SDAnnotation(
                id: UUID(),
                pdfID: syntheticPDFID.uuidString,
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
    
    /// A robust native CSV tokenizer handling quoted commas and inline stray literal quotes
    private func parseCSV(_ text: String) -> [[String]] {
        var result: [[String]] = []
        var currentRow: [String] = []
        var currentField = ""
        var inQuotes = false

        
        let characters = Array(text)
        var i = 0
        
        while i < characters.count {
            let char = characters[i]
            
            if (char == " " || char == "\t") && !inQuotes && currentField.isEmpty {
                i += 1
                continue
            }
            
            if char == "\"" {
                if currentField.isEmpty && !inQuotes {
                    // Safe Start of a fully quoted explicit field
                    inQuotes = true

                } else if inQuotes {
                    if i + 1 < characters.count && characters[i + 1] == "\"" {
                        // Escaped double quote specifically inside a quoted field
                        currentField.append("\"")
                        i += 1
                    } else {
                        // Formal End of a quoted field
                        inQuotes = false
                    }
                } else {
                    // Stray literal quote inside an unquoted sentence (e.g. He said "No!")
                    currentField.append("\"")
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
