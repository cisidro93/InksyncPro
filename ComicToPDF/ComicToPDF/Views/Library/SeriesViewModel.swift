import Foundation
import SwiftUI
import Combine

@MainActor
class SeriesViewModel: ObservableObject {
    @Published var seriesGroups: [SeriesGroup] = []
    /// Populated when the user long-presses a series to rename it
    @Published var renameTarget: SeriesGroup? = nil
    @Published var renameText: String = ""

    private var cancellables = Set<AnyCancellable>()
    private let manager: ConversionManager

    init(manager: ConversionManager) {
        self.manager = manager

        // Rebuild groups any time the library or Vault state changes
        Publishers.CombineLatest(manager.$convertedPDFs, AppSettingsManager.shared.$isVaultUnlocked)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] pdfs, isUnlocked in 
                let visible = pdfs.filter { $0.isPrivate == isUnlocked }
                self?.groupPDFs(visible) 
            }
            .store(in: &cancellables)
    }

    // MARK: - Series Rename
    /// Renames all issues in a series to the new name and refreshes groups.
    func commitRename() {
        guard let target = renameTarget else { return }
        let newName = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, newName != target.title else {
            renameTarget = nil; return
        }
        for pdf in target.issues {
            if let idx = manager.convertedPDFs.firstIndex(where: { $0.id == pdf.id }) {
                manager.convertedPDFs[idx].metadata.series = newName
                let newFilename = manager.generateRenameFilename(pdf: manager.convertedPDFs[idx], newSeriesName: newName)
                try? manager.safelyRenamePhysicalFile(pdf: manager.convertedPDFs[idx], newName: newFilename)
            }
        }
        manager.saveLibrary()
        renameTarget = nil
    }

    private func groupPDFs(_ pdfs: [ConvertedPDF]) {
        var groups: [String: [ConvertedPDF]] = [:]

        for pdf in pdfs {
            var key = (pdf.metadata.series ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            
            // Sub-group by volume locally in the library view if volume metadata is present
            if let vol = pdf.metadata.volume, !vol.trimmingCharacters(in: .whitespaces).isEmpty {
                key = "\(key) - Vol \(vol)"
            }
            
            groups[key, default: []].append(pdf)
        }

        var result: [SeriesGroup] = []
        // ✅ FIX: Covers live in ApplicationSupport/Covers, not Documents
        let coversDir = PhysicalFileSystemRouter.getCoversDirectory()

        for (seriesName, issues) in groups {
            // ✅ FIX: Natural sort so issue 2 < 10 < 100 (not lexicographic)
            let sortedIssues = issues.sorted { lhs, rhs in
                if let i1 = lhs.metadata.issueNumber, let i2 = rhs.metadata.issueNumber,
                   let n1 = Int(i1), let n2 = Int(i2) {
                    return n1 < n2
                }
                // Fallback: natural string sort handles '001' vs '010' correctly
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }

            // Resolve cover: explicit collection override first, then first issue with an on-disk cover
            var coverID: UUID? = sortedIssues.first?.id

            if let matchingCollection = manager.collections.first(where: { $0.name == seriesName }),
               let explicitID = matchingCollection.explicitCoverFileID,
               issues.contains(where: { $0.id == explicitID }) {
                let candidateURL = coversDir.appendingPathComponent("cover_\(explicitID.uuidString).jpg")
                if FileManager.default.fileExists(atPath: candidateURL.path) {
                    coverID = explicitID
                }
            } else {
                // Walk sorted issues (lowest issue # first) to find first one whose cover exists
                coverID = sortedIssues.first(where: {
                    let url = coversDir.appendingPathComponent("cover_\($0.id.uuidString).jpg")
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
