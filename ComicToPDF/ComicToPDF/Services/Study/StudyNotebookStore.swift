import Foundation
import SwiftUI
import Combine

// MARK: - Study Notebook Store

/// Authoritative single source of truth state manager for the Active Learning & Study Suite.
/// Isolated to `@MainActor` under Swift 6 strict concurrency.
@MainActor
public final class StudyNotebookStore: ObservableObject {
    
    public static let shared = StudyNotebookStore()
    
    // MARK: - Published State
    
    @Published public private(set) var cards: [StudyCard] = []
    @Published public private(set) var notes: [StudyNote] = []
    
    // Navigation / Filtering
    @Published public var searchQuery: String = ""
    @Published public var selectedTag: String? = nil
    @Published public var selectedAdler: AdlerMarker? = nil
    @Published public var onlyDueCards: Bool = false
    @Published public var activeNoteID: UUID? = nil
    
    // UI State
    @Published public var activePaperTemplate: VectorPaperTemplate = .cornellClassic
    
    // MARK: - Dependencies
    
    private let indexer = DeterministicStudyIndexer.shared
    private let scheduler = StudyCardScheduler.shared
    
    private let cardsStorageKey = "ink_study_cards_v1"
    private let notesStorageKey = "ink_study_notes_v1"
    
    // MARK: - Initialization
    
    public init() {
        loadPersistedData()
        if cards.isEmpty && notes.isEmpty {
            seedSampleKnowledgeBase()
        }
    }
    
    // MARK: - Computed Properties
    
    /// Filtered list of cards based on active search tokens, selected Bear tag, and Mortimer Adler marker.
    public var filteredCards: [StudyCard] {
        indexer.searchCards(
            query: searchQuery,
            in: cards,
            selectedTag: selectedTag,
            selectedAdler: selectedAdler,
            onlyDue: onlyDueCards
        )
    }
    
    /// Cards that are currently due for spaced repetition review.
    public var dueCards: [StudyCard] {
        cards.filter { $0.isDue }
    }
    
    /// Bear-style hierarchical nested tag tree with computed card & note counts.
    public var nestedTagTree: [NestedTagNode] {
        indexer.buildTagHierarchy(from: cards, notes: notes)
    }
    
    /// Count of cards for each Mortimer Adler marker.
    public var adlerMarkerCounts: [AdlerMarker: Int] {
        var counts: [AdlerMarker: Int] = [:]
        for marker in AdlerMarker.allCases {
            counts[marker] = cards.filter { $0.adlerTag == marker }.count
        }
        return counts
    }
    
    /// Currently selected study note document (if any).
    public var activeNote: StudyNote? {
        guard let id = activeNoteID else { return notes.first }
        return notes.first { $0.id == id }
    }
    
    // MARK: - Card CRUD Operations
    
    public func addCard(_ card: StudyCard) {
        cards.insert(card, at: 0)
        saveCards()
        HapticEngine.light()
        Logger.shared.log("StudyStore: Created new study card with ID \(card.id)", category: "Study")
    }
    
    public func updateCard(_ card: StudyCard) {
        if let idx = cards.firstIndex(where: { $0.id == card.id }) {
            cards[idx] = card
            saveCards()
            Logger.shared.log("StudyStore: Updated card \(card.id)", category: "Study")
        }
    }
    
    public func deleteCard(withID id: UUID) {
        cards.removeAll { $0.id == id }
        saveCards()
        HapticEngine.light()
        Logger.shared.log("StudyStore: Deleted card \(id)", category: "Study")
    }
    
    public func deleteCards(at offsets: IndexSet) {
        let targets = offsets.map { filteredCards[$0].id }
        cards.removeAll { targets.contains($0.id) }
        saveCards()
        HapticEngine.light()
    }
    
    // MARK: - Spaced Repetition Grading
    
    /// Rates a card during a review session, applying the SM-2 / FSRS algorithm and persisting changes.
    @discardableResult
    public func rateCard(withID id: UUID, rating: StudyReviewRating) -> StudyCard? {
        guard let idx = cards.firstIndex(where: { $0.id == id }) else { return nil }
        let current = cards[idx]
        let scheduled = scheduler.scheduleNextReview(for: current, rating: rating)
        cards[idx] = scheduled
        saveCards()
        return scheduled
    }
    
    // MARK: - Study Note CRUD Operations
    
    public func addNote(_ note: StudyNote) {
        notes.insert(note, at: 0)
        activeNoteID = note.id
        saveNotes()
        HapticEngine.light()
        Logger.shared.log("StudyStore: Created new Cornell study note \(note.id)", category: "Study")
    }
    
    public func updateNote(_ note: StudyNote) {
        if let idx = notes.firstIndex(where: { $0.id == note.id }) {
            notes[idx] = note
            saveNotes()
        }
    }
    
    public func deleteNote(withID id: UUID) {
        notes.removeAll { $0.id == id }
        if activeNoteID == id {
            activeNoteID = notes.first?.id
        }
        saveNotes()
        HapticEngine.light()
    }
    
    // MARK: - Citation / Annotation Ingestion
    
