import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Binding var selectedTab: Int
    @EnvironmentObject var conversionManager: ConversionManager
    @State private var showingDocumentPicker = false
    @State private var showingSortMenu = false
    @State private var searchText = ""
    @State private var sortOption: SortOption = .dateAdded
    @State private var isImporting = false
    
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
            }
            .sheet(isPresented: $showingDocumentPicker) {
                // ✅ Fix: Correct parameter name
                DocumentPicker(onDocumentsPicked: { urls in
                    isImporting = true
                    Task {
                        await conversionManager.processImportedFiles(urls: urls)
                        isImporting = false
                    }
                })
            }
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
        List {
            ForEach(filteredPDFs) { pdf in
                NavigationLink(destination: ConvertView(pdf: pdf)) {
                    // ✅ Fix: Added isSelected: false
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
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        conversionManager.deletePDF(pdf)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .contextMenu {
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
                    
                    Button(role: .destructive) {
                        conversionManager.deletePDF(pdf)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.plain)
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
