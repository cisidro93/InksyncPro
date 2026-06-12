import Foundation
import SwiftUI

// ✅ Unified Library Item — supports single files, publisher series, and drive folder cards
enum LibraryListItem: Identifiable, Hashable {
    case single(ConvertedPDF)
    case series(SeriesGroup)
    /// A linked external drive that has too many files to list individually.
    /// Tapping drills into LinkedDriveBrowserView rather than the flat library.
    case driveFolder(AppSettingsManager.LinkedDriveEntry)

    var id: String {
        switch self {
        case .single(let pdf):        return "single_\(pdf.id)"
        case .series(let group):      return "series_\(group.id)"
        case .driveFolder(let entry): return "drive_\(entry.id)"
        }
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        switch self {
        case .single(let pdf):        hasher.combine(pdf.hashValue)
        case .series(let group):      hasher.combine(group.hashValue)
        case .driveFolder(let entry): hasher.combine(entry.id)
        }
    }

    static func == (lhs: LibraryListItem, rhs: LibraryListItem) -> Bool {
        switch (lhs, rhs) {
        case (.single(let l), .single(let r)):               return l == r
        case (.series(let l), .series(let r)):               return l == r
        case (.driveFolder(let l), .driveFolder(let r)):     return l.id == r.id && l.fileCount == r.fileCount
        default: return false
        }
    }
}

// ✅ Series Grouping Concept
struct SeriesGroup: Identifiable, Hashable {
    let id: String
    let title: String
    var coverIssueID: UUID?
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
