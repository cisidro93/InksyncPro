import SwiftUI
import QuickLook

struct LibraryView: View {
    @Binding var selectedTab: Int
    @EnvironmentObject var conversionManager: ConversionManager
    
    // View State
    @State private var isGridView = true
    @State private var isSelectionMode = false
    @State private var searchText = ""
    @State private var selectedPDFs = Set<UUID>()
    @AppStorage("gridColumns") private var gridColumns: Int = 3
    
    func refreshLibrary() async {
        conversionManager.loadSavedData()
        for pdf in conversionManager.convertedPDFs where pdf.coverImageData == nil {
            conversionManager.generateCoverThumbnail(for: pdf)
        }
    }

    // Single Item Actions
    
    // Single Item Actions
    @State private var selectedPDF: ConvertedPDF?
    @State private var showingActionSheet = false
    @State private var showingShareSheet = false
    @State private var showingDevicePicker = false
    @State private var showingDeleteAlert = false
    
    // Batch Actions
    @State private var showingBatchMail = false
    @State private var showingBatchShare = false
    @State private var showingBatchDelete = false

    @State private var showingBatchMerge = false
    @State private var showingPanelExtractor = false
    
    @State private var readingPDF: ConvertedPDF?
    @State private var showingPageManager = false
    @State private var pdfToManage: ConvertedPDF?
    
    
    var filteredPDFs: [ConvertedPDF] {
        conversionManager.filteredPDFs
    }
    
    var body: some View {
        NavigationView {
            ZStack {
                AppTheme.background.ignoresSafeArea()
                
                if conversionManager.convertedPDFs.isEmpty {
                    emptyStateLibrary
                } else {
                    mainContent
                }
            }
            .navigationTitle("Library")
            .searchable(text: $conversionManager.searchText, prompt: "Search comics...")
            .toolbar {
                toolbarContent
            }
            // Move sheets to a background element to reduce compiler complexity
            .background(sheetHandlers)
        }
        .navigationViewStyle(.stack)
    }
    
    // MARK: - Main Content
    
