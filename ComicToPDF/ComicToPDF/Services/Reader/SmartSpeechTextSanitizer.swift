import Foundation
import CoreGraphics

/// `SmartSpeechTextSanitizer`
///
/// Studio-grade on-device text sanitizer and clutter eliminator.
/// Modeled after ElevenReader's intelligent speech parsing engine:
/// 1. Identifies and skips standalone page numbers (digits, Roman numerals, "Page X of Y", dashes).
/// 2. Filters out running headers, chapter titles, and footer artifacts based on page geometry and NLP patterns.
/// 3. Cleans inline bracketed citations (`[1]`, `[1, 2]`, `[14-16]`) so sentences flow naturally.
/// 4. Replaces or silences raw hyperlinks, DOIs, and URLs.
/// 5. Automatically rejoins hyphenated words split across line breaks (`inter-\npretation` -> `interpretation`).
/// 6. Expands common abbreviations (`Dr.`, `vs.`, `e.g.`, `i.e.`, `Fig.`, `p.`, `pp.`) for human-like prosody.
public final class SmartSpeechTextSanitizer: Sendable {
    public static let shared = SmartSpeechTextSanitizer()

    private init() {}

    // MARK: - Regex Caches (Pre-compiled for zero-latency execution)

    // Page number patterns
    private static let pureNumberRegex = try? NSRegularExpression(
        pattern: #"^\s*[-–—~•]?\s*\d{1,5}\s*[-–—~•]?\s*$"#,
        options: []
    )
    private static let pagePrefixRegex = try? NSRegularExpression(
        pattern: #"^\s*(?:page|p\.|p|pg\.)\s*[-–—~•]?\s*\d{1,5}(?:\s*(?:of|\/)\s*\d{1,5})?\s*[-–—~•]?\s*$"#,
        options: [.caseInsensitive]
    )
    private static let numberRatioRegex = try? NSRegularExpression(
        pattern: #"^\s*\d{1,5}\s*(?:of|\/)\s*\d{1,5}\s*$"#,
        options: [.caseInsensitive]
    )
    private static let romanNumeralRegex = try? NSRegularExpression(
        pattern: #"^\s*(?:page|p\.)?\s*[-–—~•]?\s*(?:x{0,3}(?:ix|iv|v?i{0,3}))\s*[-–—~•]?\s*$"#,
        options: [.caseInsensitive]
    )
    private static let headerWithPageRegex = try? NSRegularExpression(
        pattern: #"^\s*(?:\d{1,4}\s*[|/•–—]\s*.{1,40}|.{1,40}\s*[|/•–—]\s*\d{1,4})\s*$"#,
        options: []
    )

    // Clutter patterns
    private static let standaloneCitationRegex = try? NSRegularExpression(
        pattern: #"^\s*\[\s*\d{1,4}(?:\s*[,-–—]\s*\d{1,4})*\s*\]\.?\s*$"#,
        options: []
    )
    private static let standaloneUrlRegex = try? NSRegularExpression(
        pattern: #"^\s*(?:https?:\/\/|www\.|doi:)\S+\s*$"#,
        options: [.caseInsensitive]
    )
    private static let separatorSymbolsRegex = try? NSRegularExpression(
        pattern: #"^[\s\-_=*~•.·]{2,}$"#,
        options: []
    )
    private static let copyrightMetadataRegex = try? NSRegularExpression(
        pattern: #"^\s*(?:©|copyright|\(c\)|all rights reserved|isbn\s*[\d\-]+|issn\s*[\d\-]+)\b.*$"#,
        options: [.caseInsensitive]
    )

    // Inline sanitization patterns
    private static let hyphenatedLineBreakRegex = try? NSRegularExpression(
        pattern: #"(\b\p{L}+)-\s*\n\s*(\p{L}+\b)"#,
        options: []
    )
    private static let bracketedCitationRegex = try? NSRegularExpression(
        pattern: #"\[\s*\d{1,4}(?:\s*[,-–—]\s*\d{1,4})*\s*\]"#,
        options: []
    )
    private static let editorialBracketsRegex = try? NSRegularExpression(
        pattern: #"\[\s*(?:citation needed|note\s*\d+|ref\s*\d+)\s*\]"#,
        options: [.caseInsensitive]
    )
    private static let parentheticalUrlRegex = try? NSRegularExpression(
        pattern: #"\(\s*(?:see\s+)?(?:https?:\/\/|www\.)[^\s\)]+\s*\)"#,
        options: [.caseInsensitive]
    )
    private static let rawUrlRegex = try? NSRegularExpression(
        pattern: #"(?:https?:\/\/|www\.)[^\s\(\)]+"#,
        options: [.caseInsensitive]
    )
    private static let doiRegex = try? NSRegularExpression(
        pattern: #"\bdoi:\s*10\.\d{4,9}\/[-._;()/:A-Za-z0-9]+"#,
        options: [.caseInsensitive]
    )
    private static let leadingBulletRegex = try? NSRegularExpression(
        pattern: #"^[\s*•▪▫–—\-]+\s*"#,
        options: []
    )
    private static let multipleSpacesRegex = try? NSRegularExpression(
        pattern: #"[ \t]{2,}"#,
        options: []
    )
    private static let orphanedPunctuationRegex = try? NSRegularExpression(
        pattern: #"\s+([,.:;?!])"#,
        options: []
    )

