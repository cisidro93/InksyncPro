import Foundation
import SwiftUI

// ✅ NEW: Unified Library Item
// Fast Diffing
enum LibraryListItem: Identifiable, Hashable {
    case single(ConvertedPDF)
    case series(SeriesGroup)
    
    var id: String {
        switch self {
        case .single(let pdf): return "single_\(pdf.id)"
        case .series(let group): return "series_\(group.id)"
        }
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        switch self {
        case .single(let pdf): hasher.combine(pdf.hashValue)
        case .series(let group): hasher.combine(group.hashValue)
        }
    }
    
    static func == (lhs: LibraryListItem, rhs: LibraryListItem) -> Bool {
        switch (lhs, rhs) {
        case (.single(let l), .single(let r)): return l == r
        case (.series(let l), .series(let r)): return l == r
        default: return false
        }
    }
}

// ✅ Series Grouping Concept
struct SeriesGroup: Identifiable, Hashable {
    let id: String
    let title: String
    let coverIssueID: UUID?
    var count: Int
    var issues: [ConvertedPDF] // Mutable to support drag-and-drop
    
    var lastUpdated: Date {
        issues.map { $0.metadata.publicationDate ?? Date.distantPast }.max() ?? Date.distantPast
    }
    
    var coverURL: URL? { coverIssueID.flatMap { id in issues.first(where: { $0.id == id })?.url } }
    
    // ✅ Fast Equality to bypass deep struct inspection
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(count)
        hasher.combine(coverIssueID)
    }
    
    static func == (lhs: SeriesGroup, rhs: SeriesGroup) -> Bool {
        return lhs.id == rhs.id && lhs.count == rhs.count && lhs.coverIssueID == rhs.coverIssueID
    }
}
