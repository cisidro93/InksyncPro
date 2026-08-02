import Foundation
import SwiftData
import NaturalLanguage

/// Zettelkasten Auto-Linker Engine
/// Analyzes keywords, topics, semantic embeddings, and annotations across all books in the library
/// to automatically discover and suggest interconnected knowledge links.
struct ZettelkastenConnection: Identifiable, Hashable, Equatable {
    var id: UUID { targetAnnotationID }
    let sourceAnnotationID: UUID
    let targetAnnotationID: UUID
    let targetAnnotation: Annotation?
    let score: Double
    let matchedKeywords: [String]
    let reason: String
    
    static func == (lhs: ZettelkastenConnection, rhs: ZettelkastenConnection) -> Bool {
        lhs.id == rhs.id
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

@MainActor
final class ZettelkastenAutoLinker {
    static let shared = ZettelkastenAutoLinker()
    
    private let wordEmbedding = NLEmbedding.wordEmbedding(for: .english)
    
    private init() {}
    
    /// Stop-words to exclude during keyword extraction
    private let stopWords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "in", "on", "at", "to", "for",
        "of", "with", "by", "from", "up", "about", "into", "over", "after",
        "is", "are", "was", "were", "be", "been", "being", "have", "has", "had",
        "it", "its", "this", "that", "these", "those", "you", "he", "she", "they",
        "this", "which", "there", "their", "what", "when", "where", "how", "who"
    ]
    
    /// Find suggested related notes across other books for a target SDAnnotation
    func discoverConnections(for source: SDAnnotation, in allAnnotations: [SDAnnotation]) -> [ZettelkastenConnection] {
        let dtoSource = source.toDTO()
        let dtoAll = allAnnotations.map { $0.toDTO() }
        return discoverConnections(for: dtoSource, in: dtoAll)
    }
    
    /// Find suggested related notes across other books for a target Annotation
    func discoverConnections(for source: Annotation, in allAnnotations: [Annotation]) -> [ZettelkastenConnection] {
        let sourceKeywords = extractKeywords(from: source)
        guard !sourceKeywords.isEmpty else { return [] }
        
        var connections: [ZettelkastenConnection] = []
        
        for candidate in allAnnotations {
            // Ignore same annotation
            guard candidate.id != source.id else { continue }
            
            let candidateKeywords = extractKeywords(from: candidate)
            let commonKeywords = sourceKeywords.intersection(candidateKeywords)
            
            // Check semantic embedding similarity if no direct keyword match
            var semanticScore = 0.0
            var semanticMatches: [String] = []
            
            if let embedding = wordEmbedding {
                for kw1 in sourceKeywords.prefix(8) {
                    for kw2 in candidateKeywords.prefix(8) {
                        let distance = embedding.distance(between: kw1, and: kw2)
                        if distance < 0.75 && kw1 != kw2 {
                            semanticScore += (1.0 - distance) * 1.2
                            semanticMatches.append("\(kw1) ≈ \(kw2)")
                        }
                    }
                }
            }
            
            let directKeywordScore = Double(commonKeywords.count) * 1.5
            let isCrossBook = candidate.pdfID != source.pdfID || candidate.readwiseBookTitle != source.readwiseBookTitle
            let crossBookBonus = isCrossBook ? 2.0 : 0.5
            
            let totalScore = directKeywordScore + semanticScore + crossBookBonus
            
            if totalScore >= 1.8 {
                let matchedList = Array(commonKeywords).sorted() + Array(Set(semanticMatches)).prefix(3)
                let primaryReason: String
                if !commonKeywords.isEmpty && isCrossBook {
                    primaryReason = "Cross-Book Concept Link (\(commonKeywords.count) shared keywords)"
                } else if !semanticMatches.isEmpty {
                    primaryReason = "Semantic Similarity (Natural Language Vector)"
                } else if isCrossBook {
                    primaryReason = "Cross-Book Related Topic"
                } else {
                    primaryReason = "Keyword Overlap (\(commonKeywords.count) terms)"
                }
                
                connections.append(
                    ZettelkastenConnection(
                        sourceAnnotationID: source.id,
                        targetAnnotationID: candidate.id,
                        targetAnnotation: candidate,
                        score: totalScore,
                        matchedKeywords: matchedList,
                        reason: primaryReason
                    )
                )
            }
        }
        
        return connections.sorted { $0.score > $1.score }
    }
    
    private func extractKeywords(from annotation: Annotation) -> Set<String> {
        var text = ""
        if let sel = annotation.selectedText { text += " " + sel }
        if let note = annotation.noteText { text += " " + note }
        if let tags = annotation.tags { text += " " + tags.joined(separator: " ") }
        if let cue = annotation.cornellCueText { text += " " + cue }
        if let sum = annotation.cornellSummaryText { text += " " + sum }
        
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 3 && !stopWords.contains($0) }
        
        return Set(words)
    }
}

