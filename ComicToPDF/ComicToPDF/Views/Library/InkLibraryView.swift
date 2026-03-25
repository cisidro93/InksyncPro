import SwiftUI

struct InkLibraryView: View {
    @EnvironmentObject var manager: ConversionManager
    @State private var searchString: String = ""
    @State private var isBatchMode: Bool = false
    @State private var multiSelection: Set<UUID> = []
    @State private var activeSheet: LibrarySheetDestination?

    var sortedCollections: [PDFCollection] {
        manager.collections.sorted { $0.orderIndex < $1.orderIndex }
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

    var body: some View {
        NavigationStack {
            ZStack {
                Color.inkBackground.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {

                        // Search Results overlay
                        if !searchString.isEmpty {
                            searchResultsGrid
                        } else {
                            // 1. Attention Banners
                            if !attentionItems.isEmpty {
                                VStack(spacing: 8) {
                                    ForEach(attentionItems.prefix(3)) { item in
                                        AttentionBanner(pdf: item) { dest in
                                            activeSheet = dest
                                        }
                                        .padding(.horizontal, 20)
                                    }
                                }
                                .padding(.top, 16)
                            }

                            // 2. Shelf Sections
                            if manager.visiblePDFs.isEmpty {
                                emptyState
                            } else {
                                ForEach(sortedCollections) { collection in
                                    ShelfSection(
                                        collection: collection,
                                        manager: manager,
                                        isBatchMode: $isBatchMode,
                                        multiSelection: $multiSelection,
                                        onSheet: { activeSheet = $0 }
                                    )
                                }
                                .padding(.bottom, 20)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Library")
            .searchable(text: $searchString, prompt: "Search titles or series")
            .toolbar {
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
            // Add a bottom bar if batch mode is active
            .safeAreaInset(edge: .bottom) {
                if isBatchMode {
                    batchActionBar
                        .transition(.move(edge: .bottom))
                }
            }
            .sheet(item: $activeSheet) { dest in
                // We reuse LibraryRouter or switch inline to handle routing maps
                // Note: requires full destination bindings in real app; stubbed mapping here
                Text("Destination: \(String(describing: dest))")
                    .environmentObject(manager)
            }
        }
    }

    @ViewBuilder
    var searchResultsGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 16)], spacing: 20) {
            ForEach(searchResults) { pdf in
                BookCard(
                    pdf: pdf,
                    manager: manager,
                    isSelected: multiSelection.contains(pdf.id),
                    isBatchMode: isBatchMode,
                    onTap: {
                        if isBatchMode {
                            if multiSelection.contains(pdf.id) { multiSelection.remove(pdf.id) }
                            else { multiSelection.insert(pdf.id) }
                        } else {
                            activeSheet = .details(pdf)
                        }
                    },
                    onLongPress: { activeSheet = .details(pdf) },
                    onContextAction: { _ in }
                )
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
            Button("Delete") {
                // Delete selected
            }
            .foregroundColor(.inkRed)
            
            Spacer()
            
            Text("\(multiSelection.count) Selected")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.inkTextSecondary)
                
            Spacer()
            
            Button("Send") {
                // Send selected
            }
            .foregroundColor(.inkBlue)
            .disabled(multiSelection.isEmpty)
        }
        .padding()
        .background(Color.inkSurfaceRaised.ignoresSafeArea())
    }
}