    /// Converts a document highlight into an active learning Study Card.
    public func createCardFromCitation(
        citation: PassageCitation,
        markdownBody: String? = nil,
        adlerTag: AdlerMarker? = nil,
        tags: [String] = []
    ) -> StudyCard {
        let body = markdownBody ?? "What is the key mechanism described below?\n\n==\(citation.highlightedText)=="
        let newCard = StudyCard(
            citation: citation,
            markdownBody: body,
            adlerTag: adlerTag,
            tags: tags,
            dueDate: Date(),
            intervalDays: 0.0,
            repetitionCount: 0,
            easeFactor: 2.5
        )
        addCard(newCard)
        return newCard
    }
    
    // MARK: - Persistence Layer
    
    private func saveCards() {
        if let encoded = try? JSONEncoder().encode(cards) {
            UserDefaults.standard.set(encoded, forKey: cardsStorageKey)
        }
    }
    
    private func saveNotes() {
        if let encoded = try? JSONEncoder().encode(notes) {
            UserDefaults.standard.set(encoded, forKey: notesStorageKey)
        }
    }
    
    private func loadPersistedData() {
        if let data = UserDefaults.standard.data(forKey: cardsStorageKey),
           let decoded = try? JSONDecoder().decode([StudyCard].self, from: data) {
            self.cards = decoded
        }
        
        if let data = UserDefaults.standard.data(forKey: notesStorageKey),
           let decoded = try? JSONDecoder().decode([StudyNote].self, from: data) {
            self.notes = decoded
            self.activeNoteID = decoded.first?.id
        }
    }
    
    // MARK: - Sample Seed Data
    
    private func seedSampleKnowledgeBase() {
        let doc1ID = UUID()
        let doc2ID = UUID()
        
        let sampleCitation1 = PassageCitation(
            documentID: doc1ID,
            documentTitle: "Principles of Neural Science",
            pageNumber: 142,
            anchorID: "synapse-plasticity-ch7",
            highlightedText: "Long-term potentiation (LTP) in the CA1 region of the hippocampus requires NMDA receptor activation."
        )
        
        let sampleCitation2 = PassageCitation(
            documentID: doc2ID,
            documentTitle: "How to Read a Book (Mortimer Adler)",
            pageNumber: 58,
            anchorID: "syntopical-reading-p3",
            highlightedText: "The active reader must ask four basic questions: What is the book about as a whole? What is being said in detail, and how? Is the book true, in whole or part? What of it?"
        )
        
        let sampleCitation3 = PassageCitation(
            documentID: doc1ID,
            documentTitle: "Principles of Neural Science",
            pageNumber: 215,
            anchorID: "action-potential-ch9",
            highlightedText: "The absolute refractory period is caused by the inactivation of voltage-gated sodium channels."
        )
        
        let card1 = StudyCard(
            citation: sampleCitation1,
            markdownBody: "In the hippocampus CA1 region, ==Long-term potentiation (LTP)== requires the activation of ==NMDA receptors==.",
            adlerTag: .coreThesis,
            tags: ["#medicine/neuroscience/synapses", "#ch7"],
            dueDate: Date(),
            intervalDays: 0.0,
            repetitionCount: 0,
            easeFactor: 2.5
        )
        
        let card2 = StudyCard(
            citation: sampleCitation2,
            markdownBody: "Mortimer Adler's four foundational reading questions:\n1. What is the book about as a whole?\n2. What is being said in detail?\n3. ==Is the book true, in whole or part?==\n4. ==What of it?== (Significance)",
            adlerTag: .insight,
            tags: ["#epistemology/reading", "#study-skills"],
            dueDate: Date(),
            intervalDays: 1.0,
            repetitionCount: 1,
            easeFactor: 2.6
        )
        
        let card3 = StudyCard(
            citation: sampleCitation3,
            markdownBody: "What physiological event causes the ==absolute refractory period== during an action potential?\n\nAnswer: ==Inactivation of voltage-gated Na+ channels==.",
            adlerTag: .question,
            tags: ["#medicine/neuroscience/electrophysiology"],
            dueDate: Date().addingTimeInterval(86400),
            intervalDays: 2.0,
            repetitionCount: 1,
            easeFactor: 2.5
        )
        
        self.cards = [card1, card2, card3]
        
        let sampleNote = StudyNote(
            documentID: doc1ID,
            documentTitle: "Principles of Neural Science",
            title: "Hippocampal Synaptic Plasticity & LTP",
            paperTemplate: .cornellClassic,
            cueColumnText: "• What triggers LTP?\n• Role of Mg2+ block?\n• Presynaptic vs Post?",
            mainNotesMarkdown: """
            ## Mechanism of Long-Term Potentiation
            
            1. High-frequency stimulation induces strong depolarization of the postsynaptic membrane.
            2. Depolarization expels the ==Mg2+ ion block== from the pore of the ==NMDA receptor==.
            3. Calcium (Ca2+) influx triggers downstream ==CaMKII and PKC kinase cascades==.
            4. Retrograde messengers (such as Nitric Oxide) facilitate increased neurotransmitter release.
            """,
            summaryText: "LTP serves as the primary cellular model for learning and memory formation in the mammalian hippocampus.",
            adlerMarker: .coreThesis,
            tags: ["#medicine/neuroscience/synapses", "#memory"],
            citations: [sampleCitation1]
        )
        
        self.notes = [sampleNote]
        self.activeNoteID = sampleNote.id
        
        saveCards()
        saveNotes()
    }
}
