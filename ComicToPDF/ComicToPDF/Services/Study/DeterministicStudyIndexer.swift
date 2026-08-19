import Foundation

// MARK: - Deterministic Inverted Index & Query Engine

/// High-speed, 100% offline inverted index and deterministic query engine.
/// Provides Bear-style nested tag tree construction, Mortimer Adler marker filters,
/// and tokenized full-text search with zero network or cloud AI dependencies.
public final class DeterministicStudyIndexer: Sendable {
    
    public static let shared = DeterministicStudyIndexer()
    
    public init() {}
    
    // MARK: - Nested Tag Tree Construction (Bear-Style)
    
    /// Parses all raw tag strings (e.g. `["#med/neuro/synapse", "#med/cardio", "#history/rome"]`)
    /// and constructs a hierarchical `NestedTagNode` tree with aggregate card counts.
    public func buildTagHierarchy(from cards: [StudyCard], notes: [StudyNote] = []) -> [NestedTagNode] {
        // Collect all tags and track counts
        var tagCounts: [String: Int] = [:]
        
        for card in cards {
            for tag in card.tags {
                let normalized = normalizeTag(tag)
                tagCounts[normalized, default: 0] += 1
            }
        }
        
        for note in notes {
            for tag in note.tags {
                let normalized = normalizeTag(tag)
                tagCounts[normalized, default: 0] += 1
            }
        }
        
        // Build an intermediate nested dictionary structure
        var rootMap: [String: TagNodeBuilder] = [:]
        
        for (tagPath, count) in tagCounts {
            let clean = tagPath.hasPrefix("#") ? String(tagPath.dropFirst()) : tagPath
            let segments = clean.split(separator: "/").map(String.init)
            guard !segments.isEmpty else { continue }
            
            var currentPath = "#"
            var currentMap = rootMap
            
            // Recursively build branches
            insertPath(segments: segments, fullCount: count, into: &rootMap, pathPrefix: "#")
        }
        
        return rootMap.values.map { $0.toImmutableNode() }.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }
    
    private func insertPath(segments: [String], fullCount: Int, into map: inout [String: TagNodeBuilder], pathPrefix: String) {
        guard let first = segments.first else { return }
        let currentPath = (pathPrefix == "#") ? "#\(first)" : "\(pathPrefix)/\(first)"
        
        let builder: TagNodeBuilder
        if let existing = map[first] {
            builder = existing
            builder.cardCount += fullCount
        } else {
            builder = TagNodeBuilder(name: first, fullPath: currentPath, cardCount: fullCount)
            map[first] = builder
        }
        
        let remaining = Array(segments.dropFirst())
        if !remaining.isEmpty {
            insertPath(segments: remaining, fullCount: fullCount, into: &builder.childrenMap, pathPrefix: currentPath)
        }
    }
    
    // MARK: - Search & Filtering
    
    /// Evaluates a query string against the dataset using deterministic tokenized matching.
    /// Supports:
    /// - Plain keywords: `synapse action potential`
    /// - Tag filters: `tag:#med/neuro` or `#med/neuro` (matches exact and nested children)
    /// - Adler filters: `adler:?`, `adler:thesis`, `adler:insight`
    /// - Page queries: `page:42`
    /// - Document titles: `doc:"Neuroscience"`
    public func searchCards(
        query: String,
        in cards: [StudyCard],
        selectedTag: String? = nil,
        selectedAdler: AdlerMarker? = nil,
        onlyDue: Bool = false
    ) -> [StudyCard] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = parseQueryTokens(trimmed)
        
