import Foundation
import Combine

@MainActor
class SmartCollectionViewModel: ObservableObject {
    @Published var filteredPDFs: [ConvertedPDF] = []
    @Published var rule: SmartCollectionRule
    
    private var cancellables = Set<AnyCancellable>()
    
    init(rule: SmartCollectionRule) {
        self.rule = rule
        
        // Listen to changes in ConversionManager and ReaderProgressTracker to re-evaluate
        ConversionManager.shared.$convertedPDFs
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.evaluate()
            }
            .store(in: &cancellables)
            
        ReaderProgressTracker.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.evaluate()
            }
            .store(in: &cancellables)
            
        // Initial evaluation
        evaluate()
    }
    
    func evaluate() {
        let allPDFs = ConversionManager.shared.convertedPDFs
        var results: [ConvertedPDF] = []
        
        switch rule {
        case .recentlyAdded:
            results = allPDFs.sorted { $0.dateAdded > $1.dateAdded }
            // Limit to top 50 recent additions for performance and relevance
            if results.count > 50 {
                results = Array(results.prefix(50))
            }
            
        case .readingNow:
            results = allPDFs.filter { pdf in
                let maxPages = max(pdf.pageCount, 1)
                let read = pdf.metadata.lastReadPage ?? 0
                return read > 0 && read < (maxPages - 1)
            }
            // Sort by recently read
            results.sort { pdf1, pdf2 in
                let d1 = ReaderProgressTracker.shared.progress(for: pdf1.id)?.lastOpenedAt ?? Date.distantPast
                let d2 = ReaderProgressTracker.shared.progress(for: pdf2.id)?.lastOpenedAt ?? Date.distantPast
                return d1 > d2
            }
            
        case .allUnread:
            results = allPDFs.filter { pdf in
                let read = pdf.metadata.lastReadPage ?? 0
                return read == 0
            }
            results.sort { $0.dateAdded > $1.dateAdded }
            
        case .completed:
            results = allPDFs.filter { pdf in
                let maxPages = max(pdf.pageCount, 1)
                let read = pdf.metadata.lastReadPage ?? 0
                return read >= (maxPages - 1)
            }
            // Sort by recently completed / recently opened
            results.sort { pdf1, pdf2 in
                let d1 = ReaderProgressTracker.shared.progress(for: pdf1.id)?.lastOpenedAt ?? Date.distantPast
                let d2 = ReaderProgressTracker.shared.progress(for: pdf2.id)?.lastOpenedAt ?? Date.distantPast
                return d1 > d2
            }
            
        case .manga:
            results = allPDFs.filter { pdf in
                // Manga mode if preferred or implicitly detected (e.g., right-to-left flag could be checked if present)
                let prefersManga = ReaderProgressTracker.shared.progress(for: pdf.id)?.prefersMangaMode == true
                return prefersManga
            }
            results.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        
        self.filteredPDFs = results
    }
}