    // MARK: - Clutter & Page Number Detection

    /// Returns `true` if the text or block coordinates represent filler material (page number, header, URL, citation stamp)
    /// that should be completely skipped during audio narration or removed from vector reflow.
    public func isPageNumberOrClutter(
        text: String,
        boundsInPage: CGRect? = nil,
        pageSize: CGSize? = nil
    ) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        let nsRange = NSRange(location: 0, length: trimmed.utf16.count)

        // 1. Standalone pure number check (e.g. "42", "- 42 -")
        if let regex = Self.pureNumberRegex, regex.firstMatch(in: trimmed, options: [], range: nsRange) != nil {
            return true
        }

        // 2. Page prefix or ratio check (e.g. "Page 42", "42 of 300", "p. 15")
        if let regex = Self.pagePrefixRegex, regex.firstMatch(in: trimmed, options: [], range: nsRange) != nil {
            return true
        }
        if let regex = Self.numberRatioRegex, regex.firstMatch(in: trimmed, options: [], range: nsRange) != nil {
            return true
        }

        // 3. Roman numerals check (e.g. "iv", "ix", "Page xii")
        if trimmed.count <= 14 {
            if let regex = Self.romanNumeralRegex, regex.firstMatch(in: trimmed, options: [], range: nsRange) != nil {
                return true
            }
        }

        // 4. Header with page number composite (e.g. "42 | CHAPTER THREE" or "INTRODUCTION | 5")
        if trimmed.count <= 50 {
            if let regex = Self.headerWithPageRegex, regex.firstMatch(in: trimmed, options: [], range: nsRange) != nil {
                return true
            }
        }

        // 5. Standalone citations or footnotes (e.g. "[1]", "[2, 3]")
        if let regex = Self.standaloneCitationRegex, regex.firstMatch(in: trimmed, options: [], range: nsRange) != nil {
            return true
        }

        // 6. Standalone raw URLs or DOIs
        if let regex = Self.standaloneUrlRegex, regex.firstMatch(in: trimmed, options: [], range: nsRange) != nil {
            return true
        }

        // 7. Decorative line separators (e.g. "---", "***")
        if let regex = Self.separatorSymbolsRegex, regex.firstMatch(in: trimmed, options: [], range: nsRange) != nil {
            return true
        }

        // 8. Copyright / ISBN / Publishing metadata footer
        if let regex = Self.copyrightMetadataRegex, regex.firstMatch(in: trimmed, options: [], range: nsRange) != nil {
            return true
        }

        // 9. Spatial Geometry Check (Header & Footer zones)
        if let bounds = boundsInPage, let page = pageSize, page.height > 100 {
            let headerThreshold = page.height * 0.92 // Top 8% of page
            let footerThreshold = page.height * 0.07 // Bottom 7% of page

            let isNearTop = bounds.maxY >= headerThreshold
            let isNearBottom = bounds.minY <= footerThreshold

            if isNearTop || isNearBottom {
                // In margins: short text lines are almost universally running titles or page markers
                if trimmed.count <= 50 {
                    // Check if it's all uppercase, or contains digits, or is very short
                    let hasDigits = trimmed.contains { $0.isNumber }
                    let isShortHeader = trimmed.count < 35
                    let isAllCaps = trimmed.count >= 4 && trimmed.allSatisfy { $0.isUppercase || $0.isWhitespace || $0.isPunctuation }

                    if hasDigits || isShortHeader || isAllCaps {
                        return true
                    }
                }
            }
        }

