import SwiftUI

struct InkLibraryView: View {
    @EnvironmentObject var manager: ConversionManager
    @Environment(\.horizontalSizeClass) private var hSizeClass

    @State private var searchString: String = ""
    @State private var isBatchMode: Bool = false
    @State private var multiSelection: Set<UUID> = []
    @State private var activeSheet: LibrarySheetDestination?
    @State private var selectedPDF: ConvertedPDF? = nil
    @State private var pendingImportURL: URL? = nil
    @State private var showSmartImport: Bool = false
    
    var sortedCollections: [PDFCollection] {
        manager.collections.sorted(by: { $0.creationDate < $1.creationDate })
    }

    var attentionItems: [ConvertedPDF] {
        manager.visiblePDFs.filter { pdf in
            pdf.lastTransferFailed || (pdf.panelConfidenceScore ?? 1.0) < 0.75
        }
    }

    var searchResults: [ConvertedPDF] {
        if searchString.isEmpty { return [] }
        return manager.visiblePDFs.filter {
            $0.name.localizedCaseInsensitiveContains(searchString) ||
            $0.metadata.title.localizedCaseInsensitiveContains(searchString) ||
            $0.metadata.series?.localizedCaseInsensitiveContains(searchString) == true
        }
    }

    private var gridColumns: [GridItem] {
        let count = hSizeClass == .regular ? 5 : 3
        return Array(repeating: GridItem(.flexible(), spacing: 16), count: count)
    }

    var body: some View {
        if hSizeClass == .regular {
            iPadLibrarySplit
        } else {
            iPhoneLibraryNavStack
        }
    }

    // iPhone: standard NavigationStack
    private var iPhoneLibraryNavStack: some View {
        NavigationStack {
            libraryContent
                .navigationTitle("Library")
                .navigationBarTitleDisplayMode(.large)
                .toolbar { libraryToolbar }
        }
        .sheet(item: $activeSheet) { dest in librarySheet(for: dest) }
    }

    // iPad: two-column split — collection list / shelf on left, detail on right
    private var iPadLibrarySplit: some View {
        NavigationSplitView {
            libraryContent
                .navigationTitle("Library")
                .toolbar { libraryToolbar }
        } detail: {
            if let selectedPDF = selectedPDF {
                MediaDetailSheet(
                    pdf: selectedPDF,
                    onAction: { action in
                        // Handled by vm/router in full app
                        print("iPad Grid Action \(action)")
                    }
                )
            } else {
                iPadEmptyDetail
            }
        }
        .sheet(item: $activeSheet) { dest in librarySheet(for: dest) }
    }

