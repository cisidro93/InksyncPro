import Foundation
import SwiftUI
import Combine

@MainActor
class SeriesViewModel: ObservableObject {
    @Published var seriesGroups: [SeriesGroup] = []

    private var cancellables = Set<AnyCancellable>()
    private let manager: ConversionManager

    init(manager: ConversionManager) {
        self.manager = manager

        // Rebuild groups any time the library changes
        manager.$convertedPDFs
            .sink { [weak self] pdfs in self?.groupPDFs(pdfs) }
            .store(in: &cancellables)
    }

    private func groupPDFs(_ pdfs: [ConvertedPDF]) {
        var groups: [String: [ConvertedPDF]] = [:]

        for pdf in pdfs {
            let key = (pdf.metadata.series ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            groups[key, default: []].append(pdf)
        }

        var result: [SeriesGroup] = []
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

        for (seriesName, issues) in groups {
            // Sort by issue number → filename
            let sortedIssues = issues.sorted { lhs, rhs in
                if let i1 = lhs.metadata.issueNumber, let i2 = rhs.metadata.issueNumber,
                   let n1 = Int(i1), let n2 = Int(i2) {
                    return n1 < n2
                }
                return lhs.name < rhs.name
            }

            // Resolve cover: prefer explicit collection override, then first issue
            var coverID: UUID? = sortedIssues.first?.id

            if let matchingCollection = manager.collections.first(where: { $0.name == seriesName }),
               let explicitID = matchingCollection.explicitCoverFileID,
               issues.contains(where: { $0.id == explicitID }) {
                // Verify the cover file actually exists on disk before using it
                let candidateURL = docs.appendingPathComponent("cover_\(explicitID.uuidString).jpg")
                if FileManager.default.fileExists(atPath: candidateURL.path) {
                    coverID = explicitID
                }
            } else {
                // Walk sorted issues to find the first one whose cover is on disk
                coverID = sortedIssues.first(where: {
                    let url = docs.appendingPathComponent("cover_\($0.id.uuidString).jpg")
                    return FileManager.default.fileExists(atPath: url.path)
                })?.id ?? sortedIssues.first?.id
            }

            result.append(SeriesGroup(
                id: seriesName,
                title: seriesName,
                coverIssueID: coverID,
                count: sortedIssues.count,
                issues: sortedIssues
            ))
        }

        self.seriesGroups = result.sorted { $0.title < $1.title }
    }
}
