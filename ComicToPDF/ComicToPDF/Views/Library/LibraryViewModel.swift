import SwiftUI
import Combine

@MainActor
class LibraryViewModel: ObservableObject {
    @Published var cachedLibraryItems: [LibraryListItem] = []
    @Published var searchText: String = ""
    
    // Search Debouncing
    @Published private var debouncedSearchText: String = ""
    private var cancellables = Set<AnyCancellable>()
    
    // Routing State
    @Published var activeSheet: LibrarySheetDestination?
    @Published var activeFullScreen: LibraryFullScreenDestination?
    
    // Single-view specific state that isn't cleanly enum-mappable due to alerts
    @Published var pdfToRename: ConvertedPDF?
    @Published var renameText: String = ""
    
    init() {
        $searchText
            .debounce(for: .seconds(0.3), scheduler: RunLoop.main)
            .removeDuplicates()
            .sink { [weak self] text in
                self?.debouncedSearchText = text
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Core Cache System
    func updateLibraryItemsCache(pdfs: [ConvertedPDF], sortOption: ModernLibraryView.SortOption) {
        // Capture context snapshot to safely detach
        let currentSearchText = debouncedSearchText
        let sortedPDFs = sortPDFs(pdfs, sortOption: sortOption)
        
        Task.detached(priority: .background) {
            var groups: [String: SeriesGroup] = [:]
            var singles: [ConvertedPDF] = []
            var firstAppearanceIndex: [String: Int] = [:]
            
            for (index, pdf) in sortedPDFs.enumerated() {
                if let seriesName = pdf.metadata.series, !seriesName.isEmpty {
                    let seriesKey = "series_\(seriesName)"
                    if firstAppearanceIndex[seriesKey] == nil { firstAppearanceIndex[seriesKey] = index }
                    
                    if groups[seriesName] == nil {
                        groups[seriesName] = SeriesGroup(id: seriesName, title: seriesName, coverIssueID: pdf.id, count: 0, issues: [])
                    }
                    groups[seriesName]!.issues.append(pdf)
                    groups[seriesName]!.count += 1
                } else {
                    let singleKey = "single_\(pdf.id)"
                    if firstAppearanceIndex[singleKey] == nil { firstAppearanceIndex[singleKey] = index }
                    singles.append(pdf)
                }
            }
            
            var items: [(Int, LibraryListItem)] = []
            
            for (_, group) in groups {
                let item = LibraryListItem.series(group)
                items.append((firstAppearanceIndex["series_\(group.id)"] ?? 0, item))
            }
            
            for single in singles {
                let item = LibraryListItem.single(single)
                items.append((firstAppearanceIndex["single_\(single.id)"] ?? 0, item))
            }
            
            // Search Filtering
            if !currentSearchText.isEmpty {
                items = items.filter { tuple in
                    switch tuple.1 {
                    case .single(let pdf): return pdf.name.localizedCaseInsensitiveContains(currentSearchText)
                    case .series(let group): return group.title.localizedCaseInsensitiveContains(currentSearchText)
                    }
                }
            }
            
            items.sort { $0.0 < $1.0 }
            let finalItems = items.map { $0.1 }
            
            await MainActor.run { [weak self] in
                self?.cachedLibraryItems = finalItems
            }
        }
    }
    
    // MARK: - Action Router Endpoint
    func handleDetailAction(action: LibraryRowAction, for pdf: ConvertedPDF, conversionManager: ConversionManager) {
        // A slight delay ensures any active sheet finishes dismissing before popping a new one
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            switch action {
            case .read:          
                self.activeFullScreen = .read(pdf)
            case .details:       
                self.activeSheet = .details(pdf)
            case .covers:        
                self.activeFullScreen = .advancedWorkspace(pdf)
            case .fetchMetadata: 
                self.activeSheet = .searchMetadata(pdf)
            case .editMetadata:  
                self.activeSheet = .editMetadata(pdf)
            case .export:        
                self.activeSheet = .export(pdf)
            case .share:         
                self.activeSheet = .directShare(pdf)
            case .sync:          
                self.activeSheet = .cloudSync(pdf)
            case .rename:
                self.renameText = pdf.name
                self.pdfToRename = pdf
            case .addToSeries:
                self.activeSheet = .seriesAssignment(pdf, isBatch: false, selection: [])
            case .favorite:
                if let index = conversionManager.convertedPDFs.firstIndex(where: { $0.id == pdf.id }) {
                    conversionManager.convertedPDFs[index].isFavorite.toggle()
                }
            case .delete:
                conversionManager.deletePDF(pdf)
            }
        }
    }
    
    // Additional Logic Handlers...
    func sortPDFs(_ pdfs: [ConvertedPDF], sortOption: ModernLibraryView.SortOption) -> [ConvertedPDF] {
        switch sortOption {
        case .dateAdded: return pdfs.reversed() // Returns newest imported first, which places it natively at index 0 and top-left.
        case .name: return pdfs.sorted {
            let s1 = $0.metadata.series ?? ""
            let s2 = $1.metadata.series ?? ""
            if !s1.isEmpty && s1 == s2 {
                // If they belong to the same series, check for manual issue numbers to forcefully sort them correctly
                if let n1 = $0.metadata.issueNumber, let v1 = Double(n1),
                   let n2 = $1.metadata.issueNumber, let v2 = Double(n2) {
                    return v1 < v2
                }
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        case .size: return pdfs.sorted { $0.fileSize > $1.fileSize }
        case .favorites:
            return pdfs.sorted {
                if $0.isFavorite == $1.isFavorite { return false }
                return $0.isFavorite && !$1.isFavorite
            }
        case .type:
            return pdfs.sorted {
                let s1 = ($0.metadata.series ?? "").isEmpty
                let s2 = ($1.metadata.series ?? "").isEmpty
                if s1 != s2 { return s2 } // Place series first
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        case .extensionType:
            return pdfs.sorted {
                $0.fileExtensionString.localizedStandardCompare($1.fileExtensionString) == .orderedAscending
            }
        }
    }
}
