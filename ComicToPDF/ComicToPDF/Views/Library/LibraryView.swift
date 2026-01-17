import SwiftUI
import PDFKit
import UniformTypeIdentifiers

struct LibraryView: View {
    @Binding var selectedTab: Int
    @EnvironmentObject var conversionManager: ConversionManager
    
    // UI State
    @State private var showingDocumentPicker = false
    @State private var showingSortMenu = false
    @State private var searchText = ""
    @State private var sortOption: SortOption = .dateAdded
    @State private var isImporting = false
    @State private var showingMergeSheet = false
    @State private var showingAddCollection = false
    @State private var newCollectionName = ""
    
    // ✅ Fix: Data-Driven Sheet State (Prevents Blank Pages)
    @State private var pdfToShare: ConvertedPDF?
    @State private var pdfToEdit: ConvertedPDF?
    @State private var showingLargeFileAlert = false
    @State private var largeFilePDF: ConvertedPDF?
    
    enum SortOption {
        case dateAdded, name, size
    }
    
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
    
    // ✅ New State for "Save & Open" workflow
    @State private var showingWebExport = false
    @State private var webExportPDF: ConvertedPDF?

    var body: some View {
        NavigationView {
            ZStack {
                if conversionManager.convertedPDFs.isEmpty {
                    emptyStateView
                } else {
                    pdfListView
                }
                
                // Floating Action Button
                if !conversionManager.convertedPDFs.isEmpty {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Button(action: { showingDocumentPicker = true }) {
                                Image(systemName: "plus")
                                    .font(.title)
                                    .foregroundColor(.white)
                                    .frame(width: 60, height: 60)
                                    .background(Color.blue)
                                    .clipShape(Circle())
                                    .shadow(radius: 4)
                            }
                            .padding()
                        }
                    }
                }
                
                if isImporting {
                    Color.black.opacity(0.4).edgesIgnoringSafeArea(.all)
                    ProgressView("Importing...")
                        .padding()
                        .background(Color(UIColor.systemBackground))
                        .cornerRadius(10)
                }
            }
            .navigationTitle("Library")
            .toolbar {
                // Sort Menu Removed (Moved to main view)
                
                // ✅ Select Button
                ToolbarItem(placement: .navigationBarTrailing) {
                     Button(editMode == .active ? "Done" : "Select") {
                         toggleEditMode()
                     }
                }
                
                // ✅ Bottom Toolbar (Delete / Export)
                ToolbarItemGroup(placement: .bottomBar) {
                    if editMode == .active {
                         Button(role: .destructive) {
                             deleteSelection()
                         } label: {
                             Label("Delete", systemImage: "trash")
                         }
                         
                         Spacer()
                         
                         Text("\(selection.count) Selected")
                             .font(.caption)
                             .foregroundColor(.secondary)
                         
                         Spacer()
                         
                         // ✅ Batch Convert Button
                         Button {
                             performBatchConversion()
                         } label: {
                             Label("Convert", systemImage: "arrow.triangle.2.circlepath")
                         }
                         
                         Spacer()
                         
                         // ✅ Convert & Merge Button
                         Button {
                             prepareBatchMerge()
                         } label: {
                             Label("Merge & Convert", systemImage: "doc.on.doc.fill")
                         }
                         
                         Spacer()
                         
                         Button {
                             exportSelection()
                         } label: {
                             Label("Export", systemImage: "square.and.arrow.up")
                         }
                         
                         Spacer()
                         
                         Button {
                             showingMergeSheet = true
                         } label: {
                             Label("Merge", systemImage: "arrow.triangle.merge")
                         }
                    }
                }
            }
            .sheet(isPresented: $showingDocumentPicker) {
                DocumentPicker(onDocumentsPicked: { urls in
                    isImporting = true
                    Task {
                        await conversionManager.processImportedFiles(urls: urls)
                        isImporting = false
                    }
                })
            }
            // ✅ Fix: Sheet only presents when 'pdfToShare' is not nil
            .sheet(item: $pdfToShare) { pdf in
                ShareSheet(activityItems: [pdf.url])
            }

