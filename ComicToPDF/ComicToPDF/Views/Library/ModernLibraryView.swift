import SwiftUI
import UniformTypeIdentifiers
import Combine
import SwiftData
import CoreData

struct ModernLibraryView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @EnvironmentObject var settingsManager: AppSettingsManager
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @ObservedObject private var router = AppRouter.shared
    @StateObject private var viewModel = LibraryViewModel()
    @ObservedObject private var ledger = ConversionLedger.shared
    
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
    @AppStorage("dismissCharacterReviewBanner") private var dismissCharacterReviewBanner = false
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
    @State private var highlightedItemID: String? = nil
    @FocusState private var isLibraryFocused: Bool


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

    private var currentFolder: PDFCollection? {
        guard let id = viewModel.currentFolderID else { return nil }
        return conversionManager.collections.first(where: { $0.id == id })
    }

    var body: some View {
        shellWithNotifications
            // PERF D-C1 boot fix: seed the cache before the view fully renders
            // so notification-based lookups (Resume, Handoff) fire correctly even
            // if onAppear hasn't run yet (e.g. app launch via Spotlight/widget).
            .task(id: swiftDataPDFs.count) {
                if cachedVisiblePDFs.isEmpty { rebuildNativeCache() }
            }
            .focusable()
            .focused($isLibraryFocused)
            .focusEffectDisabled()
            .onKeyPress(phases: .down) { press in
                if press.modifiers.contains(.command) {
                    if press.key == "f" {
                        withAnimation(.spring) { isSearchActive.toggle() }
                        return .handled
                    }
                    if press.key == "o" || press.key == "n" {
                        (onFolderImport ?? handleDefaultImport)()
                        return .handled
                    }
                    if press.key == "a" && isBatchMode {
                        handleSelectAll()
                        return .handled
                    }
                }
                
                if press.key == .escape {
                    if isSearchActive {
                        withAnimation {
                            viewModel.searchText = ""
                            isSearchActive = false
                        }
                        return .handled
                    }
                    if isBatchMode {
                        withAnimation {
                            isBatchMode = false
                            multiSelection.removeAll()
                        }
                        return .handled
                    }
                    if highlightedItemID != nil {
                        highlightedItemID = nil
                        return .handled
                    }
                }
                
                if press.key == .leftArrow {
                    moveHighlight(direction: .left)
                    return .handled
                }
                if press.key == .rightArrow {
                    moveHighlight(direction: .right)
                    return .handled
                }
                if press.key == .upArrow {
                    moveHighlight(direction: .up)
                    return .handled
                }
                if press.key == .downArrow {
                    moveHighlight(direction: .down)
                    return .handled
                }
                if press.key == .return || press.key == .space {
                    openHighlightedItem()
                    return .handled
                }
                
                return .ignored
            }
    }

    // MARK: - Notification Handlers
    private func handleOpenMergedBook(_ notification: Notification) {
        if let newBook = notification.object as? ConvertedPDF {
            Task {
                try? await Task.sleep(nanoseconds: 500_000_000)
                await MainActor.run { AppRouter.shared.presentFullScreen(.read(newBook)) }
            }
        }
    }
    
    private func handleHandoffRequested(_ notification: Notification) {
        if let userInfo = notification.userInfo,
           let pdfID = userInfo["pdfID"] as? UUID,
           let pageIndex = userInfo["pageIndex"] as? Int {
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
    
    private func handleResumeLastRead(_ notification: Notification) {
        if let mostRecent = ReaderProgressTracker.shared.recentSessions().first {
            let pdf = cachedVisiblePDFs.first(where: { $0.id == mostRecent.pdfID })
                ?? conversionManager.convertedPDFs.first(where: { $0.id == mostRecent.pdfID })
            if let pdf = pdf {
                let readingMode = notification.userInfo?["readingMode"] as? String
                AppRouter.shared.presentFullScreen(.read(pdf, initialReadingMode: readingMode))
            }
        }
    }
    
    private func handleOpenBook(_ notification: Notification) {
        if let searchTitle = notification.userInfo?["searchTitle"] as? String {
            let pdf = cachedVisiblePDFs.first(where: { $0.name.localizedCaseInsensitiveContains(searchTitle) || $0.metadata.title.localizedCaseInsensitiveContains(searchTitle) })
            if let pdf = pdf {
                AppRouter.shared.presentFullScreen(.read(pdf))
            } else {
                viewModel.searchText = searchTitle
            }
        }
    }
    
    private func handleOPDSDownloadCompleted(_ note: Notification) {
        if let fileURL = note.userInfo?["fileURL"] as? URL {
            Task { await conversionManager.processImportedFiles(urls: [fileURL]) }
        }
    }
    
    private func handleInkTabDoubleTapLibrary(_ notification: Notification) {
        HapticEngine.selection()
        NotificationCenter.default.post(name: Notification.Name("Library_ScrollToTop"), object: nil)
    }
    
    private func handleRequestSeriesRename(_ notification: Notification) {
        guard let group = notification.object as? SeriesGroup else { return }
        listRenameGroup = group
        listRenamePendingName = group.title
    }
    
    private func handleInksyncOpenShelf(_ notification: Notification) {
        router.activeSheet = nil
        router.activeFullScreen = nil
    }
    
    private func handleManagedObjectContextDidSave(_ notification: Notification) {
        InksyncProApp.sharedModelContainer.mainContext.processPendingChanges()
        rebuildNativeCache()
        viewModel.updateLibraryItemsCache(pdfs: cachedVisiblePDFs, collections: cachedCollections, sortOption: sortOption)
    }

    // MARK: - Notification Shell (onReceive + debug overlay)
    @ViewBuilder
    private var shellWithNotifications: some View {
        shellWithChangeHandlers
            .onReceive(NotificationCenter.default.publisher(for: .openMergedBook), perform: handleOpenMergedBook)
            .onReceive(NotificationCenter.default.publisher(for: .handoffRequested), perform: handleHandoffRequested)
            .onReceive(NotificationCenter.default.publisher(for: .inkTabDoubleTapLibrary), perform: handleInkTabDoubleTapLibrary)
            .onReceive(NotificationCenter.default.publisher(for: .requestSeriesRename), perform: handleRequestSeriesRename)
            .onReceive(NotificationCenter.default.publisher(for: .inksyncResumeLastRead), perform: handleResumeLastRead)
            .onReceive(NotificationCenter.default.publisher(for: .inksyncOpenShelf), perform: handleInksyncOpenShelf)
            .onReceive(NotificationCenter.default.publisher(for: .inksyncOpenBook), perform: handleOpenBook)
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("OPDSDownloadCompleted")), perform: handleOPDSDownloadCompleted)
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name.NSManagedObjectContextDidSave), perform: handleManagedObjectContextDidSave)
            .overlay(alignment: .bottomTrailing) {
                if settingsManager.conversionSettings.showEditorDebug {
                    LibraryDebugHUD(
                        allItems: viewModel.cachedLibraryItems,
                        conversionManager: conversionManager,
                        viewModel: viewModel
                    )
                }
            }
            .navigationTitle("InkSync Pro")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    // Search Toggle
                    Button {
                        withAnimation(.spring) { isSearchActive.toggle() }
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    
                    // Import / Add File
                    Button {
                        (onFolderImport ?? handleDefaultImport)()
                    } label: {
                        Image(systemName: "plus")
                    }
                    
                    // Advanced Tools Menu
                    Menu {
                        // Sort & Filter
                        Menu("Sort Options", systemImage: "arrow.up.arrow.down") {
                            Picker("Sort By", selection: Binding(get: { sortOption }, set: { sortOption = $0; rebuildNativeCache(); viewModel.updateLibraryItemsCache(pdfs: cachedVisiblePDFs, collections: cachedCollections, sortOption: $0) })) {
                                ForEach(SortOption.allCases) { option in
                                    Text(option.rawValue).tag(option)
                                }
                            }
                        }
                        
                        Menu("Filter Options", systemImage: "line.3.horizontal.decrease.circle") {
                            Picker("Filter By", selection: $viewModel.filterState) {
                                ForEach(LibraryFilterState.allCases) { state in
                                    Text(state.rawValue).tag(state)
                                }
                            }
                        }
                        
                        Divider()
                        
                        // View Options
                        Button(action: { viewStyle = viewStyle == .grid ? .list : .grid }) {
                            Label(viewStyle == .grid ? "Switch to List View" : "Switch to Grid View", systemImage: viewStyle == .grid ? "list.bullet" : "square.grid.2x2")
                        }
                        Button(action: { withAnimation { isBatchMode.toggle() } }) {
                            Label(isBatchMode ? "Exit Batch Mode" : "Enter Batch Mode", systemImage: "checkmark.circle")
                        }
                        Button(action: handleVaultToggle) {
                            Label(settingsManager.isVaultUnlocked ? "Lock Vault" : "Unlock Vault", systemImage: settingsManager.isVaultUnlocked ? "lock.open.fill" : "lock.fill")
                        }
                        Button(action: { AppRouter.shared.presentSheet(.stats) }) {
                            Label("Library Stats", systemImage: "chart.bar.fill")
                        }
                        
                        Divider()
                        
                        // Connections
                        Menu("Connections", systemImage: "network") {
                            Button(action: { AppRouter.shared.presentSheet(.cloudBrowser) }) {
                                let cloudConnected = DropboxProvider.shared.isConnected
                                Label("Cloud Library", systemImage: cloudConnected ? "checkmark.icloud.fill" : "icloud.and.arrow.down")
                            }
                            Button(action: { AppRouter.shared.presentSheet(.wifi) }) {
                                Label("Wi-Fi Sync", systemImage: "wifi")
                            }
                            Button(action: { AppRouter.shared.presentSheet(.smartListImporter) }) {
                                Label("Smart List Import", systemImage: "list.star")
                            }
                        }
                        
                        // Metadata & AI
                        Menu("Metadata & AI", systemImage: "sparkles") {
                            Button(action: {
                                Task { await BackgroundMetadataEngine.shared.startEngine(manager: conversionManager) }
                            }) {
                                Label("Auto-Match Metadata", systemImage: "wand.and.stars.inverse")
                            }
                            
                            if !conversionManager.failedMetadataPDFs.isEmpty {
                                Button(action: {
                                    AppRouter.shared.presentSheet(.reviewMetadata)
                                }) {
                                    Label("Review Missing", systemImage: "exclamationmark.triangle.fill")
                                }
                            }
                            
                            Button(action: {
                                if multiSelection.count >= 1 {
                                    let items = conversionManager.convertedPDFs.filter { multiSelection.contains($0.id) }
                                    AppRouter.shared.presentSheet(.cognitiveBatchRenamer(items))
                                } else {
                                    withAnimation { isBatchMode = true }
                                    conversionManager.appAlert = AppAlert(title: "Select Issues", message: "Select 1 or more scrambled issues from your library to automatically rename using AI Vision.")
                                }
                            }) {
                                Label("AI Rename", systemImage: "sparkles.tv")
                            }
                            
                            Button(action: {
                                if multiSelection.count >= 1 {
                                    let items = conversionManager.convertedPDFs.filter { multiSelection.contains($0.id) }
                                    AppRouter.shared.presentSheet(.metadataSpreadsheet(items))
                                    withAnimation { isBatchMode = false }
                                } else {
                                    withAnimation { isBatchMode = true }
                                    conversionManager.appAlert = AppAlert(title: "Select Issues", message: "Select issues to edit in the Grid Editor.")
                                }
                            }) {
                                Label("Grid Editor", systemImage: "tablecells")
                            }
                        }
                        
                        // File Operations
                        Menu("File Operations", systemImage: "doc.on.doc") {
                            Button(action: {
                                AppRouter.shared.presentSheet(.merge)
                            }) {
                                Label("PDF Merge Tool", systemImage: "arrow.triangle.merge")
                            }
                            
                            Button(action: {
                                if multiSelection.count >= 2 {
                                    batchMergeItems = conversionManager.convertedPDFs.filter { multiSelection.contains($0.id) }
                                    showingBatchMergeReorder = true
                                } else {
                                    withAnimation { isBatchMode = true }
                                    conversionManager.appAlert = AppAlert(title: "Select Issues", message: "Select 2 or more issues from your library, then tap Convert & Merge again.")
                                }
                            }) {
                                Label("Convert & Merge", systemImage: "arrow.triangle.2.circlepath.doc")
                            }
                        }
                        
                        Divider()
                        
                        // App Settings
                        Button(action: { NotificationCenter.default.post(name: NSNotification.Name("ShowSettingsInspector"), object: nil) }) {
                            Label("App Settings", systemImage: "gearshape.fill")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
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
                isLibraryFocused = true

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
            .onChange(of: viewModel.contentShelf) { _, _ in
                viewModel.updateLibraryItemsCache(pdfs: cachedVisiblePDFs, collections: cachedCollections, sortOption: sortOption)
            }
            .onChange(of: viewModel.currentFolderID) { _, _ in
                viewModel.updateLibraryItemsCache(pdfs: cachedVisiblePDFs, collections: cachedCollections, sortOption: sortOption)
            }
            .onChange(of: isSearchActive) { _, newVal in
                if !newVal {
                    isLibraryFocused = true
                }
            }
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
            .sheet(item: $router.activeSheet) { item in
                destinationSheet(for: item)
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
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
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
        case .ledger:
            ConversionLedgerView()
                .environmentObject(conversionManager)
            
        case .importQueue:
            ImportQueueView()
                .environmentObject(conversionManager)

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
        case .metadataSpreadsheet(let pdfs): 
            if #available(iOS 16.0, *) {
                MetadataSpreadsheetView(items: pdfs).environmentObject(conversionManager)
            } else {
                Text("Grid Editor requires iOS 16+")
            }
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

    enum MoveDirection {
        case up, down, left, right
    }

    private func moveHighlight(direction: MoveDirection) {
        let items = viewModel.cachedLibraryItems
        guard !items.isEmpty else { return }
        
        let cols = viewStyle == .grid ? (hSizeClass == .regular ? 5 : 3) : 1
        
        // Find current index
        let currentIndex: Int
        if let currentID = highlightedItemID,
           let idx = items.firstIndex(where: { $0.id == currentID }) {
            currentIndex = idx
        } else {
            // No highlight, select first item
            highlightedItemID = items.first?.id
            return
        }
        
        let targetIndex: Int
        switch direction {
        case .up:
            targetIndex = max(0, currentIndex - cols)
        case .down:
            targetIndex = min(items.count - 1, currentIndex + cols)
        case .left:
            targetIndex = max(0, currentIndex - 1)
        case .right:
            targetIndex = min(items.count - 1, currentIndex + 1)
        }
        
        if items.indices.contains(targetIndex) {
            highlightedItemID = items[targetIndex].id
        }
    }
    
    private func openHighlightedItem() {
        guard let currentID = highlightedItemID,
              let item = viewModel.cachedLibraryItems.first(where: { $0.id == currentID }) else { return }
        
        switch item {
        case .single(let pdf):
            if case .cloud = pdf.sourceMode {
                if tapAction == .convert {
                    viewModel.handleDetailAction(action: .convert, for: pdf, conversionManager: conversionManager)
                } else {
                    viewModel.handleDetailAction(action: .details, for: pdf, conversionManager: conversionManager)
                }
            } else {
                if tapAction == .read {
                    viewModel.handleDetailAction(action: .read, for: pdf, conversionManager: conversionManager)
                } else if tapAction == .convert {
                    viewModel.handleDetailAction(action: .convert, for: pdf, conversionManager: conversionManager)
                } else {
                    viewModel.handleDetailAction(action: .details, for: pdf, conversionManager: conversionManager)
                }
            }
        case .series(let group):
            if let folderUUID = UUID(uuidString: group.id) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    viewModel.currentFolderID = folderUUID
                }
            } else {
                if let next = nextUnread(in: group) {
                    viewModel.handleDetailAction(action: .read, for: next, conversionManager: conversionManager)
                }
            }
        case .driveFolder(let entry):
            break
        }
    }

    private func nextUnread(in group: SeriesGroup) -> ConvertedPDF? {
        let sorted = group.issues.sorted { a, b in
            let aNum = Int(a.metadata.issueNumber?.filter(\.isNumber) ?? "") ?? 0
            let bNum = Int(b.metadata.issueNumber?.filter(\.isNumber) ?? "") ?? 0
            return aNum < bNum
        }
        return sorted.first {
            (ReaderProgressTracker.shared.progress(for: $0.id)?.completionFraction ?? 0) < 0.95
        } ?? sorted.first
    }

    // MARK: - Job Banner Helpers
    private func jobBannerIcon(_ job: ConversionJobRecord) -> String {
        switch job.status {
        case .queued:          return "clock"
        case .running:         return "arrow.triangle.2.circlepath.circle.fill"
        case .retrying:        return "arrow.clockwise.circle"
        case .failed, .abandoned: return "exclamationmark.triangle.fill"
        case .succeeded:       return "checkmark.circle.fill"
        }
    }

    private func jobBannerColor(_ job: ConversionJobRecord) -> Color {
        switch job.status {
        case .failed, .abandoned: return Theme.red
        case .queued, .retrying:  return Theme.orange
        default:                  return Theme.blue
        }
    }

    private func jobBannerMessage(_ job: ConversionJobRecord) -> String {
        switch job.status {
        case .queued:    return "Waiting in queue..."
        case .running:   return "Converting and packaging..."
        case .retrying:  return "Retrying..."
        case .failed, .abandoned: return "Conversion failed: \(job.failureReason ?? "Unknown error")"
        case .succeeded: return "Complete"
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
            Spacer().frame(height: 16) // Top padding to prevent overlap with the status bar and branding

            // Apple Books-style persisted Content Shelf tab strip
            ContentShelfSelector(
                selected: $viewModel.contentShelf,
                counts: contentShelfCounts
            )
            .padding(.bottom, 12)


            if !dismissCharacterReviewBanner, MetadataMatchService.shared.activeClusters.contains(where: {
                if case .matched = $0.status { return false }
                return true
            }) {
                HStack {
                    Image(systemName: "doc.text.magnifyingglass")
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
                    
                    Button {
                        withAnimation { dismissCharacterReviewBanner = true }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundColor(Theme.textTertiary)
                    }
                    .padding(.leading, 4)
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
            if let folder = currentFolder {
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
                    onImport: onFolderImport ?? handleDefaultImport,
                    onFolderTap: { uuid in viewModel.currentFolderID = uuid },
                    onDropApplied: handleDropApplied,
                    isScrolledPastHeader: $isScrolledPastHeader,
                    highlightedItemID: highlightedItemID
                )
            } else {
                LibraryGridView(
                    items: viewModel.cachedLibraryItems,
                    contentShelf: viewModel.contentShelf,
                    isBatchMode: $isBatchMode,
                    multiSelection: $multiSelection,
                    useNavigationStack: useNavigationStack,
                    tapAction: $tapAction,
                    selectedPDF: $selectedPDF,
                    onAction: { (action: LibraryRowAction, pdf: ConvertedPDF) in viewModel.handleDetailAction(action: action, for: pdf, conversionManager: conversionManager) },
                    onImport: onFolderImport ?? handleDefaultImport,
                    onFolderTap: { uuid in viewModel.currentFolderID = uuid },
                    onDropApplied: handleDropApplied,
                    isScrolledPastHeader: $isScrolledPastHeader,
                    highlightedItemID: highlightedItemID
                )
            }
        }
    }

    // PERF D-H2: reviewCount moved to @State (cachedReviewCount), rebuilt in
    // rebuildNativeCache(). Left as a private accessor for any legacy call sites.
    private var reviewCount: Int { cachedReviewCount }

    private var contentShelfCounts: [ContentShelf: Int] {
        var counts: [ContentShelf: Int] = [.all: 0, .comics: 0, .manga: 0, .books: 0, .converted: 0]
        
        counts[.all] = cachedVisiblePDFs.count
        
        for pdf in cachedVisiblePDFs {
            let nameLower = pdf.name.lowercased()
            let isConverted = pdf.lastOutputFormat != nil ||
                              pdf.url.path.contains("/Merged/") ||
                              nameLower.contains("_converted") ||
                              nameLower.contains("go merge")
            
            if isConverted {
                counts[.converted, default: 0] += 1
            }
            
            if pdf.contentType == .comic && !(pdf.metadata.isManga ?? false) {
                counts[.comics, default: 0] += 1
            } else if pdf.contentType == .manga || (pdf.metadata.isManga ?? false) {
                counts[.manga, default: 0] += 1
            } else if pdf.contentType == .book {
                counts[.books, default: 0] += 1
            }
        }
        
        return counts
    }

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
                
                // Active status pulse Button
                Button {
                    AppRouter.shared.presentSheet(.ledger)
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(!ledger.hasActiveJobs ? Color.inkGreen : Color.inkBlue)
                            .frame(width: 8, height: 8)
                        Text(!ledger.hasActiveJobs ? "Engine Idle" : "Converting")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(Color.inkTextSecondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.inkBackground.opacity(0.4))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
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
                    withAnimation { AppRouter.shared.selectedTab = 1 }
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
            if ledger.hasActiveJobs {
                HStack(spacing: 10) {
                    NeuralWaveformView(speed: 1.6, primaryColor: Color.inkBlue, secondaryColor: Color.inkViolet)
                        .frame(width: 64, height: 28)
                    Text("Processing \(ledger.activeJobsCount) file\(ledger.activeJobsCount > 1 ? "s" : "")...")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Color.inkTextSecondary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.inkBlue.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else if reviewCount > 0 {
                Button {
                    withAnimation { AppRouter.shared.selectedTab = 1 }
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
        let pendingJobs = ledger.allJobs().filter {
            $0.status == .queued || $0.status == .running ||
            $0.status == .retrying || $0.status == .failed || $0.status == .abandoned
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
    private func pendingJobRow(job: ConversionJobRecord) -> some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: jobBannerIcon(job))
                    .foregroundColor(jobBannerColor(job))
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.fileName)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(Color.inkTextPrimary)
                        .lineLimit(1)
                    Text(jobBannerMessage(job))
                        .font(.system(size: 12))
                        .foregroundColor(Color.inkTextSecondary)
                }
                Spacer()
                if job.status == .failed || job.status == .abandoned {
                    Button("Retry") {
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
                    ConversionLedger.shared.removeJob(job.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(Color.inkTextTertiary)
                        .font(.title3)
                }
            }

            if job.status == .running {
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
                .stroke(job.status == .failed || job.status == .abandoned ? Color.inkRed.opacity(0.3) : Color.inkBorderSubtle, lineWidth: 1)
        )
    }

    private func retryOrResumeJob(_ job: ConversionJobRecord) {
        ConversionLedger.shared.retryJob(job.id, manager: conversionManager)
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
                } label: { VStack(spacing: 4) { Image(systemName: "arrow.triangle.2.circlepath.doc").font(.title3); Text("Convert & Merge").font(.caption) } }
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
                    } label: { Label("Convert & Merge", systemImage: "arrow.triangle.2.circlepath.doc") }
                    
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
    
    private func handleDropApplied() {
        let livePDFs = settingsManager.isVaultUnlocked
            ? conversionManager.convertedPDFs
            : conversionManager.convertedPDFs.filter { !$0.isPrivate }
        viewModel.updateLibraryItemsCache(
            pdfs: livePDFs,
            collections: conversionManager.collections,
            sortOption: sortOption
        )
    }
    
    private func handleDefaultImport() {
        ImportCoordinator.present(type: .unified) { urls in
            Task { await conversionManager.processImportedFiles(urls: urls) }
        }
    }


}
