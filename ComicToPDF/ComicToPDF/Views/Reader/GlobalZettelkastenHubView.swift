import SwiftUI
import SwiftData
import UniformTypeIdentifiers

enum ZettelViewMode { case list, map, board, tags }
enum ZettelFilterMode { case all, annotated, highlightsOnly }
enum ZettelSortMode: String, CaseIterable {
    case dateModified = "Date Modified"
    case dateAdded    = "Date Added"
    case bookName     = "Book Name"
    case tagCount     = "Most Tagged"
    case byTopic      = "By Topic"
}

struct GlobalZettelkastenHubView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Binding var activeTab: GlobalNotebookView.Tab
    @EnvironmentObject var conversionManager: ConversionManager
    
    // Sort all annotations latest over all PDF IDs
    @Query(sort: \SDAnnotation.modifiedAt, order: .reverse) private var allAnnotations: [SDAnnotation]
    @Query private var allPDFs: [SDConvertedPDF]
    
    @State private var searchText = ""
    @State private var viewMode: ZettelViewMode = .list
    @State private var filterMode: ZettelFilterMode = .all
    @State private var sortMode: ZettelSortMode = .dateModified
    @State private var collapsedSections: Set<String> = []

    // ── PERF C1: Cached derived state ──────────────────────────────────────
    // Previously these were all plain computed properties re-evaluated on every
    // body call. Now rebuilt only when allAnnotations/allPDFs/filter/sort/search
    // actually change — O(N) work runs once, not 6× per keystroke.
    @State private var cachedActiveAnnotations: [SDAnnotation] = []
    @State private var cachedGroupedAnnotations: [(key: String, value: [SDAnnotation])] = []
    @State private var cachedDueCount: Int = 0
    @State private var cachedTotalBookCount: Int = 0
    // Composite key for change detection — avoids redundant rebuilds
    private var cacheInputKey: String {
        "\(allAnnotations.count)|\(allPDFs.count)|\(filterMode)|\(sortMode)|\(searchText)"
    }

    @State private var isImporting = false
    @State private var isExporting = false
    @State private var importMessage: String? = nil

    @State private var exportDocument: ZettelArchiveDocument?
    @State private var showingExporterDialog = false
    @State private var showingDailyReview = false
    @State private var showingMarkdownExporter = false
    @State private var markdownExportURL: URL? = nil
    @State private var showingCognitiveReflection = false
    @State private var selectedTagItem: TagExplorerItem? = nil

    // Phase 4B: iPad NavigationSplitView sidebar
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .automatic
    // ── PERF C1: Single rebuild function — called via .task(id: cacheInputKey) ─
    // Runs on a background priority task so the main thread stays free.
    private func rebuildCache() {
        let now = Date()
        // Build name lookup once
        var nameDict = [UUID: String]()
        for pdf in allPDFs { nameDict[pdf.id] = pdf.name }

        // --- active annotations ---
        var filtered = allAnnotations
        switch filterMode {
        case .all:            break
        case .annotated:      filtered = filtered.filter { $0.noteText?.isEmpty == false }
        case .highlightsOnly: filtered = filtered.filter { $0.noteText?.isEmpty ?? true }
        }
        if !searchText.isEmpty {
            filtered = filtered.filter { ann in
                let txt  = ann.selectedText?.localizedCaseInsensitiveContains(searchText) ?? false
                let note = ann.noteText?.localizedCaseInsensitiveContains(searchText) ?? false
                let ocr  = ann.drawingOCRText?.localizedCaseInsensitiveContains(searchText) ?? false
                let book = resolveTitle(ann, nameDict).localizedCaseInsensitiveContains(searchText)
                
                let allTags = (ann.tags ?? []) + (ann.readwiseTags ?? []) + (ann.readwiseDocumentTags ?? [])
                let tagMatch = allTags.contains { $0.localizedCaseInsensitiveContains(searchText) || $0.localizedCaseInsensitiveContains(searchText.replacingOccurrences(of: "#", with: "")) }
                
                return txt || note || ocr || book || tagMatch
            }
        }
        switch sortMode {
        case .dateModified: break
        case .dateAdded:    filtered.sort { $0.createdAt > $1.createdAt }
        case .bookName:     filtered.sort { resolveTitle($0, nameDict) < resolveTitle($1, nameDict) }
        case .tagCount:     filtered.sort { ($0.tags?.count ?? 0) > ($1.tags?.count ?? 0) }
        case .byTopic:      break
        }

        // --- grouped annotations ---
        let grouped: [(key: String, value: [SDAnnotation])]
        if sortMode == .byTopic {
            var dict: [String: [SDAnnotation]] = [:]
            for ann in filtered {
                let allTags = Set((ann.tags ?? []) + (ann.readwiseTags ?? []) + (ann.readwiseDocumentTags ?? []))
                if allTags.isEmpty {
                    dict["Untagged", default: []].append(ann)
                } else {
                    for tag in allTags {
                        dict[tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), default: []].append(ann)
                    }
                }
            }
            grouped = dict.sorted {
                if $0.key == "Untagged" { return false }
                if $1.key == "Untagged" { return true }
                return $0.key < $1.key
            }
        } else {
            let dict = Dictionary(grouping: filtered) { resolveTitle($0, nameDict) }
            grouped = dict.sorted { $0.key < $1.key }
        }

        // --- badge counts (use full unfiltered set) ---
        let due = allAnnotations.filter {
            $0.kindRaw == "highlight" && ($0.nextReviewDate == nil || $0.nextReviewDate! <= now)
        }.count
        let bookCount = Set(allAnnotations.map { resolveTitle($0, nameDict) }).count

        cachedActiveAnnotations  = filtered
        cachedGroupedAnnotations = grouped
        cachedDueCount           = due
        cachedTotalBookCount     = bookCount
    }

    // Inline title resolver — no heap allocation, no optional unwrapping chain
    private func resolveTitle(_ ann: SDAnnotation, _ nameDict: [UUID: String]) -> String {
        if let title = ann.readwiseBookTitle, !title.isEmpty, UUID(uuidString: title) == nil {
            return title
        }
        return nameDict[ann.pdfID] ?? "Book ID: " + String(ann.pdfID.uuidString.prefix(8))
    }
    
    var body: some View {
        hubContent
    }

    // MARK: - iPad Sidebar
    @ViewBuilder
    private var iPadSidebar: some View {
        List {
            // ── Stats card ────────────────────────────────────────────────
            Section {
                HStack(spacing: 16) {
                    statBadge(value: allAnnotations.count, label: "Highlights", icon: "highlighter", color: Color(hex: "#F5A623"))
                    Divider().frame(height: 44)
                    statBadge(value: cachedTotalBookCount, label: "Books", icon: "book.closed.fill", color: Color(hex: "#30D5C8"))
                    Divider().frame(height: 44)
                    statBadge(value: cachedDueCount, label: "Due", icon: "clock.badge.exclamationmark", color: Color(hex: "#BF5AF2"))
                }
                .padding(.vertical, 4)
            }

            // ── View mode ─────────────────────────────────────────────────
            Section("View") {
                viewModeSidebarRow(.list,  label: "List",       icon: "list.bullet")
                viewModeSidebarRow(.board, label: "Zettel Board", icon: "square.grid.2x2")
                viewModeSidebarRow(.map,   label: "Mind Map",   icon: "point.3.connected.trianglepath.dotted")
            }

            // ── Filter ────────────────────────────────────────────────────
            Section("Filter") {
                filterSidebarRow(.all,            label: "All Annotations",  icon: "note.text")
                filterSidebarRow(.annotated,      label: "Annotated Only",   icon: "text.bubble.fill")
                filterSidebarRow(.highlightsOnly, label: "Highlights Only",  icon: "highlighter")
            }

            // ── Sort ──────────────────────────────────────────────────────
            Section("Sort By") {
                ForEach(ZettelSortMode.allCases, id: \.self) { mode in
                    Button {
                        sortMode = mode
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } label: {
                        Label(mode.rawValue, systemImage: sortMode == mode ? "checkmark" : "")
                            .foregroundStyle(sortMode == mode ? Color.inkAccentKnowledge : Color.inkTextPrimary)
                    }
                }
            }

            // ── Daily Review shortcut ─────────────────────────────────────
            if cachedDueCount > 0 {
                Section {
                    Button {
                        showingDailyReview = true
                    } label: {
                        Label("\(cachedDueCount) Due for Review", systemImage: "clock.badge.exclamationmark.fill")
                            .foregroundStyle(Color(hex: "#BF5AF2"))
                    }
                }
            }
            
            // ── Exit to Notebooks shortcut ─────────────────────────────────────
            Section {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.76)) {
                        activeTab = .notebooks
                    }
                } label: {
                    Label("Exit to Notebooks", systemImage: "arrow.left.circle.fill")
                        .foregroundStyle(Color.orange)
                        .fontWeight(.semibold)
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private func statBadge(value: Int, label: String, icon: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(color)
            Text("\(value)")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(Color.inkTextPrimary)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.inkTextSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func viewModeSidebarRow(_ mode: ZettelViewMode, label: String, icon: String) -> some View {
        Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) { viewMode = mode }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            Label(label, systemImage: icon)
                .foregroundStyle(viewMode == mode ? Color.inkAccentKnowledge : Color.inkTextPrimary)
                .fontWeight(viewMode == mode ? .semibold : .regular)
        }
    }

    @ViewBuilder
    private func filterSidebarRow(_ mode: ZettelFilterMode, label: String, icon: String) -> some View {
        Button {
            filterMode = mode
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            Label(label, systemImage: icon)
                .foregroundStyle(filterMode == mode ? Color.inkAccentKnowledge : Color.inkTextPrimary)
                .fontWeight(filterMode == mode ? .semibold : .regular)
        }
    }

    // MARK: - Main Content (shared by both iPhone and iPad)
    @ViewBuilder
    private var hubContent: some View {
        ZStack {
            Color.clear.ignoresSafeArea()

            if allAnnotations.isEmpty {
                emptyStateView
            } else {
                VStack(spacing: 0) {
                    // ── View Mode Toggle: frosted capsule pills (matches app design language)
                    HStack {
                        if hSizeClass == .regular { Spacer() }
                        HStack(spacing: 0) {
                            viewModePill(.list,      label: "List",      icon: "list.bullet")
                            viewModePill(.board,     label: "Zettel Board", icon: "square.grid.2x2")
                            viewModePill(.map,       label: "Mind Map",  icon: "point.3.connected.trianglepath.dotted")
                            viewModePill(.tags,      label: "Tags",      icon: "tag.fill")
                        }
                        .frame(maxWidth: hSizeClass == .regular ? 600 : .infinity)
                        if hSizeClass == .regular { Spacer() }
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)

                    if viewMode == .list {
                        if cachedDueCount > 0 {
                            Button {
                                showingDailyReview = true
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Daily Review Due")
                                            .font(.headline)
                                        Text("\(cachedDueCount) highlights waiting to be reviewed")
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
                        Group {
                            if hSizeClass == .regular {
                                HStack(spacing: 8) {
                                    Spacer()
                                    filterPill(.all,            label: "All",             icon: "note.text")
                                    filterPill(.annotated,      label: "Annotated",       icon: "text.bubble.fill")
                                    filterPill(.highlightsOnly, label: "Highlights Only", icon: "highlighter")
                                    Spacer()
                                }
                            } else {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 8) {
                                        filterPill(.all,            label: "All",             icon: "note.text")
                                        filterPill(.annotated,      label: "Annotated",       icon: "text.bubble.fill")
                                        filterPill(.highlightsOnly, label: "Highlights Only", icon: "highlighter")
                                    }
                                    .padding(.horizontal)
                                }
                            }
                        }
                        .padding(.top, 10)
                        .padding(.bottom, 4)

                        ScrollViewReader { proxy in
                            ZStack(alignment: .trailing) {
                                ScrollView {
                                    LazyVStack(spacing: 20, pinnedViews: []) {
                                        ForEach(cachedGroupedAnnotations, id: \.key) { group in
                                            VStack(alignment: .leading, spacing: 10) {
                                                // ── Lightweight section header (Readwise-style)
                                                Button {
                                                    withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                                                        if collapsedSections.contains(group.key) {
                                                            collapsedSections.remove(group.key)
                                                        } else {
                                                            collapsedSections.insert(group.key)
                                                        }
                                                    }
                                                } label: {
                                                    HStack(spacing: 8) {
                                                        HStack(spacing: 5) {
                                                            Image(systemName: sortMode == .byTopic ? "tag.fill" : (group.value.first?.isReadwiseImport == true ? "bird.fill" : "book.closed.fill"))
                                                                .font(.system(size: 9, weight: .bold))
                                                                .foregroundColor(sortMode == .byTopic ? .orange : (group.value.first?.isReadwiseImport == true ? .blue : Theme.textSecondary))
                                                            Text(sortMode == .byTopic ? "#\(group.key)" : group.key)
                                                                .font(.system(size: 11, weight: .semibold))
                                                                .foregroundColor(Theme.textSecondary)
                                                                .lineLimit(1)
                                                                .truncationMode(.tail)
                                                            Text("\(group.value.count)")
                                                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                                                .foregroundColor(.white)
                                                                .padding(.horizontal, 6)
                                                                .padding(.vertical, 2)
                                                                .background(Color.primary.opacity(0.2), in: Capsule())
                                                            Image(systemName: collapsedSections.contains(group.key) ? "chevron.down" : "chevron.up")
                                                                .font(.system(size: 9, weight: .bold))
                                                                .foregroundColor(Theme.textSecondary)
                                                        }
                                                        Rectangle()
                                                            .fill(Color.primary.opacity(0.08))
                                                            .frame(height: 1)
                                                    }
                                                    .padding(.horizontal)
                                                    .padding(.top, 8)
                                                }
                                                .buttonStyle(.plain)
                                                .id(String(group.key.prefix(1)).uppercased())

                                                // Group Items — LazyVStack (PERF C2: was eager VStack)
                                                if !collapsedSections.contains(group.key) {
                                                    LazyVStack(spacing: 10) {
                                                        ForEach(group.value) { item in
                                                            GlobalHighlightRow(annotation: item, searchText: searchText)
                                                        }
                                                    }
                                                    .padding(.horizontal)
                                                    .transition(.opacity.combined(with: .move(edge: .top)))
                                                }
                                            }
                                        }
                                    }
                                    .padding(.vertical)
                                }
                                
                                // Index Bar
                                if cachedGroupedAnnotations.count > 10 {
                                    VStack(spacing: 2) {
                                        let letters = Array(Set(cachedGroupedAnnotations.map { String($0.key.prefix(1)).uppercased() })).sorted()
                                        ForEach(letters, id: \.self) { letter in
                                            Text(letter)
                                                .font(.system(size: 11, weight: .bold))
                                                .foregroundColor(Theme.blue)
                                                .frame(width: 22, height: 22)
                                                .contentShape(Rectangle())
                                                .onTapGesture {
                                                    withAnimation { proxy.scrollTo(letter, anchor: .top) }
                                                }
                                        }
                                    }
                                    .padding(.vertical, 8)
                                    .background(.ultraThinMaterial, in: Capsule())
                                    .padding(.trailing, 4)
                                }
                            }
                        }
                    } else if viewMode == .map {
                        ZettelkastenGraphView(annotations: cachedActiveAnnotations, pdfs: allPDFs)
                    } else if viewMode == .board {
                        ZettelkastenBoardView(annotations: cachedActiveAnnotations, pdfs: allPDFs)
                    } else if viewMode == .tags {
                        tagExplorerGrid
                    }
                }
            }
        }
        .navigationTitle("Zettelkasten Hub")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $searchText, prompt: "Search all highlights & notes...")
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.76)) {
                        activeTab = .notebooks
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Notebooks")
                    }
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundColor(.orange)
                }
            }
            
            // Stat indicators — mirrors Library's "N FILES • N SERIES" pattern
            ToolbarItem(placement: .principal) {
                VStack(spacing: 2) {
                    Text("Zettelkasten Hub")
                        .font(.headline)
                        .foregroundColor(.primary)
                    if !allAnnotations.isEmpty {
                        Text("\(allAnnotations.count) HIGHLIGHTS • \(cachedTotalBookCount) BOOKS")
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
                    Section("Organize") {
                        Button(action: { sortMode = .byTopic }) {
                            Label("Group by Topic", systemImage: "tag.fill")
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
                    
                    Section("Reflection") {
                        Button(action: { showingCognitiveReflection = true }) {
                            Label("Cognitive Reflection", systemImage: "brain.head.profile")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }

        // ── PERF C1: Rebuild cache when any input changes ─────────────────
        .task(id: cacheInputKey) { rebuildCache() }
        .task(id: allAnnotations.count) { rebuildCache() }  // also catches SwiftData inserts
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
        .fullScreenCover(isPresented: $showingDailyReview) {
            DailyReviewView()
        }
        .fullScreenCover(isPresented: $showingCognitiveReflection) {
            CognitiveReflectionView()
        }
        .sheet(item: $selectedTagItem) { item in
            TagDetailSheet(tag: item.tag, annotations: item.annotations)
                .environment(\.modelContext, modelContext)
                .environmentObject(conversionManager)
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

    private var explorerTags: [TagExplorerItem] {
        var dict = [String: [SDAnnotation]]()
        for ann in cachedActiveAnnotations {
            let allTags = (ann.tags ?? []) + (ann.readwiseTags ?? []) + (ann.readwiseDocumentTags ?? [])
            let uniqueTags = Set(allTags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
            
            if uniqueTags.isEmpty {
                dict["Untagged", default: []].append(ann)
            } else {
                for tag in uniqueTags {
                    if let existingKey = dict.keys.first(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
                        dict[existingKey]?.append(ann)
                    } else {
                        dict[tag] = [ann]
                    }
                }
            }
        }
        return dict.map { TagExplorerItem(tag: $0.key, annotations: $0.value) }
            .sorted {
                if $0.tag == "Untagged" { return false }
                if $1.tag == "Untagged" { return true }
                return $0.tag.localizedStandardCompare($1.tag) == .orderedAscending
            }
    }

    private var tagExplorerGrid: some View {
        let tags = explorerTags
        return ScrollView {
            if tags.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "tag.slash")
                        .font(.system(size: 40))
                        .foregroundColor(Theme.textSecondary)
                    Text("No Tags Found")
                        .font(.headline)
                        .foregroundColor(Theme.text)
                }
                .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                LazyVGrid(columns: [
                    GridItem(.adaptive(minimum: hSizeClass == .regular ? 200 : 150), spacing: 14)
                ], spacing: 14) {
                    ForEach(tags) { item in
                        Button {
                            HapticEngine.light()
                            selectedTagItem = item
                        } label: {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Image(systemName: "tag.circle.fill")
                                        .font(.system(size: 20))
                                        .foregroundColor(Theme.purple)
                                    Spacer()
                                    Text("\(item.annotations.count)")
                                        .font(.system(size: 11, weight: .bold, design: .rounded))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Theme.purple.opacity(0.85), in: Capsule())
                                }
                                
                                Text("#" + item.tag)
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(Theme.text)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                
                                Text("\(item.annotations.count) " + (item.annotations.count == 1 ? "highlight" : "highlights"))
                                    .font(.system(size: 11))
                                    .foregroundColor(Theme.textSecondary)
                            }
                            .padding()
                            .background(
                                RoundedRectangle(cornerRadius: 16)
                                    .fill(Theme.surface)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 16)
                                    .stroke(Color.primary.opacity(0.06), lineWidth: 0.8)
                            )
                            .shadow(color: Color.black.opacity(0.04), radius: 6, y: 3)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
        }
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
    
    // bookTitle kept for any call sites in exportAsMarkdown (uses groupedAnnotations key which is already resolved)
    private func bookTitle(for annotation: SDAnnotation?, cache: [UUID: String]? = nil) -> String {
        guard let ann = annotation else { return "Unknown Book" }
        let nameDict = cache ?? { var d = [UUID:String](); for p in allPDFs { d[p.id] = p.name }; return d }()
        return resolveTitle(ann, nameDict)
    }
    
    // MARK: - Actions
    
    private func triggerExport() {
        isExporting = true
        Task {
            do {
                let zipURL = try await ZettelkastenExporter.shared.exportToMarkdownZip(annotations: cachedActiveAnnotations.map { $0.toDTO() }, pdfs: allPDFs.map { $0.toDTO() })
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

        for group in cachedGroupedAnnotations {
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
                let page = ann.pageIndex
                md += "\n_p. \(page + 1)_\n"
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
    var searchText: String = ""
    
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject var conversionManager: ConversionManager   // Item 7: jump-to-source
    @State private var showingEdit = false
    @State private var showingArchiveAlert = false
    @Query private var manuscriptProjects: [SDManuscriptProject]

    // User-applied tags (excludes Readwise source tags already shown via readwiseTags)
    private var userTags: [String] {
        let rwSet = Set((annotation.readwiseTags ?? []) + (annotation.readwiseDocumentTags ?? []))
        return (annotation.tags ?? []).filter { !rwSet.contains($0) }
    }

    private var sourceTitle: String {
        if let rwTitle = annotation.readwiseBookTitle, !rwTitle.isEmpty {
            return rwTitle
        }
        if let matchedPDF = conversionManager.convertedPDFs.first(where: { $0.id == annotation.pdfID }) {
            return matchedPDF.name
        }
        return "Unknown Source"
    }

    // Helper to highlight searched query words inside text views
    private func highlightedText(_ fullText: String) -> Text {
        guard !searchText.isEmpty else { return Text(fullText) }
        
        var attrString = AttributedString(fullText)
        let query = searchText
        
        var searchRange = attrString.startIndex..<attrString.endIndex
        while let range = attrString[searchRange].range(of: query, options: .caseInsensitive) {
            attrString[range].backgroundColor = Color(hex: "#7B5EA7").opacity(0.24)
            attrString[range].inlinePresentationIntent = .stronglyEmphasized // Bold
            
            searchRange = range.upperBound..<attrString.endIndex
        }
        
        return Text(attrString)
    }

    var body: some View {
        Button {
            if let matchedPDF = conversionManager.convertedPDFs.first(where: { $0.id == annotation.pdfID }) {
                HapticEngine.medium()
                AppRouter.shared.presentFullScreen(.read(matchedPDF))
                // Post notification to jump to page index after presentation completes
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    NotificationCenter.default.post(
                        name: NSNotification.Name("Reader_JumpToPage"),
                        object: nil,
                        userInfo: ["pageIndex": annotation.pageIndex]
                    )
                }
            } else {
                HapticEngine.light()
                showingArchiveAlert = true
            }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                // Header with Document details & Source Badge
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(sourceTitle)
                            .font(.system(size: 11, weight: .semibold, design: .default))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                        
                        Text("Page \(annotation.pageIndex + 1)")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary.opacity(0.8))
                    }
                    
                    Spacer()
                    
                    if annotation.isReadwiseImport {
                        Image(systemName: "bird.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.blue)
                            .padding(4)
                            .background(Color.blue.opacity(0.1), in: Circle())
                    } else {
                        Image(systemName: "doc.text.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange)
                            .padding(4)
                            .background(Color.orange.opacity(0.1), in: Circle())
                    }
                }
                .padding(.bottom, 2)

                // Highlight text with warm amber/pastel highlighter background layer
                if let text = annotation.selectedText, !text.isEmpty {
                    highlightedText(text)
                        .font(.system(size: 15, weight: .regular, design: .serif))
                        .foregroundStyle(.primary)
                        .lineSpacing(4)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color(hex: annotation.colorHex ?? "#F5A623").opacity(0.10))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(hex: annotation.colorHex ?? "#F5A623").opacity(0.20), lineWidth: 0.8)
                        )
                } else if let ocrText = annotation.drawingOCRText, !ocrText.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "scribble.variable")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.top, 2)
                        highlightedText(ocrText)
                            .font(.system(size: 15, weight: .regular, design: .serif))
                            .italic()
                            .foregroundStyle(.primary)
                            .lineSpacing(4)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(hex: annotation.colorHex ?? "#F5A623").opacity(0.10))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(hex: annotation.colorHex ?? "#F5A623").opacity(0.20), lineWidth: 0.8)
                    )
                }

                // User's thought (noteText) - Styled like a premium marginalia note block
                if let note = annotation.noteText, !note.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 5) {
                            Image(systemName: "square.and.pencil")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(Theme.textSecondary)
                            Text("ANNOTATION")
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .foregroundColor(Theme.textSecondary)
                        }
                        highlightedText(note)
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(.primary)
                            .lineSpacing(2)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.03))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
                    )
                    .padding(.top, 2)
                }

                // Tags row & Relative Timestamp Footer
                HStack(alignment: .center) {
                    let rwTags = annotation.readwiseTags ?? []
                    let allTags = userTags.map { ($0, Color.orange) } + rwTags.map { ($0, Color.blue) }
                    
                    if !allTags.isEmpty {
                        HStack(spacing: 5) {
                            ForEach(Array(allTags.prefix(3)), id: \.0) { (tag, color) in
                                TagPill(tag: tag, color: color)
                            }
                            if allTags.count > 3 {
                                Text("+\(allTags.count - 3)")
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundStyle(Theme.textSecondary)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1.5)
                                    .background(Color.primary.opacity(0.06), in: Capsule())
                            }
                        }
                    }
                    
                    Spacer()
                    
                    HStack(spacing: 8) {
                        // Quick-edit shortcut button
                        Button {
                            HapticEngine.light()
                            showingEdit = true
                        } label: {
                            Image(systemName: "pencil")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(Theme.purple)
                                .padding(5)
                                .background(Theme.purple.opacity(0.12), in: Circle())
                        }
                        .buttonStyle(.plain)
                        
                        HStack(spacing: 3) {
                            Text(annotation.modifiedAt, style: .relative)
                            Text("ago")
                        }
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                    }
                }
                .padding(.top, 4)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Theme.surface)
                    .shadow(color: Color.black.opacity(0.03), radius: 6, x: 0, y: 3)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 0.6)
            )
        }
        .buttonStyle(.plain)
        .alert("Archived Source Context", isPresented: $showingArchiveAlert) {
            Button("Edit Note & Tags") {
                showingEdit = true
            }
            Button("Dismiss", role: .cancel) { }
        } message: {
            Text("This highlight is preserved in your Zettelkasten, but the source book ('\(sourceTitle)') has been removed from this device to save storage space.")
        }
        .contextMenu {
            Button {
                showingEdit = true
            } label: {
                Label("Edit Note & Tags", systemImage: "pencil")
            }
            
            // ─── Item 7: Jump-to-source ───────────────────────────────
            if let matchedPDF = conversionManager.convertedPDFs.first(where: { $0.id == annotation.pdfID }) {
                Button {
                    // Open in reader at the annotated page
                    AppRouter.shared.presentFullScreen(.read(matchedPDF))
                    // After reader opens, post a notification to jump to the page
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        NotificationCenter.default.post(
                            name: NSNotification.Name("Reader_JumpToPage"),
                            object: nil,
                            userInfo: ["pageIndex": annotation.pageIndex]
                        )
                    }
                } label: {
                    Label("Open in Reader", systemImage: "book.fill")
                }
            }
            // ─────────────────────────────────────────────────────────
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

// MARK: - Tag Explorer Helper Views & Types

struct TagExplorerItem: Identifiable {
    var id: String { tag }
    let tag: String
    let annotations: [SDAnnotation]
}

struct TagDetailSheet: View {
    let tag: String
    let annotations: [SDAnnotation]
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var conversionManager: ConversionManager
    
    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()
                
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(annotations) { ann in
                            GlobalHighlightRow(annotation: ann)
                                .environmentObject(conversionManager)
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("#" + tag)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(Color(hex: "#7B5EA7"))
                }
            }
        }
    }
}