            .sheet(item: $pdfToEdit) { pdf in
                PageManagerView(pdf: pdf)
            }
            .sheet(item: $sharePayload) { payload in
                ShareSheet(activityItems: payload.items)
            }
            .sheet(isPresented: $showingMergeSheet) {
                FileMergeView(initialSelection: selection)
            }
            // ✅ "Save for Web" File Exporter
            .fileExporter(
                isPresented: $showingWebExport,
                document: GenericFileDocument(url: webExportPDF?.url ?? URL(fileURLWithPath: "")),
                contentType: (webExportPDF?.url.pathExtension.lowercased() == "epub") ? .epub : .pdf,
                defaultFilename: webExportPDF?.name ?? "Comic"
            ) { result in
                switch result {
                case .success:
                    // Automatically open Safari after saving
                    if let url = URL(string: "https://www.amazon.com/gp/sendtokindle") {
                        UIApplication.shared.open(url)
                    }
                case .failure(let error):
                    print("Export failed: \(error.localizedDescription)")
                }
            }
            .alert("New Collection", isPresented: $showingAddCollection) {
                TextField("Collection Name", text: $newCollectionName)
                Button("Cancel", role: .cancel) { newCollectionName = "" }
                Button("Create") {
                    if !newCollectionName.isEmpty {
                        conversionManager.createCollection(name: newCollectionName, icon: "folder", color: "Blue")
                        newCollectionName = ""
                    }
                }
            }
            // ✅ Large File Alert attached to Main View
            .confirmationDialog("Large File Detected", isPresented: $showingLargeFileAlert, titleVisibility: .visible) {
                Button("Save to 'Downloads' & Open Website") {
                    // Start the Save & Open Flow
                    if let pdf = largeFilePDF {
                        webExportPDF = pdf
                        showingWebExport = true
                    }
                }
                Button("Share via System Sheet") {
                    // Fallback to standard share
                    if let pdf = largeFilePDF {
                        pdfToShare = pdf
                    }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("File is >100MB. To upload via browser, save it to 'Downloads' first. We will open the website for you immediately after saving.")
            }
        }
    }
    
    // MARK: - Helpers
    
    private func sharePDF(_ pdf: ConvertedPDF) {
        if pdf.fileSize > 100 * 1024 * 1024 {
            largeFilePDF = pdf
            showingLargeFileAlert = true
        } else {
            pdfToShare = pdf
        }
    }
    

    
    @State private var selection = Set<UUID>()
    @State private var editMode: EditMode = .inactive
    @State private var sharePayload: SharePayload?
    
    struct SharePayload: Identifiable {
        let id = UUID()
        let items: [Any]
    }
    
    func toggleEditMode() {
        withAnimation {
            if editMode == .active {
                editMode = .inactive
                selection.removeAll()
            } else {
                editMode = .active
            }
        }
    }
    
    func deleteSelection() {
        let itemsToDelete = conversionManager.convertedPDFs.filter { selection.contains($0.id) }
        for pdf in itemsToDelete {
            conversionManager.deletePDF(pdf)
        }
        selection.removeAll()
        editMode = .inactive
    }
    
    func exportSelection() {
        let itemsToExport = conversionManager.convertedPDFs.filter { selection.contains($0.id) }
        let urls = itemsToExport.map { $0.url }
        if !urls.isEmpty {
            sharePayload = SharePayload(items: urls)
        }
    }
    
    func performBatchConversion() {
        let itemsToConvert = conversionManager.convertedPDFs.filter { selection.contains($0.id) }
        editMode = .inactive
        selection.removeAll()
        Task {
            await conversionManager.convertQueue(itemsToConvert)
        }
    }
    
    @State private var showingBatchMergeReorder = false
    @State private var batchMergeItems: [ConvertedPDF] = []
    
    func prepareBatchMerge() {
        batchMergeItems = conversionManager.convertedPDFs.filter { selection.contains($0.id) }
        showingBatchMergeReorder = true
    }
    
    var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "books.vertical")
            .font(.system(size: 60))
            .foregroundColor(.gray)
            Text("Your Library is Empty")
            .font(.title2)
            .bold()
            Text("Import a CBZ, CBR, or PDF file to get started.")
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal)
            
            Button(action: { showingDocumentPicker = true }) {
                Label("Import Comic", systemImage: "plus")
                .font(.headline)
                .padding()
                .frame(width: 200)
                .background(Color.blue)
                .foregroundColor(.white)
                .cornerRadius(10)
            }
        }
    }
    
    var pdfListView: some View {
        VStack(spacing: 0) {
            // ✅ Sort Selector
            Picker("Sort By", selection: $sortOption) {
                Text("Date").tag(SortOption.dateAdded)
                Text("Name").tag(SortOption.name)
                Text("Size").tag(SortOption.size)
            }
            .pickerStyle(SegmentedPickerStyle())
            .padding()
            .background(Color(UIColor.systemBackground))
            
            List(selection: $selection) {
                ForEach(filteredPDFs) { pdf in
                    NavigationLink(destination: ConvertView(pdf: pdf)) {
                        LibraryPDFRowWithCover(pdf: pdf, isSelected: false)
                    }
                    .swipeActions(edge: .leading) {
                        Button {
                            conversionManager.toggleFavorite(pdf)
                        } label: {
                            Label("Favorite", systemImage: pdf.isFavorite ? "star.slash" : "star")
                        }
                        .tint(.yellow)
                    }
                    .contextMenu {
                        // 1. Favorite
                        Button {
                            conversionManager.toggleFavorite(pdf)
                        } label: {
                            Label(pdf.isFavorite ? "Unfavorite" : "Favorite", systemImage: pdf.isFavorite ? "star.slash" : "star")
                        }
                        
                        // 2. Add to Collection
                        Menu {
                            Button {
                                showingAddCollection = true
                            } label: {
                                Label("New Collection...", systemImage: "plus")
                            }
                            
                            if !conversionManager.collections.isEmpty {
                                Divider()
                                ForEach(conversionManager.collections) { collection in
                                    Button {
                                        conversionManager.movePDFToCollection(pdf, collectionId: collection.id)
                                    } label: {
                                        if pdf.collectionId == collection.id {
                                            Label(collection.name, systemImage: "checkmark")
                                        } else {
                                            Text(collection.name)
                                        }
                                    }
                                }
                            }
                            
                            if pdf.collectionId != nil {
                                Divider()
                                Button(role: .destructive) {
                                    conversionManager.movePDFToCollection(pdf, collectionId: nil)
                                } label: {
                                    Label("Remove from Collection", systemImage: "folder.badge.minus")
                                }
                            }
                        } label: {
                            Label("Add to Collection", systemImage: "folder")
                        }
                        
                        // 3. Export
                        Button {
                            sharePDF(pdf)
                        } label: {
                            Label("Export / Send to Kindle", systemImage: "square.and.arrow.up")
                        }
                        
                        // 4. Edit
                        Button {
                            pdfToEdit = pdf
                        } label: {
                            Label("Edit Book & Pages", systemImage: "doc.on.doc")
                        }
                        
                        // 5. Comic Vault Export
                        Button {
                            Task {
                                if let exportedURL = await conversionManager.exportWithEmbeddedMetadata(for: pdf) {
                                    await MainActor.run {
                                        sharePayload = LibraryView.SharePayload(items: [exportedURL])
                                    }
                                }
                            }
                        } label: {
                            Label("Export to Comic Vault", systemImage: "arrow.up.doc.fill")
                        }
                        
                        Divider()
                        
                        // 6. Delete
                        Button(role: .destructive) {
                            conversionManager.deletePDF(pdf)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            conversionManager.deletePDF(pdf)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
                .onDelete { indexSet in
                    for index in indexSet {
                        let pdf = filteredPDFs[index]
                        conversionManager.deletePDF(pdf)
                    }
                }
            }
            .environment(\.editMode, $editMode)
            .listStyle(PlainListStyle())
            .animation(.default, value: sortOption)
        }
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always))
        .sheet(isPresented: $showingMergeSheet) {
            FileMergeView()
        }
        .sheet(isPresented: $showingBatchMergeReorder) {
            BatchMergeReorderView(selectedFiles: $batchMergeItems)
        }
    }
}

extension ConversionManager {
    func toggleFavorite(_ pdf: ConvertedPDF) {
        if let idx = convertedPDFs.firstIndex(where: { $0.id == pdf.id }) {
            var newPDF = pdf
            newPDF.isFavorite.toggle()
            convertedPDFs[idx] = newPDF
            saveLibrary()
        }
    }
}