    var mainContent: some View {
        VStack(spacing: 0) {
            // Selection Bar
            if isSelectionMode {
                HStack {
                    Text("\(selectedPDFs.count) Selected")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Select All") {
                        selectedPDFs = Set(filteredPDFs.map { $0.id })
                    }
                }
                .padding()
                .background(AppTheme.surface)
            }
            
            if isGridView {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 220), spacing: 16)], spacing: 16) {
                        ForEach(filteredPDFs) { pdf in
                            gridItem(for: pdf)
                        }
                    }
                    .padding()
                }
                .refreshable {
                    await refreshLibrary()
                }
            } else {
                List {
                    ForEach(filteredPDFs) { pdf in
                        listItem(for: pdf)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .swipeActions(edge: .leading) {
                                Button {
                                    conversionManager.toggleFavorite(pdf)
                                } label: {
                                    Label("Favorite", systemImage: pdf.isFavorite ? "star.fill" : "star")
                                }
                                .tint(.yellow)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    selectedPDF = pdf
                                    showingDeleteAlert = true
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                
                                Button {
                                    selectedPDF = pdf
                                    showingShareSheet = true
                                } label: {
                                    Label("Share", systemImage: "square.and.arrow.up")
                                }
                                .tint(.blue)
                            }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .refreshable {
                    await refreshLibrary()
                }
            }
            
            // Bottom Action Bar (Batch)
            if isSelectionMode && !selectedPDFs.isEmpty {
                HStack(spacing: 20) {
                    batchButton(icon: "paperplane.fill", label: "Kindle", color: .orange) { showingBatchMail = true }
                    batchButton(icon: "square.and.arrow.up", label: "Share", color: .blue) { showingBatchShare = true }
                    batchButton(icon: "doc.on.doc.fill", label: "Merge", color: .purple) { showingBatchMerge = true }
                    batchButton(icon: "trash.fill", label: "Delete", color: .red) { showingBatchDelete = true }
                }
                .padding()
                .background(AppTheme.surface)
                .shadow(radius: 5)
            }
        }
    }
    
    // MARK: - Sheet Handlers
    
    @ViewBuilder
    var sheetHandlers: some View {
        EmptyView()
            .sheet(item: $selectedPDF) { pdf in
                if showingShareSheet {
                    ShareSheet(items: [pdf.url])
                } else if showingDevicePicker {
                    KindleDevicePickerView(pdfURLs: [pdf.url])
                        .environmentObject(conversionManager)
                }
            }
            .sheet(isPresented: $showingBatchMail) {
                if getSelectedPDFs().first != nil {
                    let urls = getSelectedPDFs().map { $0.url }
                    KindleDevicePickerView(pdfURLs: urls)
                        .environmentObject(conversionManager)
                }
            }
            .sheet(isPresented: $showingBatchShare) {
                let urls = getSelectedPDFs().map { $0.url }
                ShareSheet(items: urls)
            }
            .confirmationDialog("Options", isPresented: $showingActionSheet, presenting: selectedPDF) { pdf in
                Button("Send to Kindle") { showingDevicePicker = true }
                Button("Share") { showingShareSheet = true }
                Button("Delete", role: .destructive) { showingDeleteAlert = true }
                Button("Cancel", role: .cancel) { }
            }
            .alert("Delete Comic?", isPresented: $showingDeleteAlert, presenting: selectedPDF) { pdf in
                Button("Delete", role: .destructive) {
                    conversionManager.removeFromLibrary(pdf)
                }
                Button("Cancel", role: .cancel) { }
            }
            .sheet(isPresented: $showingBatchMerge) {
                 let items = getSelectedPDFs()
                 let ids = Set(items.map { $0.id })
                 FileMergeView(preselectedPDFs: ids)
                     .environmentObject(conversionManager)
            }
            .sheet(isPresented: $showingPanelExtractor) {
                if let pdf = selectedPDF {
                    PanelExtractionHost(pdf: pdf)
                }
            }
            .fullScreenCover(item: $readingPDF) { pdf in
                ReaderView(fileURL: pdf.url)
                    .environmentObject(conversionManager)
            }
            .alert("Delete \(selectedPDFs.count) Items?", isPresented: $showingBatchDelete) {
                Button("Delete", role: .destructive) {
                    let items = getSelectedPDFs()
                    items.forEach { conversionManager.removeFromLibrary($0) }
                    selectedPDFs.removeAll()
                    isSelectionMode = false
                }
                Button("Cancel", role: .cancel) { }
            }
            .sheet(item: $pdfToManage) { pdf in
                PageManagerView(pdf: pdf)
                    .environmentObject(conversionManager)
            }
    }
    
    // MARK: - Views
    
    func gridItem(for pdf: ConvertedPDF) -> some View {
        LibraryGridItem(pdf: pdf)
            .overlay(
                ZStack {
                    if isSelectionMode {
                        Color.black.opacity(0.1)
                        VStack {
                            HStack {
                                Spacer()
                                Image(systemName: selectedPDFs.contains(pdf.id) ? "checkmark.circle.fill" : "circle")
                                    .font(.title)
                                    .foregroundColor(selectedPDFs.contains(pdf.id) ? .blue : .white)
                                    .background(Circle().fill(Color.white.opacity(0.8)))
                            }
                            Spacer()
                        }
                        .padding(8)
                    }
                }
            )
            .contentShape(Rectangle())
            .onTapGesture {
                if isSelectionMode {
                    toggleSelection(pdf)
                } else {
                    readingPDF = pdf
                }
            }
            .contextMenu {
                menuItems(for: pdf)
            }
    }
    
    func listItem(for pdf: ConvertedPDF) -> some View {
        HStack {
            LibraryPDFRowWithCover(pdf: pdf, isSelected: selectedPDFs.contains(pdf.id))
            if isSelectionMode {
                Image(systemName: selectedPDFs.contains(pdf.id) ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(.blue)
            }
        }
        .padding()
        .background(AppTheme.surface)
        .cornerRadius(12)
        .onTapGesture {
            if isSelectionMode {
                toggleSelection(pdf)
            } else {
                readingPDF = pdf
            }
        }
        .contextMenu {
            menuItems(for: pdf)
        }
    }
    
    func batchButton(icon: String, label: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack {
                Image(systemName: icon).font(.title2)
                Text(label).font(.caption)
            }
            .frame(maxWidth: .infinity)
            .foregroundColor(color)
        }
    }
    
    // MARK: - Helpers
    
    @ViewBuilder
    var emptyStateLibrary: some View {
        VStack(spacing: 20) {
            Image(systemName: "books.vertical.fill")
                .font(.system(size: 80))
                .foregroundColor(.orange.opacity(0.3))
            
            Text("No Books Yet")
                .font(.title2)
                .fontWeight(.bold)
            
            Text("Start by converting your first comic or manga file")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            
            Button(action: { selectedTab = 0 }) {
                Label("Convert Files", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(PrimaryButtonStyle())
            .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    @ToolbarContentBuilder
    var toolbarContent: some ToolbarContent {
        // Grid toggle button
        ToolbarItem(placement: .navigationBarTrailing) {
            Button(action: { isGridView.toggle() }) {
                Image(systemName: isGridView ? "square.grid.2x2" : "list.bullet")
            }
        }

        // Column picker (only when grid view)
        if isGridView {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Picker("Columns", selection: $gridColumns) {
                        Text("2 Columns").tag(2)
                        Text("3 Columns").tag(3)
                        Text("4 Columns").tag(4)
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
            }
        }

        // Select button - ALWAYS VISIBLE
        ToolbarItem(placement: .principal) {
            Button(action: {
                isSelectionMode.toggle()
                if !isSelectionMode { selectedPDFs.removeAll() }
            }) {
                Text(isSelectionMode ? "Done" : "Select")
                    .fontWeight(.bold)
            }
        }
    }
    
    func menuItems(for pdf: ConvertedPDF) -> some View {
        Group {
            Button {
                selectedPDF = pdf
                showingDevicePicker = true
            } label: { Label("Send to Kindle", systemImage: "paperplane") }
            
            Button {
                selectedPDF = pdf
                showingShareSheet = true
            } label: { Label("Share", systemImage: "square.and.arrow.up") }
            
            Button(role: .destructive) {
                selectedPDF = pdf
                showingDeleteAlert = true
            } label: { Label("Delete", systemImage: "trash") }
            
            Button {
                selectedPDF = pdf
                showingPanelExtractor = true
            } label: { Label("Extract Panels", systemImage: "crop") }
            
            // Updated condition to include EPUB
            if ["pdf", "epub"].contains(pdf.url.pathExtension.lowercased()) {
                Button {
                    pdfToManage = pdf
                    showingPageManager = true
                } label: { Label("Manage Pages", systemImage: "doc.on.doc") }
            }
        }
    }
    
    func toggleSelection(_ pdf: ConvertedPDF) {
        if selectedPDFs.contains(pdf.id) {
            selectedPDFs.remove(pdf.id)
        } else {
            selectedPDFs.insert(pdf.id)
        }
    }
    
    func getSelectedPDFs() -> [ConvertedPDF] {
        conversionManager.convertedPDFs.filter { selectedPDFs.contains($0.id) }
    }
}
