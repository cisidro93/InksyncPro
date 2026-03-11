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
        let cleaned = stripCommonArtifacts(from: base)

        // --- Pass 1: Explicit keywords (highest confidence) ---
        let keywordPatterns: [(pattern: String, confidence: DetectionResult.Confidence)] = [
            // "One Piece Volume 01" / "v01" / "Vol. 1"
            (#"^(.+?)\s+(?:v(?:ol(?:ume)?)?\.?\s*)(\d+)"#, .high),
            // "Berserk Chapter 001" / "ch 01" / "Ch. 3"
            (#"^(.+?)\s+(?:ch(?:apter)?\.?\s*)(\d+)"#, .high),
            // "Title - 001" (dash separator)
            (#"^(.+?)\s*-\s*(\d{2,4})$"#, .high),
            // "Title_001" (underscore separator)
            (#"^(.+?)_(\d{2,4})$"#, .medium),
            // "Title.001" or "Title.01" (dot separator, but only if very end)
            (#"^(.+?)\.(\d{2,4})$"#, .medium),
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

        // --- Pass 3: Return the whole cleaned string (low confidence) ---
        let normalized = cleaned
            .components(separatedBy: CharacterSet.letters.inverted.union(.decimalDigits))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)

        return DetectionResult(
            seriesName: normalized.isEmpty ? cleaned : normalized,
            issueNumber: nil,
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
        let seriesName = String(string[seriesRange])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: ".", with: " ")

        var issueNumber: Int?
        if match.numberOfRanges >= 3, let numRange = Range(match.range(at: 2), in: string) {
            issueNumber = Int(string[numRange])
        }

        guard !seriesName.isEmpty else { return nil }

        return DetectionResult(seriesName: seriesName, issueNumber: issueNumber, confidence: confidence)
    }
}
