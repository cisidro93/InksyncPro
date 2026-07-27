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
    var readCount: Int
    var newCount: Int
    var isEmpty: Bool {
        count == 0 || issues.isEmpty
    }

    init(id: String, title: String, coverIssueID: UUID? = nil, count: Int, issues: [ConvertedPDF], readCount: Int = 0, newCount: Int = 0) {
        self.id = id
        self.title = title
        self.coverIssueID = coverIssueID
        self.count = count
        self.issues = issues
        self.readCount = readCount
        self.newCount = newCount
    }
    
    var lastUpdated: Date {
        issues.map { $0.metadata.publicationDate ?? Date.distantPast }.max() ?? Date.distantPast
    }
    
    var coverURL: URL? { coverIssueID.flatMap { id in issues.first(where: { $0.id == id })?.url } }
    
    // ✅ Fast Equality to bypass deep struct inspection
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(count)
        hasher.combine(coverIssueID)
        hasher.combine(readCount)
        hasher.combine(newCount)
    }
    
    static func == (lhs: SeriesGroup, rhs: SeriesGroup) -> Bool {
        return lhs.id == rhs.id && lhs.count == rhs.count && lhs.coverIssueID == rhs.coverIssueID && lhs.readCount == rhs.readCount && lhs.newCount == rhs.newCount
    }
}

extension LibraryListItem {
    var title: String {
        switch self {
        case .single(let pdf):
            let t = pdf.metadata.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? pdf.name : pdf.metadata.title
        case .series(let group):
            return group.title
        case .driveFolder(let entry):
            return entry.displayName
        }
    }

    var dateAdded: Date {
        switch self {
        case .single(let pdf):
            return pdf.lastModified
        case .series(let group):
            return group.issues.map(\.lastModified).max() ?? Date.distantPast
        case .driveFolder:
            return Date.distantPast
        }
    }

    var size: Int64 {
        switch self {
        case .single(let pdf):
            return pdf.fileSize
        case .series(let group):
            return group.issues.map(\.fileSize).reduce(0, +)
        case .driveFolder:
            return 0
        }
    }

    var isFavorite: Bool {
        switch self {
        case .single(let pdf):
            return pdf.isFavorite
        case .series(let group):
            return group.issues.contains { $0.isFavorite }
        case .driveFolder:
            return false
        }
    }

    var isSeries: Bool {
        switch self {
        case .series: return true
        default: return false
        }
    }

    var fileExtensionString: String {
        switch self {
        case .single(let pdf):
            return pdf.fileExtensionString
        case .series(let group):
            return group.issues.first?.fileExtensionString ?? ""
        case .driveFolder:
            return ""
        }
    }

    var locationRank: Int {
        switch self {
        case .single(let pdf):
            return pdf.sourceMode.isCloud ? 2 : (pdf.sourceMode.isLinked ? 1 : 0)
        case .series(let group):
            if let first = group.issues.first {
                return first.sourceMode.isCloud ? 2 : (first.sourceMode.isLinked ? 1 : 0)
            }
            return 0
        case .driveFolder:
            return 1
        }
    }
}
