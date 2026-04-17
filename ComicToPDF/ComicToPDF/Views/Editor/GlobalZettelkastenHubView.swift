import SwiftUI
import SwiftData
import UniformTypeIdentifiers

enum ZettelViewMode { case list, map }
enum ZettelFilterMode { case all, permanent, fleeting }

struct GlobalZettelkastenHubView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    
    // Sort all annotations latest over all PDF IDs
    @Query(sort: \SDAnnotation.modifiedAt, order: .reverse) private var allAnnotations: [SDAnnotation]
    @Query private var allPDFs: [SDConvertedPDF]
    
    @State private var searchText = ""
    @State private var viewMode: ZettelViewMode = .list
    @State private var filterMode: ZettelFilterMode = .all
    

    @State private var isImporting = false
    @State private var isExporting = false
    @State private var importMessage: String? = nil
    
    @State private var exportDocument: ZettelArchiveDocument?
    @State private var showingExporterDialog = false
    
    // Filtered Annotations based on UI states
    var activeAnnotations: [SDAnnotation] {
        var filtered = allAnnotations
        
        switch filterMode {
        case .all: break
        case .permanent:
            filtered = filtered.filter { $0.noteText != nil && !$0.noteText!.isEmpty }
        case .fleeting:
            filtered = filtered.filter { $0.noteText == nil || $0.noteText!.isEmpty }
        }
        
        if !searchText.isEmpty {
            let cache = makePDFNameCache()
            filtered = filtered.filter { ann in
                let txt = ann.selectedText?.localizedCaseInsensitiveContains(searchText) ?? false
                let note = ann.noteText?.localizedCaseInsensitiveContains(searchText) ?? false
                let book = bookTitle(for: ann, cache: cache).localizedCaseInsensitiveContains(searchText)
                return txt || note || book
            }
        }
        return filtered
    }
    
    // O(1) Lookup dictionary — built once per computed property access, reused for every annotation in that pass.
    private func makePDFNameCache() -> [UUID: String] {
        var dict = [UUID: String]()
        for pdf in allPDFs { dict[pdf.id] = pdf.name }
        return dict
    }
    
    // Group Highlights by Book (Native PDFs and Readwise Synced Books)
    var groupedAnnotations: [(key: String, value: [SDAnnotation])] {
        let cache = makePDFNameCache()
        let dict = Dictionary(grouping: activeAnnotations) { ann -> String in
            return bookTitle(for: ann, cache: cache)
        }
        return dict.sorted { $0.key < $1.key }
    }

    // Total unique book count across ALL annotations (not just filtered)
    private var totalBookCount: Int {
        let cache = makePDFNameCache()
        return Set(allAnnotations.map { bookTitle(for: $0, cache: cache) }).count
    }
    
    var body: some View {
        ZStack {
            Color(UIColor.systemGroupedBackground).edgesIgnoringSafeArea(.all)
            
            if allAnnotations.isEmpty {
                emptyStateView
            } else {
                VStack(spacing: 0) {
                    // Segmented Layout Controls
                    Picker("View Mode", selection: $viewMode) {
                        Text("List").tag(ZettelViewMode.list)
                        Text("Mind Map").tag(ZettelViewMode.map)
                    }
                    .pickerStyle(.segmented)
                    .padding()
                    
                    if viewMode == .list {
                        // Filter Strip
                        HStack {
                            Text("Filter:").font(.caption).foregroundColor(.secondary)
                            Picker("Filter", selection: $filterMode) {
                                Text("All Notes").tag(ZettelFilterMode.all)
                                Text("Permanent Notes").tag(ZettelFilterMode.permanent)
                                Text("Fleeting Notes").tag(ZettelFilterMode.fleeting)
                            }
                            .labelsHidden()
                            Spacer()
                        }
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                        
                        ScrollView {
                            LazyVStack(spacing: 24, pinnedViews: []) {
                                ForEach(groupedAnnotations, id: \.key) { group in
                                    VStack(alignment: .leading, spacing: 12) {
                                        // Group Header
                                        HStack {
                                            Image(systemName: group.value.first?.isReadwiseImport == true ? "books.vertical.fill" : "book.closed.fill")
                                                .foregroundColor(group.value.first?.isReadwiseImport == true ? .yellow : .blue)
                                            Text(group.key)
                                                .font(.headline)
                                                .foregroundColor(.primary)
                                            Spacer()
                                            Text("\(group.value.count) Notes")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                        .padding(.horizontal)
                                        
                                        // Group Items
                                        VStack(spacing: 0) {
                                            ForEach(group.value) { item in
                                                GlobalHighlightRow(annotation: item)
                                                if item != group.value.last {
                                                    Divider().padding(.leading, 16)
                                                }
                                            }
                                        }
                                        .background(Color(UIColor.secondarySystemGroupedBackground))
                                        .cornerRadius(12)
                                        .shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 1)
                                        .padding(.horizontal)
                                    }
                                }
                            }
                            .padding(.vertical)
                        }
                    } else {
                        // Canvas Mind Map View
                        ZettelkastenGraphView(annotations: activeAnnotations, pdfs: allPDFs)
                    }
                }
            }
        }
        .navigationTitle("Zettelkasten Hub")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $searchText, prompt: "Search all highlights & notes...")
        .toolbar {
            // Stat indicators — mirrors Library's "N FILES • N SERIES" pattern
            ToolbarItem(placement: .principal) {
                VStack(spacing: 2) {
                    Text("Zettelkasten Hub")
                        .font(.headline)
                        .foregroundColor(.primary)
                    if !allAnnotations.isEmpty {
                        Text("\(allAnnotations.count) HIGHLIGHTS • \(totalBookCount) BOOKS")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundColor(.secondary)
                            .tracking(1.2)
                    }
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button(action: { 
                        ImportCoordinator.present(type: .smartList) { urls in
                            if let first = urls.first {
                                handleCSVImport(result: .success([first]))
                            }
                        }
                    }) {
                        Label("Import Readwise", systemImage: "arrow.down.doc")
                    }
                    Button(action: triggerExport) {
                        Label("Export Mind Palace", systemImage: "square.and.arrow.up")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }

        .fileExporter(isPresented: $showingExporterDialog, document: exportDocument, contentType: .zip, defaultFilename: "MindPalace_Export") { result in
            switch result {
            case .success(let url): print("Mind Palace successfully exported to \(url)")
            case .failure(let error): print("Mind Palace Export failed: \(error.localizedDescription)")
            }
        }
        .overlay {
            if isImporting || isExporting {
                ProgressView(isImporting ? "Importing Readwise Database..." : "Compiling Mind Palace Archive...")
                    .padding()
                    .background(.ultraThinMaterial)
                    .cornerRadius(12)
            }
        }
        .alert(isPresented: Binding<Bool>(
            get: { importMessage != nil },
            set: { if !$0 { importMessage = nil } }
        )) {
            Alert(title: Text("System Status"), message: Text(importMessage ?? ""), dismissButton: .default(Text("OK")))
        }
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "highlighter")
                .font(.system(size: 60))
                .foregroundColor(.gray.opacity(0.5))
            Text("Your Mind Palace is Empty")
                .font(.title2).bold()
            Text("Highlights and Zettelkasten notes from all your books will appear here.")
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            
            Button(action: { 
                ImportCoordinator.present(type: .smartList) { urls in
                    if let first = urls.first {
                        handleCSVImport(result: .success([first]))
                    }
                }
            }) {
                Text("Import from Readwise")
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding()
                    .frame(maxWidth: 250)
                    .background(Color.blue)
                    .cornerRadius(12)
            }
            .padding(.top, 10)
        }
    }
    
    private func bookTitle(for annotation: SDAnnotation?, cache: [UUID: String]? = nil) -> String {
        guard let ann = annotation else { return "Unknown Book" }

        // Use readwiseBookTitle only if it's a real human-readable title.
        if let title = ann.readwiseBookTitle,
           !title.isEmpty,
           UUID(uuidString: title) == nil {
            return title
        }

        // Fall through to the native SwiftData PDF name via cache.
        let lookup = cache ?? makePDFNameCache()
        if let pdfName = lookup[ann.pdfID] {
            return pdfName
        }

        return "Book ID: " + String(ann.pdfID.uuidString.prefix(8))
    }
    
    // MARK: - Actions
    
    private func triggerExport() {
        isExporting = true
        Task {
            do {
                let zipURL = try await ZettelkastenExporter.shared.exportToMarkdownZip(annotations: activeAnnotations, pdfs: allPDFs)
                let data = try Data(contentsOf: zipURL)
                
                await MainActor.run {
                    self.exportDocument = ZettelArchiveDocument(zipData: data)
                    self.isExporting = false
                    self.showingExporterDialog = true
                }
            } catch {
                await MainActor.run {
                    self.isExporting = false
                    self.importMessage = "Export failed: \(error.localizedDescription)"
                }
            }
        }
    }
    
    private func handleCSVImport(result: Result<[URL], Error>) {
        if case .success(let urls) = result, let url = urls.first {
            isImporting = true
            
            let container = self.modelContext.container
            
            Task.detached(priority: .userInitiated) {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                
                do {
                    let backgroundContext = ModelContext(container)
                    let count = try await ReadwiseImportService.shared.importReadwiseCSV(from: url, context: backgroundContext)
                    
                    await MainActor.run {
                        self.isImporting = false
                        self.importMessage = "Successfully imported \(count) highlights from Readwise."
                    }
                } catch {
                    await MainActor.run {
                        self.isImporting = false
                        self.importMessage = "Import Failed: \(error.localizedDescription)"
                    }
                }
            }
        }
    }
}

struct GlobalHighlightRow: View {
    let annotation: SDAnnotation
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let text = annotation.selectedText, !text.isEmpty {
                Text(text)
                    .font(.body)
                    .foregroundColor(.primary)
            }
            if let note = annotation.noteText, !note.isEmpty {
                HStack(alignment: .top) {
                    Divider()
                        .frame(width: 3)
                        .background(Color.blue)
                    Text(note)
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .padding(.leading, 4)
                }
            }
            
            // Auto Tags System Support
            if let tags = annotation.tags, !tags.isEmpty {
                HStack {
                    ForEach(tags, id: \.self) { tag in
                        Text("#\(tag)")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.2))
                            .foregroundColor(.orange)
                            .cornerRadius(4)
                    }
                }
                .padding(.top, 4)
            }
            
            HStack {
                if annotation.isReadwiseImport {
                    Image(systemName: "bird.fill")
                        .font(.caption2)
                        .foregroundColor(.blue)
                }
                Text(annotation.modifiedAt, style: .date)
                    .font(.caption2)
                    .foregroundColor(.gray)
                Spacer()
            }
            .padding(.top, 4)
        }
        .padding()
    }
}
