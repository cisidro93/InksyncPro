import SwiftUI
import UniformTypeIdentifiers
import Combine



// Ã¢Å“â€¦ NEW: Combine Debouncer for Library Search
class SearchDebouncer: ObservableObject {
    @Published var text: String = ""
    @Published var debouncedText: String = ""
    private var bag = Set<AnyCancellable>()
    
    init() {
        $text
            .debounce(for: .seconds(0.3), scheduler: RunLoop.main)
            .removeDuplicates()
            .assign(to: &$debouncedText)
    }
}

struct ModernLibraryView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @Binding var selectedPDF: ConvertedPDF?
    @Binding var isBatchMode: Bool
    @Binding var multiSelection: Set<UUID>
    @Binding var showingBatchMergeReorder: Bool
    @Binding var batchMergeItems: [ConvertedPDF]
    
    // Ã¢Å“â€¦ Navigation Mode
    var useNavigationStack: Bool = false
    
    // Ã¢Å“â€¦ Editor State
    @State private var pdfToEditMetadata: ConvertedPDF?
    // Ã¢Å“â€¦ Root-level folder picker callback (avoids iOS 16/17 delegate swallowing bug)
    var onFolderImport: (() -> Void)? = nil
    
    // Ã¢Å“â€¦ NEW: View Style State
    enum LibraryViewStyle: String {
        case list = "List"
        case grid = "Grid"
    }
    @AppStorage("libraryViewStyle") private var viewStyle: LibraryViewStyle = .grid
    @AppStorage("libraryTapAction") private var tapAction: LibraryTapAction = .details // Ã¢Å“â€¦ NEW: Tap Action Selector
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding: Bool = false
    
    // Local State
    @StateObject private var searchDebouncer = SearchDebouncer()
    @State private var searchText = ""
    
    enum SidebarSheet: Identifiable {
        case importer, wifi, cloud, merge
        var id: Int { hashValue }
    }
    
    @State private var activeSheet: SidebarSheet?
    // UI State
    enum SortOption: String, CaseIterable, Identifiable {
        case dateAdded = "Most Recent"
        case name = "Name"
        case size = "Size"
        case favorites = "Favorites First"
        case type = "Single / Series"
        case extensionType = "Format (CBZ/PDF)" // Ã¢Å“â€¦ NEW: Format Sorting
        var id: String { rawValue }
    }
    @State private var sortOption: SortOption = .dateAdded
    @State private var showingSortMenu = false
    
    // Ã¢Å“â€¦ NEW: Rename Logic
    @State private var pdfToRename: ConvertedPDF?
    @State private var renameText = ""
    
    // Ã¢Å“â€¦ NEW: Batch Editor State
    @State private var showBatchMetadataEditor = false
    
    // Ã¢Å“â€¦ NEW: Export State
    @State private var pdfToExport: ConvertedPDF?
    @State private var pdfToDirectShare: ConvertedPDF? // Ã¢Å“â€¦ Competitor Hardening: Native Share
    @State private var pdfToSearchMetadata: ConvertedPDF?
    @State private var pdfToCloudSync: ConvertedPDF? // Ã¢Å“â€¦ NEW: WebDAV Sync
    
    // Ã¢Å“â€¦ Layer 4: Manual Series Assignment (Single)
    @State private var pdfToAssignSeries: ConvertedPDF?
    @State private var assignSeriesText = ""
    
    // Ã¢Å“â€¦ NEW: Native Reader State
    @State private var pdfToRead: ConvertedPDF?
    
    // Ã¢Å“â€¦ NEW: Media Detail Sheet State
    @State private var pdfForDetails: ConvertedPDF?
    
    // Ã¢Å“â€¦ NEW: Batch Series Assignment
    @State private var showingBatchGroupAlert = false
    @State private var batchGroupText = ""
    @State private var cachedLibraryItems: [LibraryListItem] = []

