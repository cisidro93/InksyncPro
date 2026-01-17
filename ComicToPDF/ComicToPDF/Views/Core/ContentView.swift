import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(\.horizontalSizeClass) var sizeClass
    @StateObject private var conversionManager = ConversionManager()
    @State private var selectedTab = 0
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var selectedPDF: ConvertedPDF?
    
    // Global Sheets
    @State private var pdfToShare: ConvertedPDF?
    @State private var pdfToEdit: ConvertedPDF?
    
    var body: some View {
        Group {
            if sizeClass == .compact {
                iPhoneLayout
            } else {
                iPadLayout
            }
        }
        .environmentObject(conversionManager)
        .sheet(item: $pdfToShare) { pdf in ShareSheet(activityItems: [pdf.url]) }
        .sheet(item: $pdfToEdit) { pdf in 
            PageManagerView(pdf: pdf)
                .environmentObject(conversionManager)
        }
    }
    
    var iPhoneLayout: some View {
        TabView(selection: $selectedTab) {
            LibraryView(selectedTab: $selectedTab)
                .tabItem { Label("Library", systemImage: "books.vertical") }.tag(0)
            CollectionsView()
                .tabItem { Label("Collections", systemImage: "folder") }.tag(1)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gear") }.tag(2)
        }
    }
    
    var iPadLayout: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            VStack(spacing: 0) {
                Picker("Section", selection: $selectedTab) {
                    Text("Library").tag(0)
                    Text("Collections").tag(1)
                    Text("Settings").tag(2)
                }
                .pickerStyle(.segmented)
                .padding()
                
                if selectedTab == 0 {
                    LibrarySidebarList(selectedPDF: $selectedPDF)
                } else if selectedTab == 1 {
                    CollectionsView()
                } else {
                    SettingsView()
                }
            }
            .navigationTitle("ComicToPDF")
            .navigationBarTitleDisplayMode(.inline)
            
        } detail: {
            NavigationStack {
                if let pdf = selectedPDF {
                    ConvertView(pdf: pdf)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button(action: { selectedPDF = nil }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.secondary)
                                        .font(.title3)
                                }
                            }
                            ToolbarItem(placement: .topBarTrailing) {
                                Menu {
                                    Button { pdfToShare = pdf } label: { Label("Export / Share", systemImage: "square.and.arrow.up") }
                                    Button { pdfToEdit = pdf } label: { Label("Edit Pages", systemImage: "doc.on.doc") }
                                    Divider()
                                    Button(role: .destructive) {
                                        conversionManager.deletePDF(pdf)
                                        selectedPDF = nil
                                    } label: { Label("Delete", systemImage: "trash") }
                                } label: {
                                    Image(systemName: "ellipsis.circle").font(.title3)
                                }
                            }
                        }
                        .id(pdf.id)
                } else {
                    VStack(spacing: 20) {
                        Image(systemName: "book.closed").font(.system(size: 80)).foregroundColor(.gray.opacity(0.3))
                        Text("Select a Comic").font(.title).foregroundColor(.secondary)
                        Text("Select a file from the sidebar or use the buttons below.").font(.caption).foregroundColor(.secondary)
                    }
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
    }
}

