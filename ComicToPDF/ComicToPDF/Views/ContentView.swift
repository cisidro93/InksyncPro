import SwiftUI

struct ContentView: View {
    @Environment(\.horizontalSizeClass) var sizeClass
    @StateObject private var conversionManager = ConversionManager()
    @State private var selectedTab = 0
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    
    // Selection state for iPad Sidebar
    @State private var selectedPDF: ConvertedPDF?
    
    // Feature Sheets
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
        // Global Sheets for iPad Actions
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
    
    // MARK: - iPad Layout (Sidebar + Detail)
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
                        // ✅ FIX: Custom Toolbar for iPad Detail
                        .toolbar {
                            // 1. Close Button (Unselect)
                            ToolbarItem(placement: .topBarLeading) {
                                Button(action: { selectedPDF = nil }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.secondary)
                                        .font(.title3)
                                }
                            }
                            
                            // 2. Menu Button (Replaces the 3 dots)
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
                        .id(pdf.id) // Force refresh when selection changes
                } else {
                    // Empty State
                    VStack(spacing: 20) {
                        Image(systemName: "book.closed")
                            .font(.system(size: 80))
                            .foregroundColor(.gray.opacity(0.3))
                        Text("Select a Comic")
                            .font(.title)
                            .foregroundColor(.secondary)
                        Text("Select a file from the sidebar to convert or edit.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
    }
}

// MARK: - Helper: iPad-Specific Library List
struct LibrarySidebarList: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @Binding var selectedPDF: ConvertedPDF?
    @State private var searchText = ""
    
    // Sheet States
    @State private var showingImporter = false
    @State private var showingWiFi = false
    @State private var showingCloud = false
    
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
                // Also keep context menu for power users
                .contextMenu {
                    Button(role: .destructive) { conversionManager.deletePDF(pdf) } label: { Label("Delete", systemImage: "trash") }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $searchText)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: { showingWiFi = true }) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .help("WiFi Transfer")
                }
                Button(action: { showingCloud = true }) {
                    Image(systemName: "icloud.and.arrow.down")
                        .help("Cloud Import")
                }
                Button(action: { showingImporter = true }) {
                    Image(systemName: "plus")
                        .help("Import File")
                }
            }
        }
        .sheet(isPresented: $showingImporter) {
            DocumentPicker(onDocumentsPicked: { urls in
                Task { await conversionManager.processImportedFiles(urls: urls) }
            })
        }
        .sheet(isPresented: $showingWiFi) { WiFiView() }
        .sheet(isPresented: $showingCloud) { CloudImportView() }
    }
}
