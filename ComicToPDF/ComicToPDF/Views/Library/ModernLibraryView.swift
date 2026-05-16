import SwiftUI
import UniformTypeIdentifiers
import Combine
import SwiftData

struct ModernLibraryView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @EnvironmentObject var settingsManager: AppSettingsManager
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
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding: Bool = false
    @State private var scrollToTopTrigger = false

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
    // ✅ NEW: Precomputed Types for Swift 6 Parser Speed
    private var allowedImportTypes: [UTType] {
        return [
            .folder, .pdf, .zip, .epub,
            UTType(filenameExtension: "cbz"),
            UTType(filenameExtension: "cbr"),
            UTType(filenameExtension: "cb7")
        ].compactMap { $0 }
    }
    
    // ✅ NEW: SwiftData Native Resolvers
    private var nativeVisiblePDFs: [ConvertedPDF] {
        let mapped = swiftDataPDFs.map { $0.toDTO() }
        return settingsManager.isVaultUnlocked ? mapped : mapped.filter { !$0.isPrivate }
    }
    

    private var nativeCollections: [PDFCollection] {
        swiftDataCollections.map { $0.toDTO() }
    }

    var body: some View {
        shellWithNotifications
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
                    if let targetPDF = nativeVisiblePDFs.first(where: { $0.id == pdfID }) {
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
                let readingModeStr = notification.userInfo?["readingMode"] as? String
                if let mostRecent = ReaderProgressTracker.shared.recentSessions().first,
                   let pdf = nativeVisiblePDFs.first(where: { $0.id == mostRecent.pdfID }) {
                    AppRouter.shared.presentFullScreen(.read(pdf))
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .inksyncOpenShelf)) { _ in
                // Close any open sheets or full screen covers to reveal the library shelf
                router.activeSheet = nil
                router.activeFullScreen = nil
            }
            .onReceive(NotificationCenter.default.publisher(for: .inksyncOpenBook)) { notification in
                if let searchTitle = notification.userInfo?["searchTitle"] as? String {
                    // Find the first book containing the title (case-insensitive)
                    if let pdf = nativeVisiblePDFs.first(where: { $0.name.localizedCaseInsensitiveContains(searchTitle) || $0.metadata.title.localizedCaseInsensitiveContains(searchTitle) }) {
                        AppRouter.shared.presentFullScreen(.read(pdf))
                    } else {
                        // Just set the search text if not explicitly found, so user can see partial matches
                        viewModel.searchText = searchTitle
                    }
                }
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
                viewModel.updateLibraryItemsCache(pdfs: nativeVisiblePDFs, collections: nativeCollections, sortOption: sortOption)
            }
            .onChange(of: swiftDataPDFs) { viewModel.updateLibraryItemsCache(pdfs: nativeVisiblePDFs, collections: nativeCollections, sortOption: sortOption) }
            .onChange(of: sortOption) { viewModel.updateLibraryItemsCache(pdfs: nativeVisiblePDFs, collections: nativeCollections, sortOption: sortOption) }
            .onChange(of: swiftDataCollections) { viewModel.updateLibraryItemsCache(pdfs: nativeVisiblePDFs, collections: nativeCollections, sortOption: sortOption) }
            .onChange(of: viewModel.debouncedSearchText) { viewModel.updateLibraryItemsCache(pdfs: nativeVisiblePDFs, collections: nativeCollections, sortOption: sortOption) }
            .onChange(of: viewModel.filterState) { viewModel.updateLibraryItemsCache(pdfs: nativeVisiblePDFs, collections: nativeCollections, sortOption: sortOption) }
            .onChange(of: viewModel.currentFolderID) { viewModel.updateLibraryItemsCache(pdfs: nativeVisiblePDFs, collections: nativeCollections, sortOption: sortOption) }
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
            .alert(item: $conversionManager.appAlert) { alert in
                Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("OK")))
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
            Theme.bg.ignoresSafeArea()

            libraryContent
            .safeAreaInset(edge: .bottom) {
                if isBatchMode {
                    batchBottomToolbar.transition(.move(edge: .bottom))
                }
            }
            .overlay(alignment: .top) {
                storageTransferBanner
            }
            .fullScreenCover(item: $router.activeFullScreen) { dest in
                switch dest {
                case .read(let pdf):
                    if pdf.contentType == .book { SplitStudyWorkspace(fileURL: pdf.url, contentType: pdf.contentType, pdf: pdf) } else { ReaderView(fileURL: pdf.url, contentType: pdf.contentType, pdf: pdf) }
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
        }
    }
    
    // MARK: - Actions
    private func handleSelectAll() {
        let totalVisibleItems = viewModel.cachedLibraryItems.reduce(0) { count, item in
            switch item {
            case .single: return count + 1
            case .series(let grp): return count + grp.issues.count
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
                    if let urlData = data as? Data, let url = URL(dataRepresentation: urlData, relativeTo: nil) {
                        Task { await conversionManager.processImportedFiles(urls: [url]) }
                    } else if let url = data as? URL {
                        Task { await conversionManager.processImportedFiles(urls: [url]) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var libraryContent: some View {
        VStack(spacing: 0) {
            // MARK: - Dedicated Header Component
            LibraryHeaderView(
                searchText: $viewModel.searchText,
                sortOption: Binding(get: { sortOption }, set: { sortOption = $0; _ = viewModel.sortPDFs(nativeVisiblePDFs, sortOption: $0) }),
                filterState: $viewModel.filterState,
                viewStyle: $viewStyle,
                tapAction: $tapAction,
                onSheetTrigger: { (dest: LibrarySheetDestination) in AppRouter.shared.presentSheet(dest) },
                isBatchMode: $isBatchMode,
                multiSelection: $multiSelection,
                batchMergeItems: $batchMergeItems,
                showingBatchMergeReorder: $showingBatchMergeReorder,
                onVaultToggle: handleVaultToggle,
                onSelectAll: handleSelectAll
            )

            disconnectedDrivesBanner
            pendingJobsBanner

            // MARK: - Up Next Binge Shelf
            UpNextBingeShelf(allPDFs: nativeVisiblePDFs) { pdf in
                AppRouter.shared.presentFullScreen(.read(pdf))
            }

            // MARK: - Recently Read Shelf
            RecentlyReadShelf(pdfs: nativeVisiblePDFs) { pdf in
                AppRouter.shared.presentFullScreen(.read(pdf))
            }

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
                    onFolderTap: { uuid in viewModel.currentFolderID = uuid }
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
                    }
                )
            }
        }
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
        HStack {
            Image(systemName: jobBannerIcon(job))
                .foregroundColor(jobBannerColor(job))
            VStack(alignment: .leading, spacing: 2) {
                Text(job.targetFileName)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text(jobBannerMessage(job))
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.8))
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
                    .foregroundColor(.white.opacity(0.5))
                    .font(.title3)
            }
        }
        .padding()
        .background(jobBannerColor(job).opacity(0.2))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(jobBannerColor(job).opacity(0.4), lineWidth: 1))
        .cornerRadius(12)
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

