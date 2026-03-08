import SwiftUI
import UniformTypeIdentifiers

// MARK: - Theme Colors
struct Theme {
    static let bg = Color.black
    static let surface = Color(red: 28/255, green: 28/255, blue: 30/255)
    static let surfaceElevated = Color(red: 58/255, green: 58/255, blue: 60/255)
    static let orange = Color(red: 1, green: 159/255, blue: 10/255) // #FF9F0A
    static let blue = Color(red: 10/255, green: 132/255, blue: 255/255) // #0A84FF
    static let text = Color.white
    static let textSecondary = Color(red: 142/255, green: 142/255, blue: 147/255) // #8E8E93
    static let textTertiary = Color(red: 99/255, green: 99/255, blue: 102/255) // #636366
}

struct ModernLibraryView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @Binding var selectedPDF: ConvertedPDF?
    @Binding var isBatchMode: Bool
    @Binding var multiSelection: Set<UUID>
    @Binding var showingBatchMergeReorder: Bool
    @Binding var batchMergeItems: [ConvertedPDF]
    
    // ✅ Navigation Mode
    var useNavigationStack: Bool = false
    
    // ✅ Editor State
    @State private var pdfToEditMetadata: ConvertedPDF?
    // ✅ Root-level folder picker callback (avoids iOS 16/17 delegate swallowing bug)
    var onFolderImport: (() -> Void)? = nil
    
    // ✅ NEW: View Style State
    enum LibraryViewStyle: String {
        case list = "List"
        case grid = "Grid"
    }
    @AppStorage("libraryViewStyle") private var viewStyle: LibraryViewStyle = .grid
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding: Bool = false
    
    // Local State
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
        var id: String { rawValue }
    }
    @State private var sortOption: SortOption = .dateAdded
    @State private var showingSortMenu = false
    
    // ✅ NEW: Rename Logic
    @State private var pdfToRename: ConvertedPDF?
    @State private var renameText = ""
    
    // ✅ NEW: Batch Editor State
    @State private var showBatchMetadataEditor = false
    
    // ✅ NEW: Export State
    @State private var pdfToExport: ConvertedPDF?
    @State private var pdfToSearchMetadata: ConvertedPDF?
    
    // ✅ Layer 4: Manual Series Assignment (Single)
    @State private var pdfToAssignSeries: ConvertedPDF?
    @State private var assignSeriesText = ""
    
    // ✅ NEW: Native Reader State
    @State private var pdfToRead: ConvertedPDF?
    
    // ✅ NEW: Batch Series Assignment
    @State private var showingBatchGroupAlert = false
    @State private var batchGroupText = ""
    
    // ✅ NEW: Unified Library Item
    enum LibraryListItem: Identifiable, Hashable {
        case single(ConvertedPDF)
        case series(SeriesGroup)
        
        var id: String {
            switch self {
            case .single(let pdf): return "single_\(pdf.id)"
            case .series(let group): return "series_\(group.id)"
            }
        }
    }
    
    var libraryItems: [LibraryListItem] {
        let allPDFs = sortPDFs(conversionManager.visiblePDFs)
        var items: [(Int, LibraryListItem)] = []
        var seriesDict: [String: [ConvertedPDF]] = [:]
        var singles: [ConvertedPDF] = []
        
        // Track the first appearance index for sorting
        var firstAppearanceIndex: [String: Int] = [:]
        
        for (index, pdf) in allPDFs.enumerated() {
            let key = (pdf.metadata.series ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if key.isEmpty {
                singles.append(pdf)
                firstAppearanceIndex["single_\(pdf.id)"] = index
            } else {
                seriesDict[key, default: []].append(pdf)
                if firstAppearanceIndex["series_\(key)"] == nil {
                    firstAppearanceIndex["series_\(key)"] = index
                }
            }
        }
        
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        
        for (seriesName, issues) in seriesDict {
            let sortedIssues = issues.sorted { lhs, rhs in
                if let i1 = lhs.metadata.issueNumber, let n1 = Int(i1),
                   let i2 = rhs.metadata.issueNumber, let n2 = Int(i2) {
                    return n1 < n2
                }
                return lhs.name < rhs.name
            }
            
            var coverID: UUID? = sortedIssues.first?.id
            
            if let matchingCollection = conversionManager.collections.first(where: { $0.name == seriesName }),
               let explicitID = matchingCollection.explicitCoverFileID,
               issues.contains(where: { $0.id == explicitID }) {
                let candidateURL = docs.appendingPathComponent("cover_\(explicitID.uuidString).jpg")
                if FileManager.default.fileExists(atPath: candidateURL.path) {
                    coverID = explicitID
                }
            } else {
                coverID = sortedIssues.first(where: {
                    let url = docs.appendingPathComponent("cover_\($0.id.uuidString).jpg")
                    return FileManager.default.fileExists(atPath: url.path)
                })?.id ?? sortedIssues.first?.id
            }
            
            let group = SeriesGroup(id: seriesName, title: seriesName, coverIssueID: coverID, count: sortedIssues.count, issues: sortedIssues)
            let item = LibraryListItem.series(group)
            items.append((firstAppearanceIndex["series_\(seriesName)"] ?? 0, item))
        }
        
        for single in singles {
            let item = LibraryListItem.single(single)
            items.append((firstAppearanceIndex["single_\(single.id)"] ?? 0, item))
        }
        
        // Apply Search Filter
        if !searchText.isEmpty {
            items = items.filter { tuple in
                switch tuple.1 {
                case .single(let pdf): return pdf.name.localizedCaseInsensitiveContains(searchText)
                case .series(let group): return group.title.localizedCaseInsensitiveContains(searchText)
                }
            }
        }
        
        // Restore Sorting Order based on first appearance in allPDFs
        items.sort { $0.0 < $1.0 }
        return items.map { $0.1 }
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
        }
    }

    private func toggleFavorite(for pdf: ConvertedPDF) {
        if let index = conversionManager.convertedPDFs.firstIndex(where: { $0.id == pdf.id }) {
            conversionManager.convertedPDFs[index].isFavorite.toggle()
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // MARK: - Toolbar & Filter Header
            liquidGlassHeader

            // ... (Content Area) ...
            if viewStyle == .list {
                pdfListLayout
            } else {
                pdfGridLayout
            }
        }
        .overlay(
            Group {
                if conversionManager.isConverting {
                    ImmersiveConversionOverlay(pdfName: "Processing Library Item...")
                        .transition(.opacity.animation(.easeInOut))
                }
            }
        )
        .safeAreaInset(edge: .bottom) {
            if isBatchMode {
                batchBottomToolbar
                    .transition(.move(edge: .bottom))
            }
        }
        .background(Color.black.ignoresSafeArea())
        // ✅ Native Reader
        .fullScreenCover(item: $pdfToRead) { pdf in
            ReaderView(fileURL: pdf.url, contentType: pdf.contentType, pdf: pdf)
        }
        .sheet(item: $activeSheet) { item in
            switch item {
            case .importer, .cloud:
                DocumentPicker(onDocumentsPicked: { urls in
                    Task {
                        await conversionManager.importFilesAsSeries(urls: urls)
                        activeSheet = nil
                    }
                })
            case .wifi: WiFiView()
            case .merge: FileMergeView()
            }
        }
        .sheet(item: $pdfToExport) { pdf in
            DualExportView(pdf: pdf)
        }
        .sheet(item: $pdfToSearchMetadata) { pdf in
            MetadataSearchSheet(pdf: pdf)
        }
        // ✅ NEW: Advanced Metadata & Cover Editor
        .sheet(item: $pdfToEditMetadata) { pdf in
            AdvancedMetadataEditorView(pdf: pdf)
        }
        // ✅ NEW: Batch Metadata Editor
        .sheet(isPresented: $showBatchMetadataEditor) {
            let selectedFiles = conversionManager.convertedPDFs.filter { multiSelection.contains($0.id) }
            BatchMetadataEditorView(selectedPDFs: selectedFiles)
        }
        // ✅ Rename Alert
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
        }
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
    
    @ViewBuilder private var pdfListLayout: some View {
        if conversionManager.visiblePDFs.isEmpty {
            ModernEmptyState(onImport: { activeSheet = .importer }, onFolderImport: nil)
        } else {
            List(selection: useNavigationStack ? nil : $selectedPDF) {
                ForEach(libraryItems) { item in
                    switch item {
                    case .series(let group):
                        if isBatchMode {
                            Button {
                                let allSelected = group.issues.allSatisfy { multiSelection.contains($0.id) }
                                if allSelected {
                                    for issue in group.issues { multiSelection.remove(issue.id) }
                                } else {
                                    for issue in group.issues { multiSelection.insert(issue.id) }
                                }
                            } label: {
                                ModernSeriesRow(group: group, isSelected: group.issues.allSatisfy { multiSelection.contains($0.id) }, isBatch: true)
                            }
                            .listRowBackground(Color.black)
                            .listRowSeparatorTint(Color(white: 0.2))
                        } else {
                            NavigationLink(destination: SeriesDetailView(series: group, selectedPDF: $selectedPDF, useNavigationStack: useNavigationStack)) {
                                ModernSeriesRow(group: group, isSelected: false, isBatch: false)
                            }
                            .listRowBackground(Color.black)
                            .listRowSeparatorTint(Color(white: 0.2))
                            .contextMenu {
                                Button(role: .destructive) {
                                    for issue in group.issues { conversionManager.deletePDF(issue) }
                                } label: { Label("Delete Series", systemImage: "trash") }
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    for issue in group.issues { conversionManager.deletePDF(issue) }
                                } label: { Label("Delete Series", systemImage: "trash") }
                            }
                        }
                    case .single(let pdf):
                        if isBatchMode {
                             Button {
                                 if multiSelection.contains(pdf.id) {
                                     multiSelection.remove(pdf.id)
                                 } else {
                                     multiSelection.insert(pdf.id)
                                 }
                             } label: {
                                 ModernFileRow(pdf: pdf, isSelected: multiSelection.contains(pdf.id), isBatch: true)
                             }
                             .listRowBackground(Color.black)
                             .listRowSeparatorTint(Color(white: 0.2))
                        } else {
                            if useNavigationStack {
                                NavigationLink(value: pdf) {
                                    ModernFileRow(pdf: pdf, isSelected: false, isBatch: false)
                                }
                                .listRowBackground(Color.black)
                                .listRowSeparatorTint(Color(white: 0.2))
                                .swipeActions(edge: .leading) {
                                    swipeActionsLeading(pdf)
                                }
                                .swipeActions(edge: .trailing) {
                                    swipeActionsTrailing(pdf)
                                }
                                .contextMenu {
                                    contextMenuContent(pdf)
                                }
                            } else {
                                ModernFileRow(pdf: pdf, isSelected: selectedPDF?.id == pdf.id, isBatch: false)
                                    .tag(pdf)
                                    .listRowBackground(selectedPDF?.id == pdf.id ? Theme.surfaceElevated : Color.black)
                                    .listRowSeparatorTint(Color(white: 0.2))
                                    .swipeActions(edge: .leading) {
                                        swipeActionsLeading(pdf)
                                    }
                                    .swipeActions(edge: .trailing) {
                                        swipeActionsTrailing(pdf)
                                    }
                                    .contextMenu {
                                        contextMenuContent(pdf)
                                    }
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .background(Color.black)
        }
    }
    
    // ✅ NEW: Responsive Grid Layout
    @ViewBuilder private var pdfGridLayout: some View {
        if conversionManager.visiblePDFs.isEmpty {
            ModernEmptyState(onImport: { activeSheet = .importer }, onFolderImport: nil)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 200), spacing: 16)], spacing: 20) {
                    ForEach(libraryItems) { item in
                        switch item {
                        case .series(let group):
                            if isBatchMode {
                                Button {
                                    let allSelected = group.issues.allSatisfy { multiSelection.contains($0.id) }
                                    if allSelected {
                                        for issue in group.issues { multiSelection.remove(issue.id) }
                                    } else {
                                        for issue in group.issues { multiSelection.insert(issue.id) }
                                    }
                                } label: {
                                    ModernGridSeriesCell(group: group, isSelected: group.issues.allSatisfy { multiSelection.contains($0.id) }, isBatch: true)
                                }
                                .buttonStyle(PlainButtonStyle())
                            } else {
                                NavigationLink(destination: SeriesDetailView(series: group, selectedPDF: $selectedPDF, useNavigationStack: useNavigationStack)) {
                                    ModernGridSeriesCell(group: group, isSelected: false, isBatch: false)
                                }
                                .buttonStyle(PlainButtonStyle())
                                .contextMenu {
                                    Button(role: .destructive) {
                                        for issue in group.issues { conversionManager.deletePDF(issue) }
                                    } label: { Label("Delete Series", systemImage: "trash") }
                                }
                            }
                        case .single(let pdf):
                            if isBatchMode {
                                Button {
                                    if multiSelection.contains(pdf.id) {
                                        multiSelection.remove(pdf.id)
                                    } else {
                                        multiSelection.insert(pdf.id)
                                    }
                                } label: {
                                    ModernGridFileCell(pdf: pdf, isSelected: multiSelection.contains(pdf.id), isBatch: true)
                                }
                                .buttonStyle(PlainButtonStyle())
                            } else {
                                if useNavigationStack {
                                    NavigationLink(value: pdf) {
                                        ModernGridFileCell(pdf: pdf, isSelected: false, isBatch: false)
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                    .contextMenu { contextMenuContent(pdf) }
                                } else {
                                    Button {
                                        selectedPDF = pdf
                                    } label: {
                                        ModernGridFileCell(pdf: pdf, isSelected: selectedPDF?.id == pdf.id, isBatch: false)
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                    .contextMenu { contextMenuContent(pdf) }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 100)
            }
            .background(Color.black)
        }
    }

    // MARK: - Row Actions
    
    @ViewBuilder
    private func swipeActionsLeading(_ pdf: ConvertedPDF) -> some View {
        Button {
            pdfToExport = pdf
        } label: { Label("Export", systemImage: "square.and.arrow.up") }
        .tint(.green)
    
        Button {
            pdfToSearchMetadata = pdf
        } label: { Label("Metadata", systemImage: "info.circle") }
        .tint(.blue)
        
        Button {
            toggleFavorite(for: pdf)
        } label: { Label(pdf.isFavorite ? "Unfavorite" : "Favorite", systemImage: pdf.isFavorite ? "star.slash.fill" : "star.fill") }
        .tint(.yellow)
        
        Button {
            renameText = pdf.name
            pdfToRename = pdf
        } label: { Label("Rename", systemImage: "pencil") }
        .tint(.orange)
        
        Button {
            Task { await conversionManager.embedPanels(for: pdf) }
        } label: { Label("Embed", systemImage: "flame") }
        .tint(.purple)
    }
    
    @ViewBuilder
    private func swipeActionsTrailing(_ pdf: ConvertedPDF) -> some View {
        Button(role: .destructive) { conversionManager.deletePDF(pdf) } label: { Label("Delete", systemImage: "trash") }
    }
    
    @ViewBuilder
    private func contextMenuContent(_ pdf: ConvertedPDF) -> some View {
        Button {
            pdfToRead = pdf
        } label: { Label("Read / Preview", systemImage: "book.pages") }
        
        Button {
            toggleFavorite(for: pdf)
        } label: { Label(pdf.isFavorite ? "Unfavorite" : "Favorite", systemImage: pdf.isFavorite ? "star.slash" : "star") }
        
        Button {
            pdfToExport = pdf
        } label: { Label("Export Options", systemImage: "square.and.arrow.up") }
        
        Button {
            renameText = pdf.name
            pdfToRename = pdf
        } label: { Label("Rename", systemImage: "pencil") }
        
        // Layer 4: Manual series assignment
        Button {
            assignSeriesText = pdf.metadata.series ?? ""
            pdfToAssignSeries = pdf
        } label: { Label("Add to Series...", systemImage: "books.vertical") }
        
        // Show Cover Select only if the PDF is part of a series or collection
        if (pdf.metadata.series != nil && !pdf.metadata.series!.isEmpty) || pdf.collectionId != nil {
            Button {
                conversionManager.setExplicitSeriesCover(for: pdf)
            } label: { Label("Set as Series Cover", systemImage: "photo.on.rectangle") }
        }
        
        Button {
            Task { await conversionManager.embedPanels(for: pdf) }
        } label: { Label("Embed Panels", systemImage: "flame") }
        
        Button(role: .destructive) { conversionManager.deletePDF(pdf) } label: { Label("Delete", systemImage: "trash") }
        Divider()
        
        Button {
            pdfToEditMetadata = pdf
        } label: { Label("Edit Metadata & Cover", systemImage: "pencil.and.list.clipboard") }
        
        Button {
            pdfToSearchMetadata = pdf
        } label: { Label("Fetch Metadata", systemImage: "magnifyingglass") }
    }

    // MARK: - Extracted Header
    var liquidGlassHeader: some View {
        VStack(spacing: 16) {
            
            // Row 1: Integrated Search & Title
            HStack(spacing: 12) {
                // Title / Brand
                HStack(spacing: 6) {
                     Image(systemName: "books.vertical.fill")
                         .font(.system(size: 24, weight: .bold))
                         .foregroundStyle(Theme.orange.gradient)
                     Text("Library")
                         .font(.system(size: 28, weight: .bold))
                         .foregroundColor(.white)
                         .fixedSize(horizontal: true, vertical: false)
                }
                
                Spacer()
                
                // Large Integrated Search Bar
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(Theme.textSecondary)
                    
                    TextField("Search Collection...", text: $searchText)
                        .font(.system(size: 17))
                        .foregroundColor(.white)
                        .tint(Theme.orange)
                    
                    if !searchText.isEmpty {
                        Button(action: { searchText = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(Theme.textSecondary)
                        }
                    }
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 16)
                .background(.ultraThinMaterial) // Liquid Glass Field
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(.white.opacity(0.1), lineWidth: 1)
                )
                .frame(maxWidth: 400) // Constrain width on large screens
                
                // ✅ NEW: Sort Menu
                Menu {
                    Picker("Sort By", selection: $sortOption) {
                        ForEach(SortOption.allCases) { option in Text(option.rawValue).tag(option) }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(Theme.text)
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(.white.opacity(0.1), lineWidth: 1))
                }
                
                // ✅ NEW: Grid / List Toggle
                Button {
                    withAnimation {
                        viewStyle = viewStyle == .grid ? .list : .grid
                    }
                } label: {
                    Image(systemName: viewStyle == .grid ? "list.bullet" : "square.grid.2x2")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(Theme.text)
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(.white.opacity(0.1), lineWidth: 1))
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            
            // Row 2: Cohesive Action Center (Scrollable Pills)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    
                    // 1. Target Selector Pill (Fixed & Prominent)
                    Menu {
                        Section("Standard Formats") {
                            Picker("Target Format", selection: $conversionManager.conversionSettings.outputFormat) {
                                ForEach(OutputFormat.allCases) { format in
                                    Label(format.rawValue, systemImage: format.icon).tag(format)
                                }
                            }
                        }
                        
                        if !conversionManager.conversionPresets.isEmpty {
                            Section("Custom Profiles") {
                                ForEach(conversionManager.conversionPresets) { preset in
                                    Button {
                                        conversionManager.conversionSettings = preset.settings
                                    } label: {
                                        Label(preset.name, systemImage: "list.clipboard.fill")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text("TARGET")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(Theme.textSecondary)
                                .tracking(1)
                            
                            // Separator
                            Rectangle().fill(Theme.textSecondary.opacity(0.3)).frame(width: 1, height: 12)
                            
                            // Value
                            Text(conversionManager.conversionSettings.outputFormat.rawValue)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(Theme.orange)
                                .fixedSize() // Prevent truncation
                            
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(Theme.textSecondary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.thickMaterial)
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(.white.opacity(0.1), lineWidth: 1))
                    }
                    
                    // Divider
                    Rectangle().fill(.white.opacity(0.1)).frame(width: 1, height: 24)
                    
                    // 2. Action Pills
                    Group {
                        ActionPill(title: "Import", icon: "doc.badge.plus", color: Theme.orange) {
                            activeSheet = .importer
                        }
                        ActionPill(title: "Wi-Fi", icon: "wifi", color: Theme.blue) { activeSheet = .wifi }
                        ActionPill(title: "Cloud", icon: "icloud", color: Theme.blue) { activeSheet = .cloud }
                        ActionPill(title: "Merge", icon: "arrow.triangle.merge", color: Theme.blue) { activeSheet = .merge }
                        ActionPill(title: "Vault", icon: conversionManager.isVaultUnlocked ? "lock.open.fill" : "lock.fill", color: conversionManager.isVaultUnlocked ? Theme.orange : Theme.blue) { 
                            handleVaultToggle() 
                        }
                    }
                    
                    // 3. Selection / Batch
                    Button(action: {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            isBatchMode.toggle()
                            if !isBatchMode { multiSelection.removeAll() }
                        }
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.badge.questionmark")
                            Text(isBatchMode ? "Done" : "Select")
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(isBatchMode ? .white : Theme.text)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(isBatchMode ? AnyShapeStyle(Theme.orange) : AnyShapeStyle(.thickMaterial))
                        .clipShape(Capsule())
                    }
                }
                .padding(.horizontal, 20)
            }
            .padding(.bottom, 16)
        }
        .overlay(
            Rectangle().frame(height: 1).foregroundColor(.white.opacity(0.05)),
            alignment: .bottom
        )
    }
    
    // MARK: - Batch Bottom Toolbar
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
                    VStack(spacing: 4) { Image(systemName: "doc.on.doc.fill").font(.title3); Text("Merge").font(.caption) }
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
                
                // ✅ Advanced Actions Menu 
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
                        Label("Merge", systemImage: "doc.on.doc.fill")
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
}

// MARK: - Subcomponents

struct ModernEmptyState: View {
    var onImport: () -> Void
    var onFolderImport: (() -> Void)?
    
    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            
            // Simulated "Bookshelf" Icon using SF Symbols stack
            ZStack(alignment: .bottom) {
                Image(systemName: "books.vertical.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 80, height: 80)
                    .foregroundColor(Theme.surfaceElevated)
                
                // Shelf line
                Rectangle()
                    .fill(Theme.surfaceElevated)
                    .frame(width: 120, height: 4)
                    .offset(y: 4)
            }
            .padding(.bottom, 20)
            
            Text("Your Library is Empty")
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundColor(Theme.text)
            
            Button(action: onImport) {
                HStack {
                    Image(systemName: "plus")
                    Text("Import Comic")
                }
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .background(Theme.blue)
                .cornerRadius(12)
            }
            
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}

struct ModernFileRow: View {
    let pdf: ConvertedPDF
    let isSelected: Bool
    let isBatch: Bool
    @EnvironmentObject var conversionManager: ConversionManager
    
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if let img = conversionManager.getThumbnail(for: pdf) {
                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(Theme.surfaceElevated)
                    Image(systemName: "doc.text.fill")
                        .foregroundColor(Theme.textSecondary)
                }
            }
            .frame(width: 40, height: 56)
            .cornerRadius(4)
            .clipped()
            
            VStack(alignment: .leading, spacing: 4) {
                Text(pdf.name)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(Theme.text)
                    .lineLimit(1)
                
                HStack(spacing: 6) {
                    // Content Type Badge
                    HStack(spacing: 3) {
                        Image(systemName: pdf.contentType.icon)
                            .font(.system(size: 8))
                        Text(pdf.contentType.rawValue.uppercased())
                            .font(.system(size: 10, weight: .bold))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(pdf.contentType.badgeColor.opacity(0.2))
                    .foregroundColor(pdf.contentType.badgeColor)
                    .cornerRadius(4)
                    
                    Text(pdf.formattedSize)
                        .font(.caption)
                        .foregroundColor(Theme.textSecondary)
                    if pdf.isFavorite {
                        Image(systemName: "heart.fill")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
            }
            
            Spacer()
            
            if isBatch {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundColor(isSelected ? Theme.blue : Theme.textSecondary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .hoverEffect(.lift)
    }
}

// MARK: - Action Pill Component
struct ActionPill: View {
    let title: String
    let icon: String
    let color: Color
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.thinMaterial)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(.white.opacity(0.1), lineWidth: 1)
            )
        }
    }
}

struct ModernSeriesRow: View {
    let group: SeriesGroup
    let isSelected: Bool
    let isBatch: Bool
    @EnvironmentObject var conversionManager: ConversionManager
    
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                // Stack effect
                if group.count > 1 {
                    RoundedRectangle(cornerRadius: 4).fill(Theme.surfaceElevated).frame(width: 40, height: 56).offset(x: 3, y: -3)
                }
                
                if let issueID = group.coverIssueID, let pdf = conversionManager.convertedPDFs.first(where: { $0.id == issueID }), let img = conversionManager.getThumbnail(for: pdf) {
                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(Theme.surfaceElevated)
                    Image(systemName: "books.vertical.fill")
                        .foregroundColor(Theme.textSecondary)
                }
            }
            .frame(width: 40, height: 56)
            .cornerRadius(4)
            .clipped()
            
            VStack(alignment: .leading, spacing: 4) {
                Text(group.title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(Theme.text)
                    .lineLimit(1)
                
                HStack(spacing: 6) {
                    HStack(spacing: 3) {
                        Image(systemName: "books.vertical.fill")
                            .font(.system(size: 8))
                        Text("SERIES")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.blue.opacity(0.2))
                    .foregroundColor(Theme.blue)
                    .cornerRadius(4)
                    
                    Text("\(group.count) Issues")
                        .font(.caption)
                        .foregroundColor(Theme.textSecondary)
                }
            }
            
            Spacer()
            
            if isBatch {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundColor(isSelected ? Theme.blue : Theme.textSecondary)
            } else {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(Theme.textSecondary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .hoverEffect(.lift)
    }
}

// MARK: - Grid Components

struct ModernGridFileCell: View {
    let pdf: ConvertedPDF
    let isSelected: Bool
    let isBatch: Bool
    @EnvironmentObject var conversionManager: ConversionManager
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Cover Image Setup
            ZStack(alignment: .topTrailing) {
                if let img = conversionManager.getThumbnail(for: pdf) {
                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(Theme.surfaceElevated)
                    Image(systemName: "doc.text.fill")
                        .font(.largeTitle)
                        .foregroundColor(Theme.textSecondary)
                }
                
                // Batch Selection Overlay
                if isBatch {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundColor(isSelected ? Theme.blue : .white)
                        .padding(8)
                        .shadow(radius: 2)
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(0.7, contentMode: .fill) // Standard comic aspect ratio
            .cornerRadius(8)
            .clipped()
            
            // Text Details
            VStack(alignment: .leading, spacing: 4) {
                Text(pdf.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(height: 38, alignment: .topLeading) // Fixed height to align rows
                
                HStack(spacing: 6) {
                    // Content Type Badge
                    HStack(spacing: 3) {
                        Image(systemName: pdf.contentType.icon).font(.system(size: 8))
                        Text(pdf.contentType.rawValue.uppercased()).font(.system(size: 10, weight: .bold))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(pdf.contentType.badgeColor.opacity(0.2))
                    .foregroundColor(pdf.contentType.badgeColor)
                    .cornerRadius(4)
                    
                    Spacer()
                    
                    Text(pdf.formattedSize)
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(8)
        .background(isSelected && !isBatch ? Theme.surfaceElevated : Color.clear)
        .cornerRadius(12)
        .contentShape(Rectangle())
        .hoverEffect(.lift)
    }
}

struct ModernGridSeriesCell: View {
    let group: SeriesGroup
    let isSelected: Bool
    let isBatch: Bool
    @EnvironmentObject var conversionManager: ConversionManager
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            
            // Cover Image with Stack Effect
            ZStack(alignment: .topTrailing) {
                ZStack {
                    if group.count > 1 { // Stack Effect Backgrounds
                        RoundedRectangle(cornerRadius: 12).fill(Theme.surfaceElevated).padding(4).offset(y: -8)
                        RoundedRectangle(cornerRadius: 12).fill(Theme.surfaceElevated).padding(2).offset(y: -4)
                    }
                    if let issueID = group.coverIssueID, let pdf = conversionManager.convertedPDFs.first(where: { $0.id == issueID }), let img = conversionManager.getThumbnail(for: pdf) {
                        Image(uiImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle().fill(Theme.surfaceElevated)
                        Image(systemName: "books.vertical.fill")
                            .font(.largeTitle)
                            .foregroundColor(Theme.textSecondary)
                    }
                }
                .cornerRadius(8)
                .clipped()
                
                // Batch Selection Overlay
                if isBatch {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundColor(isSelected ? Theme.blue : .white)
                        .padding(8)
                        .shadow(radius: 2)
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(0.7, contentMode: .fit) // Standard comic aspect ratio
            
            // Text Details
            VStack(alignment: .leading, spacing: 4) {
                Text(group.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(height: 38, alignment: .topLeading)
                
                HStack(spacing: 6) {
                    HStack(spacing: 3) {
                        Image(systemName: "books.vertical.fill").font(.system(size: 8))
                        Text("SERIES").font(.system(size: 10, weight: .bold))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.blue.opacity(0.2))
                    .foregroundColor(Theme.blue)
                    .cornerRadius(4)
                    
                    Spacer()
                    
                    Text("\(group.count) Issues")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(8)
        .background(isSelected && !isBatch ? Theme.surfaceElevated : Color.clear)
        .cornerRadius(12)
        .contentShape(Rectangle())
        .hoverEffect(.lift)
    }
}
