import SwiftUI
import UniformTypeIdentifiers

// MARK: - Theme Colors
struct Theme {
    static let bg = Color.black
    static let surface = Color(red: 28/255, green: 28/255, blue: 30/255)
    static let surfaceElevated = Color(red: 58/255, green: 58/255, blue: 60/255)
    static let orange = Color(red: 1, green: 159/255, blue: 10/255) // #FF9F0A
    static let blue = Color(red: 10/255, green: 132/255, blue: 255/255) // #0A84FF
    static let text = Color.white
    static let textSecondary = Color(red: 142/255, green: 142/255, blue: 147/255) // #8E8E93
    static let textTertiary = Color(red: 99/255, green: 99/255, blue: 102/255) // #636366
}

struct ModernLibraryView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @Binding var selectedPDF: ConvertedPDF?
    @Binding var isBatchMode: Bool
    @Binding var multiSelection: Set<UUID>
    @Binding var showingBatchMergeReorder: Bool
    @Binding var batchMergeItems: [ConvertedPDF]
    
    // Local State
    @State private var searchText = ""
    
    enum SidebarSheet: Identifiable {
        case importer, wifi, cloud, merge
        var id: Int { hashValue }
    }
    
    @State private var activeSheet: SidebarSheet?
    @State private var sortOption: LibraryView.SortOption = .dateAdded
    @State private var showingSortMenu = false
    
    // ✅ NEW: Rename Logic
    @State private var pdfToRename: ConvertedPDF?
    @State private var renameText = ""
    
    // ✅ NEW: Export State
    @State private var pdfToExport: ConvertedPDF?
    @State private var pdfToSearchMetadata: ConvertedPDF?
    
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
        VStack(spacing: 0) {
            // MARK: - Toolbar & Filter Header
            VStack(spacing: 0) {
                // Toolbar Row 1
                HStack(spacing: 12) {
                    // Book Icon (Library)
                    Button(action: {}) {
                        Image(systemName: "books.vertical.fill")
                            .font(.system(size: 20))
                            .foregroundColor(Theme.orange)
                    }
                    
                    // Target Selector Menu
                    Menu {
                        Picker("Target Format", selection: $conversionManager.conversionSettings.outputFormat) {
                            ForEach(OutputFormat.allCases) { format in
                                Label(format.rawValue, systemImage: format.icon).tag(format)
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text("Target:")
                                .font(.system(size: 15))
                                .foregroundColor(Theme.textSecondary)
                            
                            // Shortened display name for the badge
                            let badgeText: String = {
                                switch conversionManager.conversionSettings.outputFormat {
                                case .epub: return "EPUB"
                                case .pdf: return "PDF"
                                case .cbz: return "CBZ"
                                }
                            }()
                            
                            Text(badgeText)
                                .font(.system(size: 12, weight: .bold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Theme.orange)
                                .foregroundColor(.black)
                                .cornerRadius(6)
                        }
                    }
                    
                    // More Button
                    Menu {
                        Button(action: { activeSheet = .merge }) { Label("Merge Files", systemImage: "arrow.triangle.merge") }
                        Button(role: .destructive) { /* Batch Delete Logic? */ } label: { Label("Delete All", systemImage: "trash") }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 20))
                            .foregroundColor(Theme.textSecondary)
                    }
                    
                    Spacer()
                    
                    // Actions
                    HStack(spacing: 16) {
                        Button(action: { activeSheet = .cloud }) {
                            Image(systemName: "icloud.and.arrow.down")
                                .font(.system(size: 20))
                                .foregroundColor(Theme.orange)
                        }
                        
                        Button(action: { activeSheet = .wifi }) {
                            Image(systemName: "wifi") // Simplified for SF Symbol
                                .font(.system(size: 20))
                                .foregroundColor(Theme.orange)
                        }
                        
                        Button(action: { activeSheet = .importer }) {
                            Image(systemName: "doc.badge.plus")
                                .font(.system(size: 20))
                                .foregroundColor(Theme.orange)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                
                // Toolbar Row 2 (Search & Filter)
                HStack(spacing: 16) {
                    // Search Box
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 16))
                            .foregroundColor(Theme.textTertiary)
                        TextField("Search...", text: $searchText)
                            .font(.system(size: 17))
                            .foregroundColor(Theme.text)
                            .accentColor(Theme.blue)
                    }
                    .padding(.vertical, 9)
                    .padding(.horizontal, 12)
                    .background(Theme.surface)
                    .cornerRadius(10)
                    
                    // Icons
                    HStack(spacing: 18) {
                        // View Toggle (Placeholder)
                        Button(action: {}) {
                            Image(systemName: "list.bullet")
                                .font(.system(size: 20))
                                .foregroundColor(Theme.blue)
                        }
                        
                        // Sort
                        Menu {
                            Picker("Sort", selection: $sortOption) {
                                Text("Date").tag(LibraryView.SortOption.dateAdded)
                                Text("Name").tag(LibraryView.SortOption.name)
                                Text("Size").tag(LibraryView.SortOption.size)
                            }
                        } label: {
                            Image(systemName: "arrow.up.arrow.down")
                                .font(.system(size: 20))
                                .foregroundColor(Theme.blue)
                        }
                        
                        // Settings (Placeholder)
                        Button(action: {}) {
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 20))
                                .foregroundColor(Theme.blue)
                        }
                    }
                    
                    Spacer()
                    
                    // Select Button
                    Button(action: {
                        withAnimation {
                            isBatchMode.toggle()
                            if !isBatchMode { multiSelection.removeAll() }
                        }
                    }) {
                        Text(isBatchMode ? "Done" : "Select")
                            .font(.system(size: 17))
                            .foregroundColor(Theme.orange)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            .background(Color.black) // Header Background
            
            Divider().background(Color(white: 0.2))
            
            // ... (Content Area) ...
            if conversionManager.convertedPDFs.isEmpty {
                ModernEmptyState(onImport: { activeSheet = .importer })
            } else {
                List(selection: $selectedPDF) {
                    ForEach(filteredPDFs) { pdf in
                         // ... (Batch Mode Logic) ...
                        if isBatchMode {
                             // ...
                        } else {
                            // Link for Split View / Nav Stack
                            NavigationLink(value: pdf) {
                                ModernFileRow(pdf: pdf, isSelected: selectedPDF?.id == pdf.id, isBatch: false)
                            }
                            .listRowBackground(Color.black)
                            .listRowSeparatorTint(Color(white: 0.2))
                            .swipeActions(edge: .leading) {
                                Button {
                                    pdfToExport = pdf
                                } label: { Label("Export", systemImage: "square.and.arrow.up") }
                                .tint(.green)
                            
                                Button {
                                    pdfToSearchMetadata = pdf
                                } label: { Label("Metadata", systemImage: "info.circle") }
                                .tint(.blue)
                                
                                Button {
                                    renameText = pdf.name
                                    pdfToRename = pdf
                                } label: { Label("Rename", systemImage: "pencil") }
                                .tint(.orange)
                                
                                Button {
                                    Task { await conversionManager.embedPanels(for: pdf) }
                                } label: { Label("Embed", systemImage: "flame") }
                                .tint(.purple)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { conversionManager.deletePDF(pdf) } label: { Label("Delete", systemImage: "trash") }
                            }
                            .contextMenu {
                                Button {
                                    pdfToExport = pdf
                                } label: { Label("Export Options", systemImage: "square.and.arrow.up") }
                                
                                Button {
                                    renameText = pdf.name
                                    pdfToRename = pdf
                                } label: { Label("Rename", systemImage: "pencil") }
                                
                                Button {
                                    Task { await conversionManager.embedPanels(for: pdf) }
                                } label: { Label("Embed Panels", systemImage: "flame") }
                                
                                Button(role: .destructive) { conversionManager.deletePDF(pdf) } label: { Label("Delete", systemImage: "trash") }
                                Divider()
                                Button {
                                    pdfToSearchMetadata = pdf
                                } label: { Label("Fetch Metadata", systemImage: "magnifyingglass") }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .background(Color.black)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .sheet(item: $activeSheet) { item in
            switch item {
            case .importer, .cloud:
                DocumentPicker(onDocumentsPicked: { urls in Task { await conversionManager.processImportedFiles(urls: urls); activeSheet = nil } })
            case .wifi: WiFiView()
            case .merge: FileMergeView()
            }
        }
        .sheet(item: $pdfToExport) { pdf in
            DualExportView(pdf: pdf)
        }
        .sheet(item: $pdfToSearchMetadata) { pdf in
            MetadataSearchSheet(pdf: pdf)
        }
        // ✅ NEW: Rename Alert
        .alert("Rename File", isPresented: Binding(
            get: { pdfToRename != nil },
            set: { if !$0 { pdfToRename = nil } }
        )) {
            TextField("New Name", text: $renameText)
            Button("Cancel", role: .cancel) { }
            Button("Rename") {
                if let pdf = pdfToRename {
                    conversionManager.renamePDF(pdf, to: renameText)
                }
            }
        }
        .alert(item: $conversionManager.appAlert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("OK")))
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
            loadFiles(from: providers)
            return true
        }
    }
    
    // Copy of helpers
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

// MARK: - Subcomponents

struct ModernEmptyState: View {
    var onImport: () -> Void
    
    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            
            // Simulated "Bookshelf" Icon using SF Symbols stack
            ZStack(alignment: .bottom) {
                Image(systemName: "books.vertical.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 80, height: 80)
                    .foregroundColor(Theme.surfaceElevated)
                
                // Shelf line
                Rectangle()
                    .fill(Theme.surfaceElevated)
                    .frame(width: 120, height: 4)
                    .offset(y: 4)
            }
            .padding(.bottom, 20)
            
            Text("Your Library is Empty")
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundColor(Theme.text)
            
            Button(action: onImport) {
                HStack {
                    Image(systemName: "plus")
                    Text("Import Comic")
                }
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .background(Theme.blue)
                .cornerRadius(12)
            }
            
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}

struct ModernFileRow: View {
    let pdf: ConvertedPDF
    let isSelected: Bool
    let isBatch: Bool
    
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if let data = pdf.coverImageData, let img = UIImage(data: data) {
                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(Theme.surfaceElevated)
                    Image(systemName: "doc.text.fill")
                        .foregroundColor(Theme.textSecondary)
                }
            }
            .frame(width: 40, height: 56)
            .cornerRadius(4)
            .clipped()
            
            VStack(alignment: .leading, spacing: 4) {
                Text(pdf.name)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(Theme.text)
                    .lineLimit(1)
                
                HStack(spacing: 6) {
                    MockBadge(text: pdf.url.pathExtension.uppercased(), color: Theme.orange.opacity(0.2), textColor: Theme.orange)
                    Text(pdf.formattedSize)
                        .font(.caption)
                        .foregroundColor(Theme.textSecondary)
                    if pdf.isFavorite {
                        Image(systemName: "heart.fill")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
            }
            
            Spacer()
            
            if isBatch {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundColor(isSelected ? Theme.blue : Theme.textSecondary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

struct MockBadge: View {
    let text: String
    let color: Color
    let textColor: Color
    
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color)
            .foregroundColor(textColor)
            .cornerRadius(4)
    }
}
