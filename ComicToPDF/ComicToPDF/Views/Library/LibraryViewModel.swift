import SwiftUI
import Combine

@MainActor
class LibraryViewModel: ObservableObject {
    @Published var cachedLibraryItems: [LibraryListItem] = []
    private var cachedLibraryItemIDs: [String] = []
    @Published var searchText: String = ""

    // Search Debouncing
    @Published var debouncedSearchText: String = ""

    // Throttle publisher for high-frequency SwiftData onChange events (page-turn writes).
    // Only the grid-data triggers (sortOption, shelf, filter, search) fire immediately;
    // raw SwiftData row changes are absorbed by this 250ms debounce so reading never
    // causes a full cache rebuild on every page flip.
    let swiftDataDidChange = PassthroughSubject<Void, Never>()
    var swiftDataCancellable: AnyCancellable?

    private var cancellables = Set<AnyCancellable>()
    
    // Routing State
    @Published var activeSheet: LibrarySheetDestination?
    @Published var activeFullScreen: LibraryFullScreenDestination?
    
    // ✅ Phase 2: Nested Folders & Progress Filters
    @Published var currentFolderID: UUID? = nil
    @Published var filterState: LibraryFilterState = .all
    @Published var contentShelf: ContentShelf = .all
    
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

    // Called by ModernLibraryView's onChange(of: swiftDataPDFs) to absorb
    // high-frequency progress writes without queueing a full rebuild per page.
    func notifySwiftDataChanged() {
        swiftDataDidChange.send()
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
        let folderID = self.currentFolderID
        let filter = self.filterState
        let shelf = self.contentShelf
        let collectionsSnapshot = collections
        let pdfsSnapshot = pdfs
        let virtualOmnibusesSnapshot = LibraryService.shared.virtualOmnibuses
        // Snapshot linked drives so the background task doesn't capture @MainActor state.
        let linkedDrives = AppSettingsManager.shared.linkedDrives
        
        // Snapshot reading progress map on MainActor before starting background thread
        let progressMap = ReaderProgressTracker.shared.allProgress
        let progressSnapshot = Dictionary(uniqueKeysWithValues: progressMap.map { ($0.pdfID, $0) })

        rebuilTask = Task.detached(priority: .background) { () async -> Void in
            guard !Task.isCancelled else { return }

            // Perform sorting and grouping on the background thread using helper
            let finalItems = LibraryViewModel.rebuildCacheInBackground(
                pdfs: pdfsSnapshot,
                collections: collectionsSnapshot,
                virtualOmnibuses: virtualOmnibusesSnapshot,
                sortOption: sortOption,
                folderID: folderID,
                currentSearchText: currentSearchText,
                filter: filter,
                shelf: shelf,
                linkedDrives: linkedDrives,
                progressSnapshot: progressSnapshot
            )

            guard !Task.isCancelled else { return }
            let newIDs = finalItems.map(\.id)

            await MainActor.run { [weak self] in
                guard let self = self else { return }
                guard !Task.isCancelled else { return }

                // ID-equality guard: skip the SwiftUI diff entirely when nothing changed.
                // This absorbs spurious SwiftData onChange events (e.g. reading-progress
                // writes) that don't actually change what's visible in the library grid.
                guard newIDs != self.cachedLibraryItemIDs else { return }
                self.cachedLibraryItemIDs = newIDs

                withAnimation(.easeOut(duration: 0.18)) {
                    self.cachedLibraryItems = finalItems
                }

                Logger.shared.log("Library Cache Rebuilt: \(finalItems.count) total UI groups rendered (Filter: \(filter.rawValue), Shelf: \(shelf.rawValue), Depth: \(folderID?.uuidString ?? "Root"))", category: "Library")
            }
        }
    }

