import Foundation
import SwiftUI

// MARK: - Cloze Segment Representation

/// Represents a tokenized segment of markdown text during active recall review.
public struct ClozeSegment: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let text: String
    public let isCloze: Bool
    public let clozeIndex: Int
    public let hint: String?
    
    public init(
        id: UUID = UUID(),
        text: String,
        isCloze: Bool,
        clozeIndex: Int = 0,
        hint: String? = nil
    ) {
        self.id = id
        self.text = text
        self.isCloze = isCloze
        self.clozeIndex = clozeIndex
        self.hint = hint
    }
}

// MARK: - Cloze Deletion Parser

/// Parses Markdown text containing `==cloze==` or Anki-style `{{c1::answer}}` tokens.
/// Conforms to Swift 6 Sendable and strict concurrency.
public struct ClozeDeletionParser: Sendable {
    
    public static let shared = ClozeDeletionParser()
    
    public init() {}
    
    /// Checks if the input text contains any cloze tokens (`==...==` or `{{c...::...}}`).
    public func hasClozeDeletions(in text: String) -> Bool {
        return text.contains("==") || (text.contains("{{c") && text.contains("::"))
    }
    
    /// Parses a markdown string into alternating regular and cloze segments.
    public func parseSegments(from text: String) -> [ClozeSegment] {
        guard hasClozeDeletions(in: text) else {
            return [ClozeSegment(text: text, isCloze: false)]
        }
        
        var segments: [ClozeSegment] = []
        var currentIndex = text.startIndex
        var clozeCounter = 1
        
        // Regex 1: Matches ==highlighted cloze==
        // Regex 2: Matches {{c1::answer}} or {{c1::answer::hint}}
        let pattern = "(==(.*?)==)|(\\{\\{c(\\d+)::(.*?)(?:::([^}]+))?\\}\\})"
        
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return [ClozeSegment(text: text, isCloze: false)]
        }
        
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: nsRange)
        
        for match in matches {
            guard let matchRange = Range(match.range, in: text) else { continue }
            
            // Text before match
            if currentIndex < matchRange.lowerBound {
                let leadingText = String(text[currentIndex..<matchRange.lowerBound])
                if !leadingText.isEmpty {
                    segments.append(ClozeSegment(text: leadingText, isCloze: false))
                }
            }
            
            // Check Match Type
            let matchString = String(text[matchRange])
            if matchString.hasPrefix("==") && matchString.hasSuffix("==") {
                // `==answer==`
                let inner = matchString.dropFirst(2).dropLast(2)
                segments.append(ClozeSegment(
                    text: String(inner),
                    isCloze: true,
                    clozeIndex: clozeCounter
                ))
                clozeCounter += 1
            } else if matchString.hasPrefix("{{c") {
                // `{{c1::answer::optionalHint}}`
                let inner = matchString.dropFirst(2).dropLast(2) // remove {{ and }}
                let parts = inner.components(separatedBy: "::")
                let answer = parts.count > 1 ? parts[1] : ""
                let hint = parts.count > 2 ? parts[2] : nil
                let idx = Int(parts[0].dropFirst()) ?? clozeCounter
                
                segments.append(ClozeSegment(
                    text: answer,
                    isCloze: true,
                    clozeIndex: idx,
                    hint: hint
                ))
                clozeCounter += 1
            }
            
            currentIndex = matchRange.upperBound
        }
        
        // Trailing text
        if currentIndex < text.endIndex {
            let trailingText = String(text[currentIndex..<text.endIndex])
            if !trailingText.isEmpty {
                segments.append(ClozeSegment(text: trailingText, isCloze: false))
            }
        }
        
        return segments
    }
    
    /// Extracts all pure text answers that are masked inside cloze brackets.
    public func extractClozeAnswers(from text: String) -> [String] {
        return parseSegments(from: text)
            .filter { $0.isCloze }
            .map { $0.text }
    }
    
    /// Returns a prompt version of the markdown where cloze answers are replaced with `[...]` or `[hint]`.
    public func generateMaskedPrompt(from text: String, placeholder: String = "[...]") -> String {
        let segments = parseSegments(from: text)
        return segments.map { segment in
            if segment.isCloze {
                if let hint = segment.hint, !hint.isEmpty {
                    return "[\(hint)]"
                } else {
                    return placeholder
                }
            } else {
                return segment.text
            }
        }.joined()
    }
    
    /// Strips cloze syntax, leaving the clean, fully-revealed markdown string.
    public func generateRevealedText(from text: String) -> String {
        let segments = parseSegments(from: text)
        return segments.map { $0.text }.joined()
    }
}
