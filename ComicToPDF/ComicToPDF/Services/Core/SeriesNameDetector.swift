import Foundation

/// Detects a series name and issue number from a comic filename when no
/// structured metadata (ComicInfo.xml) is available.
///
/// Handles the most common naming schemes found in the wild:
///  - "One Piece v01.cbz"
///  - "Berserk Chapter 001.cbz"
///  - "Bleach_001.cbz"
///  - "[ScanlationGroup] One Piece - 001 [hash].cbz"
///  - "One.Piece.001.cbz"
///  - "One Piece - Volume 01 - Chapter 001.cbz"
struct SeriesNameDetector {

    struct DetectionResult {
        let seriesName: String
        let issueNumber: Int?
        let issueNumberString: String?
        let confidence: Confidence

        enum Confidence {
            case high   // Explicit keyword like "vol", "ch", or bracketed group removed
            case medium // Numeric suffix stripped
            case low    // Whole filename minus extension used as-is
        }
    }

    // Precompiled regular expressions for speed
    private static let noiseRegex = try! NSRegularExpression(pattern: #"\s*\(?digital|webrip|hd|scan\)?\s*"#, options: [.caseInsensitive])
    private static let orderingPrefixRegex = try! NSRegularExpression(pattern: #"^(?:0\d+|\d{1,2})[\s_.-]+(?=[a-zA-Z])"#, options: [])
    
    private static let groupBracketsRegex = try! NSRegularExpression(pattern: #"^\[.*?\]\s*"#, options: [])
    private static let trailingHashBracketsRegex = try! NSRegularExpression(pattern: #"\s*\[[\da-fA-F]{4,}\]$"#, options: [])
    private static let trailingHashParensRegex = try! NSRegularExpression(pattern: #"\s*\([\da-fA-F]{4,}\)$"#, options: [])

    private static let trailingDigitsRegex = try! NSRegularExpression(pattern: #"^(.+?)\s+(\d{1,4})$"#, options: [])
    private static let bracketContentRegex = try! NSRegularExpression(pattern: #"\[.*?\]"#, options: [])
    private static let nonYearParensRegex = try! NSRegularExpression(pattern: #"\((?!\d{4}\))[^\)]*\)"#, options: [])

    private static let compiledKeywordPatterns: [(NSRegularExpression, DetectionResult.Confidence)] = {
        let patterns: [(String, DetectionResult.Confidence)] = [
            (#"^(.+?)[\s_.-]+(?:(?:v(?:ol(?:ume)?)?|t(?:ome|omo)?|band|bd)\.?\s*)(\d+(?:\.\d+)?)"#, .high),
            (#"^(.+?)[\s_.-]+(?:(?:ch(?:apter)?|chap(?:itre)?|cap(?:[ií]tulo)?|kap(?:itel)?)\.?\s*)(\d+(?:\.\d+)?)"#, .high),
            (#"^(.+?)[\s_.-]+(?:(?:issue|book|part|livre|partie|n[uú]mero|num|nº|n\.º|nummer|nr)\.?\s*)(\d+(?:\.\d+)?)"#, .high),
            (#"^(.+?)[\s_.-]*(?:第\s*)?(\d+(?:\.\d+)?)\s*[巻卷話话]"#, .high),
            (#"^(.+?\s*\(\d{4}\))\s+(\d+)"#, .high),
            (#"^(.+?)\s*-\s*(\d{1,4}\w?)$"#, .high),
            (#"^(.+?)_(\d{1,4}\w?)$"#, .medium),
            (#"^(.+?)\.(\d{1,4})$"#, .medium),
            (#"^(.+?)\s*#\s*(\d{1,4})$"#, .high)
        ]
        return patterns.compactMap { pattern, confidence in
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
            return (regex, confidence)
        }
    }()

    /// Returns the best-guess series name and issue number for the given filename.
    static func detect(from filename: String) -> DetectionResult {
        let base = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        // Pass 1: Remove common noise prefixes/suffixes like "Digital", "HD", "(Webrip)"
        var cleaned = stripCommonArtifacts(from: base)
        
        let range1 = NSRange(cleaned.startIndex..., in: cleaned)
        cleaned = noiseRegex.stringByReplacingMatches(in: cleaned, options: [], range: range1, withTemplate: " ")
            .trimmingCharacters(in: .whitespaces)

        // Strip leading sequential/ordering prefixes like "01 ", "002 - ", "3. "
        let range2 = NSRange(cleaned.startIndex..., in: cleaned)
        cleaned = orderingPrefixRegex.stringByReplacingMatches(in: cleaned, options: [], range: range2, withTemplate: "")
            .trimmingCharacters(in: .whitespaces)

        // --- Pass 1: Explicit keywords (highest confidence) ---
        for (regex, confidence) in compiledKeywordPatterns {
            if let result = match(cleaned, regex: regex, confidence: confidence) {
                return result
            }
        }

        // --- Pass 2: Trailing number with whitespace (medium confidence) ---
        if let result = match(cleaned, regex: trailingDigitsRegex, confidence: .medium) {
            return result
        }

        // --- Pass 3: Return the whole cleaned string, keeping semantic numbers (low confidence) ---
        // Instead of destroying digits (which ruins "Spider-Man 2099"), we just replace 
        // programmatic delimiters like underscores and dots with spaces.
        let normalized = cleaned
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: ".", with: " ")
            .trimmingCharacters(in: .whitespaces)

        return DetectionResult(
            seriesName: normalized.isEmpty ? cleaned : normalized,
            issueNumber: nil,
            issueNumberString: nil,
            confidence: .low
        )
    }

    // MARK: - Private Helpers

    /// Removes bracketed scanlation group names and hash tags.
    /// e.g. "[MangaStream] One Piece - 001 [A3F2B1]" → "One Piece - 001"
    private static func stripCommonArtifacts(from string: String) -> String {
        var result = string
        
        // Remove leading [Group] brackets
        let range1 = NSRange(result.startIndex..., in: result)
        result = groupBracketsRegex.stringByReplacingMatches(in: result, options: [], range: range1, withTemplate: "")
        
        // Remove trailing [hash] brackets
        let range2 = NSRange(result.startIndex..., in: result)
        result = trailingHashBracketsRegex.stringByReplacingMatches(in: result, options: [], range: range2, withTemplate: "")
        
        // Remove trailing (hash) parens
        let range3 = NSRange(result.startIndex..., in: result)
        result = trailingHashParensRegex.stringByReplacingMatches(in: result, options: [], range: range3, withTemplate: "")
        
        return result.trimmingCharacters(in: .whitespaces)
    }

    private static func match(_ string: String, regex: NSRegularExpression, confidence: DetectionResult.Confidence) -> DetectionResult? {
        guard let match = regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)),
              match.numberOfRanges >= 2 else { return nil }

        guard let seriesRange = Range(match.range(at: 1), in: string) else { return nil }
        var seriesName = String(string[seriesRange])
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: ".", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove bracket content from series name (e.g. "[FR]", "[RAW]")
        let range1 = NSRange(seriesName.startIndex..., in: seriesName)
        seriesName = bracketContentRegex.stringByReplacingMatches(in: seriesName, options: [], range: range1, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove non-year parentheses content (e.g., "(FR)", "(Digital)")
        let range2 = NSRange(seriesName.startIndex..., in: seriesName)
        seriesName = nonYearParensRegex.stringByReplacingMatches(in: seriesName, options: [], range: range2, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Trim trailing dashes, colons, semicolons, and commas that are separators
        while seriesName.hasSuffix("-") || seriesName.hasSuffix(":") || seriesName.hasSuffix(";") || seriesName.hasSuffix(",") {
            seriesName.removeLast()
            seriesName = seriesName.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard !seriesName.isEmpty else { return nil }

        var issueNumber: Int?
        var issueNumberString: String?
        if match.numberOfRanges >= 3, let numRange = Range(match.range(at: 2), in: string) {
            let numStr = String(string[numRange])
            issueNumberString = numStr
            issueNumber = Int(numStr)
        }

        return DetectionResult(
            seriesName: seriesName,
            issueNumber: issueNumber,
            issueNumberString: issueNumberString,
            confidence: confidence
        )
    }
}
