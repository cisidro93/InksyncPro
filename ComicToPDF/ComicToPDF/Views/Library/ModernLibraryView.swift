import SwiftUI
import UniformTypeIdentifiers
import Combine
import SwiftData

struct ModernLibraryView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @StateObject private var viewModel = LibraryViewModel()
    
    @Query(sort: \SDConvertedPDF.lastModified, order: .reverse) private var swiftDataPDFs: [SDConvertedPDF]
    @Query private var swiftDataCollections: [SDPDFCollection]
    
    @Binding var selectedPDF: ConvertedPDF?
    @Binding var isBatchMode: Bool
    @Binding var multiSelection: Set<UUID>
    @Binding var showingBatchMergeReorder: Bool
    @Binding var batchMergeItems: [ConvertedPDF]
    
    // Ã¢Å“â€¦ Navigation Mode
    var useNavigationStack: Bool = false
    var onFolderImport: (() -> Void)? = nil
    
    // Ã¢Å“â€¦ NEW: View Style State
    enum LibraryViewStyle: String {
        case list = "List"
        case grid = "Grid"
    }
    @AppStorage("libraryViewStyle") private var viewStyle: LibraryViewStyle = .grid
    @AppStorage("libraryTapAction") private var tapAction: LibraryTapAction = .details 
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding: Bool = false
    
    // UI Options Enum (kept for picker logic)
    enum SortOption: String, CaseIterable, Identifiable {
        case dateAdded = "Most Recent"
        case name = "Name"
        case size = "Size"
        case favorites = "Favorites First"
        case type = "Single / Series"
        case extensionType = "Format (CBZ/PDF)"
        var id: String { rawValue }
    }
    @State private var sortOption: SortOption = .dateAdded
    
    // 🗑 Removed Native Importer Bypass State
    // ✅ NEW: Precomputed Types for Swift 6 Parser Speed
    private var allowedImportTypes: [UTType] {
        return [
            .folder, .pdf, .zip, .epub,
            UTType(filenameExtension: "cbz")!,
            UTType(filenameExtension: "cbr")!,
            UTType(filenameExtension: "cb7")!
        ]
    }
    
    // Ã¢Å“â€¦ NEW: SwiftData Native Resolvers
    private var nativeVisiblePDFs: [ConvertedPDF] {
        let mapped = swiftDataPDFs.map { $0.toDTO() }
        return conversionManager.isVaultUnlocked ? mapped : mapped.filter { !$0.isPrivate }
    }
    
    // ✅ NEW: Extracted to relieve compiler timeout
    @ViewBuilder
    private var ambientGlow: some View {
        GeometryReader { geo in
            Circle()
                .fill(
                    RadialGradient(gradient: Gradient(colors: [Theme.purple.opacity(0.4), Theme.blue.opacity(0.1), .clear]), center: .top, startRadius: 10, endRadius: 300)
                )
                .frame(width: geo.size.width * 1.5, height: 400)
                .position(x: geo.size.width / 2, y: -50)
                .blur(radius: 60)
                .ignoresSafeArea()
        }
    }
    
    private var nativeCollections: [PDFCollection] {
        swiftDataCollections.map { $0.toDTO() }
    }

    var body: some View {
        Group {
            ZStack(alignment: .top) {
                // Background Depth
                Color.black.ignoresSafeArea()
                
                // Ambient Header Glow
                ambientGlow
                
                libraryContent
                .safeAreaInset(edge: .bottom) {
                    if isBatchMode {
                        batchBottomToolbar.transition(.move(edge: .bottom))
                    }
                }
                // Removed redundant background to let ZStack ambient glow show through
                // Ã¢Å“â€¦ MVVM Unified Navigation Router
                .fullScreenCover(item: $viewModel.activeFullScreen) { dest in
                    switch dest {
                    case .read(let pdf):
                        if pdf.contentType == .book { SplitStudyWorkspace(fileURL: pdf.url, contentType: pdf.contentType, pdf: pdf) } else { ReaderView(fileURL: pdf.url, contentType: pdf.contentType, pdf: pdf) }
                    case .advancedWorkspace(let pdf):
                        AdvancedWorkspaceView(pdf: pdf).environmentObject(conversionManager)
                    }
                }
                .sheet(item: $viewModel.activeSheet) { item in
                    destinationSheet(for: item)
                }
            } // End Inner Group
        } // End Outer Group
        
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

        .onAppear {
            conversionManager.backfillMissingThumbnails()
            viewModel.updateLibraryItemsCache(pdfs: nativeVisiblePDFs, collections: nativeCollections, sortOption: sortOption)
        }
        .onChange(of: swiftDataPDFs) { viewModel.updateLibraryItemsCache(pdfs: nativeVisiblePDFs, collections: nativeCollections, sortOption: sortOption) }
        .onChange(of: sortOption) { viewModel.updateLibraryItemsCache(pdfs: nativeVisiblePDFs, collections: nativeCollections, sortOption: sortOption) }
        .onChange(of: swiftDataCollections) { viewModel.updateLibraryItemsCache(pdfs: nativeVisiblePDFs, collections: nativeCollections, sortOption: sortOption) }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("OpenMergedBook"))) { notification in
            if let newBook = notification.object as? ConvertedPDF {
                // Ensure the view hierarchy processes the dismissal first, then throw up the full screen cover.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    viewModel.activeFullScreen = .read(newBook)
                }
            }
        }
    }
    
    // MARK: - Extracted Router UI
    @ViewBuilder
    private func destinationSheet(for item: LibrarySheetDestination) -> some View {
        switch item {
        case .stats: ReadingStatsView()
        case .importer(let urls): ImportQueueView(prepickedURLs: urls)
        case .smartListImporter: SmartListImporterView().environmentObject(conversionManager)
        case .wifi: WiFiView()
        case .merge: FileMergeView()
        case .cloud: EmptyView()
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
        if conversionManager.isVaultUnlocked {
            withAnimation { conversionManager.isVaultUnlocked = false }
        } else {
            Task {
                if await SecurityManager.shared.authenticate() {
                    await MainActor.run { withAnimation { conversionManager.isVaultUnlocked = true } }
                }
            }
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
                viewStyle: $viewStyle,
                tapAction: $tapAction,
                onSheetTrigger: { dest in 
                    viewModel.activeSheet = dest 
                },
                isBatchMode: $isBatchMode,
                multiSelection: $multiSelection,
                batchMergeItems: $batchMergeItems,
                showingBatchMergeReorder: $showingBatchMergeReorder,
                showCognitiveBatchRenamer: .constant(false), // Handled by Router
                onVaultToggle: handleVaultToggle,
                onSelectAll: handleSelectAll
            )
            

            // MARK: - Discrete Layout Layers
            if viewStyle == .list {
                LibraryListView(
                    items: viewModel.cachedLibraryItems,
                    isBatchMode: $isBatchMode,
                    multiSelection: $multiSelection,
                    useNavigationStack: useNavigationStack,
                    tapAction: $tapAction,
                    selectedPDF: $selectedPDF,
                    onAction: { action, pdf in viewModel.handleDetailAction(action: action, for: pdf, conversionManager: conversionManager) },
                    onImport: { ImportCoordinator.present(type: .files) { urls in Task { await conversionManager.importFilesAsSeries(urls: urls) } } }
                )
            } else {
                LibraryGridView(
                    items: viewModel.cachedLibraryItems,
                    isBatchMode: $isBatchMode,
                    multiSelection: $multiSelection,
                    useNavigationStack: useNavigationStack,
                    tapAction: $tapAction,
                    selectedPDF: $selectedPDF,
                    onAction: { action, pdf in viewModel.handleDetailAction(action: action, for: pdf, conversionManager: conversionManager) },
                    onImport: { ImportCoordinator.present(type: .files) { urls in Task { await conversionManager.importFilesAsSeries(urls: urls) } } }
                )
            }
        }
        .overlay(ImportTrackerView())
    }

    @ViewBuilder private var batchBottomToolbar: some View {
        VStack(spacing: 0) {
            Divider().background(Color.white.opacity(0.1))
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
                    viewModel.activeSheet = .seriesAssignment(nil, isBatch: true, selection: items)
                } label: { VStack(spacing: 4) { Image(systemName: "rectangle.stack.badge.plus").font(.title3); Text("Group").font(.caption) } }
                .disabled(multiSelection.isEmpty)
                
                Spacer()
                
                Button {
                    let items = conversionManager.convertedPDFs.filter { multiSelection.contains($0.id) }
                    for item in items { TransferQueueManager.shared.stageFile(item) }
                    isBatchMode = false
                    multiSelection.removeAll()
                    viewModel.activeSheet = .wifi
                } label: { VStack(spacing: 4) { Image(systemName: "wifi").font(.title3); Text("Transfer").font(.caption) } }
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
                    
                    Button { viewModel.activeSheet = .merge } label: { Label("Legacy PDF Merge", systemImage: "arrow.triangle.merge") }
                    Divider()
                    Button {
                        let items = conversionManager.convertedPDFs.filter { multiSelection.contains($0.id) }
                        viewModel.activeSheet = .batchMetadata(items)
                    } label: { Label("Intelligent Metadata", systemImage: "sparkles") }
                } label: {
                    VStack(spacing: 4) { Image(systemName: "ellipsis.circle.fill").font(.title3); Text("Actions").font(.caption) }
                    .foregroundColor(Theme.orange)
                }
                .disabled(multiSelection.isEmpty)
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)
            .foregroundColor(.white)
            .environment(\.colorScheme, .dark)
        }
    }
}

