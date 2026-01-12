import SwiftUI
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
                ToolbarItem(placement: .navigationBarLeading) {
                    Menu {
                        Picker("Sort By", selection: $sortOption) {
                            Label("Date Added", systemImage: "calendar").tag(SortOption.dateAdded)
                            Label("Name", systemImage: "textformat").tag(SortOption.name)
                            Label("Size", systemImage: "externaldrive").tag(SortOption.size)
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                }
                
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
            // ✅ Fix: Sheet only presents when 'pdfToEdit' is not nil
            .sheet(item: $pdfToEdit) { pdf in
                PageManagerView(pdf: pdf)
            }

            // ✅ Fix: Sheet for Multi-Export
            .sheet(item: $sharePayload) { payload in
                ShareSheet(activityItems: payload.items)
            }
            // ✅ Fix: Merge Sheet
            .sheet(isPresented: $showingMergeSheet) {
                FileMergeView(initialSelection: selection)
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
        }
    }
    
    // ✅ NEW: Bulk Action Helpers
    
    @State private var selection = Set<UUID>()
    @State private var editMode: EditMode = .inactive
    @State private var sharePayload: SharePayload?
    
    struct SharePayload: Identifiable {
        let id = UUID()
        let items: [Any]
    }
    
    // Toggle Selection Mode
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
                    Button {
                        conversionManager.toggleFavorite(pdf)
                    } label: {
                        Label(pdf.isFavorite ? "Unfavorite" : "Favorite", systemImage: pdf.isFavorite ? "star.slash" : "star")
                    }
                    
                    Button {
                        selectedPDFForCollection = pdf
                        showingAddToCollection = true
                    } label: {
                        Label("Add to Collection", systemImage: "folder.badge.plus")
                    }
                    
                    Button {
                        // Export Logic (Share Sheet)
                        // Triggered via state? or direct?
                        // We need a share function. 'selectedPDFForCollection' is state.
                        // We likely need 'selectedPDFForExport' state or similar.
                        // Assuming sharePDF usage:
                         sharePDF(pdf)
                    } label: {
                        Label("Export File", systemImage: "square.and.arrow.up")
                    }
                    
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
                .contextMenu {
                    // 1. Export (Sets pdfToShare, triggers sheet)
                    Button {
                        pdfToShare = pdf
                    } label: {
                        Label("Export / Send to Kindle", systemImage: "square.and.arrow.up")
                    }
                    
                    // 2. Edit (Sets pdfToEdit, triggers sheet)
                    Button {
                        pdfToEdit = pdf
                    } label: {
                        Label("Edit Book & Pages", systemImage: "doc.on.doc")
                    }
                    
                    // ✅ NEW: Comic Vault Export
                    Button {
                        if let sidecarURL = conversionManager.generateSidecar(for: pdf) {
                            sharePayload = LibraryView.SharePayload(items: [pdf.url, sidecarURL])
                        }
                    } label: {
                        Label("Export to Comic Vault", systemImage: "arrow.up.doc.fill")
                    }
                    
                    Divider()
                    
                    Button {
                        Task {
                            await conversionManager.convertComic(
                                pdf,
                                mangaMode: conversionManager.conversionSettings.mangaMode
                            )
                        }
                    } label: {
                        Label("Quick Convert", systemImage: "bolt.fill")
                    }
                    
                    Button {
                        conversionManager.toggleFavorite(pdf)
                    } label: {
                        Label(pdf.isFavorite ? "Unfavorite" : "Favorite", systemImage: pdf.isFavorite ? "star.slash" : "star")
                    }
                    
                    // ✅ NEW: Collections Menu
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
                    
                    Button(role: .destructive) {
                        conversionManager.deletePDF(pdf)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.plain)
        .environment(\.editMode, $editMode) // ✅ Enable Selection Mode
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always))
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