    @ViewBuilder
    private var libraryContent: some View {
        ZStack {
            Color.inkBackground.ignoresSafeArea()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    if !searchString.isEmpty {
                        searchResultsGrid
                    } else {
                        // 1. Attention Banners
                        if let firstAttention = attentionItems.first {
                            AttentionBanner(pdf: firstAttention) { dest in
                                activeSheet = dest
                            }
                            .padding(.horizontal, 20)
                            .padding(.top, 16)
                        }

                        // 2. Shelf Sections
                        if manager.visiblePDFs.isEmpty {
                            emptyState
                        } else {
                            if hSizeClass == .regular {
                                iPadLibraryGrid
                            } else {
                                iPhoneShelfRows
                            }
                        }
                    }
                    Spacer(minLength: 100)
                }
            }
            .dropDestination(for: URL.self) { items, _ in
                guard let first = items.first else { return false }
                pendingImportURL = first
                showSmartImport = true
                return true
            }
        }
        .searchable(text: $searchString, prompt: "Search titles or series")
        .safeAreaInset(edge: .bottom) {
            if isBatchMode {
                batchActionBar.transition(.move(edge: .bottom))
            }
        }
        .sheet(isPresented: $showSmartImport) {
            if let url = pendingImportURL {
                SmartImportSheet(sourceURL: url)
                    .environmentObject(manager)
            }
        }
    }

    private var iPadLibraryGrid: some View {
        VStack(alignment: .leading, spacing: 28) {
            // Section per collection
            ForEach(sortedCollections) { collection in
                let pdfs = manager.visiblePDFs.filter { $0.collectionId == collection.id }
                if !pdfs.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(collection.name)
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundColor(.inkTextPrimary)
                            Spacer()
                            Text("\(pdfs.count) volumes")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(.inkTextSecondary)
                        }
                        .padding(.horizontal, 24)

                        LazyVGrid(columns: gridColumns, spacing: 20) {
                            ForEach(pdfs) { pdf in
                                bookCardInstance(pdf: pdf)
                            }
                        }
                        .padding(.horizontal, 24)
                    }
                }
            }

            // Uncollected
            let uncollected = manager.visiblePDFs.filter { $0.collectionId == nil }
            if !uncollected.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Uncategorised")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.inkTextPrimary)
                        .padding(.horizontal, 24)

                    LazyVGrid(columns: gridColumns, spacing: 20) {
                        ForEach(uncollected) { pdf in
                            bookCardInstance(pdf: pdf)
                        }
                    }
                    .padding(.horizontal, 24)
                }
            }
        }
        .padding(.top, 20)
    }

    private var iPhoneShelfRows: some View {
        VStack(spacing: 0) {
            ForEach(sortedCollections) { collection in
                ShelfSection(
                    collection: collection,
                    manager: manager,
                    isBatchMode: $isBatchMode,
                    multiSelection: $multiSelection,
                    onSheet: { activeSheet = $0 }
                )
            }
        }
    }

    private func bookCardInstance(pdf: ConvertedPDF) -> some View {
        // In Grids, we pass explicitly nil width to scale with columns
        BookCard(
            pdf: pdf,
            manager: manager,
            isSelected: multiSelection.contains(pdf.id),
            isBatchMode: isBatchMode,
            onTap: {
                if isBatchMode {
                    multiSelection.toggle(pdf.id)
                } else if hSizeClass == .regular {
                    selectedPDF = pdf
                } else {
                    activeSheet = .details(pdf)
                }
            },
            onLongPress: {
                if hSizeClass != .regular {
                    activeSheet = .details(pdf)
                } else {
                    selectedPDF = pdf
                }
            },
            onContextAction: { _ in },
            fixedWidth: (hSizeClass == .regular || !searchString.isEmpty) ? nil : 88
        )
    }

    private var iPadEmptyDetail: some View {
        VStack(spacing: 16) {
            Image(systemName: "books.vertical")
                .font(.system(size: 52))
                .foregroundColor(.inkTextTertiary)
            Text("Select a title")
                .font(.system(size: 17))
                .foregroundColor(.inkTextSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.inkBackground)
    }

    @ToolbarContentBuilder
    private var libraryToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            Button(isBatchMode ? "Done" : "Select") {
                withAnimation {
                    isBatchMode.toggle()
                    if !isBatchMode { multiSelection.removeAll() }
                }
            }
            .foregroundColor(.inkBlue)
        }
    }

    @ViewBuilder
    private func librarySheet(for dest: LibrarySheetDestination) -> some View {
        Text("Destination: \(String(describing: dest))")
            .environmentObject(manager)
    }

    @ViewBuilder
    var searchResultsGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 16)], spacing: 20) {
            ForEach(searchResults) { pdf in
                bookCardInstance(pdf: pdf)
            }
        }
        .padding(20)
    }

    @ViewBuilder
    var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "books.vertical.fill")
                .font(.system(size: 48))
                .foregroundColor(.inkTextSecondary)
            Text("Your library is empty")
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(.inkTextPrimary)
            Text("Switch to the Import tab to add content")
                .font(.system(size: 14))
                .foregroundColor(.inkTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 100)
    }

    @ViewBuilder
    var batchActionBar: some View {
        HStack {
            Button("Delete") { }
            .foregroundColor(.inkRed)
            
            Spacer()
            
            Text("\(multiSelection.count) Selected")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.inkTextSecondary)
                
            Spacer()
            
            Button("Send") { }
            .foregroundColor(.inkBlue)
            .disabled(multiSelection.isEmpty)
        }
        .padding()
        .background(Color.inkSurfaceRaised.ignoresSafeArea())
    }
}

private extension Set {
    mutating func toggle(_ element: Element) {
        if contains(element) { remove(element) } else { insert(element) }
    }
}
