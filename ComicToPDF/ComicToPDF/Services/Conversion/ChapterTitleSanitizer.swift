import Foundation

// MARK: - Chapter Title Sanitizer
// Synthesized for InksyncPro Omnibus & Merged Volume Studio.
// Cleanly extracts, normalizes, and titles chapters from raw file names and metadata,
// stripping scanner tags, bracketed noise, and formatting clean chapter headers for Kindle & in-app TOC.

public struct ChapterTitleSanitizer: Sendable {

    public enum TitleFormatPreset: String, CaseIterable, Identifiable, Sendable {
        case smartClean = "Smart Clean"
        case numberedChapters = "Numbered (Chapter N)"
        case rawFilename = "File Name"
        case custom = "Custom"

        public var id: String { rawValue }
    }

    /// Cleans a raw filename or title into a publication-grade TOC chapter title.
    /// Example: `[ScanGroup] Evangelion - c008 - The Beast [Digital].cbz` -> `Chapter 8: The Beast`
    public static func sanitize(
        filename: String,
        fallbackIndex: Int? = nil,
        seriesName: String? = nil,
        preset: TitleFormatPreset = .smartClean
    ) -> String {
        switch preset {
        case .numberedChapters:
            let idx = (fallbackIndex ?? 0) + 1
            return "Chapter \(idx)"

        case .rawFilename:
            let base = (filename as NSString).deletingPathExtension
            return base.trimmingCharacters(in: .whitespacesAndNewlines)

        case .custom:
            return sanitizeSmart(filename: filename, fallbackIndex: fallbackIndex, seriesName: seriesName)

        case .smartClean:
            return sanitizeSmart(filename: filename, fallbackIndex: fallbackIndex, seriesName: seriesName)
        }
    }

    private static func sanitizeSmart(
        filename: String,
        fallbackIndex: Int?,
        seriesName: String?
    ) -> String {
        var text = (filename as NSString).deletingPathExtension

        // 1. Remove bracketed scanner / release tags e.g. [Digital], [1080p], [Scanlator]
        text = text.replacingOccurrences(of: #"\[[^\]]*\]"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\([^\)]*(?:digital|webrip|scan|rip|v\d+)[^\)]*\)"#, with: " ", options: [.regularExpression, .caseInsensitive])

        // 2. Replace underscores, dots, and multiple dashes with clean spaces
        text = text.replacingOccurrences(of: "_", with: " ")
        text = text.replacingOccurrences(of: #"\s*-\s*"#, with: " - ", options: .regularExpression)

        // 3. Remove series prefix if present at start
        if let series = seriesName?.trimmingCharacters(in: .whitespacesAndNewlines), !series.isEmpty {
            let escapedSeries = NSRegularExpression.escapedPattern(for: series)
            text = text.replacingOccurrences(of: #"^"# + escapedSeries + #"\s*[-:]?\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
        }

        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // 4. Detect Chapter / Stage / Act / Episode patterns
        // Pattern A: e.g. "c008", "ch. 8", "chapter 8", "stage 08", "act 1", "episode 5"
        let chapterPattern = #"(?i)\b(?:c|ch|chap|chapter|stage|act|episode|issue|no)\.?\s*(\d+(?:\.\d+)?)(?:\s*[-:]\s*(.*))?$"#
        if let regex = try? NSRegularExpression(pattern: chapterPattern, options: []) {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            if let match = regex.firstMatch(in: text, options: [], range: range) {
                var prefix = "Chapter"
                if text.localizedCaseInsensitiveContains("stage") { prefix = "Stage" }
                else if text.localizedCaseInsensitiveContains("act") { prefix = "Act" }
                else if text.localizedCaseInsensitiveContains("episode") { prefix = "Episode" }

                let numRange = Range(match.range(at: 1), in: text)
                let numStr = numRange.map { String(text[$0]) } ?? ""
                let cleanNum = Int(numStr).map(String.init) ?? numStr

                if match.numberOfRanges > 2, let subtitleRange = Range(match.range(at: 2), in: text) {
                    let subtitle = String(text[subtitleRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !subtitle.isEmpty {
                        return "\(prefix) \(cleanNum): \(subtitle)"
                    }
                }
                return "\(prefix) \(cleanNum)"
            }
        }

        // Pattern B: Leading number e.g. "01 - The Beginning"
        let leadingNumPattern = #"^(\d+)\s*[-:]?\s*(.*)$"#
        if let regex = try? NSRegularExpression(pattern: leadingNumPattern, options: []) {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            if let match = regex.firstMatch(in: text, options: [], range: range) {
                let numRange = Range(match.range(at: 1), in: text)
                let numStr = numRange.map { String(text[$0]) } ?? ""
                let cleanNum = Int(numStr).map(String.init) ?? numStr

                if match.numberOfRanges > 2, let subtitleRange = Range(match.range(at: 2), in: text) {
                    let subtitle = String(text[subtitleRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !subtitle.isEmpty {
                        return "Chapter \(cleanNum): \(subtitle)"
                    }
                }
                return "Chapter \(cleanNum)"
            }
        }

        // 5. Clean up multiple spaces and return, or fallback to Chapter Index
        let cleaned = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if cleaned.isEmpty {
            let idx = (fallbackIndex ?? 0) + 1
            return "Chapter \(idx)"
        }

        return cleaned
    }
}
