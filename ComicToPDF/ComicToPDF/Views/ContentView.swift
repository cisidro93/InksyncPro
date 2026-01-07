import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(\.horizontalSizeClass) var sizeClass
    @StateObject private var conversionManager = ConversionManager()
    @State private var selectedTab = 0
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    
    // Selection state for iPad Sidebar
    @State private var selectedPDF: ConvertedPDF?
    
    // Global Sheets
    @State private var pdfToShare: ConvertedPDF?
    @State private var pdfToEdit: ConvertedPDF?
    
    var body: some View {
        Group {
            if sizeClass == .compact {
                // MARK: - iPhone Layout (Tab Bar)
                iPhoneLayout
            } else {
                // MARK: - iPad Layout (Split View)
                iPadLayout
            }
        }
        .environmentObject(conversionManager)
        // Global Sheets for Detail Actions
        .sheet(item: $pdfToShare) { pdf in ShareSheet(activityItems: [pdf.url]) }
        .sheet(item: $pdfToEdit) { pdf in PageManagerView(pdf: pdf) }
    }
    
    // MARK: - iPhone Layout
    var iPhoneLayout: some View {
        TabView(selection: $selectedTab) {
            LibraryView(selectedTab: $selectedTab)
                .tabItem {
                    Image(systemName: "books.vertical")
                    Text("Library")
                }
                .tag(0)
            
            CollectionsView()
                .tabItem {
                    Image(systemName: "folder")
                    Text("Collections")
                }
                .tag(1)
            
            SettingsView()
                .tabItem {
                    Image(systemName: "gear")
                    Text("Settings")
                }
                .tag(2)
        }
    }
    
    // MARK: - iPad Layout (Split View)
    var iPadLayout: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // COLUMN 1: Sidebar
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
            // COLUMN 2: Detail View
            NavigationStack {
                if let pdf = selectedPDF {
                    ConvertView(pdf: pdf)
                        .toolbar {
                            // Close Button
                            ToolbarItem(placement: .topBarLeading) {
                                Button(action: { selectedPDF = nil }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.secondary)
                                        .font(.title3)
                                }
                            }
                            // Menu Button
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
                                    Image(systemName: "ellipsis.circle")
                                        .font(.title3)
                                }
                            }
                        }
                        .id(pdf.id)
                } else {
                    // Empty State
                    VStack(spacing: 20) {
                        Image(systemName: "book.closed")
                            .font(.system(size: 80))
                            .foregroundColor(.gray.opacity(0.3))
                        Text("Select a Comic")
                            .font(.title)
                            .foregroundColor(.secondary)
                        Text("Select a file from the sidebar or use the buttons below.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
    }
}

// MARK: - Robust Library Sidebar
struct LibrarySidebarList: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @Binding var selectedPDF: ConvertedPDF?
    @State private var searchText = ""
    
    enum SidebarSheet: Identifiable {
        case importer
        case wifi
        case cloud
        
        var id: Int { hashValue }
    }
    
    @State private var activeSheet: SidebarSheet?
    
    var filteredPDFs: [ConvertedPDF] {
        if searchText.isEmpty { return conversionManager.convertedPDFs.reversed() }
        return conversionManager.convertedPDFs.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }
    
    var body: some View {
        List(selection: $selectedPDF) {
            // 1. The Comic Files
            ForEach(filteredPDFs) { pdf in
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
            
            // ✅ 2. NEW: Permanent Actions Section
            Section(header: Text("Quick Actions")) {
                Button(action: { activeSheet = .importer }) {
                    Label("Import Comic", systemImage: "plus")
                        .foregroundColor(.blue)
                }
                Button(action: { activeSheet = .wifi }) {
                    Label("WiFi Transfer", systemImage: "antenna.radiowaves.left.and.right")
                        .foregroundColor(.blue)
                }
                Button(action: { activeSheet = .cloud }) {
                    Label("Cloud Import", systemImage: "icloud.and.arrow.down")
                        .foregroundColor(.blue)
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $searchText)
        // Drag & Drop
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
            loadFiles(from: providers)
            return true
        }
        // Toolbar (Backup)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(action: { activeSheet = .importer }) { Label("Import File", systemImage: "plus") }
                    Button(action: { activeSheet = .wifi }) { Label("WiFi Transfer", systemImage: "antenna.radiowaves.left.and.right") }
                    Button(action: { activeSheet = .cloud }) { Label("Cloud Import", systemImage: "icloud.and.arrow.down") }
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.title3)
                }
            }
        }
        .sheet(item: $activeSheet) { item in
            switch item {
            case .importer:
                DocumentPicker(onDocumentsPicked: { urls in
                    Task { await conversionManager.processImportedFiles(urls: urls) }
                    activeSheet = nil
                })
            case .wifi:
                WiFiView()
            case .cloud:
                CloudBrowserView()
            }
        }
    }
    
    private func loadFiles(from providers: [NSItemProvider]) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { (data, error) in
                    if let urlData = data as? Data,
                       let url = URL(dataRepresentation: urlData, relativeTo: nil) {
                        Task { await conversionManager.processImportedFiles(urls: [url]) }
                    } else if let url = data as? URL {
                        Task { await conversionManager.processImportedFiles(urls: [url]) }
                    }
                }
            }
        }
    }
}
