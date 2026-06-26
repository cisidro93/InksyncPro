import Foundation

struct ParsedFilenameMetadata: Sendable, Equatable {
    var seriesName: String
    var issueNumber: String?
    var volumeNumber: String?
    var year: String?
    var parts: String?
}

struct SeriesHeuristicsMatcher: Sendable {
    static let shared = SeriesHeuristicsMatcher()
    
    // Regular expression definitions
    private static let yearRegex = try? NSRegularExpression(pattern: "\\b(19|20)\\d{2}\\b")
    private static let volumeRegex = try? NSRegularExpression(pattern: "(?i)\\b(?:vol|volume|v)\\.?\\s*(\\d+|[ivxldm]+)\\b")
    private static let issueRegex = try? NSRegularExpression(pattern: "(?i)(?:#|no|issue|ch|chapter|\\b)\\s*(\\d+(?:\\.\\d+)?)\\b")
    private static let partRegex = try? NSRegularExpression(pattern: "(?i)\\b(?:part|pt)\\.?\\s*(\\d+)\\b")
    
    /// Parses a filename to extract structured comic metadata.
    func parse(filename: String) -> ParsedFilenameMetadata {
        // Strip file extension
        let cleanName = (filename as NSString).deletingPathExtension
        
        var year: String?
        var volume: String?
        var issue: String?
        var part: String?
        
        let range = NSRange(cleanName.startIndex..., in: cleanName)
        
        // 1. Extract Year (e.g. (2020) or 1999)
        if let yearMatch = Self.yearRegex?.firstMatch(in: cleanName, options: [], range: range),
           let yearRange = Range(yearMatch.range(at: 0), in: cleanName) {
            year = String(cleanName[yearRange])
        }
        
        // 2. Extract Volume (e.g. Vol 2, v03, Vol. IV)
        if let volMatch = Self.volumeRegex?.firstMatch(in: cleanName, options: [], range: range),
           let volRange = Range(volMatch.range(at: 1), in: cleanName) {
            volume = String(cleanName[volRange])
        }
        
        // 3. Extract Part (e.g. Part 1, Pt. 2)
        if let partMatch = Self.partRegex?.firstMatch(in: cleanName, options: [], range: range),
           let partRange = Range(partMatch.range(at: 1), in: cleanName) {
            part = String(cleanName[partRange])
        }
        
        // 4. Extract Issue/Chapter Number (prioritize hash tags or explicit label sequences)
        // We will scan for occurrences that aren't the year or volume number.
        if let issueMatches = Self.issueRegex?.matches(in: cleanName, options: [], range: range) {
            for match in issueMatches {
                guard let valRange = Range(match.range(at: 1), in: cleanName) else { continue }
                let val = String(cleanName[valRange])
                // Make sure it doesn't match the year or volume we extracted
                if val == year || val == volume || val == part {
                    continue
                }
                issue = val
                break
            }
        }
        
        // 5. Clean up Series Name by removing extracted metadata, brackets, parentheses, and trailing spaces/punctuation
        var seriesName = cleanName
        
        // Remove year and volume matching patterns entirely from the name
        if let yearMatch = Self.yearRegex?.firstMatch(in: seriesName, options: [], range: NSRange(seriesName.startIndex..., in: seriesName)) {
            if let r = Range(yearMatch.range, in: seriesName) {
                seriesName.removeSubrange(r)
            }
        }
        
        if let volMatch = Self.volumeRegex?.firstMatch(in: seriesName, options: [], range: NSRange(seriesName.startIndex..., in: seriesName)) {
            if let r = Range(volMatch.range, in: seriesName) {
                seriesName.removeSubrange(r)
            }
        }
        
        if let partMatch = Self.partRegex?.firstMatch(in: seriesName, options: [], range: NSRange(seriesName.startIndex..., in: seriesName)) {
            if let r = Range(partMatch.range, in: seriesName) {
                seriesName.removeSubrange(r)
            }
        }
        
        // Strip issue tags (e.g., #24)
        if let issueMatch = Self.issueRegex?.firstMatch(in: seriesName, options: [], range: NSRange(seriesName.startIndex..., in: seriesName)) {
            if let r = Range(issueMatch.range, in: seriesName) {
                seriesName.removeSubrange(r)
            }
        }
        
        // Remove empty brackets and parentheses
        seriesName = seriesName
            .replacingOccurrences(of: "()", with: "")
            .replacingOccurrences(of: "[]", with: "")
            .replacingOccurrences(of: "{}", with: "")
            .replacingOccurrences(of: "( )", with: "")
            .replacingOccurrences(of: "[ ]", with: "")
        
        // Normalize whitespaces and clean up punctuation
        seriesName = seriesName
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-_,. #")))
            
        // Double space cleanup
        while seriesName.contains("  ") {
            seriesName = seriesName.replacingOccurrences(of: "  ", with: " ")
        }
        
        if seriesName.isEmpty {
            seriesName = cleanName
        }
        
        return ParsedFilenameMetadata(
            seriesName: seriesName,
            issueNumber: issue,
            volumeNumber: volume,
            year: year,
            parts: part
        )
    }
    
    /// Normalizes a series title string for comparison.
    func normalize(_ string: String) -> String {
        return string
            .lowercased()
            .folding(options: .diacriticInsensitive, locale: .current)
            .replacingOccurrences(of: "&", with: "and")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
    
    /// Computes Levenshtein distance between two strings.
    func levenshteinSimilarity(between a: String, and b: String) -> Double {
        let normA = normalize(a)
        let normB = normalize(b)
        
        let aCount = normA.count
        let bCount = normB.count
        guard aCount > 0 && bCount > 0 else { return 0.0 }
        
        if normA == normB { return 1.0 }
        
        var matrix = [[Int]](repeating: [Int](repeating: 0, count: bCount + 1), count: aCount + 1)
        
        for i in 0...aCount { matrix[i][0] = i }
        for j in 0...bCount { matrix[0][j] = j }
        
        for i in 1...aCount {
            let indexA = normA.index(normA.startIndex, offsetBy: i - 1)
            for j in 1...bCount {
                let indexB = normB.index(normB.startIndex, offsetBy: j - 1)
                
                if normA[indexA] == normB[indexB] {
                    matrix[i][j] = matrix[i - 1][j - 1]
                } else {
                    matrix[i][j] = min(
                        matrix[i - 1][j] + 1,    // deletion
                        matrix[i][j - 1] + 1,    // insertion
                        matrix[i - 1][j - 1] + 1 // substitution
                    )
                }
            }
        }
        
        let distance = Double(matrix[aCount][bCount])
        let maxLen = Double(max(aCount, bCount))
        return (maxLen - distance) / maxLen
    }
}