struct LibrarySidebarList: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @Binding var selectedPDF: ConvertedPDF?
    @State private var searchText = ""
    
    // Batch Mode State
    @State private var isBatchMode = false
    @State private var multiSelection = Set<UUID>()
    
    enum SidebarSheet: Identifiable {
        case importer, wifi, cloud, merge
        var id: Int { hashValue }
    }
    
    @State private var activeSheet: SidebarSheet?
    @State private var sortOption: LibraryView.SortOption = .dateAdded
    
    // New Sheet State for Merge Reorder
    @State private var showingBatchMergeReorder = false
    @State private var batchMergeItems: [ConvertedPDF] = []
    
    var filteredPDFs: [ConvertedPDF] {
        let pdfs = conversionManager.convertedPDFs
        let result: [ConvertedPDF]
        
        if searchText.isEmpty {
            result = pdfs
        } else {
            result = pdfs.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }
        
        return sortPDFs(result)
    }
    
    func sortPDFs(_ pdfs: [ConvertedPDF]) -> [ConvertedPDF] {
        switch sortOption {
        case .dateAdded: return pdfs.reversed()
        case .name: return pdfs.sorted { $0.name < $1.name }
        case .size: return pdfs.sorted { $0.fileSize > $1.fileSize }
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // ✅ Sort Selector
            Picker("Sort By", selection: $sortOption) {
                Text("Date").tag(LibraryView.SortOption.dateAdded)
                Text("Name").tag(LibraryView.SortOption.name)
                Text("Size").tag(LibraryView.SortOption.size)
            }
            .pickerStyle(SegmentedPickerStyle())
            .padding([.horizontal, .bottom])
            .background(Color(UIColor.systemBackground))
            
            // ✅ Batch Action Bar
            if isBatchMode {
                HStack {
                    Button("Cancel") {
                        isBatchMode = false
                        multiSelection.removeAll()
                    }
                    Spacer()
                    Text("\(multiSelection.count) Selected")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Convert") {
                        let items = conversionManager.convertedPDFs.filter { multiSelection.contains($0.id) }
                        Task { await conversionManager.convertQueue(items) }
                        isBatchMode = false
                        multiSelection.removeAll()
                    }
                    .disabled(multiSelection.isEmpty)
                    .bold()
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
                .background(Color(UIColor.systemBackground))
            }
            // ✅ Second Action Bar for Merge
            if isBatchMode {
                 HStack {
                     Spacer()
                     Button {
                        batchMergeItems = conversionManager.convertedPDFs.filter { multiSelection.contains($0.id) }
                        showingBatchMergeReorder = true
                     } label: {
                         Label("Convert & Merge", systemImage: "doc.on.doc.fill")
                     }
                     .buttonStyle(.bordered)
                     .disabled(multiSelection.count < 2)
                     Spacer()
                 }
                 .padding(.bottom)
            }
            
            List(selection: $selectedPDF) {
                ForEach(filteredPDFs) { pdf in
                    // In Batch Mode, we use a Button to toggle selection.
                    // In Normal Mode, we use NavigationLink for SplitView selection.
                    if isBatchMode {
                        Button {
                            if multiSelection.contains(pdf.id) {
                                multiSelection.remove(pdf.id)
                            } else {
                                multiSelection.insert(pdf.id)
                            }
                        } label: {
                            HStack {
                                LibraryPDFRowWithCover(pdf: pdf, isSelected: false)
                                Spacer()
                                Image(systemName: multiSelection.contains(pdf.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(multiSelection.contains(pdf.id) ? .blue : .gray)
                                    .font(.title2)
                            }
                        }
                        .tint(.primary) // Keep text black
                    } else {
                        NavigationLink(value: pdf) {
                            LibraryPDFRowWithCover(pdf: pdf, isSelected: selectedPDF?.id == pdf.id)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { conversionManager.deletePDF(pdf) } label: { Label("Delete", systemImage: "trash") }
                        }
                        .contextMenu {
                            Button(role: .destructive) { conversionManager.deletePDF(pdf) } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                }
                
                if !isBatchMode {
                    Section(header: Text("Quick Actions")) {
                        Button(action: { activeSheet = .importer }) { Label("Import Comic", systemImage: "plus").foregroundColor(.blue) }
                        Button(action: { activeSheet = .wifi }) { Label("WiFi Transfer", systemImage: "antenna.radiowaves.left.and.right").foregroundColor(.blue) }
                        Button(action: { activeSheet = .cloud }) { Label("Cloud Import", systemImage: "icloud.and.arrow.down").foregroundColor(.blue) }
                        Button(action: { activeSheet = .merge }) { Label("Merge Files", systemImage: "arrow.triangle.merge").foregroundColor(.blue) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $searchText)
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
            loadFiles(from: providers)
            return true
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack {
                    Button(isBatchMode ? "Done" : "Select") {
                        withAnimation {
                            isBatchMode.toggle()
                            if !isBatchMode { multiSelection.removeAll() }
                        }
                    }
                    
                    if !isBatchMode {
                        Menu {
                            Button(action: { activeSheet = .importer }) { Label("Import File", systemImage: "plus") }
                            Button(action: { activeSheet = .wifi }) { Label("WiFi Transfer", systemImage: "antenna.radiowaves.left.and.right") }
                            Button(action: { activeSheet = .merge }) { Label("Merge Files", systemImage: "arrow.triangle.merge") }
                        } label: { Image(systemName: "plus.circle").font(.title3) }
                    }
                }
            }
        }
        .sheet(item: $activeSheet) { item in
            switch item {
            case .importer, .cloud:
                // Both trigger the same system Document Picker, which handles Local + Cloud (iCloud, Drive, etc)
                DocumentPicker(onDocumentsPicked: { urls in Task { await conversionManager.processImportedFiles(urls: urls); activeSheet = nil } })
            case .wifi: WiFiView()
            case .merge: FileMergeView()
            }
        }
        .sheet(isPresented: $showingBatchMergeReorder) {
            BatchMergeReorderView(selectedFiles: batchMergeItems)
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
}
