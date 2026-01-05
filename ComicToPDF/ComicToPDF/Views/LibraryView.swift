import SwiftUI
import QuickLook
import UniformTypeIdentifiers

// ✅ DEFINE TYPES LOCALLY
extension UTType {
    static var cbz: UTType { UTType(filenameExtension: "cbz", conformingTo: .data) ?? .data }
    static var cbr: UTType { UTType(filenameExtension: "cbr", conformingTo: .data) ?? .data }
}

struct LibraryView: View {
    @Binding var selectedTab: Int
    @EnvironmentObject var conversionManager: ConversionManager
    
    // View State
    @State private var isGridView = true
    @State private var isSelectionMode = false
    @State private var searchText = ""
    @State private var selectedPDFs = Set<UUID>()
    @AppStorage("gridColumns") private var gridColumns: Int = 3
    
    // Actions
    @State private var selectedPDF: ConvertedPDF?
    @State private var showingMergeSheet = false
    @State private var showingWiFiTransfer = false
    @State private var showingMetadataSearch = false
    @State private var showingPanelExtractor = false
    
    // ✅ LOCAL IMPORT STATE
    @State private var showingCloudImport = false
    @State private var importError: String? = nil
    @State private var showingImportError = false
    
    // Reading
    @State private var showingPageManager = false
    @State private var pdfToManage: ConvertedPDF?
    @State private var readingPDF: ConvertedPDF?
    
    var filteredPDFs: [ConvertedPDF] {
        conversionManager.filteredPDFs
    }
    
    // TASK MONITOR
    var taskMonitorOverlay: some View {
        Group {
            if !conversionManager.activeTasks.isEmpty {
                VStack(spacing: 8) {
                    ForEach(conversionManager.activeTasks) { task in
                        HStack {
                            ProgressView().scaleEffect(0.8)
                            Text(task.description).font(.caption).fontWeight(.medium)
                            Spacer()
                        }
                        .padding(12)
                        .background(.thinMaterial)
                        .cornerRadius(10)
                        .shadow(radius: 2)
                    }
                }
                .padding()
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }
    
    // EMPTY STATE
    var emptyStateView: some View {
        VStack(spacing: 25) {
            Image(systemName: "books.vertical.fill")
                .font(.system(size: 80))
                .foregroundColor(.gray.opacity(0.5))
            
            Text("Your Library is Empty")
                .font(.title2).bold()
            
            Button(action: { showingCloudImport = true }) {
                Text("Tap here to Import Comic")
                    .padding()
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(10)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var body: some View {
        NavigationView {
            VStack {
                // FILTER BAR
                LibraryInteractiveSearchBar(
                    isGridView: $isGridView,
                    isSelectionMode: $isSelectionMode,
                    searchText: $searchText,
                    gridColumns: $gridColumns,
                    sortMethod: $conversionManager.organizationMethod,
                    onSelectAll: {
                        if selectedPDFs.count == filteredPDFs.count { selectedPDFs.removeAll() }
                        else { selectedPDFs = Set(filteredPDFs.map { $0.id }) }
                    }
                )
                
                // MAIN CONTENT
                ScrollView {
                    libraryContent.padding()
                }
                
                // Bottom Toolbar (Counts)
                if !conversionManager.convertedPDFs.isEmpty {
                    Text("\(conversionManager.convertedPDFs.count) items")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.bottom, 5)
                }
            }
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Target Format Selector
                ToolbarItem(placement: .navigationBarLeading) {
                    Menu {
                        Picker("Output Format", selection: $conversionManager.conversionSettings.outputFormat) {
                            ForEach(OutputFormat.allCases) { format in
                                Label(format.rawValue, systemImage: format.icon).tag(format)
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text("Target:")
                                .font(.caption).foregroundColor(.secondary)
                            Text(conversionManager.conversionSettings.outputFormat.rawValue)
                                .font(.caption).bold()
                                .padding(4)
                                .background(Color.orange.opacity(0.1))
                                .cornerRadius(4)
                        }
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack {
                         Button { showingCloudImport = true } label: { Image(systemName: "icloud.and.arrow.down") }
                         Button { showingWiFiTransfer = true } label: { Image(systemName: "wifi") }
                         Button { showingMergeSheet = true } label: { Image(systemName: "doc.on.doc") }
                    }
                }
            }
            // ✅ STABLE ANCHOR: All sheets attached to NavigationView, NOT ScrollView
            .sheet(isPresented: $showingMergeSheet) {
                FileMergeView(filesToMerge: Array(filteredPDFs.filter { selectedPDFs.contains($0.id) }))
            }
            .sheet(isPresented: $showingWiFiTransfer) { WiFiView() }
            .sheet(isPresented: $showingPageManager) {
                if let pdf = pdfToManage { PageManagerView(pdf: pdf) }
            }
            .fullScreenCover(item: $readingPDF) { pdf in
                ReaderView(fileURL: pdf.url)
            }
            .sheet(isPresented: $showingMetadataSearch) {
                if let pdf = selectedPDF { MetadataSearchSheet(pdf: pdf) }
            }
            .sheet(isPresented: $showingPanelExtractor) {
                if let pdf = selectedPDF {
                    VStack(spacing: 20) {
                        Text("Panel Extraction").font(.headline)
                        Button("Start Editor") {
                            showingPanelExtractor = false
                            Task {
                                let settings = conversionManager.conversionSettings.epubSettings
                                _ = try? await conversionManager.performPanelReview(sourceEPUB: pdf.url, settings: settings)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }.padding().presentationDetents([.medium])
                }
            }
            // ✅ THE FIX: Attached to the most stable view
            .fileImporter(
                isPresented: $showingCloudImport,
                allowedContentTypes: [.cbz, .cbr, .zip, .pdf, .epub, .data, .item],
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    // Pass to Manager to handle logic
                    conversionManager.processImportedFiles(urls: urls)
                case .failure(let error):
                    importError = error.localizedDescription
                    showingImportError = true
                }
            }
            .alert("Import Error", isPresented: $showingImportError) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(importError ?? "Unknown error")
            }
            .overlay(alignment: .top) { taskMonitorOverlay }
            .onChange(of: conversionManager.organizationMethod) {
                conversionManager.sortPDFs()
            }
        }
    }

    @ViewBuilder
    var libraryContent: some View {
        if filteredPDFs.isEmpty {
            emptyStateView
        } else {
            if isGridView {
                libraryGridView
            } else {
                libraryListView
            }
        }
    }
    
    // Grid View
    var libraryGridView: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 15), count: gridColumns), spacing: 20) {
            ForEach(filteredPDFs) { pdf in
                LibraryGridCellView(
                    pdf: pdf,
                    isSelected: selectedPDFs.contains(pdf.id),
                    isSelectionMode: isSelectionMode,
                    onTap: {
                        if isSelectionMode {
                            if selectedPDFs.contains(pdf.id) { selectedPDFs.remove(pdf.id) } else { selectedPDFs.insert(pdf.id) }
                        } else {
                            selectedPDF = pdf
                            if pdf.url.pathExtension.lowercased() == "epub" || pdf.url.pathExtension.lowercased() == "pdf" {
                                readingPDF = pdf
                            }
                        }
                    },
                    menuItems: { menuItems(for: pdf) }
                )
            }
        }
    }
    
    // List View
    var libraryListView: some View {
        LazyVStack(spacing: 0) {
            ForEach(filteredPDFs) { pdf in
                LibraryPDFRowWithCover(pdf: pdf, isSelected: selectedPDFs.contains(pdf.id))
                    .padding(.horizontal).padding(.vertical, 4)
                    .background(selectedPDFs.contains(pdf.id) ? Color.blue.opacity(0.1) : Color.clear)
                    .onTapGesture {
                        if isSelectionMode {
                            if selectedPDFs.contains(pdf.id) { selectedPDFs.remove(pdf.id) } else { selectedPDFs.insert(pdf.id) }
                        } else {
                            selectedPDF = pdf
                            if pdf.url.pathExtension.lowercased() == "epub" || pdf.url.pathExtension.lowercased() == "pdf" {
                                readingPDF = pdf
                            }
                        }
                    }
                    .contextMenu { menuItems(for: pdf) }
                Divider().padding(.leading)
            }
        }
    }
    
    func menuItems(for pdf: ConvertedPDF) -> some View {
        Group {
            Button { selectedPDF = pdf } label: { Label("Read", systemImage: "book") }
            Button { selectedPDF = pdf; showingWiFiTransfer = true } label: { Label("Share via Wi-Fi", systemImage: "wifi") }
            Button { selectedPDF = pdf; showingMetadataSearch = true } label: { Label("Fetch Metadata", systemImage: "magnifyingglass") }
            Button { selectedPDF = pdf; showingPanelExtractor = true } label: { Label("Extract Panels", systemImage: "crop") }
            Divider()
            Button(role: .destructive) { conversionManager.deletePDF(pdf) } label: { Label("Delete", systemImage: "trash") }
        }
    }
}

// SEARCH BAR STRUCT
struct LibraryInteractiveSearchBar: View {
    @Binding var isGridView: Bool
    @Binding var isSelectionMode: Bool
    @Binding var searchText: String
    @Binding var gridColumns: Int
    @Binding var sortMethod: OrganizationMethod
    var onSelectAll: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundColor(.gray)
                TextField("Search library...", text: $searchText)
            }
            .padding(8)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(10)
            
