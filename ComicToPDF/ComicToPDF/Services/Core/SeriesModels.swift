import Foundation
import SwiftUI

struct SeriesGroup: Identifiable, Hashable {
    let id: String // Series Name is the ID
    let title: String
    let cover: Data?
    let count: Int
    let issues: [ConvertedPDF]
    
    var lastUpdated: Date {
        issues.map { $0.metadata.publicationDate ?? Date.distantPast }.max() ?? Date.distantPast
    }
}