    static nonisolated func rebuildCacheInBackground(
        pdfs: [ConvertedPDF],
        collections: [PDFCollection],
        virtualOmnibuses: [VirtualOmnibus],
        sortOption: ModernLibraryView.SortOption,
        folderID: UUID?,
        currentSearchText: String,
        filter: LibraryFilterState,
        shelf: ContentShelf,
        linkedDrives: [AppSettingsManager.LinkedDriveEntry],
        progressSnapshot: [UUID: ReadingProgress]
    ) -> [LibraryListItem] {
        guard !Task.isCancelled else { return [] }

        // We no longer pre-sort raw PDFs because we sort grouped list items directly.
        let sortedPDFs = pdfs

        var groups: [String: SeriesGroup] = [:]
        var singles: [ConvertedPDF] = []
        var firstAppearanceIndex: [String: Int] = [:]
        
        // Build a map of series title aliases based on virtual omnibuses
        var seriesAliases: [String: String] = [:]
        for omnibus in virtualOmnibuses {
            for fileId in omnibus.fileIDs {
                if let matchedPDF = pdfs.first(where: { $0.id == fileId }),
                   let fileSeries = matchedPDF.metadata.series, !fileSeries.isEmpty {
                    seriesAliases[fileSeries.lowercased()] = omnibus.name
                }
            }
        }

        // O(1) lookup dict — replaces the O(N×M) collections.first(where:) scan inside the hot loop below.
        let collectionByID: [UUID: PDFCollection] = Dictionary(uniqueKeysWithValues: collections.map { ($0.id, $0) })

        // ── LARGE DRIVE CARDS ───────────────────────────────────────────────
        // Drives above the file-count threshold surface as a single DriveFolder
        // card rather than flooding the grid. They always appear at position 0
        // so they are visible regardless of sort order.
        var driveFolderItems: [LibraryListItem] = []
        if folderID == nil && currentSearchText.isEmpty {
            for drive in linkedDrives where drive.fileCount > LinkedLibraryScanner.largeDriveThreshold {
                driveFolderItems.append(.driveFolder(drive))
            }
        }

        // ✅ PHASE 2: Ensure all child collections of the current folder exist, even if empty
        for collection in collections where collection.parentId == folderID {
            let colKey = "col_\(collection.id.uuidString)"
            groups[colKey] = SeriesGroup(id: collection.id.uuidString, title: collection.name, coverIssueID: collection.explicitCoverFileID, count: 0, issues: [])
        }

        for (index, pdf) in sortedPDFs.enumerated() {
            guard !Task.isCancelled else { return [] }

            // ── Shelf pre-filter (content type) ─────────────────────────
            switch shelf {
            case .all: break
            case .comics:
                guard (pdf.contentType == .comic || pdf.contentType == .hybrid) && !(pdf.metadata.isManga ?? false) else { continue }
            case .manga:
                guard pdf.contentType == .manga || (pdf.metadata.isManga ?? false) else { continue }
            case .books:
                guard pdf.contentType == .book else { continue }
            case .converted:
                let nameLower = pdf.name.lowercased()
                let isConverted = pdf.lastOutputFormat != nil ||
                                  pdf.url.path.contains("/Merged/") ||
                                  nameLower.contains("_converted") ||
                                  nameLower.contains("go merge")
                guard isConverted else { continue }
            }

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
            } else if filter == .onDrive {
                // Show only files sourced from a linked external drive
                guard case .linked = pdf.sourceMode else { continue }
            } else if filter == .cloudLibrary {
                // Show only files sourced from cloud providers
                guard case .cloud = pdf.sourceMode else { continue }
            }
            let isOrphan = pdf.collectionId == nil || (collectionByID[pdf.collectionId!] == nil && !collections.isEmpty)
            var inAnyGroup = false
            
            // 1. Process standard Publisher Series (Only at Root)
            if folderID == nil, let rawSeriesName = pdf.metadata.series, !rawSeriesName.isEmpty, isOrphan {
                let seriesName = seriesAliases[rawSeriesName.lowercased()] ?? rawSeriesName
                let lowerSeries = seriesName.lowercased()
                
                // If a custom collection with matching title exists at root, coalesce into collection key
                let matchingCol = collections.first(where: { $0.parentId == folderID && $0.name.lowercased() == lowerSeries })
                let targetKey = matchingCol != nil ? "col_\(matchingCol!.id.uuidString)" : "series_\(seriesName)"
                
                if firstAppearanceIndex[targetKey] == nil { firstAppearanceIndex[targetKey] = index }
                
                if groups[targetKey] == nil {
                    let title = matchingCol?.name ?? seriesName
                    let coverID = matchingCol?.explicitCoverFileID ?? pdf.id
                    groups[targetKey] = SeriesGroup(id: matchingCol?.id.uuidString ?? seriesName, title: title, coverIssueID: coverID, count: 0, issues: [])
                }
                groups[targetKey]?.issues.append(pdf)
                groups[targetKey]?.count += 1
                inAnyGroup = true
            }
            
            // 2. Process Custom Collections (Events / Folders)
            if let cid = pdf.collectionId, let collection = collectionByID[cid] {
                // Only render if the collection is a direct child of the current view
                if collection.parentId == folderID {
                    let colKey = "col_\(collection.id.uuidString)"
                    if firstAppearanceIndex[colKey] == nil { firstAppearanceIndex[colKey] = index }
                    
                    if groups[colKey] == nil {
                        let coverID = collection.explicitCoverFileID ?? pdf.id
                        groups[colKey] = SeriesGroup(id: collection.id.uuidString, title: collection.name, coverIssueID: coverID, count: 0, issues: [])
                    }
                    if !(groups[colKey]?.issues.contains(where: { $0.id == pdf.id }) ?? false) {
                        groups[colKey]?.issues.append(pdf)
                        groups[colKey]?.count += 1
                    }
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
            if !inAnyGroup && (isOrphan ? folderID == nil : pdf.collectionId == folderID) {
                let singleKey = "single_\(pdf.id)"
                if firstAppearanceIndex[singleKey] == nil { firstAppearanceIndex[singleKey] = index }
                singles.append(pdf)
            }
        }
        
        // Post-Process Collections to apply manual sorting
        for collection in collections {
            guard !Task.isCancelled else { return [] }
            let colKey = "col_\(collection.id.uuidString)"
            if var group = groups[colKey], let manualOrder = collection.manualSortOrder, !manualOrder.isEmpty {
                // Create a lookup dictionary for fast indexing
                let orderDict = Dictionary(uniqueKeysWithValues: manualOrder.enumerated().map { ($0.element, $0.offset) })
                // Sort the issues array based on the manual order. If not in the list, push to back
                group.issues.sort { pdf1, pdf2 in
                    let idx1 = orderDict[pdf1.id] ?? Int.max
                    let idx2 = orderDict[pdf2.id] ?? Int.max
                    if idx1 == idx2 {
                        let t1 = pdf1.metadata.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? pdf1.name : pdf1.metadata.title
                        let t2 = pdf2.metadata.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? pdf2.name : pdf2.metadata.title
                        return t1.localizedStandardCompare(t2) == .orderedAscending
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
        for (key, group) in groups {
            guard !Task.isCancelled else { return [] }
            var mutableGroup = group
            if key.starts(with: "col_") {
                let overlappingSeriesKey = "series_\(mutableGroup.title)"
                if let orphanSeries = groups[overlappingSeriesKey] {
                    // Merge the items into the collection group!
                    for issue in orphanSeries.issues {
                        if !mutableGroup.issues.contains(where: { $0.id == issue.id }) {
                            mutableGroup.issues.append(issue)
                            mutableGroup.count += 1
                        }
                    }
                    groups[key] = mutableGroup
                    keysToRemove.append(overlappingSeriesKey)
                }
            }
        }
        for k in keysToRemove {
            groups.removeValue(forKey: k)
        }
        
        var items: [LibraryListItem] = []

        for (_, group) in groups {
            guard !Task.isCancelled else { return [] }
            var mutableGroup = group
            // ── SHELF FILTER: Drop series that have zero visible issues ─────
            if shelf != .all && mutableGroup.issues.isEmpty { continue }

            // ✅ PHASE 4: Internal Sorting & Cover Assigner
            let hasVols = mutableGroup.issues.contains { Double($0.metadata.volume ?? "") != nil }
            mutableGroup.issues = mutableGroup.issues
                .map { pdf -> (ConvertedPDF, Double, Double) in
                    (pdf,
                     Double(pdf.metadata.volume ?? "")      ?? Double.infinity,
                     Double(pdf.metadata.issueNumber ?? "") ?? Double.infinity)
                }
                .sorted { a, b in
                    if hasVols, a.1 != b.1 { return a.1 < b.1 }
                    if a.2 != b.2 { return a.2 < b.2 }
                    let t1 = a.0.metadata.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? a.0.name : a.0.metadata.title
                    let t2 = b.0.metadata.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? b.0.name : b.0.metadata.title
                    return t1.localizedStandardCompare(t2) == .orderedAscending
                }
                .map(\.0)

            if let cover = mutableGroup.issues.first {
                mutableGroup.coverIssueID = cover.id
            }

            // Precompute read and new issue counts on the background thread using our snapshot
            mutableGroup.readCount = mutableGroup.issues.filter {
                (progressSnapshot[$0.id]?.completionFraction ?? 0.0) >= 0.95
            }.count
            mutableGroup.newCount = mutableGroup.issues.filter {
                progressSnapshot[$0.id] == nil
            }.count

            items.append(.series(mutableGroup))
        }

        for single in singles {
            guard !Task.isCancelled else { return [] }
            items.append(.single(single))
        }

        // Search Filtering
        if !currentSearchText.isEmpty {
            items = items.filter { item in
                switch item {
                case .single(let pdf):
                    return pdf.name.localizedCaseInsensitiveContains(currentSearchText) ||
                           pdf.metadata.title.localizedCaseInsensitiveContains(currentSearchText) ||
                           (pdf.metadata.series?.localizedCaseInsensitiveContains(currentSearchText) == true)
                case .series(let group):
                    return group.title.localizedCaseInsensitiveContains(currentSearchText)
                case .driveFolder(let entry):
                    return entry.displayName.localizedCaseInsensitiveContains(currentSearchText)
                }
            }
        }

        // Sort items directly based on user preference!
        items.sort { item1, item2 in
            switch sortOption {
            case .dateAdded:
                let d1 = item1.dateAdded
                let d2 = item2.dateAdded
                if d1 != d2 { return d1 > d2 } // Newest first
                return item1.title.localizedStandardCompare(item2.title) == .orderedAscending
            case .name:
                return item1.title.localizedStandardCompare(item2.title) == .orderedAscending
            case .size:
                let s1 = item1.size
                let s2 = item2.size
                if s1 != s2 { return s1 > s2 } // Largest first
                return item1.title.localizedStandardCompare(item2.title) == .orderedAscending
            case .favorites:
                let f1 = item1.isFavorite
                let f2 = item2.isFavorite
                if f1 != f2 { return f1 && !f2 } // Favorites first
                return item1.title.localizedStandardCompare(item2.title) == .orderedAscending
            case .type:
                let s1 = item1.isSeries
                let s2 = item2.isSeries
                if s1 != s2 { return s1 && !s2 } // Series first
                return item1.title.localizedStandardCompare(item2.title) == .orderedAscending
            case .extensionType:
                let ext1 = item1.fileExtensionString
                let ext2 = item2.fileExtensionString
                if ext1 != ext2 { return ext1.localizedStandardCompare(ext2) == .orderedAscending }
                return item1.title.localizedStandardCompare(item2.title) == .orderedAscending
            case .location:
                let rank1 = item1.locationRank
                let rank2 = item2.locationRank
                if rank1 != rank2 { return rank1 < rank2 }
                return item1.title.localizedStandardCompare(item2.title) == .orderedAscending
            }
        }

        guard !Task.isCancelled else { return [] }

        // Prepend large drive cards (always pinned to top of library grid)
        return driveFolderItems + items
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
            self.presentShareSheet(for: pdf)
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
                self.presentShareSheet(for: pdf)
            } else {
                AppRouter.shared.presentSheet(.export(pdf))
            }
        case .convert:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            if case .cloud = pdf.sourceMode {
                Task {
                    await CloudDownloadManager.shared.downloadAndStore(
                        pdf: pdf,
                        thenConvert: false,
                        manager: conversionManager
                    )
                    await MainActor.run {
                        if let updated = conversionManager.convertedPDFs.first(where: { $0.id == pdf.id }) {
                            // Already on @MainActor — call directly instead of dispatching again.
                            // DispatchQueue.main.async inside MainActor.run adds an extra hop
                            // and leaves a confusing breadcrumb in async stack traces.
                            AppRouter.shared.presentSheet(.convert(updated))
                        }
                    }
                }
            } else {
                AppRouter.shared.presentSheet(.convert(pdf))
            }
        }
    }
    
    private func presentShareSheet(for pdf: ConvertedPDF) {
        Task {
            do {
                let resolved = try await CloudDownloadManager.shared.resolveLocalURL(for: pdf)
                let localSourceURL = resolved.url
                let needsSourceCleanup = resolved.needsCleanup
                
                let fileManager = FileManager.default
                let tempDir = fileManager.temporaryDirectory.appendingPathComponent("InksyncShare", isDirectory: true)
                try? fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
                let exportURL = tempDir.appendingPathComponent(pdf.name)
                try? fileManager.removeItem(at: exportURL)
                
                let didAccess = localSourceURL.startAccessingSecurityScopedResource()
                defer {
                    if didAccess { localSourceURL.stopAccessingSecurityScopedResource() }
                    if needsSourceCleanup { try? fileManager.removeItem(at: localSourceURL) }
                }
                
                try fileManager.copyItem(at: localSourceURL, to: exportURL)
                
                await MainActor.run {
                    AppRouter.shared.presentSheet(.directShare(exportURL))
                }
            } catch {
                Logger.shared.log("Share preparation failed: \(error.localizedDescription)", category: "Library", type: .error)
            }
        }
    }
    
    // Additional Logic Handlers...
    static nonisolated func getDisplayTitle(_ pdf: ConvertedPDF) -> String {
        let title = pdf.metadata.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? pdf.name : pdf.metadata.title
    }

    static nonisolated func sortPDFs(_ pdfs: [ConvertedPDF], sortOption: ModernLibraryView.SortOption) -> [ConvertedPDF] {
        switch sortOption {
        case .dateAdded: return pdfs.sorted { $0.lastModified > $1.lastModified }
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
            return getDisplayTitle($0).localizedStandardCompare(getDisplayTitle($1)) == .orderedAscending
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
                return getDisplayTitle($0).localizedStandardCompare(getDisplayTitle($1)) == .orderedAscending
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
                return getDisplayTitle($0).localizedStandardCompare(getDisplayTitle($1)) == .orderedAscending
            }
        }
    }
}

enum LibraryFilterState: String, CaseIterable, Identifiable {
    case all          = "All"
    case unread       = "Unread"
    case reading      = "Reading"
    case completed    = "Completed"
    case onDrive      = "On Drive"
    case cloudLibrary = "Cloud"

    var id: String { rawValue }
}

// MARK: - Content Shelf

enum ContentShelf: String, CaseIterable, Identifiable {
    case all    = "All"
    case comics = "Comics"
    case manga  = "Manga"
    case books  = "Books"
    case converted = "Converted"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .all:    return "square.grid.2x2.fill"
        case .comics: return "books.vertical.fill"
        case .manga:  return "text.book.closed.fill"
        case .books:  return "book.fill"
        case .converted: return "arrow.triangle.2.circlepath"
        }
    }

    var accentColor: Color {
        switch self {
        case .all:
            return Theme.text
        case .comics:
            let hex = UserDefaults.standard.string(forKey: "comicBadgeColorHex") ?? "#3d6fff"
            return Color(hex: hex)
        case .manga:
            let hex = UserDefaults.standard.string(forKey: "mangaBadgeColorHex") ?? "#ff5a36"
            return Color(hex: hex)
        case .books:
            let hex = UserDefaults.standard.string(forKey: "booksBadgeColorHex") ?? "#14b8a6"
            return Color(hex: hex)
        case .converted:
            let hex = UserDefaults.standard.string(forKey: "convertedBadgeColorHex") ?? "#f5a623"
            return Color(hex: hex)
        }
    }
}
