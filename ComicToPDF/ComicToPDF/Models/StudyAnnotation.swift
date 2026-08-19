import Foundation
import SwiftUI

// MARK: - Mortimer Adler Syntopical Active Reading Markers

/// Mortimer Adler's classic active reading marginalia notation tokens.
/// Conforms to Swift 6 Sendable and strict concurrency.
public enum AdlerMarker: String, Codable, Sendable, CaseIterable, Identifiable {
    case question   = "?"   // Incomprehension / investigation / open question
    case insight    = "!"   // Key epiphany / breakthrough concept
    case coreThesis = "★"   // Primary argument / core thesis of document
    case counterArg = "≠"   // Opposing perspective / rebuttal / counterpoint
    case logicShift = "Δ"   // Shift in mechanism / narrative / logical transition

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .question:   return "Question / Unclear"
        case .insight:    return "Insight / Epiphany"
        case .coreThesis: return "Core Thesis"
        case .counterArg: return "Counter-Argument"
        case .logicShift: return "Logic / Delta Shift"
        }
    }

    public var meaning: String {
        switch self {
        case .question:   return "Needs clarification or further research"
        case .insight:    return "Pivotal breakthrough or foundational premise"
        case .coreThesis: return "Author's central claim or main hypothesis"
        case .counterArg: return "Contradiction, alternative view, or exception"
        case .logicShift: return "Transition in reasoning, mechanism, or proof"
        }
    }

    public var symbol: String { rawValue }

    public var colorHex: String {
        switch self {
        case .question:   return "#3D6FFF" // InkBlue
        case .insight:    return "#FF9F0A" // InkOrange
        case .coreThesis: return "#8B5CF6" // InkViolet
        case .counterArg: return "#FF4D6D" // InkRed
        case .logicShift: return "#2DD4A0" // InkGreen
        }
    }

    public var accentColor: Color {
        Color(hex: colorHex)
    }

    public var sfSymbol: String {
        switch self {
        case .question:   return "questionmark.circle.fill"
        case .insight:    return "lightbulb.fill"
        case .coreThesis: return "star.fill"
        case .counterArg: return "arrow.left.arrow.right.circle.fill"
        case .logicShift: return "triangle.fill"
        }
    }
}

// MARK: - Passage Citation Model

/// Deterministic, deep-linkable document passage citation.
public struct PassageCitation: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var id: String {
        "\(documentID.uuidString)-\(pageNumber)-\(anchorID ?? "none")-\(highlightedText.hashValue)"
    }

    public let documentID: UUID
    public let documentTitle: String
    public let pageNumber: Int          // 1-indexed human-readable display page
    public let anchorID: String?        // EPUB DOM anchor or PDF paragraph hash
    public let highlightedText: String

    public init(
        documentID: UUID,
        documentTitle: String,
        pageNumber: Int,
        anchorID: String? = nil,
        highlightedText: String
    ) {
        self.documentID = documentID
        self.documentTitle = documentTitle
        self.pageNumber = pageNumber
        self.anchorID = anchorID
        self.highlightedText = highlightedText
    }

    /// Formats the citation into standard academic in-text markdown: `"[quote]" (Document Title, p. 42)`
    public var formattedMarkdownCitation: String {
        let cleanQuote = highlightedText.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\"\(cleanQuote)\" (*\(documentTitle)*, p. \(pageNumber))"
    }
}

// MARK: - Spaced Repetition Study Card

/// Active learning flashcard and cloze review item conforming to Swift 6 strict concurrency.
public struct StudyCard: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var citation: PassageCitation
    public var markdownBody: String   // Supports ==cloze deletions== and standard markdown
    public var adlerTag: AdlerMarker?
    public var tags: [String]         // E.g. ["#med/neuro", "#ch3"]
    public var dueDate: Date
    public var intervalDays: Double
    public var repetitionCount: Int
    public var easeFactor: Double     // SM-2 / FSRS baseline (default: 2.5)
    public var createdAt: Date
    public var modifiedAt: Date

    public init(
        id: UUID = UUID(),
        citation: PassageCitation,
        markdownBody: String,
        adlerTag: AdlerMarker? = nil,
        tags: [String] = [],
        dueDate: Date = Date(),
        intervalDays: Double = 0.0,
        repetitionCount: Int = 0,
        easeFactor: Double = 2.5,
        createdAt: Date = Date(),
        modifiedAt: Date = Date()
    ) {
        self.id = id
        self.citation = citation
        self.markdownBody = markdownBody
        self.adlerTag = adlerTag
        self.tags = tags
        self.dueDate = dueDate
        self.intervalDays = intervalDays
        self.repetitionCount = repetitionCount
        self.easeFactor = easeFactor
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }

    /// Indicates whether this card is currently due for spaced repetition review.
    public var isDue: Bool {
        dueDate <= Date()
    }
}

// MARK: - Spaced Repetition Rating

/// SuperMemo-2 / FSRS User response grading.
public enum StudyReviewRating: String, Codable, Sendable, CaseIterable, Identifiable {
    case again = "Again"
    case hard  = "Hard"
    case good  = "Good"
    case easy  = "Easy"