        return cards.filter { card in
            // Filter 1: Due date
            if onlyDue && !card.isDue {
                return false
            }
            
            // Filter 2: UI-selected Adler marker
            if let selectedAdler = selectedAdler, card.adlerTag != selectedAdler {
                return false
            }
            
            // Filter 3: UI-selected Tag (hierarchical match)
            if let selectedTag = selectedTag {
                let matchesTag = card.tags.contains { cardTag in
                    isTagMatch(candidate: cardTag, target: selectedTag)
                }
                if !matchesTag { return false }
            }
            
            // Filter 4: Query token rules
            if !parsed.isEmpty {
                for token in parsed {
                    switch token {
                    case .keyword(let word):
                        let inBody = card.markdownBody.localizedCaseInsensitiveContains(word)
                        let inCitation = card.citation.highlightedText.localizedCaseInsensitiveContains(word) ||
                                         card.citation.documentTitle.localizedCaseInsensitiveContains(word)
                        if !inBody && !inCitation { return false }
                        
                    case .tag(let tagQuery):
                        let matches = card.tags.contains { isTagMatch(candidate: $0, target: tagQuery) }
                        if !matches { return false }
                        
                    case .adler(let marker):
                        if card.adlerTag != marker { return false }
                        
                    case .page(let pageNum):
                        if card.citation.pageNumber != pageNum { return false }
                        
                    case .document(let docName):
                        if !card.citation.documentTitle.localizedCaseInsensitiveContains(docName) { return false }
                    }
                }
            }
            
            return true
        }
    }
    
    // MARK: - Query Parser Internals
    
    private enum QueryToken {
        case keyword(String)
        case tag(String)
        case adler(AdlerMarker)
        case page(Int)
        case document(String)
    }
    
    private func parseQueryTokens(_ query: String) -> [QueryToken] {
        guard !query.isEmpty else { return [] }
        var tokens: [QueryToken] = []
        let rawParts = query.split(separator: " ")
        
        for part in rawParts {
            let str = String(part)
            if str.hasPrefix("#") {
                tokens.append(.tag(str))
            } else if str.lowercased().hasPrefix("tag:") {
                let tagVal = String(str.dropFirst(4))
                tokens.append(.tag(tagVal.hasPrefix("#") ? tagVal : "#\(tagVal)"))
            } else if str.lowercased().hasPrefix("adler:") {
                let markerVal = String(str.dropFirst(6))
                if let marker = parseAdlerString(markerVal) {
                    tokens.append(.adler(marker))
                }
            } else if str.lowercased().hasPrefix("page:") {
                if let pageNum = Int(str.dropFirst(5)) {
                    tokens.append(.page(pageNum))
                }
            } else if str.lowercased().hasPrefix("doc:") {
                let docName = String(str.dropFirst(4)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                tokens.append(.document(docName))
            } else {
                tokens.append(.keyword(str))
            }
        }
        
        return tokens
    }
    
    private func parseAdlerString(_ val: String) -> AdlerMarker? {
        let clean = val.lowercased().trimmingCharacters(in: .whitespaces)
        switch clean {
        case "?", "question", "unclear": return .question
        case "!", "insight", "epiphany":  return .insight
        case "★", "*", "thesis", "core": return .coreThesis
        case "≠", "!=", "counter", "rebuttal": return .counterArg
        case "δ", "delta", "shift", "logic": return .logicShift
        default: return nil
        }
    }
    
    /// Evaluates if `candidate` tag is either equal to or a child subtag of `target`.
    /// E.g., `#med/neuro/synapse` matches target `#med/neuro` and `#med`.
    public func isTagMatch(candidate: String, target: String) -> Bool {
        let normCand = normalizeTag(candidate).lowercased()
        let normTarg = normalizeTag(target).lowercased()
        
        if normCand == normTarg { return true }
        if normCand.hasPrefix(normTarg + "/") { return true }
        return false
    }
    
    public func normalizeTag(_ tag: String) -> String {
        var trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.hasPrefix("#") {
            trimmed = "#" + trimmed
        }
        return trimmed
    }
}

// MARK: - Internal Tree Builder Class

private final class TagNodeBuilder {
    let name: String
    let fullPath: String
    var cardCount: Int
    var childrenMap: [String: TagNodeBuilder] = [:]
    
    init(name: String, fullPath: String, cardCount: Int) {
        self.name = name
        self.fullPath = fullPath
        self.cardCount = cardCount
    }
    
    func toImmutableNode() -> NestedTagNode {
        let sortedChildren = childrenMap.values
            .map { $0.toImmutableNode() }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
        
        return NestedTagNode(
            name: name,
            fullPath: fullPath,
            cardCount: cardCount,
            children: sortedChildren,
            isExpanded: true
        )
    }
}
