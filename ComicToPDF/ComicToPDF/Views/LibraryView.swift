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
    @State private var showingWiFiTransfer = false // Wi-Fi Transfer Sheet
    @State private var showingCloudImport = false // Cloud Import Sheet
    @State private var showingMetadataSearch = false // Metadata Search Sheet
    
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
                    sortMethod: $conversionManager.organizationMethod,
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
                    emptyStateView
                } else {
                    libraryContentView
                }
            }
            .navigationTitle("Library")
            .navigationBarHidden(false) // Changed to false to show toolbar
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack {
                        // Cloud Import Button
                        Button { showingCloudImport = true } label: { 
                            Image(systemName: "icloud.and.arrow.down") 
                        }
                        
                        // Wi-Fi Button
                        Button { showingWiFiTransfer = true } label: { 
                            Image(systemName: "wifi") 
                        }
                    }
                }
            }
            
            // ✅ FILES MODALS
            .fullScreenCover(item: $readingPDF) { pdf in ReaderView(fileURL: pdf.url) }
            .sheet(isPresented: $showingPageManager) { if let pdf = pdfToManage { PageManagerView(pdf: pdf) } }
            .sheet(isPresented: $showingShareSheet) { if let pdf = selectedPDF { ShareSheet(items: [pdf.url]) } }
            .sheet(isPresented: $showingDevicePicker) { if let pdf = selectedPDF { DevicePickerView(pdf: pdf) } }
            .sheet(isPresented: $showingMergeSheet) {
                 // ✅ FIX: Removed 'if let' since getSelectedPDFs() returns [ConvertedPDF]
                 let files = getSelectedPDFs()
                 if !files.isEmpty { FileMergeView(filesToMerge: files) }
            }
            .alert("Delete Comic?", isPresented: $showingDeleteAlert) {
                Button("Delete", role: .destructive) { if let pdf = selectedPDF { conversionManager.removeFromLibrary(pdf) } }
                Button("Cancel", role: .cancel) {}
            }
            .sheet(isPresented: $showingWiFiTransfer) {
                WiFiView()
            }
            .fileImporter(
                isPresented: $showingCloudImport,
                allowedContentTypes: [.pdf, .epub, .zip, .init(filenameExtension: "cbz")!, .init(filenameExtension: "cbr")!],
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    Task {
                        for url in urls {
                            guard url.startAccessingSecurityScopedResource() else { continue }
                            defer { url.stopAccessingSecurityScopedResource() }
                            
                            // 1. Copy File
                            let fileName = url.lastPathComponent
                            let destURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(fileName)
                            try? FileManager.default.removeItem(at: destURL)
                            try? FileManager.default.copyItem(at: url, to: destURL)
                            
                            // 2. Auto-Convert if needed
                            let ext = destURL.pathExtension.lowercased()
                            if ["cbz", "cbr", "zip"].contains(ext) {
                                // Add to task queue
                                let taskID = UUID()
                                let taskDesc = "Converting \(fileName)..."
                                await MainActor.run {
                                    conversionManager.activeTasks.append(BackgroundTask(description: taskDesc))
                                }
                                
                                // Convert
                                try? await conversionManager.convertToFormat(
                                    conversionManager.conversionSettings.outputFormat, // Use User's Default
                                    from: destURL,
                                    progressHandler: { _ in }
                                )
                                
                                // Remove task
                                await MainActor.run {
                                    conversionManager.activeTasks.removeAll { $0.description == taskDesc }
                                }
                            }
                        }
                        await MainActor.run { conversionManager.scanForPDFs() }
                    }
                case .failure(let error):
                    print("Import failed: \(error.localizedDescription)")
                }
            }
            .sheet(isPresented: $showingMetadataSearch) {
                if let pdf = selectedPDF { MetadataSearchSheet(pdf: pdf) }
            }
            // ✅ FIX: Connect the "Extract Panels" button
            .sheet(isPresented: $showingPanelExtractor) {
                if let pdf = selectedPDF {
                    // This is a simplified view to trigger the extraction process
                    VStack(spacing: 20) {
                        Text("Panel Extraction").font(.headline)
                        Text("This will analyze \(pdf.name) and let you manually adjust the panels.").multilineTextAlignment(.center).padding()
                        
                        Button("Start Editor") {
                            showingPanelExtractor = false // Close this sheet
                            
                            // Trigger the editor flow
                            Task {
                                let settings = conversionManager.conversionSettings.epubSettings
                                // Call the manager to prepare the session
                                // Note: We ignore the result here because the manager will trigger the full-screen editor in ContentView
                                _ = try? await conversionManager.performPanelReview(sourceEPUB: pdf.url, settings: settings)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding()
                    .presentationDetents([.medium])
                }
            }
        }
        .overlay(alignment: .bottom) { batchMergeOverlay }
        .overlay(alignment: .top) { taskMonitorOverlay } // ✅ ADD THIS LINE
        .onAppear { Task { await refreshLibrary() } }
        .onChange(of: conversionManager.organizationMethod) { _ in 
            conversionManager.sortPDFs() 
        }
    }
    
    // MARK: - Subviews
    
    var taskMonitorOverlay: some View {
        Group {
            if !conversionManager.activeTasks.isEmpty {
                VStack(spacing: 8) {
                    ForEach(conversionManager.activeTasks) { task in
                        HStack {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text(task.description)
                                .font(.caption)
                                .fontWeight(.medium)
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
    
    var batchMergeOverlay: some View {
        Group {
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
    }
    
    var emptyStateView: some View {
        // ✅ FIX: Wrapped in VStack to return a single View type
        VStack {
            VStack(spacing: 20) {
                Image(systemName: "books.vertical").font(.system(size: 60)).foregroundColor(.gray)
                Text("No Comics Found").font(.title2).bold()
                Text("Tap 'Convert' to add files.").foregroundColor(.secondary)
            }
            .padding()
            Spacer()
        }
    }
    
    var libraryContentView: some View {
        ScrollView {
            if isGridView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 15), count: gridColumns), spacing: 20) {
                    ForEach(filteredPDFs) { pdf in
                        ZStack(alignment: .topTrailing) {
                            // The Item
                            LibraryGridItem(pdf: pdf)
                            
                            // ✅ NEW: File Type Badge
                            Text(pdf.typeLabel)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(pdf.typeColor)
                                .cornerRadius(4)
                                .padding(6) // Offset from corner
                                .shadow(radius: 2)
                        }
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.blue, lineWidth: selectedPDFs.contains(pdf.id) ? 3 : 0)
                        )
                        .onTapGesture { handleTap(pdf) }
                        .contextMenu { menuItems(for: pdf) }
                    }
                }
                .padding()
            } else {
                LazyVStack {
                    ForEach(filteredPDFs) { pdf in
                        LibraryPDFRowWithCover(pdf: pdf, isSelected: selectedPDFs.contains(pdf.id))
                            .onTapGesture { handleTap(pdf) }
                            .contextMenu { menuItems(for: pdf) }
                    }
                }
                .padding()
            }
        }
    }
    

    
    func handleTap(_ pdf: ConvertedPDF) {
        if isSelectionMode {
             toggleSelection(pdf)
        } else {
             readingPDF = pdf
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
                showingMetadataSearch = true
            } label: { Label("Fetch Metadata", systemImage: "magnifyingglass") }
            
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
    @Binding var sortMethod: OrganizationMethod
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
