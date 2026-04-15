import SwiftUI
import Combine

@MainActor
class LibraryViewModel: ObservableObject {
    @Published var cachedLibraryItems: [LibraryListItem] = []
    @Published var searchText: String = ""
    
    // Search Debouncing
    @Published var debouncedSearchText: String = ""
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
    func updateLibraryItemsCache(pdfs: [ConvertedPDF], collections: [PDFCollection], sortOption: ModernLibraryView.SortOption) {
        // Capture context snapshot to safely detach
        let currentSearchText = debouncedSearchText
        let sortedPDFs = sortPDFs(pdfs, sortOption: sortOption)
        
        Task.detached(priority: .background) {
            var groups: [String: SeriesGroup] = [:]
            var singles: [ConvertedPDF] = []
            var firstAppearanceIndex: [String: Int] = [:]
            
            for (index, pdf) in sortedPDFs.enumerated() {
                var inAnyGroup = false
                
                // 1. Process standard Publisher Series
                if let seriesName = pdf.metadata.series, !seriesName.isEmpty {
                    let seriesKey = "series_\(seriesName)"
                    if firstAppearanceIndex[seriesKey] == nil { firstAppearanceIndex[seriesKey] = index }
                    
                    if groups[seriesKey] == nil {
                        groups[seriesKey] = SeriesGroup(id: seriesName, title: seriesName, coverIssueID: pdf.id, count: 0, issues: [])
                    }
                    groups[seriesKey]?.issues.append(pdf)
                    groups[seriesKey]?.count += 1
                    inAnyGroup = true
                }
                
                // 2. Process Custom Collections (Events)
                if let cid = pdf.collectionId, let collection = collections.first(where: { $0.id == cid }) {
                    let colKey = "col_\(collection.id.uuidString)"
                    if firstAppearanceIndex[colKey] == nil { firstAppearanceIndex[colKey] = index }
                    
                    if groups[colKey] == nil {
                        // Use explicit cover if specified, otherwise the first generated
                        let coverID = collection.explicitCoverFileID ?? pdf.id
                        groups[colKey] = SeriesGroup(id: collection.id.uuidString, title: collection.name, coverIssueID: coverID, count: 0, issues: [])
                    }
                    groups[colKey]?.issues.append(pdf)
                    groups[colKey]?.count += 1
                    inAnyGroup = true
                }
                
                // 3. Fallback to Singles if not in ANY group
                if !inAnyGroup {
                    let singleKey = "single_\(pdf.id)"
                    if firstAppearanceIndex[singleKey] == nil { firstAppearanceIndex[singleKey] = index }
                    singles.append(pdf)
                }
            }
            
            // Post-Process Collections to apply manual sorting
            for collection in collections {
                let colKey = "col_\(collection.id.uuidString)"
                if var group = groups[colKey], let manualOrder = collection.manualSortOrder, !manualOrder.isEmpty {
                    // Create a lookup dictionary for fast indexing
                    let orderDict = Dictionary(uniqueKeysWithValues: manualOrder.enumerated().map { ($0.element, $0.offset) })
                    // Sort the issues array based on the manual order. If not in the list, push to back
                    group.issues.sort { pdf1, pdf2 in
                        let idx1 = orderDict[pdf1.id] ?? Int.max
                        let idx2 = orderDict[pdf2.id] ?? Int.max
                        if idx1 == idx2 {
                            return pdf1.name.localizedStandardCompare(pdf2.name) == .orderedAscending
                        }
                        return idx1 < idx2
                    }
                    // Update the cover to the first item of the manually sorted list unless explicitly overridden
                    if collection.explicitCoverFileID == nil, let firstID = group.issues.first?.id {
                        group.coverIssueID = firstID
                    }
                    groups[colKey] = group
                }
            }
            
            // 4. Deduplication Pass for Identical Collections and Series
            // If a user imports a Folder "Batman", and the Metadata parsed is also "Batman",
            // the UI will double-render the series item if both exist. We prefer the collection group.
            var keysToRemove: [String] = []
            for (key, var group) in groups {
                if key.starts(with: "col_") {
                    let overlappingSeriesKey = "series_\(group.title)"
                    if let orphanSeries = groups[overlappingSeriesKey] {
                        // Merge the items into the collection group!
                        for issue in orphanSeries.issues {
                            if !group.issues.contains(where: { $0.id == issue.id }) {
                                group.issues.append(issue)
                                group.count += 1
                            }
                        }
                        groups[key] = group
                        keysToRemove.append(overlappingSeriesKey)
                    }
                }
            }
            for k in keysToRemove {
                groups.removeValue(forKey: k)
            }
            
            var items: [(Int, LibraryListItem)] = []
            
            for (key, var group) in groups {
                // ✅ PHASE 4: Internal Sorting & Cover Assigner
                // Ensure issues inside the folder always display in reading sequence
                group.issues.sort { a, b in
                    let aNumStr = a.metadata.issueNumber ?? ""
                    let bNumStr = b.metadata.issueNumber ?? ""
                    
                    // Check if these are from the same volume first to prevent cross-volume jumbling
                    let aVolStr = a.metadata.volume ?? ""
                    let bVolStr = b.metadata.volume ?? ""
                    if !aVolStr.isEmpty && !bVolStr.isEmpty && aVolStr != bVolStr,
                       let aVol = Double(aVolStr), let bVol = Double(bVolStr) {
                        return aVol < bVol
                    }
                    
                    if !aNumStr.isEmpty && !bNumStr.isEmpty, let aNum = Double(aNumStr), let bNum = Double(bNumStr) {
                        return aNum < bNum
                    }
                    
                    return a.name.localizedStandardCompare(b.name) == .orderedAscending
                }
                
                if let cover = group.issues.first {
                    group.coverIssueID = cover.id
                }
                
                let item = LibraryListItem.series(group)
                items.append((firstAppearanceIndex[key] ?? 0, item))
            }
            
            for single in singles {
                let item = LibraryListItem.single(single)
                items.append((firstAppearanceIndex["single_\(single.id)"] ?? 0, item))
            }
            
            // Search Filtering
            if !currentSearchText.isEmpty {
                items = items.filter { tuple in
                    switch tuple.1 {
                    case .single(let pdf): 
                        return pdf.name.localizedCaseInsensitiveContains(currentSearchText) ||
                               pdf.metadata.title.localizedCaseInsensitiveContains(currentSearchText) ||
                               (pdf.metadata.series?.localizedCaseInsensitiveContains(currentSearchText) == true)
                    case .series(let group): 
                        return group.title.localizedCaseInsensitiveContains(currentSearchText)
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
        Task {
            try? await Task.sleep(nanoseconds: 300_000_000) // 0.3 s
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
                    withAnimation {
                        conversionManager.convertedPDFs[index].isFavorite.toggle()
                    }
                }
            case .toggleVault:
                if let index = conversionManager.convertedPDFs.firstIndex(where: { $0.id == pdf.id }) {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        conversionManager.convertedPDFs[index].isPrivate.toggle()
                    }
                    conversionManager.saveLibrary()
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