    public var id: String { rawValue }

    public var gradeScore: Int {
        switch self {
        case .again: return 1
        case .hard:  return 2
        case .good:  return 3
        case .easy:  return 4
        }
    }

    public var color: Color {
        switch self {
        case .again: return .inkRed
        case .hard:  return .inkOrange
        case .good:  return .inkBlue
        case .easy:  return .inkGreen
        }
    }

    public var keyboardShortcutHint: String {
        switch self {
        case .again: return "1"
        case .hard:  return "2"
        case .good:  return "3"
        case .easy:  return "4"
        }
    }
}

// MARK: - Bear-Style Nested Tags

/// Tree node representation for nested tags (e.g., `#medicine/neurology/synapses`).
public struct NestedTagNode: Identifiable, Sendable, Equatable, Hashable {
    public var id: String { fullPath }
    public let name: String            // Leaf tag segment name (e.g. "neurology")
    public let fullPath: String        // Full path (e.g. "#medicine/neurology")
    public var cardCount: Int          // Cards categorized under this node or its descendants
    public var children: [NestedTagNode]
    public var isExpanded: Bool

    public init(
        name: String,
        fullPath: String,
        cardCount: Int = 0,
        children: [NestedTagNode] = [],
        isExpanded: Bool = true
    ) {
        self.name = name
        self.fullPath = fullPath
        self.cardCount = cardCount
        self.children = children
        self.isExpanded = isExpanded
    }
}

// MARK: - Goodnotes-Style Vector Paper Templates

/// Mathematical vector paper template styles rendered without bitmap scaling artifacts.
public enum VectorPaperTemplate: String, Codable, Sendable, CaseIterable, Identifiable {
    case cornellClassic    = "Cornell 3-Zone"
    case dotGrid           = "Dot Grid (5mm)"
    case engineeringGrid   = "Engineering (1mm / 5mm)"
    case isometricGrid     = "Isometric 3D (60°)"
    case linedCollegeRuled = "College Ruled (7.1mm)"
    case hexagonalGrid     = "Hexagonal Lattice"
    case blankCanvas       = "Clean Blank"

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
        case .cornellClassic:    return "doc.text.fill"
        case .dotGrid:           return "circle.grid.2x2.fill"
        case .engineeringGrid:   return "grid"
        case .isometricGrid:     return "triangle"
        case .linedCollegeRuled: return "text.alignleft"
        case .hexagonalGrid:     return "hexagon"
        case .blankCanvas:       return "square"
        }
    }

    public var description: String {
        switch self {
        case .cornellClassic:    return "Walter Pauk 3-zone format: Cues, Main Notes, Summary"
        case .dotGrid:           return "Parametric 5mm dot grid for versatile diagrams and sketches"
        case .engineeringGrid:   return "Millimeter grid with 5mm accent divisions for precision schemas"
        case .isometricGrid:     return "60° isometric triangular matrix for 3D technical drawing"
        case .linedCollegeRuled: return "Standard 7.1mm lined rule with left vertical margin boundary"
        case .hexagonalGrid:     return "Honeycomb lattice for organic chemistry and structured graphing"
        case .blankCanvas:       return "Distraction-free high contrast minimalist canvas"
        }
    }
}

// MARK: - Cornell 3-Zone Study Note Model

/// Structured multi-zone study note document supporting active recall and synthesis.
public struct StudyNote: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var documentID: UUID?
    public var documentTitle: String
    public var title: String
    public var paperTemplate: VectorPaperTemplate
    
    // Cornell 3-Zone Fields
    public var cueColumnText: String       // Key questions, recall prompts, keywords
    public var mainNotesMarkdown: String   // Body notes with cloze deletion support
    public var summaryText: String         // Bottom synthesis / takeaway block
    
    public var adlerMarker: AdlerMarker?
    public var tags: [String]              // Bear-style tags: ["#med/neuro", "#core"]
    public var citations: [PassageCitation]
    public var isRecitationCoverActive: Bool // If true, main notes are obscured to test recall
    
    public var createdAt: Date
    public var modifiedAt: Date

    public init(
        id: UUID = UUID(),
        documentID: UUID? = nil,
        documentTitle: String = "Untitled Note",
        title: String = "New Study Note",
        paperTemplate: VectorPaperTemplate = .cornellClassic,
        cueColumnText: String = "",
        mainNotesMarkdown: String = "",
        summaryText: String = "",
        adlerMarker: AdlerMarker? = nil,
        tags: [String] = [],
        citations: [PassageCitation] = [],
        isRecitationCoverActive: Bool = false,
        createdAt: Date = Date(),
        modifiedAt: Date = Date()
    ) {
        self.id = id
        self.documentID = documentID
        self.documentTitle = documentTitle
        self.title = title
        self.paperTemplate = paperTemplate
        self.cueColumnText = cueColumnText
        self.mainNotesMarkdown = mainNotesMarkdown
        self.summaryText = summaryText
        self.adlerMarker = adlerMarker
        self.tags = tags
        self.citations = citations
        self.isRecitationCoverActive = isRecitationCoverActive
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }
}
