import Foundation

// MARK: - Study Export Engine

/// Deterministic data exporter converting Study Cards and Notes into Bear-compatible Markdown,
/// Anki-compatible TSV flashcard decks, and full-fidelity JSON backups.
public struct StudyExportEngine: Sendable {
    
    public static let shared = StudyExportEngine()
    
    public init() {}
    
    // MARK: - Bear Markdown Exporter
    
    /// Exports cards and notes as clean Bear / Obsidian compatible Markdown.
    public func exportToMarkdown(cards: [StudyCard], notes: [StudyNote]) -> String {
        var output = "# InkSync Pro — Study Knowledge Base\n\n"
        output += "*Exported on \(Date().formatted(date: .abbreviated, time: .shortened))*\n\n"
        output += "---\n\n"
        
        // Export Cornell Study Notes
        if !notes.isEmpty {
            output += "## 📓 Cornell Study Notes\n\n"
            for note in notes {
                output += "### \(note.title)\n"
                output += "**Source:** *\(note.documentTitle)*  \n"
                if let marker = note.adlerMarker {
                    output += "**Reading Marker:** \(marker.symbol) \(marker.title)  \n"
                }
                if !note.tags.isEmpty {
                    output += "**Tags:** \(note.tags.joined(separator: " "))  \n"
                }
                output += "\n"
                
                if !note.cueColumnText.isEmpty {
                    output += "#### 🎯 Cues & Recall Prompts\n"
                    output += note.cueColumnText + "\n\n"
                }
                
                output += "#### 📝 Main Notes\n"
                output += note.mainNotesMarkdown + "\n\n"
                
                if !note.summaryText.isEmpty {
                    output += "#### 💡 Synthesis Summary\n"
                    output += "> " + note.summaryText.replacingOccurrences(of: "\n", with: "\n> ") + "\n\n"
                }
                
                output += "---\n\n"
            }
        }
        
        // Export Flashcards / Cloze Cards
        if !cards.isEmpty {
            output += "## 🃏 Active Recall Study Deck (\(cards.count) Cards)\n\n"
            for (idx, card) in cards.enumerated() {
                output += "### Card \(idx + 1)\n"
                if let marker = card.adlerTag {
                    output += "> [!adler-\(marker.rawValue)] \(marker.symbol) **\(marker.title)**\n"
                }
                output += card.markdownBody + "\n\n"
                output += "**Citation:** \(card.citation.formattedMarkdownCitation)  \n"
                if !card.tags.isEmpty {
                    output += "**Tags:** \(card.tags.joined(separator: " "))  \n"
                }
                output += "**SRS Stats:** Reps: \(card.repetitionCount) | Interval: \(card.intervalDays)d | EF: \(card.easeFactor)\n\n"
                output += "---\n\n"
            }
        }
        
        return output
    }
    
    // MARK: - Anki TSV Exporter
    
    /// Exports flashcards in Anki-compatible TSV format for direct import.
    public func exportToAnkiTSV(cards: [StudyCard]) -> String {
        var lines: [String] = []
        lines.append("#separator:Tab")
        lines.append("#html:false")
        lines.append("#tags column:3")
        
        for card in cards {
            // Convert ==cloze== to {{c1::cloze}} for Anki standard if present
            var ankiBody = card.markdownBody
            let segments = ClozeDeletionParser.shared.parseSegments(from: card.markdownBody)
            if segments.contains(where: { $0.isCloze }) {
                ankiBody = segments.map { seg in
                    if seg.isCloze {
                        return "{{c\(seg.clozeIndex)::\(seg.text)}}"
                    } else {
                        return seg.text
                    }
                }.joined()
            }
            
            let cleanBody = ankiBody
                .replacingOccurrences(of: "\t", with: " ")
                .replacingOccurrences(of: "\n", with: "<br>")
            
            let citationText = card.citation.formattedMarkdownCitation
                .replacingOccurrences(of: "\t", with: " ")
                .replacingOccurrences(of: "\n", with: "<br>")
            
            let tagsString = card.tags
                .map { $0.replacingOccurrences(of: "#", with: "").replacingOccurrences(of: "/", with: "::") }
                .joined(separator: " ")
            
            let line = "\(cleanBody)\t\(citationText)\t\(tagsString)"
            lines.append(line)
        }
        
        return lines.joined(separator: "\n")
    }
    
    // MARK: - Lossless JSON Backup
    
    public struct StudyBackupBundle: Codable, Sendable {
        public let exportDate: Date
        public let version: String
        public let cards: [StudyCard]
        public let notes: [StudyNote]
    }
    
    public func exportToJSON(cards: [StudyCard], notes: [StudyNote]) -> Data? {
        let bundle = StudyBackupBundle(
            exportDate: Date(),
            version: "1.0.0",
            cards: cards,
            notes: notes
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(bundle)
    }
}
