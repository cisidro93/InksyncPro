import SwiftUI
import SwiftData
import UniformTypeIdentifiers

enum ZettelViewMode { case list, map, corkboard }
enum ZettelFilterMode { case all, annotated, highlightsOnly }
enum ZettelSortMode: String, CaseIterable {
    case dateModified = "Date Modified"
    case dateAdded    = "Date Added"
    case bookName     = "Book Name"
    case tagCount     = "Most Tagged"
}

struct GlobalZettelkastenHubView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    
    // Sort all annotations latest over all PDF IDs
    @Query(sort: \SDAnnotation.modifiedAt, order: .reverse) private var allAnnotations: [SDAnnotation]
    @Query private var allPDFs: [SDConvertedPDF]
    
    @State private var searchText = ""
    @State private var viewMode: ZettelViewMode = .list
    @State private var filterMode: ZettelFilterMode = .all
    @State private var sortMode: ZettelSortMode = .dateModified
    

    @State private var isImporting = false
    @State private var isExporting = false
    @State private var importMessage: String? = nil
    
    @State private var exportDocument: ZettelArchiveDocument?
    @State private var showingExporterDialog = false
    @State private var showingDailyReview = false
    @State private var showingMarkdownExporter = false
    @State private var markdownExportURL: URL? = nil
    
    private var dueCount: Int {
        let now = Date()
        return allAnnotations.filter { $0.kindRaw == "highlight" && ($0.nextReviewDate == nil || $0.nextReviewDate! <= now) }.count
    }
    
    // Filtered + Sorted Annotations
    var activeAnnotations: [SDAnnotation] {
        var filtered = allAnnotations

        // Filter (user-friendly labels, same underlying logic)
        switch filterMode {
        case .all:            break
        case .annotated:      filtered = filtered.filter { $0.noteText != nil && !($0.noteText!.isEmpty) }
        case .highlightsOnly: filtered = filtered.filter { $0.noteText == nil || $0.noteText!.isEmpty }
        }

        // Search
        if !searchText.isEmpty {
            let cache = makePDFNameCache()
            filtered = filtered.filter { ann in
                let txt  = ann.selectedText?.localizedCaseInsensitiveContains(searchText) ?? false
                let note = ann.noteText?.localizedCaseInsensitiveContains(searchText) ?? false
                let book = bookTitle(for: ann, cache: cache).localizedCaseInsensitiveContains(searchText)
                return txt || note || book
            }
        }

        // Sort
        let cache = makePDFNameCache()
        switch sortMode {
        case .dateModified: break  // already sorted by @Query
        case .dateAdded:    filtered.sort { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
        case .bookName:     filtered.sort { bookTitle(for: $0, cache: cache) < bookTitle(for: $1, cache: cache) }
        case .tagCount:     filtered.sort { ($0.tags?.count ?? 0) > ($1.tags?.count ?? 0) }
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
            Color.inkBackground.ignoresSafeArea()

            if allAnnotations.isEmpty {
                emptyStateView
            } else {
                VStack(spacing: 0) {
                    // ── View Mode Toggle: frosted capsule pills (matches app design language)
                    HStack(spacing: 0) {
                        viewModePill(.list,      label: "List",      icon: "list.bullet")
                        viewModePill(.corkboard, label: "Corkboard", icon: "square.grid.3x3")
                        viewModePill(.map,       label: "Mind Map",  icon: "point.3.connected.trianglepath.dotted")
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)

                    if viewMode == .list {
                        if dueCount > 0 {
                            Button {
                                showingDailyReview = true
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Daily Review Due")
                                            .font(.headline)
                                        Text("\(dueCount) highlights waiting to be reviewed")
                                            .font(.subheadline)
                                            .foregroundStyle(Theme.textSecondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .foregroundStyle(Theme.textSecondary)
                                }
                                .padding()
                                .background(Theme.surface)
                                .cornerRadius(12)
                                .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal)
                            .padding(.top, 12)
                        }

                        // ── Filter pill strip (user-friendly labels)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                filterPill(.all,            label: "All",             icon: "note.text")
                                filterPill(.annotated,      label: "Annotated",       icon: "text.bubble.fill")
                                filterPill(.highlightsOnly, label: "Highlights Only", icon: "highlighter")
                            }
                            .padding(.horizontal)
                        }
                        .padding(.top, 10)
                        .padding(.bottom, 4)

                        ScrollView {
                            LazyVStack(spacing: 20, pinnedViews: []) {
                                ForEach(groupedAnnotations, id: \.key) { group in
                                    VStack(alignment: .leading, spacing: 10) {
                                        // ── Lightweight section header (Readwise-style)
                                        HStack(spacing: 8) {
                                            Rectangle()
                                                .fill(Color.primary.opacity(0.08))
                                                .frame(height: 1)
                                            HStack(spacing: 5) {
                                                Image(systemName: group.value.first?.isReadwiseImport == true
                                                      ? "bird.fill" : "book.closed.fill")
                                                    .font(.system(size: 9, weight: .bold))
                                                    .foregroundColor(group.value.first?.isReadwiseImport == true
                                                                     ? .blue : Theme.textSecondary)
                                                Text(group.key)
                                                    .font(.system(size: 11, weight: .semibold))
                                                    .foregroundColor(Theme.textSecondary)
                                                    .lineLimit(1)
                                                Text("\(group.value.count)")
                                                    .font(.system(size: 10, weight: .bold, design: .rounded))
                                                    .foregroundColor(.white)
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 2)
                                                    .background(Color.primary.opacity(0.2), in: Capsule())
                                            }
                                            .fixedSize()
                                        }
                                        .padding(.horizontal)
                                        .padding(.top, 8)

                                        // Group Items
                                        VStack(spacing: 10) {
                                            ForEach(group.value) { item in
                                                GlobalHighlightRow(annotation: item)
                                            }
                                        }
                                        .padding(.horizontal)
                                    }
                                }
                            }
                            .padding(.vertical)
                        }
                    } else if viewMode == .map {
                        ZettelkastenGraphView(annotations: activeAnnotations, pdfs: allPDFs)
                    } else if viewMode == .corkboard {
                        ZettelkastenCorkboardView(annotations: activeAnnotations, pdfs: allPDFs)
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
                    // Sort options
                    Section("Sort By") {
                        Picker("Sort", selection: $sortMode) {
                            ForEach(ZettelSortMode.allCases, id: \.self) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                    }
                    // Data actions
                    Section {
                        Button(action: {
                            ImportCoordinator.present(type: .smartList) { urls in
                                if let first = urls.first { handleCSVImport(result: .success([first])) }
                            }
                        }) {
                            Label("Import Readwise", systemImage: "arrow.down.doc")
                        }
                        Button(action: triggerExport) {
                            Label("Export Mind Palace", systemImage: "square.and.arrow.up")
                        }
                        Button(action: exportAsMarkdown) {
                            Label("Export Highlights as Markdown", systemImage: "doc.plaintext")
                        }
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
                VStack(spacing: 12) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(Color(hex: "#7B5EA7"))
                        .controlSize(.large)
                    Text(isImporting ? "Importing Readwise…" : "Compiling Mind Palace…")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.text)
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 24)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .shadow(color: .black.opacity(0.15), radius: 20, y: 8)
            }
        }
        .alert("Status", isPresented: Binding(get: { importMessage != nil }, set: { if !$0 { importMessage = nil } })) {
            Button("OK") { importMessage = nil }
        } message: {
            Text(importMessage ?? "")
        }
        .sheet(isPresented: $showingDailyReview) {
            DailyReviewView()
        }
    }
    
    // MARK: - View Mode Pill (frosted capsule — matches app design language)
    @ViewBuilder
    private func viewModePill(_ mode: ZettelViewMode, label: String, icon: String) -> some View {
        Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) { viewMode = mode }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(viewMode == mode ? Color.white : Theme.textSecondary)
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(
                viewMode == mode
                    ? AnyShapeStyle(Color(hex: "#7B5EA7"))
                    : AnyShapeStyle(.regularMaterial)
            )
        }
        .buttonStyle(.plain)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
    }

    // MARK: - Filter Pill
    @ViewBuilder
    private func filterPill(_ mode: ZettelFilterMode, label: String, icon: String) -> some View {
        Button {
            withAnimation(.spring(response: 0.28)) { filterMode = mode }
        } label: {
            Label(label, systemImage: icon)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(filterMode == mode ? AnyShapeStyle(Color(hex: "#7B5EA7")) : AnyShapeStyle(.regularMaterial))
                .foregroundStyle(filterMode == mode ? Color.white : Theme.textSecondary)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Color.primary.opacity(filterMode == mode ? 0 : 0.08), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Empty State
    private var emptyStateView: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color(hex: "#7B5EA7").opacity(0.2), Color.clear],
                            center: .center, startRadius: 0, endRadius: 60
                        )
                    )
                    .frame(width: 120, height: 120)
                Image(systemName: "brain.filled.head.profile")
                    .font(.system(size: 52))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color(hex: "#7B5EA7"), Color(hex: "#B39DDB")],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
            }
            VStack(spacing: 8) {
                Text("Your Mind Palace is Empty")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.text)
                Text("Every highlight, annotation, and note from your books lives here — connected, searchable, and yours forever.")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            Button {
                ImportCoordinator.present(type: .smartList) { urls in
                    if let first = urls.first { handleCSVImport(result: .success([first])) }
                }
            } label: {
                Label("Import from Readwise", systemImage: "arrow.down.doc.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.vertical, 14)
                    .padding(.horizontal, 28)
                    .background(
                        LinearGradient(
                            colors: [Color(hex: "#7B5EA7"), Color(hex: "#9C6BC4")],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                    .clipShape(Capsule())
                    .shadow(color: Color(hex: "#7B5EA7").opacity(0.35), radius: 12, y: 6)
            }
            .buttonStyle(.plain)
            Text("Start by highlighting in the reader, or import your Readwise CSV export.")
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    /// Renders all highlights grouped by book as a Markdown document and presents
    /// a share sheet so the user can send it to Obsidian, Bear, Notion, Mail, etc.
    private func exportAsMarkdown() {
        let dateFormatter: DateFormatter = {
            let df = DateFormatter()
            df.dateStyle = .medium
            df.timeStyle = .none
            return df
        }()

        var md = "# InksyncPro — Highlights & Notes\n"
        md += "_Exported \(dateFormatter.string(from: Date()))_\n\n---\n\n"

        for group in groupedAnnotations {
            md += "## \(group.key)\n\n"
            for ann in group.value {
                // Highlight text
                if let text = ann.selectedText, !text.isEmpty {
                    md += "> \(text)\n"
                }
                // Attached note
                if let note = ann.noteText, !note.isEmpty {
                    md += "\n**Note:** \(note)\n"
                }
                // Tags
                if let tags = ann.tags, !tags.isEmpty {
                    md += "\n" + tags.map { "#\($0)" }.joined(separator: " ") + "\n"
                }
                // Page reference
                if let page = ann.pageIndex {
                    md += "\n_p. \(page + 1)_\n"
                }
                md += "\n---\n\n"
            }
        }

        // Write to temp file
        let filename = "InksyncPro_Highlights_\(Int(Date().timeIntervalSince1970)).md"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        guard let data = md.data(using: .utf8),
              (try? data.write(to: tempURL)) != nil else {
            importMessage = "Markdown export failed — could not write file."
            return
        }

        // Share sheet
        let activityVC = UIActivityViewController(activityItems: [tempURL], applicationActivities: nil)
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = windowScene.windows.first?.rootViewController {
            var topVC = rootVC
            while let presented = topVC.presentedViewController { topVC = presented }
            if let popover = activityVC.popoverPresentationController {
                popover.sourceView = topVC.view
                popover.sourceRect = CGRect(x: topVC.view.bounds.midX, y: topVC.view.bounds.midY, width: 0, height: 0)
                popover.permittedArrowDirections = []
            }
            topVC.present(activityVC, animated: true)
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
    
    @Environment(\.modelContext) private var modelContext
    @State private var showingEdit = false
    @Query private var manuscriptProjects: [SDManuscriptProject]

    // User-applied tags (excludes Readwise source tags already shown via readwiseTags)
    private var userTags: [String] {
        let rwSet = Set((annotation.readwiseTags ?? []) + (annotation.readwiseDocumentTags ?? []))
        return (annotation.tags ?? []).filter { !rwSet.contains($0) }
    }

    var body: some View {
        Button { showingEdit = true } label: {
            VStack(alignment: .leading, spacing: 8) {

                // Highlight text with left color bar
                HStack(alignment: .top, spacing: 0) {
                    if let hex = annotation.colorHex {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color(hex: hex))
                            .frame(width: 4)
                            .padding(.vertical, 2)
                    }
                    if let text = annotation.selectedText, !text.isEmpty {
                        Text(text)
                            .font(.system(size: 16, weight: .regular, design: .serif))
                            .foregroundStyle(.primary)
                            .lineSpacing(4)
                            .padding(.leading, 12)
                    }
                }

                // User's thought (noteText)
                if let note = annotation.noteText, !note.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "text.bubble.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(Color.accentColor)
                                .padding(.top, 2)
                            Text(note)
                                .font(.system(size: 15, weight: .medium, design: .rounded))
                                .foregroundStyle(Color.accentColor)
                                .lineSpacing(2)
                        }
                    }
                    .padding(12)
                    .background(Color.accentColor.opacity(0.08))
                    .cornerRadius(10)
                    .padding(.top, 4)
                }

                // Tags row — cap at 3 visible + overflow pill
                let rwTags = annotation.readwiseTags ?? []
                let allTags = userTags.map { ($0, Color.orange) } + rwTags.map { ($0, Color.blue) }
                if !allTags.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(Array(allTags.prefix(3)), id: \.0) { (tag, color) in
                            TagPill(tag: tag, color: color)
                        }
                        if allTags.count > 3 {
                            Text("+\(allTags.count - 3)")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Theme.textSecondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.primary.opacity(0.07), in: Capsule())
                        }
                    }
                    .padding(.top, 2)
                }

                // Footer
                HStack(spacing: 5) {
                    if annotation.isReadwiseImport {
                        Image(systemName: "bird.fill")
                            .font(.caption2)
                            .foregroundStyle(.blue)
                    }
                    Text(annotation.modifiedAt, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text("ago")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Image(systemName: "pencil")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.top, 6)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Theme.surface)
                    .shadow(color: Color.black.opacity(0.06), radius: 10, x: 0, y: 4)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Menu("Send to Manuscript...") {
                if manuscriptProjects.isEmpty {
                    Text("No Writing Projects Found")
                } else {
                    ForEach(manuscriptProjects) { project in
                        Menu(project.title) {
                            ForEach(project.documents) { doc in
                                Button(doc.title) {
                                    if !doc.attachedNoteIDs.contains(annotation.id.uuidString) {
                                        doc.attachedNoteIDs.append(annotation.id.uuidString)
                                        try? modelContext.save()
                                        HapticEngine.success()
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showingEdit) {
            AnnotationEditSheet(annotation: annotation)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }
}

// Small inline chip that doesn't need removal capability
private struct TagPill: View {
    let tag: String
    let color: Color
    var body: some View {
        Text("#\(tag)")
            .font(.caption2)
            .fontWeight(.medium)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }
}

