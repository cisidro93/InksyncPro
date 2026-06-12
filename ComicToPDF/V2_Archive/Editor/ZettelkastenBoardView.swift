import SwiftUI
import SwiftData

// MARK: - Identifiable String wrapper
// Used by sheet(item:) to present a rename sheet for a specific column name.
private struct IdentifiableString: Identifiable {
    let id: String
    let value: String
    init(value: String) { self.id = value; self.value = value }
}

struct ZettelkastenBoardView: View {
    let annotations: [SDAnnotation]
    let pdfs: [SDConvertedPDF]

    @Environment(\.modelContext) private var modelContext
    
    // Query manuscript projects for pushing/compiling outlines
    @Query(sort: \SDManuscriptProject.modifiedAt, order: .reverse) private var manuscriptProjects: [SDManuscriptProject]

    // Board Grouping Mode
    enum BoardGroupingMode: String, CaseIterable, Identifiable {
        case customOutline = "Custom Outline"
        case byTag = "By Tag"
        case byBook = "By Book"
        case byColor = "By Color"
        
        var id: String { rawValue }
        
        var icon: String {
            switch self {
            case .customOutline: return "sidebar.left"
            case .byTag: return "tag"
            case .byBook: return "book.closed"
            case .byColor: return "paintbrush"
            }
        }
    }

    @State private var groupingMode: BoardGroupingMode = .customOutline
    @State private var customColumns: [String] = ["Intro", "Section 1", "Section 2"]
    @State private var newColumnName: String = ""
    @State private var showingAddColumn = false

    // Column rename — SwiftUI sheet replaces UIAlertController
    @State private var renamingColumn: String? = nil
    @State private var renameText: String = ""
    @FocusState private var renameFieldFocused: Bool
    
    // Collapsed/visible states
    @State private var isShowingInbox = true
    @State private var searchInboxText = ""
    @State private var selectedAnnotation: SDAnnotation? = nil
    
    // Inspector navigation stack for linked notes
    @State private var inspectorHistory: [SDAnnotation] = []

    // Compile & Push to Manuscript states
    @State private var showingCompileSheet = false
    @State private var selectedColumnForCompile: String? = nil
    @State private var selectedProject: SDManuscriptProject? = nil
    @State private var selectedDocument: SDManuscriptDocument? = nil
    @State private var newDocumentTitle = ""
    @State private var isCreatingNewDocument = false
    
    // Programmatic navigation target
    @State private var compiledProject: SDManuscriptProject? = nil

    // Highlight colors list mapping
    private let colorsList = [
        (name: "Yellow", hex: "#FFD60A"),
        (name: "Blue", hex: "#007AFF"),
        (name: "Pink", hex: "#FF2D55"),
        (name: "Aqua", hex: "#32ADE6"),
        (name: "Orange", hex: "#FF9F0A"),
        (name: "Purple", hex: "#BF5AF2")
    ]

