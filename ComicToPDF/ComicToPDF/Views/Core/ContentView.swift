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
    
    enum SidebarSheet: Identifiable {
        case importer, wifi, cloud, merge
        var id: Int { hashValue }
    }
    
    @State private var activeSheet: SidebarSheet?
    
    var filteredPDFs: [ConvertedPDF] {
        if searchText.isEmpty { return conversionManager.convertedPDFs.reversed() }
        return conversionManager.convertedPDFs.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }
    
    var body: some View {
        List(selection: $selectedPDF) {
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
            
            Section(header: Text("Quick Actions")) {
                Button(action: { activeSheet = .importer }) { Label("Import Comic", systemImage: "plus").foregroundColor(.blue) }
                Button(action: { activeSheet = .wifi }) { Label("WiFi Transfer", systemImage: "antenna.radiowaves.left.and.right").foregroundColor(.blue) }
                Button(action: { activeSheet = .cloud }) { Label("Cloud Import", systemImage: "icloud.and.arrow.down").foregroundColor(.blue) }
                Button(action: { activeSheet = .merge }) { Label("Merge Files", systemImage: "arrow.triangle.merge").foregroundColor(.blue) }
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
                Menu {
                    Button(action: { activeSheet = .importer }) { Label("Import File", systemImage: "plus") }
                    Button(action: { activeSheet = .wifi }) { Label("WiFi Transfer", systemImage: "antenna.radiowaves.left.and.right") }
                    Button(action: { activeSheet = .merge }) { Label("Merge Files", systemImage: "arrow.triangle.merge") }
                } label: { Image(systemName: "plus.circle").font(.title3) }
            }
        }
        .sheet(item: $activeSheet) { item in
            switch item {
            case .importer:
                DocumentPicker(onDocumentsPicked: { urls in Task { await conversionManager.processImportedFiles(urls: urls); activeSheet = nil } })
            case .wifi: WiFiView()
            case .cloud: CloudBrowserView()
            case .merge: FileMergeView()
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
}

// Placeholder for Cloud Browser (Keep this to avoid build errors if CloudViews.swift is missing)
struct CloudBrowserView: View {
    var body: some View {
        VStack {
            Image(systemName: "icloud.slash").font(.largeTitle).padding()
            Text("Cloud Feature Pending").font(.headline)
            Text("Please ensure CloudViews.swift is added to your target.").font(.caption).foregroundColor(.secondary)
        }
    }
}
