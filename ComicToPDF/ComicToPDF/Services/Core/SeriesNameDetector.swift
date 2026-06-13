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

    /// Returns the best-guess series name and issue number for the given filename.
    static func detect(from filename: String) -> DetectionResult {
        let base = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        // Pass 1: Remove common noise prefixes/suffixes like "Digital", "HD", "(Webrip)"
        var cleaned = stripCommonArtifacts(from: base)
        cleaned = cleaned.replacingOccurrences(of: #"(?i)\s*\(?digital|webrip|hd|scan\)?\s*"#, with: " ", options: .regularExpression)
                         .trimmingCharacters(in: .whitespaces)

        // --- Pass 1: Explicit keywords (highest confidence) ---
        let keywordPatterns: [(pattern: String, confidence: DetectionResult.Confidence)] = [
            // Multilingual Volume patterns (v/vol/volume/tome/tomo/band/bd)
            (#"^(.+?)[\s_.-]+(?:(?:v(?:ol(?:ume)?)?|t(?:ome|omo)?|band|bd)\.?\s*)(\d+(?:\.\d+)?)"#, .high),
            
            // Multilingual Chapter patterns (ch/chapter/chapitre/capitulo/capítulo/kapitel)
            (#"^(.+?)[\s_.-]+(?:(?:ch(?:apter)?|chap(?:itre)?|cap(?:[ií]tulo)?|kap(?:itel)?)\.?\s*)(\d+(?:\.\d+)?)"#, .high),
            
            // Multilingual Issue/Part/Number patterns (issue/book/part/livre/partie/numero/número/num/nº/n.º/nummer/nr)
            (#"^(.+?)[\s_.-]+(?:(?:issue|book|part|livre|partie|n[uú]mero|num|nº|n\.º|nummer|nr)\.?\s*)(\d+(?:\.\d+)?)"#, .high),
            
            // CJK volumes and chapters: e.g. "ワンピース第12巻", "ワンピース 12巻", "ワンピース_12話"
            (#"^(.+?)[\s_.-]*(?:第\s*)?(\d+(?:\.\d+)?)\s*[巻卷話话]"#, .high),
            
            // "Title (2024) 001" (Year in parens followed by number)
            (#"^(.+?\s*\(\d{4}\))\s+(\d+)"#, .high),
            // "Title - 001" (dash separator)
            (#"^(.+?)\s*-\s*(\d{1,4}\w?)$"#, .high),
            // "Title_001" (underscore separator)
            (#"^(.+?)_(\d{1,4}\w?)$"#, .medium),
            // "Title.001" or "Title.01" (dot separator)
            (#"^(.+?)\.(\d{1,4})$"#, .medium),
            // "Title #001" (Hash separator)
            (#"^(.+?)\s*#\s*(\d{1,4})$"#, .high)
        ]

        for (pattern, confidence) in keywordPatterns {
            if let result = match(cleaned, pattern: pattern, confidence: confidence) {
                return result
            }
        }

        // --- Pass 2: Trailing number with whitespace (medium confidence) ---
        if let result = match(cleaned, pattern: #"^(.+?)\s+(\d{1,4})$"#, confidence: .medium) {
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
        result = result.replacingOccurrences(of: #"^\[.*?\]\s*"#, with: "", options: .regularExpression)
        // Remove trailing [hash] brackets
        result = result.replacingOccurrences(of: #"\s*\[[\da-fA-F]{4,}\]$"#, with: "", options: .regularExpression)
        // Remove trailing (hash) parens
        result = result.replacingOccurrences(of: #"\s*\([\da-fA-F]{4,}\)$"#, with: "", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespaces)
    }

    private static func match(_ string: String, pattern: String, confidence: DetectionResult.Confidence) -> DetectionResult? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)),
              match.numberOfRanges >= 2 else { return nil }

        guard let seriesRange = Range(match.range(at: 1), in: string) else { return nil }
        var seriesName = String(string[seriesRange])
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: ".", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove bracket content from series name (e.g. "[FR]", "[RAW]")
        seriesName = seriesName.replacingOccurrences(of: #"\[.*?\]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove non-year parentheses content (e.g., "(FR)", "(Digital)")
        seriesName = seriesName.replacingOccurrences(of: #"\((?!\d{4}\))[^\)]*\)"#, with: "", options: .regularExpression)
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
