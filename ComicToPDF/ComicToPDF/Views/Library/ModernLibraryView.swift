import SwiftUI
import UniformTypeIdentifiers
import Combine
import SwiftData
import CoreData

struct ModernLibraryView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @EnvironmentObject var settingsManager: AppSettingsManager
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @State private var iPadSidebarSelection: String? = "all"
    @State private var isCollectionsExpanded: Bool = true
    @ObservedObject private var router = AppRouter.shared
    @StateObject private var viewModel = LibraryViewModel()
    @ObservedObject private var jobQueue = ConversionJobQueue.shared
    
    @Query(sort: \SDConvertedPDF.lastModified, order: .reverse) private var swiftDataPDFs: [SDConvertedPDF]
    @Query private var swiftDataCollections: [SDPDFCollection]
    
    @Binding var selectedPDF: ConvertedPDF?
    @Binding var isBatchMode: Bool
    @Binding var multiSelection: Set<UUID>
    @Binding var showingBatchMergeReorder: Bool
    @Binding var batchMergeItems: [ConvertedPDF]
    
    // Navigation Mode
    var useNavigationStack: Bool = false
    var onFolderImport: (() -> Void)? = nil

    @State private var listRenameGroup: SeriesGroup? = nil
    @State private var listRenamePendingName: String = ""

    // View Style State
    enum LibraryViewStyle: String {
        case list = "List"
        case grid = "Grid"
    }
    @AppStorage("libraryViewStyle") private var viewStyle: LibraryViewStyle = .grid
    @AppStorage("libraryTapAction") private var tapAction: LibraryTapAction = .read
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding: Bool = false
    @AppStorage("libraryHeaderPinMode") private var headerPinModeRaw: String = HeaderPinMode.auto.rawValue
    @State private var scrollToTopTrigger = false
    @State private var isScrolledPastHeader: Bool = false
    /// Detected via UIDevice orientation notification — landscape forces the header
    /// into compact mode regardless of pin/scroll state.
    @State private var isLandscape: Bool = false
    @Environment(\.verticalSizeClass) private var vSizeClass
    @State private var isSearchActive: Bool = false


    /// Derived header collapse state.
    /// Priority: landscape (always collapsed) → pin lock → scroll threshold.
    private var isHeaderCollapsed: Bool {
        // iPhone landscape uses vSizeClass == .compact; iPad landscape is detected via isLandscape
        if vSizeClass == .compact || isLandscape { return true }
        switch HeaderPinMode(rawValue: headerPinModeRaw) ?? .auto {
        case .auto:            return isScrolledPastHeader
        case .pinnedExpanded:  return false
        case .pinnedCollapsed: return true
        }
    }

    private var headerPinMode: HeaderPinMode {
        HeaderPinMode(rawValue: headerPinModeRaw) ?? .auto
    }

    // Storage Transfer State
    @State private var isStorageTransferring = false
    @State private var transferProgress: Double = 0.0
    @State private var transferStatus: String = ""
    
    // UI Options Enum (kept for picker logic)
    enum SortOption: String, CaseIterable, Identifiable {
        case dateAdded = "Most Recent"
        case name = "Name"
        case size = "Size"
        case favorites = "Favorites First"
        case type = "Single / Series"
        case extensionType = "Format (CBZ/PDF)"
        case location = "Storage (Local / Cloud)"
        var id: String { rawValue }
    }
    @State private var sortOption: SortOption = .dateAdded
    
    // 🗑 Removed Native Importer Bypass State
    // PERF D-H3: static let avoids UTType system registry query on every render
    private static let allowedImportTypes: [UTType] = [
        .folder, .pdf, .zip, .epub,
        UTType(filenameExtension: "cbz"),
        UTType(filenameExtension: "cbr"),
        UTType(filenameExtension: "cb7"),
        UTType(filenameExtension: "cbt")
    ].compactMap { $0 }

    // PERF D-C1: Cached DTO mapping — previously recomputed on every render.
    // @State so SwiftUI only re-renders when the array identity actually changes.
    // Rebuilt only in rebuildNativeCache() which is gated behind the 250ms debounce
    // for SwiftData page-turn writes and immediate for low-frequency user actions.
    @State private var cachedVisiblePDFs: [ConvertedPDF] = []
    @State private var cachedCollections: [PDFCollection] = []
    // PERF D-H2: reviewCount scanned 15K trimmingCharacters per render — now cached.
    @State private var cachedReviewCount: Int = 0

    private func rebuildNativeCache() {
        let mapped = swiftDataPDFs.map { $0.toDTO() }
        cachedVisiblePDFs = settingsManager.isVaultUnlocked ? mapped : mapped.filter { !$0.isPrivate }
        cachedCollections = swiftDataCollections.map { $0.toDTO() }
        cachedReviewCount = mapped.filter { pdf in
            let seriesEmpty = pdf.metadata.series?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
            let authorEmpty = pdf.metadata.author?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
            let titleEmpty  = pdf.metadata.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return seriesEmpty || authorEmpty || titleEmpty
        }.count
        MetadataMatchService.shared.rebuildClusters(pdfs: cachedVisiblePDFs)
    }

    var body: some View {
        shellWithNotifications
            // PERF D-C1 boot fix: seed the cache before the view fully renders
            // so notification-based lookups (Resume, Handoff) fire correctly even
            // if onAppear hasn't run yet (e.g. app launch via Spotlight/widget).
            .task(id: swiftDataPDFs.count) {
                if cachedVisiblePDFs.isEmpty { rebuildNativeCache() }
            }
    }

    // MARK: - Notification Shell (onReceive + debug overlay)
    @ViewBuilder
    private var shellWithNotifications: some View {
        shellWithChangeHandlers
            .onReceive(NotificationCenter.default.publisher(for: .openMergedBook)) { notification in
                if let newBook = notification.object as? ConvertedPDF {
                    Task {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        await MainActor.run { AppRouter.shared.presentFullScreen(.read(newBook)) }
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .handoffRequested)) { notification in
                if let userInfo = notification.userInfo,
                   let pdfID = userInfo["pdfID"] as? UUID,
                   let pageIndex = userInfo["pageIndex"] as? Int {
                    // Search cached list first; fall back to conversionManager for cold-launch
                    let targetPDF = cachedVisiblePDFs.first(where: { $0.id == pdfID })
                        ?? conversionManager.convertedPDFs.first(where: { $0.id == pdfID })
                    if let targetPDF = targetPDF {
                        var progress = ReaderProgressTracker.shared.progress(for: targetPDF.id) ?? ReadingProgress(pdfID: targetPDF.id, lastOpenedAt: Date(), currentPageIndex: pageIndex, totalPagesRead: 1, completionFraction: 0, readingSessionDates: [])
                        progress.currentPageIndex = pageIndex
                        ReaderProgressTracker.shared.update(progress)
                        Task {
                            try? await Task.sleep(nanoseconds: 300_000_000)
                            await MainActor.run { AppRouter.shared.presentFullScreen(.read(targetPDF)) }
                        }
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .inkTabDoubleTapLibrary)) { _ in
                HapticEngine.selection()
                NotificationCenter.default.post(name: Notification.Name("Library_ScrollToTop"), object: nil)
            }
            .onReceive(NotificationCenter.default.publisher(for: .requestSeriesRename)) { notification in
                guard let group = notification.object as? SeriesGroup else { return }
                listRenameGroup = group
                listRenamePendingName = group.title
            }
            .onReceive(NotificationCenter.default.publisher(for: .inksyncResumeLastRead)) { notification in
                if let mostRecent = ReaderProgressTracker.shared.recentSessions().first {
                    let pdf = cachedVisiblePDFs.first(where: { $0.id == mostRecent.pdfID })
                        ?? conversionManager.convertedPDFs.first(where: { $0.id == mostRecent.pdfID })
                    if let pdf = pdf {
                        let readingMode = notification.userInfo?["readingMode"] as? String
                        AppRouter.shared.presentFullScreen(.read(pdf, initialReadingMode: readingMode))
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .inksyncOpenShelf)) { _ in
                // Close any open sheets or full screen covers to reveal the library shelf
                router.activeSheet = nil
                router.activeFullScreen = nil
            }
            .onReceive(NotificationCenter.default.publisher(for: .inksyncOpenBook)) { notification in
                if let searchTitle = notification.userInfo?["searchTitle"] as? String {
                    let pdf = cachedVisiblePDFs.first(where: { $0.name.localizedCaseInsensitiveContains(searchTitle) || $0.metadata.title.localizedCaseInsensitiveContains(searchTitle) })
                    if let pdf = pdf {
                        AppRouter.shared.presentFullScreen(.read(pdf))
                    } else {
                        // Just set the search text if not explicitly found, so user can see partial matches
                        viewModel.searchText = searchTitle
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("OPDSDownloadCompleted"))) { note in
                // Item 9 — Background OPDS download completed; import into library
                if let fileURL = note.userInfo?["fileURL"] as? URL {
                    Task { await conversionManager.processImportedFiles(urls: [fileURL]) }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name.NSManagedObjectContextDidSave)) { _ in
                // Background context saves trigger NSManagedObjectContextDidSave.
                // We force-merge changes on the main context and refresh the cached items.
                InksyncProApp.sharedModelContainer.mainContext.processPendingChanges()
                rebuildNativeCache()
                viewModel.updateLibraryItemsCache(pdfs: cachedVisiblePDFs, collections: cachedCollections, sortOption: sortOption)
            }
            .overlay(alignment: .bottomTrailing) {
                if settingsManager.conversionSettings.showEditorDebug {
                    LibraryDebugHUD(
                        allItems: viewModel.cachedLibraryItems,
                        conversionManager: conversionManager,
                        viewModel: viewModel
                    )
                }
            }
    }

    // MARK: - Change Handler Shell (onAppear + onChange)
    @ViewBuilder
    private var shellWithChangeHandlers: some View {
        shellWithAlerts
            .onAppear {
                conversionManager.backfillMissingThumbnails()
                rebuildNativeCache()
                viewModel.updateLibraryItemsCache(pdfs: cachedVisiblePDFs, collections: cachedCollections, sortOption: sortOption)

                // Seed landscape state immediately (handles cold-launch in landscape)
                let size = UIScreen.main.bounds.size
                isLandscape = size.width > size.height

                // PERF D-C1: debounce absorbs page-turn bursts; rebuilds DTO map once per 250ms
                viewModel.swiftDataCancellable = viewModel.swiftDataDidChange
                    .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
                    .sink { [weak viewModel] in
                        guard let vm = viewModel else { return }
                        self.rebuildNativeCache()
                        vm.updateLibraryItemsCache(pdfs: self.cachedVisiblePDFs, collections: self.cachedCollections, sortOption: self.sortOption)
                    }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
                let size = UIScreen.main.bounds.size
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                    isLandscape = size.width > size.height
                }
            }
            // Raw SwiftData row changes: send through the debounced publisher
            // instead of calling updateLibraryItemsCache directly.
            .onChange(of: swiftDataPDFs) { viewModel.notifySwiftDataChanged() }
            // All other triggers are low-frequency and user-initiated — rebuild immediately.
            .onChange(of: sortOption) {
                rebuildNativeCache()
                viewModel.updateLibraryItemsCache(pdfs: cachedVisiblePDFs, collections: cachedCollections, sortOption: sortOption)
            }
            .onChange(of: swiftDataCollections) {
                rebuildNativeCache()
                viewModel.updateLibraryItemsCache(pdfs: cachedVisiblePDFs, collections: cachedCollections, sortOption: sortOption)
            }
            .onChange(of: viewModel.debouncedSearchText) {
                viewModel.updateLibraryItemsCache(pdfs: cachedVisiblePDFs, collections: cachedCollections, sortOption: sortOption)
            }
            .onChange(of: viewModel.filterState) {
                viewModel.updateLibraryItemsCache(pdfs: cachedVisiblePDFs, collections: cachedCollections, sortOption: sortOption)
            }
            .onChange(of: viewModel.contentShelf) {
                viewModel.updateLibraryItemsCache(pdfs: cachedVisiblePDFs, collections: cachedCollections, sortOption: sortOption)
            }
            .onChange(of: viewModel.currentFolderID) {
                viewModel.updateLibraryItemsCache(pdfs: cachedVisiblePDFs, collections: cachedCollections, sortOption: sortOption)
            }
    }

    // MARK: - Alert Shell (rootShell + alerts + onDrop)
    @ViewBuilder
    private var shellWithAlerts: some View {
        rootShell
            .alert("Rename Series", isPresented: Binding(
                get: { listRenameGroup != nil },
                set: { if !$0 { listRenameGroup = nil } }
            )) {
                TextField("Series Name", text: $listRenamePendingName)
                    .autocorrectionDisabled()
                Button("Rename") {
                    guard let group = listRenameGroup else { return }
                    let newName = listRenamePendingName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !newName.isEmpty, newName != group.title else { listRenameGroup = nil; return }
                    
                    if let folderUUID = UUID(uuidString: group.id),
                       let colIdx = conversionManager.collections.firstIndex(where: { $0.id == folderUUID }) {
                        conversionManager.collections[colIdx].name = newName
                    }
                    
                    for pdf in group.issues {
                        if let idx = conversionManager.convertedPDFs.firstIndex(where: { $0.id == pdf.id }) {
                            conversionManager.convertedPDFs[idx].metadata.series = newName
                        }
                    }
                    conversionManager.saveLibrary()
                    listRenameGroup = nil
                }
                Button("Cancel", role: .cancel) { listRenameGroup = nil }
            } message: {
                Text("This will rename all \(listRenameGroup?.count ?? 0) issues in this series.")
            }
            .alert("Rename File", isPresented: Binding(
                get: { viewModel.pdfToRename != nil },
                set: { if !$0 { viewModel.pdfToRename = nil } }
            )) {
                TextField("New Name", text: $viewModel.renameText)
                Button("Cancel", role: .cancel) { }
                Button("Rename") {
                    if let pdf = viewModel.pdfToRename {
                        conversionManager.renamePDF(pdf, to: viewModel.renameText)
                    }
                }
            }
            }
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
                loadFiles(from: providers)
                return true
            }
    }

    // MARK: - Root Shell (split out to avoid type-checker timeout)
    @ViewBuilder
    private var rootShell: some View {
        ZStack(alignment: .top) {
            Color.clear.ignoresSafeArea()
            
            // Edge-to-edge content
            libraryContent
                .safeAreaInset(edge: .bottom) {
                    if isBatchMode { batchBottomToolbar.transition(.move(edge: .bottom)) }
                }
                .overlay(alignment: .top) { storageTransferBanner }
                .fullScreenCover(item: $router.activeFullScreen) { dest in
                    switch dest {
                    case .read(let pdf, _):
                        UnifiedReaderView(pdf: pdf, allBooks: conversionManager.convertedPDFs)
                    case .advancedWorkspace(let pdf):
                        AdvancedWorkspaceView(pdf: pdf).environmentObject(conversionManager)
                    case .smartCollection(let rule):
                        SmartCollectionDetailView(rule: rule).environmentObject(conversionManager)
                    }
                }
                .sheet(item: $router.activeSheet) { item in destinationSheet(for: item) }

            // Branding Overlay
            VStack {
                HStack(spacing: 8) {
                    Image(systemName: "square.fill.on.square.fill")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Color.inkBlue)
                    Text("InkSync Pro")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.inkTextPrimary)
                    Spacer()
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)
                Spacer()
            }
            .ignoresSafeArea(edges: .bottom)
            
            // Omni-Dock Overlay
            OmniDockView(
                contentShelf: $viewModel.contentShelf,
                filterState: $viewModel.filterState,
                sortOption: Binding(get: { sortOption }, set: { sortOption = $0; _ = viewModel.sortPDFs(cachedVisiblePDFs, sortOption: $0) }),
                isBatchMode: $isBatchMode,
                viewStyle: Binding(get: { viewStyle }, set: { viewStyle = $0 }),
                currentFolderID: $viewModel.currentFolderID,
                collections: cachedCollections,
                onWorkArea: { AppRouter.shared.presentSheet(.inbox) },
                onImport: onFolderImport ?? {},
                onSettings: { NotificationCenter.default.post(name: NSNotification.Name("ShowSettingsInspector"), object: nil) },
                onVaultToggle: handleVaultToggle,
                onSearch: { withAnimation(.spring) { isSearchActive.toggle() } }
            )
            .ignoresSafeArea(edges: .bottom)
            
            // Search Overlay
            if isSearchActive {
                VStack {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundColor(.gray)
                        TextField("Search library...", text: $viewModel.searchText)
                            .textFieldStyle(.plain)
                            .foregroundColor(.white)
                        if !viewModel.searchText.isEmpty {
                            Button(action: { viewModel.searchText = "" }) {
                                Image(systemName: "xmark.circle.fill").foregroundColor(.gray)
                            }
                        }
                        Button("Cancel") {
                            withAnimation(.spring) {
                                viewModel.searchText = ""
                                isSearchActive = false
                            }
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.inkBlue)
                        .padding(.leading, 8)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.15)))
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
                    .shadow(color: .black.opacity(0.2), radius: 10, y: 5)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    
                    Spacer()
                }
                .zIndex(100)
            }
        }
    }



    // MARK: - Storage Transfer Banner (extracted to reduce body complexity)
    @ViewBuilder
    private var storageTransferBanner: some View {
        if isStorageTransferring {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Color(hex: "#7B5EA7"))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Storage Transfer")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.text)
                        Text(transferStatus)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Text("\(Int(transferProgress * 100))%")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(hex: "#7B5EA7"))
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.surface).frame(height: 3)
                        Capsule()
                            .fill(Color(hex: "#7B5EA7"))
                            .frame(width: geo.size.width * transferProgress, height: 3)
                            .animation(.easeInOut(duration: 0.3), value: transferProgress)
                    }
                }
                .frame(height: 3)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
            .padding(.top, 60)
            .padding(.horizontal, 40)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
    
    // MARK: - Extracted Router UI
    @ViewBuilder
    private func destinationSheet(for item: LibrarySheetDestination) -> some View {
        switch item {
        case .inbox:
            NavigationStack {
                InboxReviewView()
                    .environmentObject(conversionManager)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("Done") {
                                AppRouter.shared.dismissSheet()
                            }
                            .foregroundColor(.inkBlue)
                        }
                    }
            }
            
        case .metadataInbox:
            NavigationStack {
                MetadataInboxView()
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("Done") {
                                AppRouter.shared.dismissSheet()
                            }
                            .foregroundColor(.inkBlue)
                        }
                    }
            }
            
        case .stats: ReadingStatsView()
 
        case .smartListImporter: SmartListImporterView().environmentObject(conversionManager)
        case .wifi: WiFiView()
        case .merge: FileMergeView()
        case .cloudBrowser: CloudBrowserPickerView()
            .environmentObject(conversionManager)
        case .cloudSync(let pdf): CloudSyncView(targetPDF: pdf)
        case .export(let pdf): DualExportView(pdf: pdf)
        case .directShare(let pdf): ShareSheet(activityItems: [pdf.url])
        case .details(let pdf):
            MediaDetailSheet(pdf: pdf, onAction: { action in
                viewModel.handleDetailAction(action: action, for: pdf, conversionManager: conversionManager)
            })
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        case .searchMetadata(let pdf): MetadataSearchSheet(pdf: pdf)
        case .reviewMetadata: BatchMetadataFetchView(pdfs: conversionManager.failedMetadataPDFs, conversionManager: conversionManager)
        case .editMetadata(let pdf): AdvancedMetadataEditorView(pdf: pdf)
        case .batchMetadata(let pdfs): BatchMetadataEditorView(selectedPDFs: pdfs)
        case .cognitiveBatchRenamer(let pdfs):
            BatchLocalRenamerView(pdfs: pdfs).environmentObject(conversionManager)
 
        case .seriesAssignment(let pdf, let isBatch, let selection):
            CollectionEditorSheet { name, icon, color in
                if let singlePDF = pdf, !name.trimmingCharacters(in: .whitespaces).isEmpty {
                    conversionManager.assignToSeries(singlePDF, seriesName: name)
                    conversionManager.createCollection(name: name, icon: icon, color: color)
                } else if isBatch {
                    let cleanName = name.trimmingCharacters(in: .whitespaces)
                    if !cleanName.isEmpty && !selection.isEmpty {
                        for item in selection { conversionManager.assignToSeries(item, seriesName: cleanName) }
                        conversionManager.createCollection(name: cleanName, icon: icon, color: color)
                        isBatchMode = false
                        multiSelection.removeAll()
                    }
                }
            }
            .environmentObject(conversionManager)
        case .convert(let pdf):
            NavigationStack {
                ConvertView(pdf: pdf)
                    .environmentObject(conversionManager)
                    .environmentObject(settingsManager)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button("Close") {
                                AppRouter.shared.dismissSheet()
                            }
                        }
                    }
            }
        }
    }
    
    // MARK: - Actions
    private func handleSelectAll() {
        let totalVisibleItems = viewModel.cachedLibraryItems.reduce(0) { count, item in
            switch item {
            case .single: return count + 1
            case .series(let grp): return count + grp.issues.count
            case .driveFolder: return count   // drive cards are not batch-selectable
            }
        }
        let isAllSelected = totalVisibleItems > 0 && multiSelection.count >= totalVisibleItems
        if isAllSelected {
            multiSelection.removeAll()
        } else {
            let allIds = viewModel.cachedLibraryItems.flatMap { item -> [UUID] in
                switch item {
                case .single(let pdf): return [pdf.id]
                case .series(let group): return group.issues.map { $0.id }
                case .driveFolder: return []
                }
            }
            allIds.forEach { multiSelection.insert($0) }
        }
    }

    private func handleVaultToggle() {
        if settingsManager.isVaultUnlocked {
            withAnimation { settingsManager.isVaultUnlocked = false }
        } else {
            Task {
                if await SecurityManager.shared.authenticate() {
                    await MainActor.run { withAnimation { settingsManager.isVaultUnlocked = true } }
                }
            }
        }
    }

    // MARK: - Job Banner Helpers
    private func jobBannerIcon(_ job: ConversionJob) -> String {
        switch job.status {
        case .suspended:       return "pause.circle.fill"
        case .failed:          return "exclamationmark.circle.fill"
        case .waitingForDownload: return "arrow.down.circle.fill"
        default:               return "arrow.triangle.2.circlepath.circle.fill"
        }
    }

    private func jobBannerColor(_ job: ConversionJob) -> Color {
        switch job.status {
        case .failed:    return Theme.red
        case .suspended: return Theme.orange
        default:         return Theme.blue
        }
    }

    private func jobBannerMessage(_ job: ConversionJob) -> String {
        switch job.status {
        case .waitingForDownload: return "Downloading from cloud..."
        case .extracting:         return "Extracting & converting..."
        case .merging:            return "Merging volumes..."
        case .suspended:          return "Conversion paused — tap Resume to continue"
        case .failed:             return "Download failed — tap Retry to try again"
        default:                  return ""
        }
    }
    
    private func loadFiles(from providers: [NSItemProvider]) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { (data, error) in
                    // NSItemProvider completion fires on an arbitrary background thread.
                    // @MainActor hop is required before touching conversionManager.
                    if let urlData = data as? Data, let url = URL(dataRepresentation: urlData, relativeTo: nil) {
                        Task { @MainActor in await conversionManager.processImportedFiles(urls: [url]) }
                    } else if let url = data as? URL {
                        Task { @MainActor in await conversionManager.processImportedFiles(urls: [url]) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var libraryContent: some View {
        VStack(spacing: 0) {
            // MARK: - Legacy Header Removed
            // The Omni-Dock now handles all navigation and filtering.
            Spacer().frame(height: 60) // Top padding to prevent overlap with the status bar and branding


            if MetadataMatchService.shared.activeClusters.contains(where: {
                if case .matched = $0.status { return false }
                return true
            }) {
                HStack {
                    Image(systemName: "square.stack.3d.up.badge.a.fill")
                        .foregroundColor(.purple)
                        .font(.system(size: 16))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Metadata Review")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(Theme.text)
                        Text("Identify your series to activate Character Maps.")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textSecondary)
                    }
                    Spacer()
                    Button("Match Now") {
                        AppRouter.shared.presentSheet(.metadataInbox)
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.purple.opacity(0.2), in: Capsule())
                    .foregroundColor(.purple)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial)
                .overlay(Rectangle().frame(height: 1).foregroundColor(Color.white.opacity(0.1)), alignment: .bottom)
            }

            disconnectedDrivesBanner
            pendingJobsBanner

            // Daily Brief and Recently Added sections removed for an uncluttered bookshelf view.

            // MARK: - Breadcrumb Navigation for Nested Folders
            if let folderID = viewModel.currentFolderID,
               let folder = conversionManager.collections.first(where: { $0.id == folderID }) {
                breadcrumbRow(folder: folder)
            }

            // MARK: - Discrete Layout Layers
            if viewStyle == .list {
                LibraryListView(
                    items: viewModel.cachedLibraryItems,
                    isBatchMode: $isBatchMode,
                    multiSelection: $multiSelection,
                    useNavigationStack: useNavigationStack,
                    tapAction: $tapAction,
                    selectedPDF: $selectedPDF,
                    onAction: { (action: LibraryRowAction, pdf: ConvertedPDF) in viewModel.handleDetailAction(action: action, for: pdf, conversionManager: conversionManager) },
                    onImport: { NotificationCenter.default.post(name: NSNotification.Name("ShowImportQueue"), object: nil) },
                    onFolderTap: { uuid in viewModel.currentFolderID = uuid },
                    onDropApplied: {
                        let livePDFs = settingsManager.isVaultUnlocked
                            ? conversionManager.convertedPDFs
                            : conversionManager.convertedPDFs.filter { !$0.isPrivate }
                        viewModel.updateLibraryItemsCache(
                            pdfs: livePDFs,
                            collections: conversionManager.collections,
                            sortOption: sortOption
                        )
                    },
                    isScrolledPastHeader: $isScrolledPastHeader
                )
            } else {
                LibraryGridView(
                    items: viewModel.cachedLibraryItems,
                    isBatchMode: $isBatchMode,
                    multiSelection: $multiSelection,
                    useNavigationStack: useNavigationStack,
                    tapAction: $tapAction,
                    selectedPDF: $selectedPDF,
                    onAction: { (action: LibraryRowAction, pdf: ConvertedPDF) in viewModel.handleDetailAction(action: action, for: pdf, conversionManager: conversionManager) },
                    onImport: { NotificationCenter.default.post(name: NSNotification.Name("ShowImportQueue"), object: nil) },
                    onFolderTap: { uuid in viewModel.currentFolderID = uuid },
                    onDropApplied: {
                        let livePDFs = settingsManager.isVaultUnlocked
                            ? conversionManager.convertedPDFs
                            : conversionManager.convertedPDFs.filter { !$0.isPrivate }
                        viewModel.updateLibraryItemsCache(
                            pdfs: livePDFs,
                            collections: conversionManager.collections,
                            sortOption: sortOption
                        )
                    },
                    isScrolledPastHeader: $isScrolledPastHeader
                )
            }
        }
    }

    // PERF D-H2: reviewCount moved to @State (cachedReviewCount), rebuilt in
    // rebuildNativeCache(). Left as a private accessor for any legacy call sites.
    private var reviewCount: Int { cachedReviewCount }

    @ViewBuilder
    private var dailyBriefCard: some View {
        let greetingText: String = {
            let hour = Calendar.current.component(.hour, from: Date())
            if hour < 12 { return "Good morning" }
            else if hour < 17 { return "Good afternoon" }
            else { return "Good evening" }
        }()

        VStack(alignment: .leading, spacing: 14) {
            // Header with Greeting and Neural Glow indicator
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(greetingText.uppercased())
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color.inkBlue, Color.inkViolet],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                        .tracking(1.5)
                    
                    Text("Your Library Brief")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(Color.inkTextPrimary)
                }
                Spacer()
                
                // Active status pulse
                HStack(spacing: 6) {
                    Circle()
                        .fill(jobQueue.jobs.isEmpty ? Color.inkGreen : Color.inkBlue)
                        .frame(width: 8, height: 8)
                    Text(jobQueue.jobs.isEmpty ? "Engine Idle" : "Converting")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(Color.inkTextSecondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.inkBackground.opacity(0.4))
                .clipShape(Capsule())
            }

            // Summary Stats Cards (2 Columns)
            HStack(spacing: 12) {
                // Col 1: Total Books
                VStack(alignment: .leading, spacing: 6) {
                    Text("Total Books")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Color.inkTextSecondary)
                    Text("\(conversionManager.convertedPDFs.count)")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundColor(Color.inkTextPrimary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.inkBackground.opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                // Col 2: Metadata Review
                let reviewNum = reviewCount
                Button {
                    AppRouter.shared.presentSheet(.inbox)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Metadata Tasks")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Color.inkTextSecondary)
                        HStack(spacing: 4) {
                            Text("\(reviewNum)")
                                .font(.system(size: 22, weight: .bold, design: .rounded))
                                .foregroundColor(reviewNum > 0 ? Color.inkAmber : Color.inkTextPrimary)
                            if reviewNum > 0 {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundColor(Color.inkAmber)
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.inkBackground.opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            // Active conversions preview / smart hint
            if !jobQueue.jobs.isEmpty {
                HStack(spacing: 10) {
                    NeuralWaveformView(speed: 1.6, primaryColor: Color.inkBlue, secondaryColor: Color.inkViolet)
                        .frame(width: 64, height: 28)
                    Text("Processing \(jobQueue.jobs.count) file\(jobQueue.jobs.count > 1 ? "s" : "")...")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Color.inkTextSecondary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.inkBlue.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else if reviewCount > 0 {
                Button {
                    AppRouter.shared.presentSheet(.inbox)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 14))
                            .foregroundColor(.white)
                        Text("Review & Auto-Match Metadata")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.white)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white.opacity(0.7))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        LinearGradient(
                            colors: [Color.inkBlue, Color.inkViolet],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(18)
        .background(
            ZStack {
                // Breathing background aura leaked behind glass
                NeuralExpressiveBackground()
                    .opacity(0.12)
                Color.inkSurface.opacity(0.65)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0.15), Color.white.opacity(0.05)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: Color.black.opacity(0.08), radius: 16, y: 8)
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    // MARK: - Disconnected Drives Banner

    @ViewBuilder
    private var disconnectedDrivesBanner: some View {
        let disconnectedDrives = settingsManager.linkedDrives.filter {
            !DriveMonitor.shared.isConnected(driveID: $0.id)
        }
        if !disconnectedDrives.isEmpty {
            let driveName = disconnectedDrives.first?.displayName ?? "Drive"
            VStack(spacing: 4) {
                HStack {
                    Image(systemName: "externaldrive.fill.badge.xmark")
                        .foregroundColor(.red)
                    Text("External Drive Disconnected")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                    Spacer()
                }
                HStack {
                    Text("Please reconnect '\(driveName)' to read your linked comics.")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.8))
                    Spacer()
                }
            }
            .padding()
            .background(Theme.red.opacity(0.2))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.red.opacity(0.4), lineWidth: 1))
            .cornerRadius(12)
            .padding(.horizontal, 20)
            .padding(.top, 10)
        }
    }

    // MARK: - Pending Jobs Banner

    @ViewBuilder
    private var pendingJobsBanner: some View {
        let pendingJobs = jobQueue.jobs.filter {
            $0.status == .suspended || $0.status == .waitingForDownload ||
            $0.status == .extracting || $0.status == .failed
        }
        if !pendingJobs.isEmpty {
            VStack(spacing: 8) {
                ForEach(pendingJobs) { job in
                    pendingJobRow(job: job)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
        }
    }

    @ViewBuilder
    private func pendingJobRow(job: ConversionJob) -> some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: jobBannerIcon(job))
                    .foregroundColor(jobBannerColor(job))
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.targetFileName)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(Color.inkTextPrimary)
                        .lineLimit(1)
                    Text(jobBannerMessage(job))
                        .font(.system(size: 12))
                        .foregroundColor(Color.inkTextSecondary)
                }
                Spacer()
                if job.status == .suspended || job.status == .failed {
                    Button(job.status == .failed ? "Retry" : "Resume") {
                        retryOrResumeJob(job)
                    }
                    .font(.caption.bold())
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(jobBannerColor(job))
                    .clipShape(Capsule())
                }
                Button {
                    jobQueue.removeJob(pdfID: job.pdfID)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(Color.inkTextTertiary)
                        .font(.title3)
                }
            }

            if job.status == .extracting || job.status == .merging || job.status == .waitingForDownload {
                NeuralWaveformView(speed: 1.5, primaryColor: Color.inkBlue, secondaryColor: Color.inkViolet)
                    .frame(height: 24)
                    .padding(.top, 4)
            }
        }
        .padding()
        .background(Color.inkSurface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(job.status == .failed ? Color.inkRed.opacity(0.3) : Color.inkBorderSubtle, lineWidth: 1)
        )
    }

    private func retryOrResumeJob(_ job: ConversionJob) {
        if job.status == .failed {
            jobQueue.updateJobStatus(pdfID: job.pdfID, newStatus: .waitingForDownload)
            if let pdf = conversionManager.convertedPDFs.first(where: { $0.id == job.pdfID }) {
                Task { await CloudDownloadManager.shared.downloadAndStore(pdf: pdf, thenConvert: true, manager: conversionManager) }
            }
        } else {
            jobQueue.updateJobStatus(pdfID: job.pdfID, newStatus: .extracting)
            if let pdf = conversionManager.convertedPDFs.first(where: { $0.id == job.pdfID }) {
                Task {
                    if job.isMerge {
                        await ConversionOrchestrator.shared.convertAndMerge(
                            sourceFiles: [pdf], outputName: job.outputName ?? "",
                            mangaMode: job.mangaMode ?? false, manager: conversionManager
                        )
                    } else {
                        await ConversionOrchestrator.shared.convertComic(pdf, mangaMode: job.mangaMode, manager: conversionManager)
                    }
                    jobQueue.updateJobStatus(pdfID: job.pdfID, newStatus: .completed)
                    jobQueue.removeJob(pdfID: job.pdfID)
                }
            }
        }
    }

    @ViewBuilder
    private func breadcrumbRow(folder: PDFCollection) -> some View {
        HStack {
            Button {
                withAnimation { viewModel.currentFolderID = folder.parentId }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text("Back")
                }
            }
            .font(.subheadline.bold())
            .foregroundColor(Theme.blue)
            Spacer()
            Text(folder.name)
                .font(.headline)
                .foregroundColor(.primary)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder private var batchBottomToolbar: some View {
        VStack(spacing: 0) {
            Divider().background(Theme.text.opacity(0.1))
            HStack {
                Button(role: .destructive) {
                    let items = conversionManager.convertedPDFs.filter { multiSelection.contains($0.id) }
                    for item in items { conversionManager.deletePDF(item) }
                    isBatchMode = false
                    multiSelection.removeAll()
                } label: { VStack(spacing: 4) { Image(systemName: "trash").font(.title3); Text("Delete").font(.caption) } }
                .disabled(multiSelection.isEmpty)
                
                Spacer()
                
                Button {
                    batchMergeItems = conversionManager.convertedPDFs.filter { multiSelection.contains($0.id) }
                    showingBatchMergeReorder = true
                } label: { VStack(spacing: 4) { Image(systemName: "doc.on.doc.fill").font(.title3); Text("Convert & Merge").font(.caption) } }
                .disabled(multiSelection.count < 2)
                
                Spacer()
                
                Button {
                    let items = conversionManager.convertedPDFs.filter { multiSelection.contains($0.id) }
                    AppRouter.shared.presentSheet(.seriesAssignment(nil, isBatch: true, selection: items))
                } label: { VStack(spacing: 4) { Image(systemName: "rectangle.stack.badge.plus").font(.title3); Text("Group").font(.caption) } }
                .disabled(multiSelection.isEmpty)
                
                Spacer()
                
                Button {
                    let items = conversionManager.convertedPDFs.filter { multiSelection.contains($0.id) }
                    for item in items { TransferQueueManager.shared.stageFile(item) }
                    isBatchMode = false
                    multiSelection.removeAll()
                    AppRouter.shared.presentSheet(.wifi)
                } label: { VStack(spacing: 4) { Image(systemName: "wifi").font(.title3); Text("Transfer").font(.caption) } }
                .disabled(multiSelection.isEmpty)
                
                Spacer()
                
                Menu {
                    Button {
                        let items = conversionManager.convertedPDFs.filter { multiSelection.contains($0.id) }
                        FolderLinkCoordinator.present { urls in
                            guard let targetURL = urls.first else { return }
                            Task {
                                await MainActor.run { isStorageTransferring = true; transferProgress = 0 }
                                do {
                                    try await LinkedLibraryScanner.shared.offloadToExternalDrive(
                                        files: items,
                                        targetFolderURL: targetURL
                                    ) { progress, status in
                                        DispatchQueue.main.async {
                                            self.transferProgress = progress
                                            self.transferStatus = status
                                        }
                                    }
                                    await MainActor.run {
                                        isStorageTransferring = false
                                        isBatchMode = false
                                        multiSelection.removeAll()
                                    }
                                } catch {
                                    await MainActor.run {
                                        isStorageTransferring = false
                                        conversionManager.appAlert = AppAlert(title: "Transfer Failed", message: error.localizedDescription)
                                    }
                                }
                            }
                        }
                    } label: { Label("Move to External Drive", systemImage: "externaldrive.fill.badge.plus") }
                    
                    Button {
                        let items = conversionManager.convertedPDFs.filter { multiSelection.contains($0.id) }
                        Task {
                            await MainActor.run { isStorageTransferring = true; transferProgress = 0 }
                            do {
                                try await LinkedLibraryScanner.shared.downloadToDevice(
                                    files: items
                                ) { progress, status in
                                    DispatchQueue.main.async {
                                        self.transferProgress = progress
                                        self.transferStatus = status
                                    }
                                }
                                await MainActor.run {
                                    isStorageTransferring = false
                                    isBatchMode = false
                                    multiSelection.removeAll()
                                }
                            } catch {
                                await MainActor.run {
                                    isStorageTransferring = false
                                    conversionManager.appAlert = AppAlert(title: "Download Failed", message: error.localizedDescription)
                                }
                            }
                        }
                    } label: { Label("Download to iPad", systemImage: "ipad.and.arrow.forward") }
                } label: {
                    VStack(spacing: 4) { Image(systemName: "externaldrive.fill").font(.title3); Text("Storage").font(.caption) }
                }
                .disabled(multiSelection.isEmpty)
                
                Spacer()
                
                Menu {
                    Button {
                        let items = conversionManager.convertedPDFs.filter { multiSelection.contains($0.id) }
                        Task { await conversionManager.convertQueue(items) }
                        isBatchMode = false
                        multiSelection.removeAll()
                    } label: { Label("Fast Convert", systemImage: "arrow.triangle.2.circlepath") }
                    
                    Button {
                        batchMergeItems = conversionManager.convertedPDFs.filter { multiSelection.contains($0.id) }
                        showingBatchMergeReorder = true
                    } label: { Label("Convert & Merge", systemImage: "doc.on.doc.fill") }
                    
                    Button { AppRouter.shared.presentSheet(.merge) } label: { Label("Legacy PDF Merge", systemImage: "arrow.triangle.merge") }
                    Divider()
                    Button {
                        let items = conversionManager.convertedPDFs.filter { multiSelection.contains($0.id) }
                        AppRouter.shared.presentSheet(.batchMetadata(items))
                    } label: { Label("Intelligent Metadata", systemImage: "sparkles") }
                } label: {
                    VStack(spacing: 4) { Image(systemName: "ellipsis.circle.fill").font(.title3); Text("Actions").font(.caption) }
                    .foregroundColor(Theme.orange)
                }
                .disabled(multiSelection.isEmpty)
                    
            }
            .padding(.horizontal, 10) // Tweak padding slightly to fit 6 icons
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)
            .foregroundColor(Theme.text)
        }
    }
}