            Button(action: { isGridView.toggle() }) {
                Image(systemName: isGridView ? "list.bullet" : "square.grid.2x2")
                    .foregroundColor(.blue).font(.title2)
            }
            
            Menu {
                Picker("Sort By", selection: $sortMethod) {
                    ForEach(OrganizationMethod.allCases) { method in
                        Text(method.rawValue).tag(method)
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down").foregroundColor(.blue).font(.title2)
            }
            
            if isGridView {
                Menu {
                    Picker("Columns", selection: $gridColumns) {
                        Text("2 Columns").tag(2)
                        Text("3 Columns").tag(3)
                        Text("4 Columns").tag(4)
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3").foregroundColor(.blue).font(.title2)
                }
            }
            
            Button(action: { isSelectionMode.toggle() }) {
                Text(isSelectionMode ? "Done" : "Select").fontWeight(.bold)
            }
            
            if isSelectionMode {
                Button("All", action: onSelectAll)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

// GRID CELL STRUCT
struct LibraryGridCellView<MenuContent: View>: View {
    let pdf: ConvertedPDF
    let isSelected: Bool
    let isSelectionMode: Bool
    let onTap: () -> Void
    @ViewBuilder let menuItems: () -> MenuContent
    
    var body: some View {
        ZStack(alignment: .topTrailing) {
            LibraryGridItem(pdf: pdf)
            Text(pdf.typeLabel)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(pdf.typeColor)
                .cornerRadius(4)
                .padding(6)
                .shadow(radius: 2)
        }
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.blue, lineWidth: isSelected ? 3 : 0))
        .onTapGesture { onTap() }
        .contextMenu { menuItems() }
    }
}

// EXTENSION
extension ConvertedPDF {
    var typeColor: Color {
        switch url.pathExtension.lowercased() {
        case "pdf": return .red
        case "epub": return .blue
        case "cbz", "cbr", "zip": return .orange
        default: return .gray
        }
    }
    
    var typeLabel: String {
        return url.pathExtension.uppercased()
    }
}