// Definitions moved to SeriesModels.swift
    // Ã¢Å“â€¦ Detached Background Compute
    private func updateLibraryItemsCache() {
        // Capture context snapshot to safely detach
        let pdfs = conversionManager.visiblePDFs
        
        Task.detached(priority: .background) {
            var groups: [String: SeriesGroup] = [:]
            var singles: [ConvertedPDF] = []
            var firstAppearanceIndex: [String: Int] = [:]
            
            for (index, pdf) in pdfs.enumerated() {
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
            
            let query = await MainActor.run { self.searchDebouncer.debouncedText }
            if !query.isEmpty {
                items = items.filter { tuple in
                    switch tuple.1 {
                    case .single(let pdf): return pdf.name.localizedCaseInsensitiveContains(query)
                    case .series(let group): return group.title.localizedCaseInsensitiveContains(query)
                    }
                }
            }
            
            items.sort { $0.0 < $1.0 }
            let finalItems = items.map { $0.1 }
            
            await MainActor.run {
                self.cachedLibraryItems = finalItems
            }
        }
    }
    
    func sortPDFs(_ pdfs: [ConvertedPDF]) -> [ConvertedPDF] {
        switch sortOption {
        case .dateAdded: return pdfs.reversed() // Returns newest imported first, which places it natively at index 0 and top-left.
        case .name: return pdfs.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
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

    private func toggleFavorite(for pdf: ConvertedPDF) {
        if let index = conversionManager.convertedPDFs.firstIndex(where: { $0.id == pdf.id }) {
            conversionManager.convertedPDFs[index].isFavorite.toggle()
        }
    }

    var body: some View {
        Group {
            Group {
                VStack(spacing: 0) {
                    // MARK: - Dedicated Header Component
                    LibraryHeaderView(
                        searchText: $searchText,
                        sortOption: $sortOption,
                        viewStyle: $viewStyle,
                        tapAction: $tapAction,
                        activeSheet: $activeSheet,
                        isBatchMode: $isBatchMode,
                        multiSelection: $multiSelection,
                        batchMergeItems: $batchMergeItems,
                        showingBatchMergeReorder: $showingBatchMergeReorder,
                        onVaultToggle: handleVaultToggle
                    )

                    // MARK: - Discrete Layout Layers
                    if viewStyle == .list {
                        LibraryListView(
                            items: cachedLibraryItems,
                            isBatchMode: $isBatchMode,
                            multiSelection: $multiSelection,
                            useNavigationStack: useNavigationStack,
                            tapAction: $tapAction,
                            selectedPDF: $selectedPDF,
                            onAction: handleDetailAction,
                            onImport: { activeSheet = .importer }
                        )
                    } else {
                        LibraryGridView(
                            items: cachedLibraryItems,
                            isBatchMode: $isBatchMode,
                            multiSelection: $multiSelection,
                            useNavigationStack: useNavigationStack,
                            tapAction: $tapAction,
                            selectedPDF: $selectedPDF,
                            onAction: handleDetailAction,
                            onImport: { activeSheet = .importer }
                        )
                    }
                }
        .overlay(
            Group {
                if conversionManager.isConverting {
                    ImmersiveConversionOverlay(pdfName: "Processing Library Item...")
                        .transition(.opacity.animation(.easeInOut))
                }
                
                // Ã¢Å“â€¦ NEW: Background Import Tracker
                ImportTrackerView()
            }
        )
        .safeAreaInset(edge: .bottom) {
            if isBatchMode {
                batchBottomToolbar
                    .transition(.move(edge: .bottom))
            }
        }
        .background(Color.black.ignoresSafeArea())
        // Ã¢Å“â€¦ Native Reader
        .fullScreenCover(item: $pdfToRead) { pdf in
            ReaderView(fileURL: pdf.url, contentType: pdf.contentType, pdf: pdf)
        }
        .sheet(item: $activeSheet) { item in
            switch item {
            case .importer, .cloud:
                ImportQueueView()
            case .wifi: WiFiView()
            case .merge: FileMergeView()
            }
        }
        .fullScreenCover(item: $selectedPDF) { pdf in
            AdvancedWorkspaceView(pdf: pdf)
                .environmentObject(conversionManager)
        }
        .sheet(item: $pdfToExport) { pdf in
            DualExportView(pdf: pdf)
        }
        } // End of Inner Group
        .sheet(item: $pdfToDirectShare) { pdf in
            ShareSheet(activityItems: [pdf.url])
        }
        .sheet(item: $pdfToSearchMetadata) { pdf in
            MetadataSearchSheet(pdf: pdf)
        }
        .sheet(item: $pdfToCloudSync) { pdf in
            CloudSyncView(targetPDF: pdf)
        }
        // Ã¢Å“â€¦ NEW: Media Details Sheet Layout (Option 1)
        .sheet(item: $pdfForDetails) { pdf in
            MediaDetailSheet(pdf: pdf, onAction: { action in
                handleDetailAction(action: action, for: pdf)
            })
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        // Ã¢Å“â€¦ NEW: Advanced Metadata & Cover Editor
        .sheet(item: $pdfToEditMetadata) { pdf in
            AdvancedMetadataEditorView(pdf: pdf)
        }
        // Ã¢Å“â€¦ NEW: Batch Metadata Editor
        .sheet(isPresented: $showBatchMetadataEditor) {
            let selectedFiles = conversionManager.convertedPDFs.filter { multiSelection.contains($0.id) }
            BatchMetadataEditorView(selectedPDFs: selectedFiles)
        }
        } // End of Outer Group
        // Ã¢Å“â€¦ Rename Alert
        .alert("Rename File", isPresented: Binding(
            get: { pdfToRename != nil },
            set: { if !$0 { pdfToRename = nil } }
        )) {
            TextField("New Name", text: $renameText)
            Button("Cancel", role: .cancel) { }
            Button("Rename") {
                if let pdf = pdfToRename {
                    conversionManager.renamePDF(pdf, to: renameText)
                }
            }
        }
        // Layer 4: Custom Series Sheet
        .sheet(isPresented: Binding(
            get: { pdfToAssignSeries != nil || showingBatchGroupAlert },
            set: { isPresented in
                if !isPresented {
                    pdfToAssignSeries = nil
                    showingBatchGroupAlert = false
                }
            }
        )) {
            CollectionEditorSheet { name, icon, color in
                if let singlePDF = pdfToAssignSeries {
                    // Single Assignment
                    if !name.trimmingCharacters(in: .whitespaces).isEmpty {
                        conversionManager.assignToSeries(singlePDF, seriesName: name)
                        // Also create the metadata collection record
                        conversionManager.createCollection(name: name, icon: icon, color: color)
                    }
                } else if showingBatchGroupAlert {
                    // Batch group assignment
                    let items = conversionManager.convertedPDFs.filter { multiSelection.contains($0.id) }
                    let cleanName = name.trimmingCharacters(in: .whitespaces)
                    if !cleanName.isEmpty && !items.isEmpty {
                        for item in items {
                            conversionManager.assignToSeries(item, seriesName: cleanName)
                        }
                        // Create the metadata collection record
                        conversionManager.createCollection(name: cleanName, icon: icon, color: color)
                        
                        isBatchMode = false
                        multiSelection.removeAll()
                    }
                }
                
                pdfToAssignSeries = nil
                showingBatchGroupAlert = false
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
            // Backfill thumbnails for any files imported before the cover fix
            conversionManager.backfillMissingThumbnails()
            updateLibraryItemsCache()
        }
        .onChange(of: conversionManager.visiblePDFs, perform: { _ in updateLibraryItemsCache() })
        .onChange(of: searchText, perform: { _ in updateLibraryItemsCache() })
        .onChange(of: sortOption, perform: { _ in updateLibraryItemsCache() })
        .onChange(of: conversionManager.collections.count, perform: { _ in updateLibraryItemsCache() })
    }
    
    // Copy of helpers
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
                } label: {
                    VStack(spacing: 4) { Image(systemName: "trash").font(.title3); Text("Delete").font(.caption) }
                }
                .disabled(multiSelection.isEmpty)
                
                Spacer()
                
                Button {
                    batchMergeItems = conversionManager.convertedPDFs.filter { multiSelection.contains($0.id) }
                    showingBatchMergeReorder = true
                } label: {
                    VStack(spacing: 4) { Image(systemName: "doc.on.doc.fill").font(.title3); Text("Convert & Merge").font(.caption) }
                }
                .disabled(multiSelection.count < 2)
                
                Spacer()
                
                Button {
                    batchGroupText = ""
                    showingBatchGroupAlert = true
                } label: {
                    VStack(spacing: 4) { Image(systemName: "rectangle.stack.badge.plus").font(.title3); Text("Group").font(.caption) }
                }
                .disabled(multiSelection.isEmpty)
                
                Spacer()
                
                Button {
                    let items = conversionManager.convertedPDFs.filter { multiSelection.contains($0.id) }
                    for item in items {
                        TransferQueueManager.shared.stageFile(item)
                    }
                    isBatchMode = false
                    multiSelection.removeAll()
                    activeSheet = .wifi
                } label: {
                    VStack(spacing: 4) { Image(systemName: "wifi").font(.title3); Text("Transfer").font(.caption) }
                }
                .disabled(multiSelection.isEmpty)
                
                Spacer()
                // Ã¢Å“â€¦ Advanced Actions Menu 
                Menu {
                    Button {
                        let items = conversionManager.convertedPDFs.filter { multiSelection.contains($0.id) }
                        Task { await conversionManager.convertQueue(items) }
                        isBatchMode = false
                        multiSelection.removeAll()
                    } label: {
                        Label("Fast Convert", systemImage: "arrow.triangle.2.circlepath")
                    }
                    
                    Button {
                        batchMergeItems = conversionManager.convertedPDFs.filter { multiSelection.contains($0.id) }
                        showingBatchMergeReorder = true
                    } label: {
                        Label("Convert & Merge", systemImage: "doc.on.doc.fill")
                    }
                    
                    Button {
                        activeSheet = .merge
                    } label: {
                        Label("Legacy PDF Merge", systemImage: "arrow.triangle.merge")
                    }
                    
                    Divider()
                    
                    Button {
                        showBatchMetadataEditor = true
                    } label: {
                        Label("Intelligent Metadata", systemImage: "sparkles")
                    }
                } label: {
                    VStack(spacing: 4) { 
                        Image(systemName: "ellipsis.circle.fill").font(.title3)
                        Text("Actions").font(.caption) 
                    }
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
    
    // MARK: - Handlers
    private func handleVaultToggle() {
        if conversionManager.isVaultUnlocked {
            withAnimation { conversionManager.isVaultUnlocked = false }
        } else {
            Task {
                let success = await SecurityManager.shared.authenticate()
                if success {
                    await MainActor.run {
                        withAnimation { conversionManager.isVaultUnlocked = true }
                    }
                }
            }
        }
    }
    
    // MARK: - Navigation Action Router
    private func handleDetailAction(action: LibraryRowAction, for pdf: ConvertedPDF) {
        // A slight delay ensures the detail sheet finishes dismissing before we pop up a new one
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            switch action {
            case .read:          pdfToRead = pdf
            case .covers:        selectedPDF = pdf
            case .fetchMetadata: pdfToSearchMetadata = pdf
            case .editMetadata:  pdfToEditMetadata = pdf
            case .export:        pdfToExport = pdf
            case .share:         pdfToDirectShare = pdf
            case .sync:          pdfToCloudSync = pdf
            case .rename:
                renameText = pdf.name
                pdfToRename = pdf
            case .addToSeries:
                assignSeriesText = pdf.metadata.series ?? ""
                pdfToAssignSeries = pdf
            case .delete:
                conversionManager.deletePDF(pdf)
            }
        }
    }
}
