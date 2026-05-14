import SwiftUI
import Combine

@MainActor
class LibraryViewModel: ObservableObject {
    @Published var cachedLibraryItems: [LibraryListItem] = []
    @Published var searchText: String = ""
    
    // Search Debouncing
    @Published var debouncedSearchText: String = ""
    private var cancellables = Set<AnyCancellable>()
    
    // Routing State (Migrated to global AppRouter.shared)
    // @Published var activeSheet: LibrarySheetDestination?
    // @Published var activeFullScreen: LibraryFullScreenDestination?
    
    // ✅ Phase 2: Nested Folders & Progress Filters
    @Published var currentFolderID: UUID? = nil
    @Published var filterState: LibraryFilterState = .all
    
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

    /// Active rebuild task — cancelled whenever a new one starts to prevent
    /// out-of-order UI updates when SwiftData fires rapid onChange events.
    private var rebuilTask: Task<Void, Never>?

    func updateLibraryItemsCache(pdfs: [ConvertedPDF], collections: [PDFCollection], sortOption: ModernLibraryView.SortOption) {
        // Cancel any in-flight rebuild so rapid SwiftData events (e.g. reading-progress
        // writes) don't stack up and deliver results out of order.
        rebuilTask?.cancel()

        let currentSearchText = debouncedSearchText
        let sortedPDFs = sortPDFs(pdfs, sortOption: sortOption)
        let folderID = self.currentFolderID
        let filter = self.filterState

        rebuilTask = Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            guard !Task.isCancelled else { return }

            var groups: [String: SeriesGroup] = [:]
            var singles: [ConvertedPDF] = []
            var firstAppearanceIndex: [String: Int] = [:]
            
            // ✅ PHASE 2: Ensure all child collections of the current folder exist, even if empty
            for collection in collections where collection.parentId == folderID {
                let colKey = "col_\(collection.id.uuidString)"
                groups[colKey] = SeriesGroup(id: collection.id.uuidString, title: collection.name, coverIssueID: collection.explicitCoverFileID, count: 0, issues: [])
            }
            
            for (index, pdf) in sortedPDFs.enumerated() {
                // Apply Reading Progress Filters
                if filter == .unread {
                    if let read = pdf.metadata.lastReadPage, read > 0 { continue }
                } else if filter == .reading {
                    let maxPages = max(pdf.pageCount, 1)
                    let read = pdf.metadata.lastReadPage ?? 0
                    if read == 0 || read >= maxPages - 1 { continue }
                } else if filter == .completed {
                    let maxPages = max(pdf.pageCount, 1)
                    let read = pdf.metadata.lastReadPage ?? 0
                    if read < maxPages - 1 { continue }
                }
                
                var inAnyGroup = false
                
                // 1. Process standard Publisher Series (Only at Root)
                if folderID == nil, let seriesName = pdf.metadata.series, !seriesName.isEmpty, pdf.collectionId == nil {
                    let seriesKey = "series_\(seriesName)"
                    if firstAppearanceIndex[seriesKey] == nil { firstAppearanceIndex[seriesKey] = index }
                    
                    if groups[seriesKey] == nil {
                        groups[seriesKey] = SeriesGroup(id: seriesName, title: seriesName, coverIssueID: pdf.id, count: 0, issues: [])
                    }
                    groups[seriesKey]?.issues.append(pdf)
                    groups[seriesKey]?.count += 1
                    inAnyGroup = true
                }
                
                // 2. Process Custom Collections (Events / Folders)
                if let cid = pdf.collectionId, let collection = collections.first(where: { $0.id == cid }) {
                    // Only render if the collection is a direct child of the current view
                    if collection.parentId == folderID {
                        let colKey = "col_\(collection.id.uuidString)"
                        if firstAppearanceIndex[colKey] == nil { firstAppearanceIndex[colKey] = index }
                        
                        if groups[colKey] == nil {
                            let coverID = collection.explicitCoverFileID ?? pdf.id
                            groups[colKey] = SeriesGroup(id: collection.id.uuidString, title: collection.name, coverIssueID: coverID, count: 0, issues: [])
                        }
                        groups[colKey]?.issues.append(pdf)
                        groups[colKey]?.count += 1
                        inAnyGroup = true
                    } else if cid == folderID {
                        // If the PDF is INSIDE the current folder we are viewing, render it as a single
                        inAnyGroup = false
                    } else {
                        // The PDF is in a different nested folder, hide it
                        inAnyGroup = true
                    }
                }
                
                // 3. Fallback to Singles if not in ANY group, and we are at the correct level
                if !inAnyGroup && pdf.collectionId == folderID {
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

            // Cancellation guard: don't publish a stale result if a newer rebuild
            // has already been queued by the time we finish computing.
            guard !Task.isCancelled else { return }
            let finalItems = items.map { $0.1 }

            // Publish results back to main thread
            Task { @MainActor in
                guard !Task.isCancelled else { return }
                self.cachedLibraryItems = finalItems
                
                // ✅ Phase 2 Logging Integration
                Logger.shared.log("Library Cache Rebuilt: \(finalItems.count) total UI groups rendered (Filter: \(filter.rawValue), Depth: \(folderID?.uuidString ?? "Root"))", category: "Library")
            }
        }
    }
    
    // MARK: - Action Router Endpoint
    func handleDetailAction(action: LibraryRowAction, for pdf: ConvertedPDF, conversionManager: ConversionManager) {
        switch action {
        case .read:
            AppRouter.shared.presentFullScreen(.read(pdf))
        case .details:
            AppRouter.shared.presentSheet(.details(pdf))
        case .covers:
            AppRouter.shared.presentFullScreen(.advancedWorkspace(pdf))
        case .fetchMetadata:
            AppRouter.shared.presentSheet(.searchMetadata(pdf))
        case .editMetadata:
            AppRouter.shared.presentSheet(.editMetadata(pdf))
        case .export:
            AppRouter.shared.presentSheet(.export(pdf))
        case .share:
            AppRouter.shared.presentSheet(.directShare(pdf))
        case .sync:
            AppRouter.shared.presentSheet(.cloudSync(pdf))
        case .rename:
            self.renameText = pdf.name
            self.pdfToRename = pdf
        case .addToSeries:
            AppRouter.shared.presentSheet(.seriesAssignment(pdf, isBatch: false, selection: []))
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
        case .saveToDrive:
            DriveSaveCoordinator.present { targetURL in
                guard let targetURL = targetURL else { return }
                Task { @MainActor in
                    do {
                        let count = try await LinkedLibraryScanner.shared.saveFilesToDrive(
                            [pdf],
                            targetFolderURL: targetURL
                        ) { _, _ in }
                        let msg = count > 0
                            ? "'\(pdf.name)' saved to '\(targetURL.lastPathComponent)' on your drive."
                            : "Save failed — file could not be copied to the drive."
                        Logger.shared.log(msg, category: "Drive")
                    } catch {
                        Logger.shared.log("Save to Drive failed: \(error.localizedDescription)", category: "Drive", type: .error)
                    }
                }
            }
        case .sendToKindle:
            if pdf.url.pathExtension.lowercased() == "epub" {
                AppRouter.shared.presentSheet(.directShare(pdf))
            } else {
                AppRouter.shared.presentSheet(.export(pdf))
            }
        case .convert:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            Task { await conversionManager.convertComic(pdf) }
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
        case .location:
            return pdfs.sorted {
                let rank0 = $0.sourceMode.isCloud ? 2 : ($0.sourceMode.isLinked ? 1 : 0)
                let rank1 = $1.sourceMode.isCloud ? 2 : ($1.sourceMode.isLinked ? 1 : 0)
                if rank0 != rank1 { return rank0 < rank1 }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }
    }
}

enum LibraryFilterState: String, CaseIterable, Identifiable {
    case all = "All"
    case unread = "Unread"
    case reading = "Reading"
    case completed = "Completed"
    
    var id: String { rawValue }
}
