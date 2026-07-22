import Foundation
import NaturalLanguage
import SwiftData

@MainActor
struct SemanticRecommendation: Identifiable {
    var id: UUID { annotation.id }
    let annotation: SDAnnotation
    let score: Double
}

@MainActor
final class SemanticSearchService {
    static let shared = SemanticSearchService()
    
    private let embedding = NLEmbedding.wordEmbedding(for: .english)
    
    private init() {}
    
    /// Calculates semantic similarity score (0.0 to 1.0) between target text and candidate text using NLEmbedding
    func similarity(between text1: String, and text2: String) -> Double {
        guard let embedding = embedding else { return 0.0 }
        
        let words1 = extractKeywords(from: text1)
        let words2 = extractKeywords(from: text2)
        
        guard !words1.isEmpty && !words2.isEmpty else { return 0.0 }
        
        var totalScore: Double = 0.0
        var matchCount: Double = 0.0
        
        for w1 in words1 {
            for w2 in words2 {
                if w1 == w2 {
                    totalScore += 1.0
                    matchCount += 1.0
                } else {
                    let distance = embedding.distance(between: w1, and: w2)
                    if distance < 2.0 {
                        let sim = max(0, 1.0 - distance)
                        if sim > 0.4 {
                            totalScore += sim
                            matchCount += 1.0
                        }
                    }
                }
            }
        }
        
        guard matchCount > 0 else { return 0.0 }
        return min(1.0, totalScore / matchCount)
    }
    
    /// Finds top N semantically related annotations across all books in the library
    func findRelatedAnnotations(for target: SDAnnotation, in allAnnotations: [SDAnnotation], limit: Int = 4) -> [SemanticRecommendation] {
        guard let targetText = target.selectedText ?? target.noteText, !targetText.isEmpty else { return [] }
        
        var recommendations: [SemanticRecommendation] = []
        
        for candidate in allAnnotations {
            guard candidate.id != target.id else { continue }
            guard let candidateText = candidate.selectedText ?? candidate.noteText, !candidateText.isEmpty else { continue }
            
            let score = similarity(between: targetText, and: candidateText)
            if score > 0.25 {
                recommendations.append(SemanticRecommendation(annotation: candidate, score: score))
            }
        }
        
        return Array(recommendations
            .sorted { $0.score > $1.score }
            .prefix(limit))
    }
    
    private func extractKeywords(from text: String) -> [String] {
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .joinNames]
        
        var words: [String] = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass, options: options) { tag, tokenRange in
            if let tag = tag, tag == .noun || tag == .verb || tag == .adjective {
                let word = String(text[tokenRange]).lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                if word.count > 3 { words.append(word) }
            }
            return true
        }
        return Array(Set(words))
    }
}
