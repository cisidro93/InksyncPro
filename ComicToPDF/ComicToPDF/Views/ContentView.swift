import SwiftUI

struct ContentView: View {
    @Environment(\.horizontalSizeClass) var sizeClass
    @StateObject private var conversionManager = ConversionManager()
    @State private var selectedTab = 0
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    
    // Selection state for iPad Sidebar
    @State private var selectedPDF: ConvertedPDF?
    
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
        // Global Modifier to ensure sheets work everywhere
        .onAppear {
            // Any global setup
        }
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
                // Custom "Tab" Switcher for Sidebar
                Picker("Section", selection: $selectedTab) {
                    Text("Library").tag(0)
                    Text("Collections").tag(1)
                    Text("Settings").tag(2)
                }
                .pickerStyle(.segmented)
                .padding()
                
                // Content based on Picker
                if selectedTab == 0 {
                    LibrarySidebarList(selectedPDF: $selectedPDF)
                } else if selectedTab == 1 {
                    CollectionsView() // Reuse existing view
                } else {
                    SettingsView() // Reuse existing view
                }
            }
            .navigationTitle("ComicToPDF")
            .navigationBarTitleDisplayMode(.inline)
            
        } detail: {
            // COLUMN 2: Detail View
            if let pdf = selectedPDF {
                ConvertView(pdf: pdf)
            } else {
                // Empty State (The "Black Void" from your screenshot)
                VStack(spacing: 20) {
                    Image(systemName: "book.closed")
                        .font(.system(size: 80))
                        .foregroundColor(.gray.opacity(0.3))
                    Text("Select a Comic")
                        .font(.title)
                        .foregroundColor(.secondary)
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
    }
}

// MARK: - Helper: iPad-Specific Library List
// This strips out the navigation/toolbar from the main LibraryView 
// so it fits cleanly inside the sidebar.
struct LibrarySidebarList: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @Binding var selectedPDF: ConvertedPDF?
    @State private var searchText = ""
    @State private var showingImporter = false
    
    // Reuse the sheet states for iPad
    @State private var pdfToShare: ConvertedPDF?
    @State private var pdfToEdit: ConvertedPDF?
    
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
                    Button { pdfToShare = pdf } label: { Label("Export", systemImage: "square.and.arrow.up") }
                    Button { pdfToEdit = pdf } label: { Label("Edit Pages", systemImage: "doc.on.doc") }
                    Button(role: .destructive) { conversionManager.deletePDF(pdf) } label: { Label("Delete", systemImage: "trash") }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $searchText)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: { showingImporter = true }) {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingImporter) {
            DocumentPicker(onDocumentsPicked: { urls in
                Task { await conversionManager.processImportedFiles(urls: urls) }
            })
        }
        // iPad Feature Sheets
        .sheet(item: $pdfToShare) { pdf in ShareSheet(activityItems: [pdf.url]) }
        .sheet(item: $pdfToEdit) { pdf in PageManagerView(pdf: pdf) }
    }
}
