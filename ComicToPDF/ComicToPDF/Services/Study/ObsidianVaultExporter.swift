import Foundation

// MARK: - Obsidian Vault Exporter

/// Exports study notes, flashcards, and citations into an Obsidian-compatible Markdown vault format,
/// featuring native Obsidian Callouts (`> [!cite]`, `> [!summary]`), YAML frontmatter metadata,
/// and clickable `inksync://open` universal deep-links.
public final class ObsidianVaultExporter: Sendable {
    
    public static let shared = ObsidianVaultExporter()
    
    public init() {}
    
    // MARK: - Individual Note Markdown Generation
    
    /// Converts a single Cornell Study Note into an Obsidian Markdown file string.
    public func exportNoteToObsidianMarkdown(_ note: StudyNote) -> String {
        let docID = note.documentID ?? UUID()
        let pageNum = note.citations.first?.pageNumber ?? 1
        let universalLink = UniversalLinkBridge.shared.generateUniversalLink(
            documentID: docID,
            pageIndex: max(0, pageNum - 1)
        )
        
        let tagsYaml = note.tags.map { "  - \($0.replacingOccurrences(of: "#", with: ""))" }.joined(separator: "\n")
        
        var md = """
        ---
        title: "\(note.title.replacingOccurrences(of: "\"", with: "\\\""))"
        document: "\(note.documentTitle.replacingOccurrences(of: "\"", with: "\\\""))"
        page: \(pageNum)
        created: \(note.createdAt.ISO8601Format())
        tags:
        \(tagsYaml.isEmpty ? "  - study-note" : tagsYaml)
        inksync_uri: "\(universalLink.absoluteString)"
        ---

        # \(note.title)
        
        > [!info] Document Reference
        > **Source:** *\(note.documentTitle)* (Page \(pageNum))  
        > [🔗 Open in InkSync Pro](\(universalLink.absoluteString))
        
        """
        
        if let marker = note.adlerMarker {
            md += """
            > [!adler] Reading Marker: \(marker.symbol) \(marker.title)
            
            """
        }
        
        if !note.cueColumnText.isEmpty {
            md += """
            ## 🎯 Recall Cues & Prompts
            \(note.cueColumnText)
            
            """
        }
        
        md += """
        ## 📝 Notes
        \(note.mainNotesMarkdown)
        
        """
        
        if !note.summaryText.isEmpty {
            md += """
            > [!summary] Key Synthesis Summary
            > \(note.summaryText.replacingOccurrences(of: "\n", with: "\n> "))
            
            """
        }
        
        return md
    }
    
    // MARK: - Aggregated Vault Exporter
    
    /// Exports all notes and flashcards into a master Obsidian workspace document.
    public func exportCompleteVaultMarkdown(notes: [StudyNote], cards: [StudyCard]) -> String {
        var master = """
        ---
        vault_title: "InkSync Pro Study Knowledge Base"
        exported_at: \(Date().ISO8601Format())
        total_notes: \(notes.count)
        total_cards: \(cards.count)
        ---
        
        # 🧠 InkSync Pro — Study Knowledge Vault
        
        ---
        
        ## 📓 Cornell Study Notes (\(notes.count))
        
        """
        
        for note in notes {
            master += exportNoteToObsidianMarkdown(note)
            master += "\n\n---\n\n"
        }
        
        if !cards.isEmpty {
            master += """
            ## 🃏 Active Recall Study Decks (\(cards.count) Flashcards)
            
            """
            
            for (idx, card) in cards.enumerated() {
                let cardLink = UniversalLinkBridge.shared.generateUniversalLink(
                    documentID: card.citation.documentID,
                    pageIndex: max(0, card.citation.pageNumber - 1)
                )
                
                let cardBlock = """
                ### Flashcard \(idx + 1)
                \(card.markdownBody)
                
                > [!cite] Source Citation
                > *\(card.citation.documentTitle)* — Page \(card.citation.pageNumber)  
                > [🔗 Open in InkSync Pro](\(cardLink.absoluteString))
                
                **Tags:** \(card.tags.joined(separator: " "))  
                **SRS Reps:** \(card.repetitionCount) | **Interval:** \(card.intervalDays) days
                
                ---
                
                """
                master += cardBlock
            }
        }
        
        return master
    }
}
