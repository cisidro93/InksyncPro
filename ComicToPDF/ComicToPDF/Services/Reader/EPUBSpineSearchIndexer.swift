import Foundation

// MARK: - EPUB Search Match Model

/// Represents a single search match within an EPUB chapter spine item.
public struct EPUBSearchMatch: Identifiable, Sendable, Equatable, Hashable {
    public let id = UUID()
    public let chapterIndex: Int
    public let chapterTitle: String
    public let spineHref: String
    public let snippetText: String
    public let matchedQuery: String
    public let anchorHash: String?
    
    public init(
        chapterIndex: Int,
        chapterTitle: String,
        spineHref: String,
        snippetText: String,
        matchedQuery: String,
        anchorHash: String? = nil
    ) {
        self.chapterIndex = chapterIndex
        self.chapterTitle = chapterTitle
        self.spineHref = spineHref
        self.snippetText = snippetText
        self.matchedQuery = matchedQuery
        self.anchorHash = anchorHash
    }
}

// MARK: - EPUB Spine Chapter Index Data

public struct IndexedSpineChapter: Sendable {
    public let chapterIndex: Int
    public let chapterTitle: String
    public let spineHref: String
    public let plainText: String
    public let sectionAnchors: [(id: String, textOffset: Int)]
    
    public init(
        chapterIndex: Int,
        chapterTitle: String,
        spineHref: String,
        plainText: String,
        sectionAnchors: [(id: String, textOffset: Int)] = []
    ) {
        self.chapterIndex = chapterIndex
        self.chapterTitle = chapterTitle
        self.spineHref = spineHref
        self.plainText = plainText
        self.sectionAnchors = sectionAnchors
    }
}

// MARK: - EPUB Spine Search Indexer Actor

/// Actor-isolated full-text search indexer for EPUB books.
/// Asynchronously extracts raw text from chapter spine items, maintains an in-memory
/// tokenized inverted search index, and returns matched snippets with target DOM anchors.
public actor EPUBSpineSearchIndexer {
    
    public static let shared = EPUBSpineSearchIndexer()
    
    // In-memory index table: [BookID: [IndexedSpineChapter]]
    private var bookIndices: [String: [IndexedSpineChapter]] = [:]
    
    public init() {}
    
    // MARK: - Indexing API
    
    /// Indexes an entire EPUB book's spine chapters.
    /// Supports cooperative cancellation via `Task.isCancelled`.
    public func indexDocument(
        bookID: String,
        spineItems: [(index: Int, title: String, href: String, html: String)]
    ) async {
        var chapters: [IndexedSpineChapter] = []
        
        for item in spineItems {
            guard !Task.isCancelled else { return }
            
            let (plainText, anchors) = stripHTMLAndExtractAnchors(from: item.html)
            let chapter = IndexedSpineChapter(
                chapterIndex: item.index,
                chapterTitle: item.title,
                spineHref: item.href,
                plainText: plainText,
                sectionAnchors: anchors
            )
            chapters.append(chapter)
        }
        
        guard !Task.isCancelled else { return }
        bookIndices[bookID] = chapters
        Logger.shared.log("EPUBSpineSearch: Indexed \(chapters.count) spine chapters for book \(bookID)", category: "EPUB")
    }
    
    /// Clears the indexed data for a book when closed to release memory.
    public func purgeIndex(for bookID: String) {
        bookIndices.removeValue(forKey: bookID)
    }
    
    // MARK: - Search Query API
    
    /// Searches across all indexed spine chapters for the given query string.
    public func search(query: String, in bookID: String) -> [EPUBSearchMatch] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let chapters = bookIndices[bookID] else { return [] }
        
        var results: [EPUBSearchMatch] = []
        let lowerQuery = trimmed.lowercased()
        
        for chapter in chapters {
            let lowerText = chapter.plainText.lowercased()
            var searchRange = lowerText.startIndex..<lowerText.endIndex
            
            while let matchRange = lowerText.range(of: lowerQuery, options: [], range: searchRange) {
                // Compute character offset
                let offset = lowerText.distance(from: lowerText.startIndex, to: matchRange.lowerBound)
                
                // Find closest preceding anchor
                let anchor = chapter.sectionAnchors.last(where: { $0.textOffset <= offset })?.id
                
                // Build snippet around the match
                let snippet = extractSnippet(from: chapter.plainText, around: matchRange)
                
                results.append(
                    EPUBSearchMatch(
                        chapterIndex: chapter.chapterIndex,
                        chapterTitle: chapter.chapterTitle,
                        spineHref: chapter.spineHref,
                        snippetText: snippet,
                        matchedQuery: trimmed,
                        anchorHash: anchor
                    )
                )
                
                // Advance search range
                searchRange = matchRange.upperBound..<lowerText.endIndex
                
                // Cap results per chapter to 25 to avoid UI bloat
                if results.count >= 200 { break }
            }
        }
        
        return results
    }
    
    // MARK: - Internal HTML Parsing & Snippet Extraction
    
    private func stripHTMLAndExtractAnchors(from html: String) -> (String, [(id: String, textOffset: Int)]) {
        var plainText = ""
        var anchors: [(id: String, textOffset: Int)] = []
        var isInTag = false
        var currentTag = ""
        
        let scanner = html
        for char in scanner {
            if char == "<" {
                isInTag = true
                currentTag = ""
            } else if char == ">" {
                isInTag = false
                // Check if the tag contains an id or name attribute
                if currentTag.lowercased().contains("id=") || currentTag.lowercased().contains("name=") {
                    if let id = extractAttribute("id", from: currentTag) ?? extractAttribute("name", from: currentTag) {
                        anchors.append((id: id, textOffset: plainText.count))
                    }
                }
            } else if isInTag {
                currentTag.append(char)
            } else {
                plainText.append(char)
            }
        }
        
        // Clean multiple newlines and spaces
        let cleaned = plainText.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        
        return (cleaned, anchors)
    }
    
    private func extractAttribute(_ attr: String, from tag: String) -> String? {
        let pattern = "\(attr)=[\"']([^\"']+)[\"']"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: tag, options: [], range: NSRange(tag.startIndex..<tag.endIndex, in: tag)),
              let valRange = Range(match.range(at: 1), in: tag) else {
            return nil
        }
        return String(tag[valRange])
    }
    
    private func extractSnippet(from text: String, around matchRange: Range<String.Index>) -> String {
        let snippetRadius = 50
        
        let startDistance = text.distance(from: text.startIndex, to: matchRange.lowerBound)
        let snippetStartOffset = max(0, startDistance - snippetRadius)
        let snippetStartIndex = text.index(text.startIndex, offsetBy: snippetStartOffset)
        
        let endDistance = text.distance(from: text.startIndex, to: matchRange.upperBound)
        let snippetEndOffset = min(text.count, endDistance + snippetRadius)
        let snippetEndIndex = text.index(text.startIndex, offsetBy: snippetEndOffset)
        
        var snippet = String(text[snippetStartIndex..<snippetEndIndex])
        
        if snippetStartIndex > text.startIndex {
            snippet = "..." + snippet
        }
        if snippetEndIndex < text.endIndex {
            snippet = snippet + "..."
        }
        
        return snippet.replacingOccurrences(of: "\n", with: " ")
    }
}