        return false
    }

    // MARK: - Natural Speech Text Sanitizer

    /// Transforms raw book text into human-sounding, audiobook-quality spoken text.
    /// - Strips bracketed citations `[1, 2]`
    /// - Cleans raw web URLs and DOIs
    /// - Reconnects line-broken hyphenated words
    /// - Expands abbreviations (`Dr.`, `vs.`, `e.g.`, `Fig.`, `p.`)
    public func sanitizeForSpeech(
        _ text: String,
        skipCitations: Bool = true,
        silenceUrls: Bool = true,
        expandAbbreviations: Bool = true
    ) -> String {
        var processed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !processed.isEmpty else { return "" }

        // 0. Sanitize publisher CMap font artifacts (e.g. thin-spaces mapped to '!', ligatures mapped to '$')
        processed = PDFSpatialParser.sanitizeExtractedText(processed)

        // 1. Rejoin words split across line breaks: "trans- \nport" -> "transport"
        if let regex = Self.hyphenatedLineBreakRegex {
            let nsRange = NSRange(location: 0, length: processed.utf16.count)
            processed = regex.stringByReplacingMatches(
                in: processed,
                options: [],
                range: nsRange,
                withTemplate: "$1$2"
            )
        }

        // 2. Strip bracketed numeric citations (e.g. "[12]", "[3, 4]", "[5-8]")
        if skipCitations {
            if let regex = Self.bracketedCitationRegex {
                let nsRange = NSRange(location: 0, length: processed.utf16.count)
                processed = regex.stringByReplacingMatches(
                    in: processed,
                    options: [],
                    range: nsRange,
                    withTemplate: ""
                )
            }
            if let regex = Self.editorialBracketsRegex {
                let nsRange = NSRange(location: 0, length: processed.utf16.count)
                processed = regex.stringByReplacingMatches(
                    in: processed,
                    options: [],
                    range: nsRange,
                    withTemplate: ""
                )
            }
        }

        // 3. Clean or silence raw URLs and DOIs
        if silenceUrls {
            // Remove parenthetical URLs completely: "(see https://example.com)" -> ""
            if let regex = Self.parentheticalUrlRegex {
                let nsRange = NSRange(location: 0, length: processed.utf16.count)
                processed = regex.stringByReplacingMatches(
                    in: processed,
                    options: [],
                    range: nsRange,
                    withTemplate: ""
                )
            }
            // Replace remaining raw URLs with natural speech
            if let regex = Self.rawUrlRegex {
                let nsRange = NSRange(location: 0, length: processed.utf16.count)
                processed = regex.stringByReplacingMatches(
                    in: processed,
                    options: [],
                    range: nsRange,
                    withTemplate: "web link"
                )
            }
            // Remove raw DOIs
            if let regex = Self.doiRegex {
                let nsRange = NSRange(location: 0, length: processed.utf16.count)
                processed = regex.stringByReplacingMatches(
                    in: processed,
                    options: [],
                    range: nsRange,
                    withTemplate: ""
                )
            }
        }

        // 4. Expand abbreviations for natural speech cadence
        if expandAbbreviations {
            processed = expandCommonAbbreviations(in: processed)
        }

        // 5. Clean up formatting and punctuation artifacts
        if let regex = Self.leadingBulletRegex {
            let nsRange = NSRange(location: 0, length: processed.utf16.count)
            processed = regex.stringByReplacingMatches(
                in: processed,
                options: [],
                range: nsRange,
                withTemplate: ""
            )
        }

        // Fix double spaces or spaces before punctuation caused by citation stripping
        if let regex = Self.orphanedPunctuationRegex {
            let nsRange = NSRange(location: 0, length: processed.utf16.count)
            processed = regex.stringByReplacingMatches(
                in: processed,
                options: [],
                range: nsRange,
                withTemplate: "$1"
            )
        }

        if let regex = Self.multipleSpacesRegex {
            let nsRange = NSRange(location: 0, length: processed.utf16.count)
            processed = regex.stringByReplacingMatches(
                in: processed,
                options: [],
                range: nsRange,
                withTemplate: " "
            )
        }

        return processed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Abbreviation Expansion

    private func expandCommonAbbreviations(in text: String) -> String {
        var str = text

        let replacements: [(pattern: String, replacement: String)] = [
            // Titles (followed by uppercase letter)
            (#"\bDr\.(?=\s+[A-Z])"#, "Doctor"),
            (#"\bMr\.(?=\s+[A-Z])"#, "Mister"),
            (#"\bMrs\.(?=\s+[A-Z])"#, "Missus"),
            (#"\bMs\.(?=\s+[A-Z])"#, "Miz"),
            (#"\bProf\.(?=\s+[A-Z])"#, "Professor"),
            (#"\bGen\.(?=\s+[A-Z])"#, "General"),
            (#"\bCol\.(?=\s+[A-Z])"#, "Colonel"),
            (#"\bCapt\.(?=\s+[A-Z])"#, "Captain"),
            (#"\bLt\.(?=\s+[A-Z])"#, "Lieutenant"),
            (#"\bSgt\.(?=\s+[A-Z])"#, "Sergeant"),
            (#"\bSt\.(?=\s+[A-Z])"#, "Saint"),

            // Latin & Conversational abbreviations
            (#"\bvs\.\b|\bv\.\b(?=\s+[A-Z])"#, "versus"),
            (#"\be\.g\.,?"#, "for example,"),
            (#"\bi\.e\.,?"#, "that is,"),
            (#"\betc\.\b"#, "et cetera"),
            (#"\bet\s+al\.\b"#, "and others"),
            (#"\bapprox\.\b"#, "approximately"),
            (#"\best\.\b"#, "estimated"),

            // Book & Reference terms with numbers
            (#"\bFigs?\.\s*(\d+)"#, "Figure $1"),
            (#"\bpp?\.\s*(\d+)"#, "page $1"),
            (#"\bch\.\s*(\d+)|\bchap\.\s*(\d+)"#, "chapter $1$2"),
            (#"\bvol\.\s*(\d+)"#, "volume $1"),
            (#"\bno\.\s*(\d+)"#, "number $1"),
            (#"\bsec\.\s*(\d+)|\bsect\.\s*(\d+)"#, "section $1$2")
        ]

        for item in replacements {
            if let regex = try? NSRegularExpression(pattern: item.pattern, options: []) {
                let range = NSRange(location: 0, length: str.utf16.count)
                str = regex.stringByReplacingMatches(in: str, options: [], range: range, withTemplate: item.replacement)
            }
        }

        return str
    }
}
