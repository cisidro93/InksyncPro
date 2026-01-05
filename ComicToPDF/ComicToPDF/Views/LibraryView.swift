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
    
    // Actions
    @State private var selectedPDF: ConvertedPDF?
    @State private var showingActionSheet = false
    @State private var showingShareSheet = false
    @State private var showingDevicePicker = false
    @State private var showingDeleteAlert = false
    @State private var showingPanelExtractor = false
    
    // Page Management & Reading
    @State private var showingPageManager = false
    @State private var pdfToManage: ConvertedPDF?
    @State private var readingPDF: ConvertedPDF? // <--- Controls the Reader
    @State private var showingMergeSheet = false // Batch Merge Sheet
    
    var filteredPDFs: [ConvertedPDF] {
        conversionManager.filteredPDFs
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
                    onSelectAll: {
                        if selectedPDFs.count == filteredPDFs.count { selectedPDFs.removeAll() } 
                        else { selectedPDFs = Set(filteredPDFs.map { $0.id }) }
                    }
                )
                .padding(.horizontal)
                
                if conversionManager.isLoading {
                    ProgressView("Loading Library...").padding()
                    Spacer()
                } else if filteredPDFs.isEmpty {
                    VStack(spacing: 20) {
                        Image(systemName: "books.vertical").font(.system(size: 60)).foregroundColor(.gray)
                        Text("No Comics Found").font(.title2).bold()
                        Text("Tap 'Convert' to add files.").foregroundColor(.secondary)
                    }
                    .padding()
                    Spacer()
                } else {
                    ScrollView {
                        if isGridView {
                            // GRID VIEW
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 15), count: gridColumns), spacing: 20) {
                                ForEach(filteredPDFs) { pdf in
                                    LibraryGridItem(pdf: pdf, isSelected: selectedPDFs.contains(pdf.id))
                                        .onTapGesture {
                                            if isSelectionMode {
                                                toggleSelection(pdf)
                                            } else {
                                                // ✅ FIX: Use State to trigger Reader
                                                readingPDF = pdf
                                            }
                                        }
                                        .contextMenu { menuItems(for: pdf) } // Long Press Menu
                                }
                            }
                            .padding()
                        } else {
                            // LIST VIEW
                            LazyVStack {
                                ForEach(filteredPDFs) { pdf in
                                    LibraryPDFRowWithCover(pdf: pdf, isSelected: selectedPDFs.contains(pdf.id))
                                        .onTapGesture {
                                            if isSelectionMode {
                                                toggleSelection(pdf)
                                            } else {
                                                // ✅ FIX: Use State to trigger Reader
                                                readingPDF = pdf
                                            }
                                        }
                                        .contextMenu { menuItems(for: pdf) }
                                }
                            }
                            .padding()
                        }
                    }
                }
            }
            .navigationTitle("Library")
            .navigationBarHidden(true)
            
            // ✅ READER PRESENTER (Full Screen Modal)
            .fullScreenCover(item: $readingPDF) { pdf in
                ReaderView(fileURL: pdf.url)
            }
            
            // ✅ PAGE MANAGER PRESENTER
            .sheet(isPresented: $showingPageManager) {
                if let pdf = pdfToManage {
                    PageManagerView(pdf: pdf)
                }
            }
            // Other Sheets
            .sheet(isPresented: $showingShareSheet) {
                if let pdf = selectedPDF { ShareSheet(items: [pdf.url]) }
            }
            .sheet(isPresented: $showingDevicePicker) {
                if let pdf = selectedPDF { DevicePickerView(pdf: pdf) }
            }
            // Batch Merge Sheet
            .sheet(isPresented: $showingMergeSheet) {
                let files = getSelectedPDFs()
                if !files.isEmpty {
                    FileMergeView(filesToMerge: files)
                }
            }
            .alert("Delete Comic?", isPresented: $showingDeleteAlert) {
                Button("Delete", role: .destructive) {
                    if let pdf = selectedPDF {
                        conversionManager.removeFromLibrary(pdf)
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
        .overlay(alignment: .bottom) {
            if isSelectionMode && !selectedPDFs.isEmpty {
                Button(action: { showingMergeSheet = true }) {
                    HStack {
                        Image(systemName: "rectangle.stack.badge.plus")
                        Text("Merge \(selectedPDFs.count) Files")
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding()
                    .background(Color.orange)
                    .cornerRadius(12)
                    .shadow(radius: 4)
                }
                .padding(.bottom, 20)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onAppear {
            Task { await refreshLibrary() }
        }
    }
    
    func refreshLibrary() async {
        conversionManager.loadSavedData()
        for pdf in conversionManager.convertedPDFs where pdf.coverImageData == nil {
            conversionManager.generateCoverThumbnail(for: pdf)
        }
    }
    
    // MARK: - Context Menu Actions
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
            
            // ✅ Manage Pages Action
            if ["pdf", "epub"].contains(pdf.url.pathExtension.lowercased()) {
                Button {
                    pdfToManage = pdf
                    showingPageManager = true
                } label: { Label("Manage Pages", systemImage: "doc.on.doc") }
            }
            
            Button {
                selectedPDF = pdf
                showingPanelExtractor = true
            } label: { Label("Extract Panels", systemImage: "crop") }
            
            Button(role: .destructive) {
                selectedPDF = pdf
                showingDeleteAlert = true
            } label: { Label("Delete", systemImage: "trash") }
        }
    }
    
    // MARK: - Helpers
    func toggleSelection(_ pdf: ConvertedPDF) {
        if selectedPDFs.contains(pdf.id) {
            selectedPDFs.remove(pdf.id)
        } else {
            selectedPDFs.insert(pdf.id)
        }
    }
    
    func getSelectedPDFs() -> [ConvertedPDF] {
        return conversionManager.convertedPDFs.filter { selectedPDFs.contains($0.id) }
    }
}

// MARK: - Local Device Picker Adapter
struct DevicePickerView: View {
    let pdf: ConvertedPDF
    var body: some View {
        KindleDevicePickerView(pdfURLs: [pdf.url])
    }
}

// MARK: - Local Search Bar (To avoid modifying SearchFilterBar.swift)
struct LibraryInteractiveSearchBar: View {
    @Binding var isGridView: Bool
    @Binding var isSelectionMode: Bool
    @Binding var searchText: String
    @Binding var gridColumns: Int
    var onSelectAll: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            // Search Field
            HStack {
                Image(systemName: "magnifyingglass").foregroundColor(.gray)
                TextField("Search library...", text: $searchText)
            }
            .padding(8)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(10)
            
            // View Toggle
            Button(action: { isGridView.toggle() }) {
                Image(systemName: isGridView ? "list.bullet" : "square.grid.2x2")
                    .foregroundColor(.blue)
                    .font(.title2)
            }
            
            // Grid Columns (Only in Grid Mode)
            if isGridView {
                Menu {
                    Picker("Columns", selection: $gridColumns) {
                        Text("2 Columns").tag(2)
                        Text("3 Columns").tag(3)
                        Text("4 Columns").tag(4)
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundColor(.blue)
                        .font(.title2)
                }
            }
            
            // Selection Mode
            Button(action: { isSelectionMode.toggle() }) {
                Text(isSelectionMode ? "Done" : "Select")
                    .fontWeight(.bold)
            }
            
            // Select All (Only in Selection Mode)
            if isSelectionMode {
                Button("All", action: onSelectAll)
            }
        }
        .padding(.vertical, 8)
    }
}
