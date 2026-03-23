import SwiftUI
import UniformTypeIdentifiers
import Combine

struct ModernLibraryView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @StateObject private var viewModel = LibraryViewModel()
    
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

    var body: some View {
        Group {
            Group {
                VStack(spacing: 0) {
                    // MARK: - Dedicated Header Component
                    LibraryHeaderView(
                        searchText: $viewModel.searchText,
                        sortOption: Binding(get: { sortOption }, set: { sortOption = $0; viewModel.sortPDFs(conversionManager.visiblePDFs, sortOption: $0) }),
                        viewStyle: $viewStyle,
                        tapAction: $tapAction,
                        activeSheet: .constant(nil), // Handled by Router now
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
                            onImport: { viewModel.activeSheet = .importer }
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
                            onImport: { viewModel.activeSheet = .importer }
                        )
                    }
                }
                .overlay(ImportTrackerView())
                .safeAreaInset(edge: .bottom) {
                    if isBatchMode {
                        batchBottomToolbar.transition(.move(edge: .bottom))
                    }
                }
                .background(Color.black.ignoresSafeArea())
                // Ã¢Å“â€¦ MVVM Unified Navigation Router
                .fullScreenCover(item: $viewModel.activeFullScreen) { dest in
                    switch dest {
                    case .read(let pdf):
                        ReaderView(fileURL: pdf.url, contentType: pdf.contentType, pdf: pdf)
                    case .advancedWorkspace(let pdf):
                        AdvancedWorkspaceView(pdf: pdf).environmentObject(conversionManager)
                    }
                }
                .sheet(item: $viewModel.activeSheet) { item in
                    switch item {
                    case .importer: ImportQueueView()
                    case .wifi: WiFiView()
                    case .merge: FileMergeView()
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
            viewModel.updateLibraryItemsCache(pdfs: conversionManager.visiblePDFs, sortOption: sortOption)
        }
        .onChange(of: conversionManager.visiblePDFs) { viewModel.updateLibraryItemsCache(pdfs: conversionManager.visiblePDFs, sortOption: sortOption) }
        .onChange(of: sortOption) { viewModel.updateLibraryItemsCache(pdfs: conversionManager.visiblePDFs, sortOption: sortOption) }
        .onChange(of: conversionManager.collections.count) { viewModel.updateLibraryItemsCache(pdfs: conversionManager.visiblePDFs, sortOption: sortOption) }
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
