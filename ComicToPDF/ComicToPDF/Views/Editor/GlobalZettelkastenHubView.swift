import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct GlobalZettelkastenHubView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    
    // Sort all annotations latest over all PDF IDs
    @Query(sort: \SDAnnotation.modifiedAt, order: .reverse) private var allAnnotations: [SDAnnotation]
    
    @State private var searchText = ""
    @State private var showingReadwiseImporter = false
    @State private var isImporting = false
    @State private var importMessage: String? = nil
    
    // Group Highlights by Book (Native PDFs and Readwise Synced Books)
    var groupedAnnotations: [(key: String, value: [SDAnnotation])] {
        var filtered = allAnnotations
        if !searchText.isEmpty {
            filtered = filtered.filter { ann in
                let txt = ann.selectedText?.localizedCaseInsensitiveContains(searchText) ?? false
                let note = ann.noteText?.localizedCaseInsensitiveContains(searchText) ?? false
                let book = (ann.readwiseBookTitle ?? ann.pdfID.uuidString).localizedCaseInsensitiveContains(searchText)
                return txt || note || book
            }
        }
        
        let dict = Dictionary(grouping: filtered) { ann -> String in
            // If it's a Readwise import, group by its explicit title, else group by its PDF ID (which acts as title fallback for now)
            return ann.readwiseBookTitle ?? ann.pdfID.uuidString
        }
        return dict.sorted { $0.key < $1.key }
    }
    
    var body: some View {
        ZStack {
            Color(UIColor.systemGroupedBackground).edgesIgnoringSafeArea(.all)
            
            if allAnnotations.isEmpty {
                emptyStateView
            } else {
                ScrollView {
                    LazyVStack(spacing: 24, pinnedViews: []) {
                        ForEach(groupedAnnotations, id: \.key) { group in
                            VStack(alignment: .leading, spacing: 12) {
                                // Group Header
                                HStack {
                                    Image(systemName: group.value.first?.isReadwiseImport == true ? "books.vertical.fill" : "book.closed.fill")
                                        .foregroundColor(group.value.first?.isReadwiseImport == true ? .yellow : .blue)
                                    Text(bookTitle(for: group.value.first))
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
            }
        }
        .navigationTitle("Zettelkasten Hub")
        .searchable(text: $searchText, prompt: "Search all highlights & notes...")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: { showingReadwiseImporter.toggle() }) {
                    Label("Import Readwise", systemImage: "arrow.down.doc.fill")
                }
            }
        }
        .fileImporter(
            isPresented: $showingReadwiseImporter,
            allowedContentTypes: [UTType.commaSeparatedText, UTType.plainText, UTType.text, UTType.data],
            allowsMultipleSelection: false
        ) { result in
            handleCSVImport(result: result)
        }
        .overlay {
            if isImporting {
                ProgressView("Importing Readwise Database...")
                    .padding()
                    .background(.ultraThinMaterial)
                    .cornerRadius(12)
            }
        }
        .alert(isPresented: Binding<Bool>(
            get: { importMessage != nil },
            set: { if !$0 { importMessage = nil } }
        )) {
            Alert(title: Text("Import Status"), message: Text(importMessage ?? ""), dismissButton: .default(Text("OK")))
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
            
            Button(action: { showingReadwiseImporter.toggle() }) {
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
    
    private func bookTitle(for annotation: SDAnnotation?) -> String {
        guard let ann = annotation else { return "Unknown Book" }
        if let title = ann.readwiseBookTitle { return title }
        // For native PDFs, we would dynamically fetch the ConversionManager instance if needed,
        // but since we only have the ID here, we use a simple clean format.
        // A robust app would join the SwiftData `SDConvertedPDF` table.
        return "Book ID: " + String(ann.pdfID.uuidString.prefix(8)) 
    }
    
    private func handleCSVImport(result: Result<[URL], Error>) {
        if case .success(let urls) = result, let url = urls.first {
            isImporting = true
            
            // Unpack SwiftData Container securely for background Actor injection
            let container = self.modelContext.container
            
            Task.detached(priority: .userInitiated) {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                
                do {
                    // Phase 32 Fix: Initialize an isolated context off the MainActor
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
