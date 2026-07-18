import Foundation

/// Protocol that aligns evaluators with the reader mode preferences and controls
public protocol ReaderControllable: AnyObject {
    var theme: String { get set }
    var fontSize: Double { get set }
    var fontFamily: String { get set }
    var lineHeight: Double { get set }
    var isReaderModeEnabled: Bool { get set }
    
    func toggleReaderMode()
    func applyStyles()
}

/// Represents the parsed structure of a readability-cleaned chapter
public struct ReadabilityArticle {
    public let title: String
    public let content: String
    public let textContent: String
    public let excerpt: String?
}

/// Swift wrapper for stripping clutter and rendering clean article content
public class SwiftReadability {
    
    public static func parse(html: String) -> ReadabilityArticle {
        let title = extractTitle(from: html)
        let cleanContent = curlTypography(stripUnwantedTags(from: html))
        let text = stripHTML(from: cleanContent)
        
        return ReadabilityArticle(
            title: title,
            content: cleanContent,
            textContent: text,
            excerpt: String(text.prefix(200))
        )
    }
    
    private static func extractTitle(from html: String) -> String {
        let pattern = "<title>(.*?)</title>"
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: html, options: [], range: NSRange(html.startIndex..., in: html)),
           let range = Range(match.range(at: 1), in: html) {
            return String(html[range])
        }
        return "Untitled Chapter"
    }
    
    private static func stripUnwantedTags(from html: String) -> String {
        var result = html
        let tagsToRemove = [
            "<script[^>]*?>[\\s\\S]*?<\\/script>",
            "<style[^>]*?>[\\s\\S]*?<\\/style>",
            "<form[^>]*?>[\\s\\S]*?<\\/form>",
            "<iframe[^>]*?>[\\s\\S]*?<\\/iframe>",
            "<nav[^>]*?>[\\s\\S]*?<\\/nav>"
        ]
        
        for pattern in tagsToRemove {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                result = regex.stringByReplacingMatches(
                    in: result,
                    options: [],
                    range: NSRange(result.startIndex..., in: result),
                    withTemplate: ""
                )
            }
        }
        return result
    }
    
    private static func stripHTML(from html: String) -> String {
        let pattern = "<[^>]*>"
        if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
            return regex.stringByReplacingMatches(
                in: html,
                options: [],
                range: NSRange(html.startIndex..., in: html),
                withTemplate: ""
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return html
    }
    
    private static func curlTypography(_ input: String) -> String {
        var text = input
        text = text.replacingOccurrences(of: "--", with: "—")
        text = text.replacingOccurrences(of: "...", with: "…")
        
        let parts = text.components(separatedBy: "<")
        var processedParts: [String] = []
        
        for (i, part) in parts.enumerated() {
            if i == 0 {
                processedParts.append(curlQuotes(part))
            } else {
                let subparts = part.components(separatedBy: ">")
                if subparts.count > 1 {
                    let tag = subparts[0]
                    let remainingText = subparts.dropFirst().joined(separator: ">")
                    processedParts.append(tag + ">" + curlQuotes(remainingText))
                } else {
                    processedParts.append(part)
                }
            }
        }
        return processedParts.joined(separator: "<")
    }
    
    private static func curlQuotes(_ input: String) -> String {
        var result = ""
        var inDoubleQuote = false
        var inSingleQuote = false
        
        let chars = Array(input)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\"" {
                if inDoubleQuote {
                    result.append("”")
                    inDoubleQuote = false
                } else {
                    let prevChar = i > 0 ? chars[i - 1] : " "
                    if prevChar.isWhitespace || prevChar == "(" || prevChar == "[" || prevChar == "-" {
                        result.append("“")
                        inDoubleQuote = true
                    } else {
                        result.append("”")
                    }
                }
            } else if c == "'" {
                if inSingleQuote {
                    result.append("’")
                    inSingleQuote = false
                } else {
                    let prevChar = i > 0 ? chars[i - 1] : " "
                    let nextChar = i + 1 < chars.count ? chars[i + 1] : " "
                    if prevChar.isLetter && nextChar.isLetter {
                        result.append("’")
                    } else if prevChar.isWhitespace || prevChar == "(" || prevChar == "[" {
                        result.append("‘")
                        inSingleQuote = true
                    } else {
                        result.append("’")
                    }
                }
            } else {
                result.append(c)
            }
            i += 1
        }
        return result
    }
}