    // Computed properties for Tags, Books, and Colors
    private var allTags: [String] {
        let all = annotations.compactMap { $0.tags }.flatMap { $0 } + 
                  annotations.compactMap { $0.readwiseTags }.flatMap { $0 } +
                  annotations.compactMap { $0.readwiseDocumentTags }.flatMap { $0 }
        return Array(Set(all.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })).sorted()
    }

    private var allBooks: [String] {
        let all = annotations.compactMap { $0.readwiseBookTitle } + pdfs.map { $0.name }
        return Array(Set(all)).sorted()
    }

    // Filtered Inbox annotations (those with no custom column assigned in Custom Outline mode, or all when searching)
    private var inboxAnnotations: [SDAnnotation] {
        let list: [SDAnnotation]
        if groupingMode == .customOutline {
            list = annotations.filter { $0.outlineColumn == nil }
        } else {
            list = annotations
        }
        
        if searchInboxText.isEmpty {
            return list.sorted { ($0.modifiedAt) > ($1.modifiedAt) }
        } else {
            return list.filter { ann in
                (ann.selectedText?.localizedCaseInsensitiveContains(searchInboxText) ?? false) ||
                (ann.noteText?.localizedCaseInsensitiveContains(searchInboxText) ?? false) ||
                (ann.readwiseBookTitle?.localizedCaseInsensitiveContains(searchInboxText) ?? false)
            }.sorted { ($0.modifiedAt) > ($1.modifiedAt) }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // ── Left Side: Collapsible Highlight Inbox Drawer ────────────────
            if isShowingInbox {
                inboxDrawer
                    .frame(width: 300)
                    .transition(.move(edge: .leading))
                Divider()
            }

            // ── Main Workspace: Horizontal Columns ───────────────────────────
            VStack(spacing: 0) {
                boardHeader
                
                if annotations.isEmpty {
                    emptyBoardView
                } else {
                    boardCanvas
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            // ── Right Side: Card Inspector & Linker ──────────────────────────
            if let selected = selectedAnnotation {
                Divider()
                CardInspectorView(
                    annotation: Binding(
                        get: { selectedAnnotation ?? selected },
                        set: { selectedAnnotation = $0 }
                    ),
                    allAnnotations: annotations,
                    pdfs: pdfs,
                    history: $inspectorHistory,
                    onNavigate: { nextAnn in
                        inspectorHistory.append(selected)
                        selectedAnnotation = nextAnn
                    },
                    onClose: {
                        selectedAnnotation = nil
                        inspectorHistory.removeAll()
                    }
                )
                .frame(width: 340)
                .transition(.move(edge: .trailing))
            }
        }
        .background(Color.inkBackground.ignoresSafeArea())
        .onAppear {
            syncCustomColumns()
        }
        .sheet(isPresented: $showingCompileSheet) {
            compileToManuscriptSheet
        }
        // SwiftUI-native column rename sheet
        .sheet(item: Binding(
            get: { renamingColumn.map { IdentifiableString(value: $0) } },
            set: { renamingColumn = $0?.value }
        )) { item in
            columnRenameSheet(for: item.value)
        }
        .navigationDestination(isPresented: Binding(
            get: { compiledProject != nil },
            set: { if !$0 { compiledProject = nil } }
        )) {
            if let project = compiledProject {
                ManuscriptEditorWorkspace(project: project)
            }
        }
    }

    // MARK: - Board Header
    private var boardHeader: some View {
        HStack(spacing: 12) {
            // Toggle Inbox button
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    isShowingInbox.toggle()
                }
            } label: {
                Label("Inbox", systemImage: isShowingInbox ? "sidebar.left" : "sidebar.right")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 16, weight: .semibold))
                    .padding(8)
                    .background(.regularMaterial, in: Circle())
            }
            .buttonStyle(.plain)

            // Grouping Mode picker
            Picker("Layout Mode", selection: $groupingMode) {
                ForEach(BoardGroupingMode.allCases) { mode in
                    Label(mode.rawValue, systemImage: mode.icon).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 0.5))

            Spacer()

            if groupingMode == .customOutline {
                Button {
                    showingAddColumn = true
                } label: {
                    Label("Add Column", systemImage: "plus")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.inkAccentKnowledge, in: Capsule())
                }
                .buttonStyle(.plain)
                .alert("New Outline Column", isPresented: $showingAddColumn) {
                    TextField("Column Name", text: $newColumnName)
                    Button("Cancel", role: .cancel) { newColumnName = "" }
                    Button("Add") {
                        let name = newColumnName.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !name.isEmpty && !customColumns.contains(name) {
                            withAnimation(.spring()) {
                                customColumns.append(name)
                            }
                        }
                        newColumnName = ""
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.inkSurfaceRaised.opacity(0.5))
    }

    // MARK: - Inbox Drawer
    private var inboxDrawer: some View {
        VStack(spacing: 0) {
            // Search Bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(Theme.textSecondary)
                    .font(.system(size: 14))
                TextField("Search highlights...", text: $searchInboxText)
                    .font(.system(size: 14))
                if !searchInboxText.isEmpty {
                    Button { searchInboxText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(Theme.textTertiary)
                    }
                }
            }
            .padding(10)
            .background(Color.inkSurface)
            .cornerRadius(10)
            .padding(12)

            // Header info
            HStack {
                Text(groupingMode == .customOutline ? "Unassigned Highlights" : "All Highlights")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                    .tracking(0.8)
                Spacer()
                Text("\(inboxAnnotations.count)")
                    .font(.caption2.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.1), in: Capsule())
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            // Lazy vertical list of cards in Inbox
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(inboxAnnotations) { ann in
                        HighlightCard(annotation: ann, showActions: true, onSelect: {
                            selectedAnnotation = ann
                        })
                        .draggable(ann.id.uuidString)
                    }
                }
                .padding(12)
            }
        }
        .background(Color.inkBackground)
    }

    // MARK: - Board Canvas
    private var boardCanvas: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            LazyHStack(alignment: .top, spacing: 16) {
                switch groupingMode {
                case .customOutline:
                    ForEach(customColumns, id: \.self) { colName in
                        boardColumn(
                            title: colName,
                            icon: "list.bullet.indent",
                            cards: annotations.filter { $0.outlineColumn == colName }.sorted { $0.outlineOrder < $1.outlineOrder },
                            columnID: colName
                        )
                    }
                case .byTag:
                    let tags = allTags.isEmpty ? ["untagged"] : allTags
                    ForEach(tags, id: \.self) { tag in
                        let isUntagged = tag == "untagged"
                        let tagCards = annotations.filter { ann in
                            let annTags = (ann.tags ?? []) + (ann.readwiseTags ?? [])
                            if isUntagged { return annTags.isEmpty }
                            return annTags.contains(tag)
                        }
                        boardColumn(
                            title: isUntagged ? "Untagged" : "#\(tag)",
                            icon: isUntagged ? "tag.slash" : "tag.fill",
                            cards: tagCards,
                            columnID: tag
                        )
                    }
                case .byBook:
                    let books = allBooks.isEmpty ? ["Unknown Source"] : allBooks
                    ForEach(books, id: \.self) { book in
                        let bookCards = annotations.filter { ann in
                            let title = ann.readwiseBookTitle ?? pdfs.first(where: { $0.id == ann.pdfID })?.name ?? "Unknown Source"
                            return title == book
                        }
                        boardColumn(
                            title: book,
                            icon: "book",
                            cards: bookCards,
                            columnID: book
                        )
                    }
                case .byColor:
                    ForEach(colorsList, id: \.hex) { colorObj in
                        let colorCards = annotations.filter { $0.colorHex?.uppercased() == colorObj.hex }
                        boardColumn(
                            title: colorObj.name,
                            icon: "circle.fill",
                            cards: colorCards,
                            columnID: colorObj.hex,
                            tintColor: Color(hex: colorObj.hex)
                        )
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .background(DotGridBackground().ignoresSafeArea())
    }

    // MARK: - Board Column component
    @ViewBuilder
    private func boardColumn(title: String, icon: String, cards: [SDAnnotation], columnID: String, tintColor: Color? = nil) -> some View {
        VStack(spacing: 0) {
            // Column Header
            HStack {
                if let tint = tintColor {
                    Image(systemName: icon)
                        .foregroundColor(tint)
                        .font(.system(size: 14))
                } else {
                    Image(systemName: icon)
                        .foregroundColor(Theme.orange)
                        .font(.system(size: 12))
                }
                Text(title)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer()
                
                // Card count badge
                Text("\(cards.count)")
                    .font(.caption2.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.1), in: Capsule())

                // Column Action Menu
                Menu {
                    if groupingMode == .customOutline {
                        Button("Rename") {
                            // Quick rename prompt
                            renameColumn(columnID)
                        }
                        Button("Delete Column", role: .destructive) {
                            deleteColumn(columnID)
                        }
                    }
                    Button("Assemble Manuscript Chapter") {
                        selectedColumnForCompile = columnID
                        showingCompileSheet = true
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(4)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.inkSurfaceRaised.opacity(0.8))
            
            Divider()

            // Vertical list of cards
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(cards) { ann in
                        HighlightCard(annotation: ann, showActions: false, onSelect: {
                            selectedAnnotation = ann
                        })
                        .draggable(ann.id.uuidString)
                    }
                }
                .padding(10)
            }
            .frame(maxHeight: .infinity)
            .background(Color.inkSurface.opacity(0.35))
            .dropDestination(for: String.self) { items, location in
                guard let firstID = items.first else { return false }
                handleDrop(idString: firstID, targetColumn: columnID)
                return true
            }
        }
        .frame(width: 300)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }

    // MARK: - Drag and Drop Handler
    private func handleDrop(idString: String, targetColumn: String) {
        guard let uuid = UUID(uuidString: idString),
              let ann = annotations.first(where: { $0.id == uuid }) else { return }

        HapticEngine.success()

        switch groupingMode {
        case .customOutline:
            // Moving between custom columns
            ann.outlineColumn = targetColumn
            // Set order to end of column
            let existingInCol = annotations.filter { $0.outlineColumn == targetColumn }
            ann.outlineOrder = (existingInCol.map { $0.outlineOrder }.max() ?? 0) + 1
            
        case .byTag:
            // Add tag to annotation
            var tags = ann.tags ?? []
            if targetColumn != "untagged" && !tags.contains(targetColumn) {
                tags.append(targetColumn)
                ann.tags = tags
            }
            
        case .byBook:
            // Books are source-defined and read-only
            break
            
        case .byColor:
            // Update hex code
            ann.colorHex = targetColumn
        }

        ann.modifiedAt = Date()
        try? modelContext.save()
    }

    // MARK: - Helper Actions
    private func syncCustomColumns() {
        let existing = Set(annotations.compactMap { $0.outlineColumn })
        var columns = customColumns
        for c in existing {
            if !columns.contains(c) {
                columns.append(c)
            }
        }
        customColumns = columns
    }

    private func renameColumn(_ oldName: String) {
        // SwiftUI sheet — works correctly on both iPhone and iPad
        renameText = oldName
        renamingColumn = oldName
    }

    @ViewBuilder
    private func columnRenameSheet(for oldName: String) -> some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "pencil.line")
                    .font(.system(size: 36))
                    .foregroundStyle(Color.inkAccentKnowledge)
                    .padding(.top, 32)

                Text("Rename Column")
                    .font(.title3.bold())
                    .foregroundStyle(Color.inkTextPrimary)

                TextField("Column name", text: $renameText)
                    .focused($renameFieldFocused)
                    .font(.body)
                    .padding(12)
                    .background(Color.inkSurface, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.inkBorderSubtle, lineWidth: 0.5))
                    .padding(.horizontal, 24)
                    .onSubmit { commitRename(oldName: oldName) }

                Button {
                    commitRename(oldName: oldName)
                } label: {
                    Text("Save")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.gray : Color.inkAccentKnowledge,
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .padding(.horizontal, 24)

                Spacer()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { renamingColumn = nil }
                        .foregroundStyle(Color.inkTextSecondary)
                }
            }
            .onAppear { renameFieldFocused = true }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private func commitRename(oldName: String) {
        let text = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let idx = customColumns.firstIndex(of: oldName) {
            customColumns[idx] = text
        }
        for ann in annotations where ann.outlineColumn == oldName {
            ann.outlineColumn = text
        }
        try? modelContext.save()
        renamingColumn = nil
    }

    private func deleteColumn(_ colName: String) {
        withAnimation(.spring()) {
            customColumns.removeAll(where: { $0 == colName })
        }
        // Dissociate annotations so they go back to Inbox
        for ann in annotations where ann.outlineColumn == colName {
            ann.outlineColumn = nil
        }
        try? modelContext.save()
    }

    // MARK: - Compile to Manuscript Sheet
    private var compileToManuscriptSheet: some View {
        NavigationView {
            Form {
                Section("Source Outline") {
                    if let col = selectedColumnForCompile {
                        Text("Column: \(col)")
                            .font(.headline)
                        Text("\(annotations.filter { $0.outlineColumn == col }.count) highlights will be compiled in outline order.")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }

                Section("Target Manuscript Project") {
                    if manuscriptProjects.isEmpty {
                        Text("No projects found. Create one in the Manuscript Binder first.")
                            .foregroundColor(Theme.red)
                    } else {
                        Picker("Project", selection: $selectedProject) {
                            Text("Select a project").tag(nil as SDManuscriptProject?)
                            ForEach(manuscriptProjects) { proj in
                                Text(proj.title).tag(proj as SDManuscriptProject?)
                            }
                        }
                    }
                }

                if let project = selectedProject {
                    Section("Destination Chapter") {
                        Picker("Destination", selection: $isCreatingNewDocument) {
                            Text("Append to Existing Chapter").tag(false)
                            Text("Create New Chapter").tag(true)
                        }
                        .pickerStyle(.segmented)

                        if isCreatingNewDocument {
                            TextField("Chapter Title", text: $newDocumentTitle)
                        } else {
                            Picker("Select Chapter", selection: $selectedDocument) {
                                Text("Select chapter").tag(nil as SDManuscriptDocument?)
                                ForEach(project.documents.sorted(by: { $0.orderIndex < $1.orderIndex })) { doc in
                                    Text(doc.title).tag(doc as SDManuscriptDocument?)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Compile Draft")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showingCompileSheet = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Compile") {
                        performCompilation()
                    }
                    .disabled(selectedProject == nil || (isCreatingNewDocument ? newDocumentTitle.isEmpty : selectedDocument == nil))
                    .fontWeight(.semibold)
                }
            }
        }
    }

    private func performCompilation() {
        guard let project = selectedProject,
              let col = selectedColumnForCompile else { return }

        // Find and sort annotations in outline order
        let colCards = annotations
            .filter { $0.outlineColumn == col }
            .sorted(by: { $0.outlineOrder < $1.outlineOrder })

        var md = "\n\n## Outline Chapter: \(col)\n\n"
        for ann in colCards {
            if let text = ann.selectedText, !text.isEmpty {
                md += "> \(text)\n"
            }
            let sourceTitle = ann.readwiseBookTitle ?? pdfs.first(where: { $0.id == ann.pdfID })?.name ?? "Unknown Source"
            md += "_Source: \(sourceTitle), p. \(ann.pageIndex + 1)_\n\n"
            if let note = ann.noteText, !note.isEmpty {
                md += "\(note)\n\n"
            }
            md += "---\n\n"
        }

        let targetDoc: SDManuscriptDocument
        if isCreatingNewDocument {
            targetDoc = SDManuscriptDocument(title: newDocumentTitle, contentMarkdown: md, orderIndex: project.documents.count)
            targetDoc.project = project
            project.documents.append(targetDoc)
            modelContext.insert(targetDoc)
        } else if let doc = selectedDocument {
            doc.contentMarkdown += md
            doc.modifiedAt = Date()
            targetDoc = doc
        } else {
            return
        }

        // Pin the annotations to this document's references
        for ann in colCards {
            if !targetDoc.attachedNoteIDs.contains(ann.id.uuidString) {
                targetDoc.attachedNoteIDs.append(ann.id.uuidString)
            }
        }

        try? modelContext.save()
        HapticEngine.success()
        showingCompileSheet = false

        // Transition: Open the manuscript editor directly
        self.compiledProject = project
    }

    // MARK: - Empty State
    private var emptyBoardView: some View {
        VStack(spacing: 20) {
            Image(systemName: "tray.2")
                .font(.system(size: 40))
                .foregroundColor(Theme.textTertiary)
            Text("No Highlights Available")
                .font(.headline)
            Text("Highlights you extract from books or import from Readwise will appear here.")
                .font(.subheadline)
                .foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Highlight Card Component
private struct HighlightCard: View {
    let annotation: SDAnnotation
    var showActions: Bool
    var onSelect: () -> Void
    
    private var accentColor: Color {
        Color(hex: annotation.colorHex ?? "#FFD60A")
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 0) {
                // Accent Strip
                RoundedRectangle(cornerRadius: 2)
                    .fill(accentColor)
                    .frame(width: 3)
                    .padding(.vertical, 8)
                    .padding(.leading, 8)

                VStack(alignment: .leading, spacing: 4) {
                    if let source = annotation.readwiseBookTitle {
                        Text(source)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.inkTextTertiary)
                            .lineLimit(1)
                    }
                    
                    if let text = annotation.selectedText, !text.isEmpty {
                        Text(text)
                            .font(.system(size: 13, design: .serif))
                            .foregroundStyle(Color.inkTextPrimary)
                            .lineLimit(3)
                            .lineSpacing(2)
                    }
                    
                    if let note = annotation.noteText, !note.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "pencil")
                                .font(.system(size: 9))
                                .foregroundStyle(Color.inkAccentKnowledge)
                            Text(note)
                                .font(.system(size: 11))
                                .italic()
                                .foregroundStyle(Color.inkTextSecondary)
                                .lineLimit(1)
                        }
                        .padding(.top, 2)
                    }
                }
                .padding(8)
                Spacer()
            }
            .background(Color.inkSurface)
            .cornerRadius(8)
            .shadow(color: Color.black.opacity(0.04), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Detailed Inspector View
private struct CardInspectorView: View {
    @Binding var annotation: SDAnnotation
    let allAnnotations: [SDAnnotation]
    let pdfs: [SDConvertedPDF]
    
    @Binding var history: [SDAnnotation]
    var onNavigate: (SDAnnotation) -> Void
    var onClose: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SDManuscriptProject.modifiedAt, order: .reverse) private var projects: [SDManuscriptProject]

    @State private var connectionSearchQuery = ""
    @State private var showingAddConnection = false

    private var sourceBookTitle: String {
        annotation.readwiseBookTitle ?? pdfs.first(where: { $0.id == annotation.pdfID })?.name ?? "Unknown Source"
    }

    private var accentColor: Color {
        Color(hex: annotation.colorHex ?? "#FFD60A")
    }

    // Explicit and dynamic connections
    private var connectedAnnotations: [SDAnnotation] {
        let explicitIDs = annotation.linkedAnnotationIDs ?? []
        let explicit = allAnnotations.filter { explicitIDs.contains($0.id.uuidString) }
        
        // Dynamic co-occurring tags links
        let currentTags = Set((annotation.tags ?? []) + (annotation.readwiseTags ?? []))
        let dynamic = allAnnotations.filter { other in
            guard other.id != annotation.id else { return false }
            let otherTags = Set((other.tags ?? []) + (other.readwiseTags ?? []))
            return !currentTags.isDisjoint(with: otherTags) && !explicitIDs.contains(other.id.uuidString)
        }.prefix(5)
        
        return explicit + Array(dynamic)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Inspector Header
            HStack {
                if !history.isEmpty {
                    Button {
                        if let prev = history.popLast() {
                            annotation = prev
                        }
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
                
                Text("Card Inspector")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.text)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(6)
                        .background(.primary.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(14)
            .background(Color.inkSurfaceRaised.opacity(0.8))

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Blockquote Highlight
                    VStack(alignment: .leading, spacing: 6) {
                        Text(sourceBookTitle.uppercased())
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.orange)
                            .tracking(1.0)
                        
                        if let selectedText = annotation.selectedText, !selectedText.isEmpty {
                            Text("\"\(selectedText)\"")
                                .font(.system(.body, design: .serif))
                                .foregroundStyle(Theme.text)
                                .lineSpacing(4)
                                .padding(12)
                                .background(accentColor.opacity(0.08))
                                .cornerRadius(8)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .strokeBorder(accentColor.opacity(0.2), lineWidth: 1)
                                )
                        }
                        
                        HStack {
                            Text("Page \(annotation.pageIndex + 1)")
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                            Spacer()
                            
                            // Deep Link to Reader
                            if let matchedPDF = pdfs.first(where: { $0.id == annotation.pdfID }) {
                                Button("Open in Reader") {
                                    AppRouter.shared.presentFullScreen(.read(matchedPDF.toDTO()))
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                        NotificationCenter.default.post(
                                            name: NSNotification.Name("Reader_JumpToPage"),
                                            object: nil,
                                            userInfo: ["pageIndex": annotation.pageIndex]
                                        )
                                    }
                                }
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(Color.inkAccentKnowledge)
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.top, 4)
                    }

                    // Rich notes editor
                    VStack(alignment: .leading, spacing: 8) {
                        Label("My Thoughts", systemImage: "pencil.line")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.textSecondary)
                        
                        TextEditor(text: Binding(
                            get: { annotation.noteText ?? "" },
                            set: { val in
                                annotation.noteText = val.isEmpty ? nil : val
                                annotation.modifiedAt = Date()
                                try? modelContext.save()
                            }
                        ))
                        .font(.system(size: 13))
                        .scrollContentBackground(.hidden)
                        .background(Color.inkSurface, in: RoundedRectangle(cornerRadius: 10))
                        .frame(height: 100)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                        )
                    }

                    // Bidirectional Connection Linker
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label("Linked Highlights", systemImage: "link")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundStyle(Theme.textSecondary)
                            Spacer()
                            Button {
                                showingAddConnection.toggle()
                            } label: {
                                Image(systemName: "plus.circle.fill")
                                    .foregroundColor(Color.inkAccentKnowledge)
                                    .font(.system(size: 16))
                            }
                            .buttonStyle(.plain)
                        }

                        if showingAddConnection {
                            connectionSearchBox
                        }

                        if connectedAnnotations.isEmpty {
                            Text("No linked cards yet. Tap + to link related highlights.")
                                .font(.system(size: 11))
                                .foregroundColor(Theme.textTertiary)
                                .padding(.vertical, 4)
                        } else {
                            VStack(spacing: 8) {
                                ForEach(connectedAnnotations) { other in
                                    let isExplicit = (annotation.linkedAnnotationIDs ?? []).contains(other.id.uuidString)
                                    Button {
                                        onNavigate(other)
                                    } label: {
                                        HStack {
                                            Circle()
                                                .fill(Color(hex: other.colorHex ?? "#FFD60A"))
                                                .frame(width: 6, height: 6)
                                            
                                            Text(other.selectedText ?? other.noteText ?? "Untitled note")
                                                .font(.system(size: 12))
                                                .foregroundColor(Theme.text)
                                                .lineLimit(1)
                                            Spacer()
                                            
                                            if isExplicit {
                                                Button {
                                                    unlinkNotes(other)
                                                } label: {
                                                    Image(systemName: "minus.circle.fill")
                                                        .foregroundColor(Theme.red)
                                                        .font(.system(size: 12))
                                                }
                                                .buttonStyle(.plain)
                                            } else {
                                                Image(systemName: "tag.fill")
                                                    .foregroundColor(Theme.blue)
                                                    .font(.system(size: 8))
                                            }
                                        }
                                        .padding(8)
                                        .background(Color.inkSurface, in: RoundedRectangle(cornerRadius: 6))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }

                    // Manuscript Pinning
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Pinned Chapters", systemImage: "pin.fill")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.textSecondary)

                        ForEach(projects) { proj in
                            ForEach(proj.documents) { doc in
                                let isPinned = doc.attachedNoteIDs.contains(annotation.id.uuidString)
                                Button {
                                    if isPinned {
                                        doc.attachedNoteIDs.removeAll(where: { $0 == annotation.id.uuidString })
                                    } else {
                                        doc.attachedNoteIDs.append(annotation.id.uuidString)
                                    }
                                    try? modelContext.save()
                                } label: {
                                    HStack {
                                        Image(systemName: isPinned ? "pin.circle.fill" : "circle")
                                            .foregroundColor(isPinned ? Color.inkAccentKnowledge : Theme.textTertiary)
                                        Text("\(proj.title) - \(doc.title)")
                                            .font(.system(size: 12))
                                            .foregroundColor(Theme.text)
                                            .lineLimit(1)
                                        Spacer()
                                    }
                                    .padding(8)
                                    .background(Color.inkSurface, in: RoundedRectangle(cornerRadius: 6))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(16)
            }
        }
        .background(Color.inkBackground)
    }

    // Connection Search Panel
    private var connectionSearchBox: some View {
        VStack(spacing: 8) {
            TextField("Search notes to link...", text: $connectionSearchQuery)
                .font(.system(size: 12))
                .padding(8)
                .background(Color.inkSurface, in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
                )

            let results = allAnnotations.filter { other in
                other.id != annotation.id &&
                !(annotation.linkedAnnotationIDs ?? []).contains(other.id.uuidString) &&
                (!connectionSearchQuery.isEmpty &&
                 ((other.selectedText?.localizedCaseInsensitiveContains(connectionSearchQuery) ?? false) ||
                  (other.noteText?.localizedCaseInsensitiveContains(connectionSearchQuery) ?? false)))
            }.prefix(5)

            if !results.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(results) { other in
                        Button {
                            linkNotes(other)
                            connectionSearchQuery = ""
                            showingAddConnection = false
                        } label: {
                            HStack {
                                Circle()
                                    .fill(Color(hex: other.colorHex ?? "#FFD60A"))
                                    .frame(width: 5, height: 5)
                                Text(other.selectedText ?? other.noteText ?? "")
                                    .font(.system(size: 11))
                                    .foregroundColor(Theme.textSecondary)
                                    .lineLimit(1)
                                Spacer()
                                Image(systemName: "plus.circle")
                                    .foregroundColor(Color.inkAccentKnowledge)
                                    .font(.system(size: 12))
                            }
                            .padding(6)
                            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 4))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(8)
        .background(Color.inkSurfaceRaised, in: RoundedRectangle(cornerRadius: 8))
    }

    private func linkNotes(_ other: SDAnnotation) {
        var listA = annotation.linkedAnnotationIDs ?? []
        var listB = other.linkedAnnotationIDs ?? []
        let idA = annotation.id.uuidString
        let idB = other.id.uuidString

        if !listA.contains(idB) {
            listA.append(idB)
            annotation.linkedAnnotationIDs = listA
        }
        if !listB.contains(idA) {
            listB.append(idA)
            other.linkedAnnotationIDs = listB
        }
        annotation.modifiedAt = Date()
        other.modifiedAt = Date()
        try? modelContext.save()
        HapticEngine.selection()
    }

    private func unlinkNotes(_ other: SDAnnotation) {
        annotation.linkedAnnotationIDs?.removeAll(where: { $0 == other.id.uuidString })
        other.linkedAnnotationIDs?.removeAll(where: { $0 == annotation.id.uuidString })
        annotation.modifiedAt = Date()
        other.modifiedAt = Date()
        try? modelContext.save()
        HapticEngine.medium()
    }
}

// MARK: - Dot Grid Background
struct DotGridBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let bg: Color = colorScheme == .dark
            ? Color(red: 0.054, green: 0.054, blue: 0.070)
            : Color(red: 0.961, green: 0.941, blue: 0.918)
        let dot: Color = colorScheme == .dark
            ? Color(red: 0.118, green: 0.118, blue: 0.157)
            : Color(red: 0.851, green: 0.788, blue: 0.714)

        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(bg))
            let spacing: CGFloat = 28
            let r: CGFloat = 1.5
            var x: CGFloat = spacing / 2
            while x < size.width {
                var y: CGFloat = spacing / 2
                while y < size.height {
                    ctx.fill(
                        Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                        with: .color(dot)
                    )
                    y += spacing
                }
                x += spacing
            }
        }
    }
}
