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
        
        // Observe changes in the library
        manager.$convertedPDFs
            .sink { [weak self] pdfs in
                self?.groupPDFs(pdfs)
            }
            .store(in: &cancellables)
    }
    
    private func groupPDFs(_ pdfs: [ConvertedPDF]) {
        // Dictionary grouping
        var groups: [String: [ConvertedPDF]] = [:]
        var noSeriesPDFs: [ConvertedPDF] = []
        
        for pdf in pdfs {
            if let series = pdf.metadata.series, !series.isEmpty {
                // Normalize Series Name (trim whitespace)
                let key = series.trimmingCharacters(in: .whitespacesAndNewlines)
                groups[key, default: []].append(pdf)
            } else {
                noSeriesPDFs.append(pdf)
            }
        }
        
        // Convert to SeriesGroup models
        var result: [SeriesGroup] = []
        
        for (seriesName, issues) in groups {
            // Sort issues by Volume -> Issue Number
            let sortedIssues = issues.sorted { lhs, rhs in
                // Simple sort by filename or issue number if available
                // Ideally we'd parse "Issue #1" etc.
                if let i1 = lhs.metadata.issueNumber, let i2 = rhs.metadata.issueNumber,
                   let n1 = Int(i1), let n2 = Int(i2) {
                    return n1 < n2
                }
                return lhs.name < rhs.name
            }
            
            // Representative Cover (First issue or latest?)
            // Usually first issue cover is best for Series
            let cover = sortedIssues.first?.coverImageData
            
            let group = SeriesGroup(
                id: seriesName,
                title: seriesName,
                cover: cover,
                count: sortedIssues.count,
                issues: sortedIssues
            )
            result.append(group)
        }
        
        // Sort Groups by Title
        result.sort { $0.title < $1.title }
        
        // Handle "Uncategorized" if you want to show them?
        // For now, libraries usually split "Series" and "All".
        // The "Series" view usually only shows actual series.
        // We'll expose result directly.
        self.seriesGroups = result
    }
}
