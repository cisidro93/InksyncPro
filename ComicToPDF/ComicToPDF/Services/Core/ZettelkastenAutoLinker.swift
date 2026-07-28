import Foundation
import SwiftData

/// Zettelkasten Auto-Linker Engine
/// Analyzes keywords, topics, and annotations across all books in the library
/// to automatically discover and suggest interconnected knowledge links.
struct ZettelkastenConnection: Identifiable, Hashable, Equatable {
    var id: UUID { targetAnnotation.id }
    let sourceAnnotationID: UUID
    let targetAnnotation: Annotation
    let score: Double
    let matchedKeywords: [String]
    
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
    
    private init() {}
    
    /// Stop-words to exclude during keyword extraction
    private let stopWords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "in", "on", "at", "to", "for",
        "of", "with", "by", "from", "up", "about", "into", "over", "after",
        "is", "are", "was", "were", "be", "been", "being", "have", "has", "had",
        "it", "its", "this", "that", "these", "those", "you", "he", "she", "they"
    ]
    
    /// Find suggested related notes across other books for a target annotation
    func discoverConnections(for source: Annotation, in allAnnotations: [Annotation]) -> [ZettelkastenConnection] {
        let sourceKeywords = extractKeywords(from: source)
        guard !sourceKeywords.isEmpty else { return [] }
        
        var connections: [ZettelkastenConnection] = []
        
        for candidate in allAnnotations {
            // Ignore same annotation or same book if desired
            guard candidate.id != source.id else { continue }
            
            let candidateKeywords = extractKeywords(from: candidate)
            let common = sourceKeywords.intersection(candidateKeywords)
            
            guard !common.isEmpty else { continue }
            
            // Score based on shared keyword count and text length
            let score = Double(common.count) * 1.5 + (candidate.pdfID != source.pdfID ? 2.0 : 0.5)
            
            if score >= 1.5 {
                connections.append(
                    ZettelkastenConnection(
                        sourceAnnotationID: source.id,
                        targetAnnotation: candidate,
                        score: score,
                        matchedKeywords: Array(common).sorted()
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
        
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 3 && !stopWords.contains($0) }
        
        return Set(words)
    }
}
