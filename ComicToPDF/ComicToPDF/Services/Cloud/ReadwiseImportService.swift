import Foundation
import SwiftData
import CryptoKit

/// Readwise CSV Import Engine — maps all 11 columns from the Readwise export format.
///
/// CSV columns (from the user's actual export):
///   Highlight, Book Title, Book Author, Amazon Book ID,
///   Note, Color, Tags, Location Type, Location, Highlighted at, Document tags
///
class ReadwiseImportService {
    static let shared = ReadwiseImportService()

    func importReadwiseCSV(from url: URL, context: ModelContext) async throws -> Int {
        guard let data = try? Data(contentsOf: url) else {
            throw NSError(domain: "ReadwiseImport", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to read file data."])
        }

        // Support UTF-8 (with or without BOM), Latin-1, Windows-1252
        var content = String(data: data, encoding: .utf8)
                   ?? String(data: data, encoding: .isoLatin1)
                   ?? String(data: data, encoding: .windowsCP1252)
                   ?? ""
        if content.hasPrefix("\u{FEFF}") { content.removeFirst() } // strip BOM

        guard !content.isEmpty else {
            throw NSError(domain: "ReadwiseImport", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "File is empty or has unsupported encoding."])
        }

        let rows = parseCSV(content)
        guard rows.count > 1 else { return 0 }

        // Normalise headers: strip quotes, lowercase, trim
        let headers = rows[0].map {
            $0.replacingOccurrences(of: "\"", with: "")
              .trimmingCharacters(in: .whitespacesAndNewlines)
              .lowercased()
        }
        Logger.shared.log("Readwise: headers → \(headers.joined(separator: " | "))", category: "Import")

        // --- Column index resolution ---
        // Every alias Readwise has used across export versions is listed here.
        func col(_ candidates: String...) -> Int? {
            candidates.first(where: { headers.contains($0) }).flatMap { headers.firstIndex(of: $0) }
        }

        guard let highlightIdx = col("highlight", "highlights", "text"),
              let titleIdx     = col("book title", "title", "book_title") else {
            throw NSError(domain: "ReadwiseImport", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "CSV is missing required 'Highlight' or 'Book Title' columns."])
        }

        let authorIdx      = col("book author", "author", "book_author")
        let amazonIdx      = col("amazon book id", "amazon_book_id", "asin", "url")
        let noteIdx        = col("note", "notes")
        let colorIdx       = col("color", "highlight_color", "colour")
        let tagsIdx        = col("tags", "tag")
        let locTypeIdx     = col("location type", "location_type")
        let locationIdx    = col("location")
        let highlightedIdx = col("highlighted at", "highlighted_at", "date", "created_at", "created", "added")
        let docTagsIdx     = col("document tags", "document_tags")

        Logger.shared.log("Readwise: mapped \(rows.count - 1) data rows", category: "Import")

