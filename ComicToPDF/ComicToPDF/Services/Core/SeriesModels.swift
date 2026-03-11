import Foundation
import SwiftUI

struct SeriesGroup: Identifiable, Hashable {
    let id: String          // Series name is the stable ID
    let title: String
    let coverIssueID: UUID? // ID of the issue whose cover_{UUID}.jpg is used as the series cover
    let count: Int
    let issues: [ConvertedPDF]
    
    var lastUpdated: Date {
        issues.map { $0.metadata.publicationDate ?? Date.distantPast }.max() ?? Date.distantPast
    }
    
    /// Resolved cover URL: cover_{coverIssueID}.jpg in the app's Documents directory.
    var coverURL: URL? {
        guard let id = coverIssueID else { return nil }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent("cover_\(id.uuidString).jpg")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
