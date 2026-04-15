import Foundation

struct RequestedComicItem: Identifiable, Hashable {
    let id = UUID()
    var series: String
    var issueNumber: String?
    var year: String?
    var volume: String?
    var title: String?
    var readingOrder: String?
    var sortOrder: Int?
    var label: String?
    var isOptional: Bool?
    
    // Fallback original string for debugging or generic text matching
    var originalText: String
}

enum ResolutionCategory {
    case matched(ConvertedPDF)
    case suggested(ConvertedPDF)
    case missing
}

struct ResolvedEventItem: Identifiable {
    let id = UUID()
    let request: RequestedComicItem
    var resolution: ResolutionCategory
}

class SmartListImporter {
    static let shared = SmartListImporter()
    
    /// Parses a standard .cbl XML file and extracts the reading order
    func parseCBL(from url: URL) throws -> [RequestedComicItem] {
        guard let xmlString = try? readStringResiliently(from: url) else {
            throw NSError(domain: "SmartListImporter", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to read CBL file. Encoding may be corrupted."])
        }
        return parseCBLString(xmlString)
    }
    
    // MARK: - CSV AI Table Parser
    func parseCSVList(from url: URL, defaultSeriesName: String) throws -> [RequestedComicItem] {
        guard let text = try? readStringResiliently(from: url) else {
            throw NSError(domain: "SmartListImporter", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to read CSV file. Encoding may be corrupted."])
        }
        
        var items: [RequestedComicItem] = []
        let lines = text.components(separatedBy: .newlines)
        var headers: [String] = []
        var hasHeaders = false
        
        for (idx, line) in lines.enumerated() {
            let row = line.trimmingCharacters(in: .whitespaces)
            if row.isEmpty { continue }
            
            // Quote-aware CSV tokenizer (handles commas inside quoted fields)
            let columns = parseCSVRow(row)
            
            if idx == 0 {
                let testHeaders = columns.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
                if testHeaders.contains(where: { $0.contains("chapter") || $0.contains("start") || $0.contains("end") || $0.contains("issue") || $0.contains("series") || $0.contains("title") || $0.contains("reading") || $0.contains("sort") }) {
                    headers = testHeaders
                    hasHeaders = true
                    continue
                } else {
                    // No recognizable headers: fallback to basic text processing below
                    break
                }
            }
            
            var volInfo: String? = nil
            var startChap: Int? = nil
            var endChap: Int? = nil
            var parsedSeries: String? = nil
            var parsedIssue: String? = nil
            
            var parsedReadingOrder: String? = nil
            var parsedSortOrder: Int? = nil
            var parsedLabel: String? = nil
            var parsedOptional: Bool? = nil
            
            for (colIdx, value) in columns.enumerated() {
                guard colIdx < headers.count else { continue }
                let header = headers[colIdx]
                let cleanVal = value.trimmingCharacters(in: .whitespaces)
                
                if header.contains("series") || header == "title" || header == "book" || header.contains("name") {
                    parsedSeries = cleanVal
                } else if header == "issue" || header.contains("issue") || header == "number" || header == "#" {
                    parsedIssue = cleanVal
                } else if header.contains("volume") || header.contains("vol") {
                    volInfo = cleanVal
                } else if header == "start_chapter" || header == "chapter" || header == "start" {
                    startChap = Int(cleanVal)
                } else if header == "end_chapter" || header == "end" {
                    endChap = Int(cleanVal)
                } else if header == "readingorder" || header.contains("reading") || header == "event" {
                    parsedReadingOrder = cleanVal
                } else if header == "sortorder" || header == "order" || header == "sort" {
                    parsedSortOrder = Int(cleanVal)
                } else if header == "label" || header == "category" || header == "type" {
                    parsedLabel = cleanVal
                } else if header == "optional" {
                    let optStr = cleanVal.lowercased()
                    if optStr == "true" || optStr == "1" || optStr == "yes" { parsedOptional = true }
                    else if optStr == "false" || optStr == "0" || optStr == "no" { parsedOptional = false }
                }
            }
            
            if let series = parsedSeries ?? (defaultSeriesName.isEmpty ? nil : defaultSeriesName) {
                if let issue = parsedIssue {
                    items.append(RequestedComicItem(series: series, issueNumber: issue, volume: volInfo, readingOrder: parsedReadingOrder, sortOrder: parsedSortOrder, label: parsedLabel, isOptional: parsedOptional, originalText: row))
                } else if let start = startChap {
                    let end = endChap ?? start
                    for chap in start...end {
                        items.append(RequestedComicItem(series: series, issueNumber: "\(chap)", volume: volInfo, readingOrder: parsedReadingOrder, sortOrder: parsedSortOrder, label: parsedLabel, isOptional: parsedOptional, originalText: "Vol \(volInfo ?? "?"), Ch \(chap)"))
                    }
                } else {
                    items.append(RequestedComicItem(series: series, issueNumber: nil, volume: volInfo, readingOrder: parsedReadingOrder, sortOrder: parsedSortOrder, label: parsedLabel, isOptional: parsedOptional, originalText: row))
                }
            }
        }
        
        // If CSV has no recognizable table headers, evaluate it as an explicit newline text document
        if !hasHeaders && items.isEmpty {
            return try parseTextList(from: url, defaultSeriesName: defaultSeriesName)
        }
        
        return items
    }
    
    /// Parses a lightweight text/CSV/Markdown file utilizing Context Engine inheritance
    func parseTextList(from url: URL, defaultSeriesName: String) throws -> [RequestedComicItem] {
        guard let text = try? readStringResiliently(from: url) else {
            throw NSError(domain: "SmartListImporter", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to read text file. Encoding may be corrupted."])
        }
        
        var items: [RequestedComicItem] = []
        let lines = text.components(separatedBy: .newlines)
        
        var currentVolumeContext: String? = nil
        var currentSeriesContext: String = defaultSeriesName
        
        for line in lines {
            let row = line.trimmingCharacters(in: .whitespaces)
            if row.isEmpty || row.hasPrefix("//") { continue }
            
            // Markdown Headings
            if row.hasPrefix("# ") {
                let heading = String(row.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                currentSeriesContext = heading // Replace generic series name with explicitly authored H1
                continue
            } else if row.hasPrefix("## ") || row.hasPrefix("### ") || row.lowercased().hasPrefix("volume") {
                // Detect Contextually nested Volumes
                let header = row.lowercased()
                if let volRange = header.range(of: "volume") {
                    let volNumStr = String(header[volRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if let firstWord = volNumStr.components(separatedBy: .whitespaces).first {
                        currentVolumeContext = String(firstWord.filter { $0.isNumber })
                    }
                }
                continue
            }
            
            let lowerRow = row.lowercased()
            // Smart AI Range Extraction (e.g., "Ch. 1-7")
            if lowerRow.contains("ch.") || lowerRow.contains("chapter") || lowerRow.contains("issues") || lowerRow.contains("ch ") {
                let pattern = "([0-9]+)\\s*(?:-|to)\\s*([0-9]+)"
                if let rangeRange = row.range(of: pattern, options: .regularExpression) {
                    let match = String(row[rangeRange])
                    let numbers = match.components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty }
                    
                    if numbers.count == 2, let start = Int(numbers[0]), let end = Int(numbers[1]), start <= end {
                        for c in start...end {
                            items.append(RequestedComicItem(series: currentSeriesContext, issueNumber: "\(c)", volume: currentVolumeContext, originalText: "Range Expanded: \(c) from \(row)"))
                        }
                        continue
                    }
                } else {
                    let singlePattern = "(?:ch\\.|chapter|issue)\\s*#?\\s*([0-9]+)"
                    if let singleRange = lowerRow.range(of: singlePattern, options: .regularExpression) {
                        let match = String(lowerRow[singleRange])
                        let numbers = match.components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty }
                        if let first = numbers.first {
                            items.append(RequestedComicItem(series: currentSeriesContext, issueNumber: first, volume: currentVolumeContext, originalText: row))
                            continue
                        }
                    }
                }
            }
            
            // Legacy Generic Parser handling
            var series = row
            var issue: String? = nil
            
            if series.hasPrefix("- ") || series.hasPrefix("* ") {
                series = String(series.dropFirst(2))
            }
            
            if let hashRange = series.range(of: "#") {
                let sName = String(series[..<hashRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                let remaining = String(series[hashRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                let components = remaining.components(separatedBy: .whitespaces)
                
                series = sName
                issue = components.first
            } else if let lastSpace = series.lastIndex(of: " ") {
                let lastWord = String(series[series.index(after: lastSpace)...])
                if Double(lastWord) != nil {
                    issue = lastWord
                    series = String(series[..<lastSpace]).trimmingCharacters(in: .whitespaces)
                }
            }
            
            // Garbage collection check (strips typical AI rambling sentences "Note: this may vary")
            if ["note:", "this", "these", "note", "the"].contains(series.lowercased()) || (series.count > 40 && issue == nil) { continue }
            
            if series.count <= 3 && issue == nil {
                // If a line is just a bare number and we have an inherited context
                if let num = Int(series), !currentSeriesContext.isEmpty {
                    issue = "\(num)"
                    series = currentSeriesContext
                } else if series.count < 2 {
                    continue
                }
            }
            
            items.append(RequestedComicItem(series: series, issueNumber: issue, volume: currentVolumeContext, originalText: row))
        }
        
        return items
    }
    
    func resolveList(_ requests: [RequestedComicItem], against library: [ConvertedPDF]) -> [ResolvedEventItem] {
        var results: [ResolvedEventItem] = []
        
        // Track which PDFs have already been assigned to prevent duplicate assignment
        var assignedPDFIds = Set<UUID>()
        
        for req in requests {
            let reqSeriesClean = normalizeString(req.series)
            
            var bestMatch: ConvertedPDF? = nil
            var highestScore = 0
            var exactMatchFound = false
            
            for pdf in library {
                if assignedPDFIds.contains(pdf.id) { continue }
                
                let pdfSeriesClean = normalizeString(pdf.metadata.series ?? "")
                let pdfNameClean = normalizeString(pdf.name)
                
                var score = 0
                
                // 1. Precise Series matches
                if !pdfSeriesClean.isEmpty {
                    if reqSeriesClean == pdfSeriesClean { 
                        score += 50
                    } else if reqSeriesClean.hasPrefix(pdfSeriesClean) || pdfSeriesClean.hasPrefix(reqSeriesClean) {
                        score += 30
                    }
                }
                
                if score < 50 && pdfNameClean.contains(reqSeriesClean) {
                    score += 20
                }
                
                // Advanced Context: Volume Matches!
                if let reqVol = req.volume, !reqVol.isEmpty {
                    if let pdfVol = pdf.metadata.volume, pdfVol == reqVol {
                        score += 30
                    } else if pdfNameClean.contains("v\(reqVol)") || pdfNameClean.contains("vol \(reqVol)") || pdfNameClean.contains("volume \(reqVol)") || pdfNameClean.contains("v0\(reqVol)") {
                        score += 30
                    }
                }
                
                // 2. Strict Issue Number Matching
                if let reqIssue = req.issueNumber, !reqIssue.isEmpty {
                    let pdfIssue = pdf.metadata.issueNumber ?? ""
                    if reqIssue == pdfIssue {
                        score += 50
                    } else {
                        // Word-boundary testing to prevent "1" matching "10"
                        let paddedName = " \(pdfNameClean.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "-", with: " ")) "
                        let paddedIssue1 = " \(reqIssue) "
                        let paddedIssue2 = " #\(reqIssue) "
                        let paddedIssue3 = " issue \(reqIssue) "
                        let paddedIssue4 = " ch \(reqIssue) "
                        
                        if paddedName.contains(paddedIssue1) || paddedName.contains(paddedIssue2) || paddedName.contains(paddedIssue3) || paddedName.contains(paddedIssue4) {
                            score += 40
                        } else if !pdfIssue.isEmpty {
                            // Heavy Penalty for wrong issue number inside matched series
                            score -= 60
                        }
                    }
                }
                
                // Perfect hit threshold
                if score >= 100 {
                    bestMatch = pdf
                    exactMatchFound = true
                    assignedPDFIds.insert(pdf.id)
                    break
                }
                
                if score > highestScore {
                    highestScore = score
                    bestMatch = pdf
                }
            }
            
            if exactMatchFound, let pdf = bestMatch {
                results.append(ResolvedEventItem(request: req, resolution: .matched(pdf)))
            } else if highestScore >= 40, let pdf = bestMatch {
                // Above threshold but not perfect -> Suggestion
                results.append(ResolvedEventItem(request: req, resolution: .suggested(pdf)))
            } else {
                results.append(ResolvedEventItem(request: req, resolution: .missing))
            }
        }
        
        return results
    }
    
    private func normalizeString(_ str: String) -> String {
        return str.lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    // MARK: - CBL XML Parser
    private func parseCBLString(_ xmlString: String) -> [RequestedComicItem] {
        // Since Foundation XMLParser is delegate-heavy and CBL XML is very flat,
        // we can use regex/string-scanning for massive performance gains on 1000+ issue files.
        var items: [RequestedComicItem] = []
        
        let bookBlocks = xmlString.components(separatedBy: "<Book ")
        for block in bookBlocks.dropFirst() {
            let series = extractXMLAttribute(from: block, attr: "Series")
            let number = extractXMLAttribute(from: block, attr: "Number")
            let volume = extractXMLAttribute(from: block, attr: "Volume")
            
            if let s = series, !s.isEmpty {
                let req = RequestedComicItem(
                    series: s,
                    issueNumber: number,
                    year: volume,
                    originalText: "\(s) #\(number ?? "??") (\(volume ?? ""))"
                )
                items.append(req)
            }
        }
        
        return items
    }
    
    private func extractXMLAttribute(from block: String, attr: String) -> String? {
        let pattern = "\(attr)=\"([^\"]*)\""
        if let range = block.range(of: pattern, options: .regularExpression) {
            var match = String(block[range])
            match = match.replacingOccurrences(of: "\(attr)=\"", with: "")
            if match.hasSuffix("\"") { match.removeLast() }
            
            // Decode XML entities manually for titles containing &amp;
            match = match.replacingOccurrences(of: "&amp;", with: "&")
                         .replacingOccurrences(of: "&apos;", with: "'")
                         .replacingOccurrences(of: "&quot;", with: "\"")
                         .replacingOccurrences(of: "&lt;", with: "<")
                         .replacingOccurrences(of: "&gt;", with: ">")
            return match
        }
        return nil
    }
    
    /// Quote-aware CSV row tokenizer. Handles commas and escaped quotes inside quoted fields.
    private func parseCSVRow(_ row: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        let chars = Array(row)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\"" {
                if inQuotes && i + 1 < chars.count && chars[i + 1] == "\"" {
                    current.append("\""); i += 1
                } else {
                    inQuotes.toggle()
                }
            } else if c == "," && !inQuotes {
                fields.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(c)
            }
            i += 1
        }
        fields.append(current.trimmingCharacters(in: .whitespaces))
        return fields
    }
    
    private func readStringResiliently(from url: URL) throws -> String {
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            let data = try Data(contentsOf: url)
            if let str = String(data: data, encoding: .windowsCP1252) ?? String(data: data, encoding: .isoLatin1) {
                return str
            }
            throw error
        }
    }
}