        // Date parsers (covers every format Readwise has shipped)
        let isoFull: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withTimeZone]
            return f
        }()
        let isoBasic: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
            return f
        }()
        let fallbackFormatters: [DateFormatter] = [
            "yyyy-MM-dd HH:mm:ssZ", "yyyy-MM-dd HH:mm:ss z",
            "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd",
            "MM/dd/yyyy", "MMM d, yyyy",
            "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        ].map {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = $0
            return df
        }

        func parseDate(_ raw: String) -> Date {
            let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty else { return Date() }
            if let d = isoFull.date(from: s) ?? isoBasic.date(from: s) { return d }
            for df in fallbackFormatters { if let d = df.date(from: s) { return d } }
            Logger.shared.log("Readwise: unparseable date '\(s)' — using import time", category: "Import", type: .warning)
            return Date()
        }

        func cell(_ row: [String], _ idx: Int?) -> String {
            guard let idx, row.count > idx else { return "" }
            return row[idx].trimmingCharacters(in: .whitespacesAndNewlines)
        }

        /// Split a Readwise tag string: comma or space separated, strips leading #
        func parseTags(_ raw: String) -> [String]? {
            guard !raw.isEmpty else { return nil }
            let parts = raw.components(separatedBy: CharacterSet(charactersIn: ",;"))
                           .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "#")) }
                           .filter { !$0.isEmpty }
            return parts.isEmpty ? nil : parts
        }

        var importedCount = 0
        var skippedDuplicates = 0
        var skippedMalformed = 0

        for i in 1..<rows.count {
            let row = rows[i]

            let highlightText = cell(row, highlightIdx)
            let bookTitle     = cell(row, titleIdx)

            guard !highlightText.isEmpty, !bookTitle.isEmpty else {
                skippedMalformed += 1
                continue
            }
            guard row.count > max(highlightIdx, titleIdx) else {
                skippedMalformed += 1
                Logger.shared.log("Readwise: row \(i) has too few columns — skipping", category: "Import", type: .warning)
                continue
            }

            let noteText      = cell(row, noteIdx)
            let author        = cell(row, authorIdx)
            let amazonID      = cell(row, amazonIdx)
            let colorName     = cell(row, colorIdx)          // "yellow", "blue", etc.
            let tagsRaw       = cell(row, tagsIdx)
            let docTagsRaw    = cell(row, docTagsIdx)
            let locTypeRaw    = cell(row, locTypeIdx)
            let locationRaw   = cell(row, locationIdx)
            let dateRaw       = cell(row, highlightedIdx)

            let highlightDate = parseDate(dateRaw)
            let location      = Int(locationRaw)
            // Map location to pageIndex where possible
            let pageIndex     = location ?? 0
            let tags          = parseTags(tagsRaw)
            let docTags       = parseTags(docTagsRaw)

            // Deterministic UUID from (title + text) → re-importing same CSV is always idempotent
            let contentKey  = "\(bookTitle)||||\(highlightText)"
            let contentHash = Insecure.MD5.hash(data: Data(contentKey.utf8))
            let detID = contentHash.withUnsafeBytes { ptr -> UUID in
                let b = ptr.bindMemory(to: UInt8.self).baseAddress!
                return UUID(uuid: (b[0],b[1],b[2],b[3],b[4],b[5],b[6],b[7],
                                   b[8],b[9],b[10],b[11],b[12],b[13],b[14],b[15]))
            }

            // Deterministic pdfID from book title → all highlights for a book share one pdfID
            let titleHash = Insecure.MD5.hash(data: Data(bookTitle.utf8))
            let syntheticPDFID = titleHash.withUnsafeBytes { ptr -> UUID in
                let b = ptr.bindMemory(to: UInt8.self).baseAddress!
                return UUID(uuid: (b[0],b[1],b[2],b[3],b[4],b[5],b[6],b[7],
                                   b[8],b[9],b[10],b[11],b[12],b[13],b[14],b[15]))
            }

            // Deduplication: skip if this exact highlight already exists
            let existing = try? context.fetch(FetchDescriptor<SDAnnotation>(predicate: #Predicate { $0.id == detID }))
            if let existing, !existing.isEmpty {
                skippedDuplicates += 1
                continue
            }

            let annotation = SDAnnotation(
                id:                   detID,
                pdfID:                syntheticPDFID.uuidString,
                pageIndex:            pageIndex,
                text:                 highlightText,
                note:                 noteText,
                isReadwiseImport:     true,
                readwiseBookTitle:    bookTitle,
                readwiseAuthor:       author.isEmpty ? nil : author,
                readwiseColor:        colorName.isEmpty ? nil : colorName,
                readwiseTags:         tags,
                readwiseDocumentTags: docTags,
                readwiseAmazonID:     amazonID.isEmpty ? nil : amazonID,
                readwiseLocationType: locTypeRaw.isEmpty ? nil : locTypeRaw,
                readwiseLocation:     location,
                createdAt:            highlightDate
            )

            context.insert(annotation)
            importedCount += 1
        }

        try context.save()
        Logger.shared.log(
            "Readwise: ✅ imported \(importedCount) | skipped duplicates \(skippedDuplicates) | skipped malformed \(skippedMalformed)",
            category: "Import", type: .success
        )
        return importedCount
    }

    // MARK: - RFC 4180-compliant CSV tokeniser

    /// Handles quoted fields (including embedded commas and escaped double-quotes `""`),
    /// CRLF and LF line endings, and stray literal quotes in unquoted fields.
    private func parseCSV(_ text: String) -> [[String]] {
        var result: [[String]] = []
        var currentRow: [String] = []
        var currentField = ""
        var inQuotes = false

        let chars = Array(text)
        var i = 0

        while i < chars.count {
            let c = chars[i]

            // Skip leading whitespace in unquoted fields
            if (c == " " || c == "\t") && !inQuotes && currentField.isEmpty {
                i += 1; continue
            }

            if c == "\"" {
                if !inQuotes && currentField.isEmpty {
                    inQuotes = true
                } else if inQuotes {
                    if i + 1 < chars.count && chars[i + 1] == "\"" {
                        currentField.append("\""); i += 1   // escaped ""
                    } else {
                        inQuotes = false                    // closing quote
                    }
                } else {
                    currentField.append("\"")               // stray quote in unquoted field
                }
            } else if c == "," && !inQuotes {
                currentRow.append(currentField)
                currentField = ""
            } else if (c == "\r" || c == "\n") && !inQuotes {
                if c == "\r" && i + 1 < chars.count && chars[i + 1] == "\n" { i += 1 }
                currentRow.append(currentField)
                result.append(currentRow)
                currentRow = []
                currentField = ""
            } else {
                currentField.append(c)
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
