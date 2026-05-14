import SwiftUI
import SwiftData

// MARK: - ManuscriptEditorWorkspace
struct ManuscriptEditorWorkspace: View {
    @Bindable var project: SDManuscriptProject
    @Environment(\.modelContext) private var modelContext
    @Query private var allAnnotations: [SDAnnotation]

    @State private var selectedDocumentID: UUID?
    @State private var isInspectorVisible = true
    @State private var showingNewDocumentDialog = false
    @State private var newDocumentTitle = ""

    // Focus / Distraction-Free Mode
    @State private var isFocusMode = false

    // Write / Preview toggle
    enum EditorMode: String, CaseIterable { case write = "Write"; case preview = "Preview" }
    @State private var editorMode: EditorMode = .write

    // Export
    @State private var showExportMenu = false
    @State private var exportItems: [Any] = []
    @State private var showShareSheet = false
    @State private var isExporting = false
    @State private var exportError: String?
    @State private var showExportError = false

    private var sortedDocuments: [SDManuscriptDocument] {
        project.documents.sorted(by: { $0.orderIndex < $1.orderIndex })
    }

    private var selectedDocument: SDManuscriptDocument? {
        project.documents.first(where: { $0.id == selectedDocumentID })
    }

    var body: some View {
        Group {
            if isFocusMode {
                focusModeView
            } else {
                splitView
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .alert("New Chapter", isPresented: $showingNewDocumentDialog) {
            TextField("Chapter Title", text: $newDocumentTitle)
            Button("Create") { createDocument() }
            Button("Cancel", role: .cancel) { newDocumentTitle = "" }
        } message: {
            Text("Enter a title for the new chapter or scene.")
        }
        .alert("Export Failed", isPresented: $showExportError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportError ?? "Unknown error")
        }
        .sheet(isPresented: $showShareSheet) {
            ActivityViewController(activityItems: exportItems)
        }
    }

    // MARK: - Split View (Normal Mode)

    private var splitView: some View {
        NavigationSplitView {
            binderList
        } detail: {
            if let document = selectedDocument {
                editorWithInspector(document: document)
            } else {
                noSelectionPlaceholder
            }
        }
    }

    // MARK: - Binder

    private var binderList: some View {
        List(selection: $selectedDocumentID) {
            Section("Chapters") {
                ForEach(sortedDocuments) { doc in
                    HStack {
                        Image(systemName: "doc.text")
                            .foregroundStyle(Color.inkAccentKnowledge)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(doc.title)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(Color.inkTextPrimary)
                            Text("\(doc.wordCount) words")
                                .font(.caption2)
                                .foregroundStyle(Color.inkTextTertiary)
                        }
                        Spacer()
                    }
                    .tag(doc.id)
                    .contentShape(Rectangle())
                    .onTapGesture { selectedDocumentID = doc.id }
                }
                .onMove(perform: moveDocuments)
                .onDelete(perform: deleteDocuments)
            }
        }
        .navigationTitle("Binder")
        .scrollContentBackground(.hidden)
        .background(Color.inkBackground)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                // Export menu
                Menu {
                    Button {
                        performExport(format: .markdownZip)
                    } label: { Label("Export as Markdown (.zip)", systemImage: "archivebox") }

                    Button {
                        performExport(format: .markdownBundle)
                    } label: { Label("Export as Single Markdown (.md)", systemImage: "doc.text") }

                    Button {
                        performExport(format: .plainText)
                    } label: { Label("Export as Plain Text (.txt)", systemImage: "doc.plaintext") }
                } label: {
                    if isExporting {
                        ProgressView().tint(Color.inkAccentKnowledge)
                    } else {
                        Image(systemName: "square.and.arrow.up")
                            .foregroundStyle(Color.inkAccentKnowledge)
                    }
                }
                .disabled(isExporting || project.documents.isEmpty)

                Button {
                    showingNewDocumentDialog = true
                } label: {
                    Image(systemName: "plus")
                        .foregroundStyle(Color.inkAccentKnowledge)
                }
            }
        }
    }

    // MARK: - Editor + Inspector

    @ViewBuilder
    private func editorWithInspector(document: SDManuscriptDocument) -> some View {
        HStack(spacing: 0) {
            // Center: Editor or Preview
            VStack(spacing: 0) {
                editorHeader(document: document)
                Divider()
                if editorMode == .write {
                    InkTextEditor(document: document, modelContext: modelContext)
                } else {
                    MarkdownPreviewPane(markdown: document.contentMarkdown)
                }
            }
            .frame(maxWidth: .infinity)

            // Right: Inspector
            if isInspectorVisible {
                Divider()
                InspectorPane(document: document, allAnnotations: allAnnotations)
                    .frame(width: 300)
                    .transition(.move(edge: .trailing))
            }
        }
        .background(Color.inkBackground)
    }

    private func editorHeader(document: SDManuscriptDocument) -> some View {
        HStack(spacing: 12) {
            Text(document.title)
                .font(.title2.bold())
                .foregroundStyle(Color.inkTextPrimary)

            Spacer()

            // Write / Preview segmented control
            Picker("Mode", selection: $editorMode) {
                ForEach(EditorMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 160)
            .onChange(of: document.id) { _, _ in editorMode = .write }

            // Word count chip
            Text("\(document.wordCount) Words")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Color.inkTextSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.inkSurfaceElevated, in: Capsule())

            // Inspector toggle
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    isInspectorVisible.toggle()
                }
            } label: {
                Image(systemName: "sidebar.right")
                    .foregroundStyle(isInspectorVisible ? Color.inkAccentKnowledge : Color.inkTextTertiary)
            }

            // Focus mode toggle
            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    isFocusMode = true
                }
            } label: {
                Image(systemName: "pencil.and.outline")
                    .foregroundStyle(Color.inkAccentKnowledge)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.inkBackground)
    }

    private var noSelectionPlaceholder: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 52))
                .foregroundStyle(Color.inkTextTertiary)
            Text("Select a chapter from the Binder")
                .font(.headline)
                .foregroundStyle(Color.inkTextSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.inkBackground)
    }

    // MARK: - Focus Mode (Distraction-Free)

    private var focusModeView: some View {
        ZStack {
            Color.inkBackground.ignoresSafeArea()

            if let document = selectedDocument {
                FocusModeEditor(
                    document: document,
                    modelContext: modelContext,
                    onExit: {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            isFocusMode = false
                        }
                    }
                )
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 52))
                        .foregroundStyle(Color.inkTextTertiary)
                    Text("Select a chapter first")
                        .foregroundStyle(Color.inkTextSecondary)
                }
            }
        }
        .statusBarHidden(true)
    }

    // MARK: - Export

    private func performExport(format: ManuscriptExportFormat) {
        isExporting = true
        let chapters = sortedDocuments.map { (title: $0.title, markdown: $0.contentMarkdown) }
        let projectTitle = project.title

        Task.detached(priority: .userInitiated) {
            do {
                let url: URL
                switch format {
                case .markdownZip:
                    url = try ManuscriptExportService.exportAsMarkdownZip(title: projectTitle, chapters: chapters)
                case .markdownBundle:
                    url = try ManuscriptExportService.exportAsMarkdownBundle(title: projectTitle, chapters: chapters)
                case .plainText:
                    url = try ManuscriptExportService.exportAsPlainText(title: projectTitle, chapters: chapters)
                }
                await MainActor.run {
                    exportItems = [url]
                    isExporting = false
                    showShareSheet = true
                }
            } catch {
                await MainActor.run {
                    exportError = error.localizedDescription
                    isExporting = false
                    showExportError = true
                }
            }
        }
    }

    // MARK: - Binder Actions

    private func createDocument() {
        guard !newDocumentTitle.isEmpty else { return }
        let newDoc = SDManuscriptDocument(title: newDocumentTitle, orderIndex: project.documents.count)
        newDoc.project = project
        project.documents.append(newDoc)
        modelContext.insert(newDoc)
        try? modelContext.save()
        selectedDocumentID = newDoc.id
        newDocumentTitle = ""
    }

    private func moveDocuments(from source: IndexSet, to destination: Int) {
        var revisedItems = sortedDocuments
        revisedItems.move(fromOffsets: source, toOffset: destination)
        for (index, item) in revisedItems.enumerated() { item.orderIndex = index }
        try? modelContext.save()
    }

    private func deleteDocuments(at offsets: IndexSet) {
        for index in offsets {
            let doc = sortedDocuments[index]
            if let idx = project.documents.firstIndex(of: doc) {
                project.documents.remove(at: idx)
                modelContext.delete(doc)
            }
        }
        try? modelContext.save()
    }
}

// MARK: - Ink Text Editor (raw markdown with serifed font)
struct InkTextEditor: View {
    let document: SDManuscriptDocument
    let modelContext: ModelContext

    var body: some View {
        TextEditor(text: Binding(
            get: { document.contentMarkdown },
            set: { newValue in
                document.contentMarkdown = newValue
                document.modifiedAt = Date()
                try? modelContext.save()
            }
        ))
        .font(.system(.body, design: .serif))
        .foregroundStyle(Color.inkTextPrimary)
        .scrollContentBackground(.hidden)
        .background(Color.inkBackground)
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }
}

// MARK: - Focus Mode Editor
// Full-bleed, no chrome. Typewriter scrolling keeps cursor at ~60% from top.
struct FocusModeEditor: View {
    let document: SDManuscriptDocument
    let modelContext: ModelContext
    let onExit: () -> Void

    @State private var text: String = ""
    @State private var showControls = false

    var body: some View {
        ZStack(alignment: .bottom) {
            // Full-bleed editor
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        // Typewriter top spacer — pushes content down initially
                        Color.clear.frame(height: UIScreen.main.bounds.height * 0.35)

                        TextEditor(text: $text)
                            .font(.system(size: 18, weight: .regular, design: .serif))
                            .foregroundStyle(Color.inkTextPrimary)
                            .scrollContentBackground(.hidden)
                            .background(Color.clear)
                            .frame(minHeight: UIScreen.main.bounds.height * 0.5)
                            .padding(.horizontal, 32)

                        // Typewriter bottom spacer — keeps cursor from hitting bottom
                        Color.clear
                            .frame(height: UIScreen.main.bounds.height * 0.4)
                            .id("cursor")
                    }
                }
                .background(Color.inkBackground)
                .onChange(of: text) { _, _ in
                    // Scroll cursor anchor into view on every keystroke
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo("cursor", anchor: .bottom)
                    }
                }
            }
            .onTapGesture(count: 2) { onExit() }

            // Ambient word count chip — fades in on tap
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    if showControls {
                        VStack(spacing: 10) {
                            Text("\(wordCount) words")
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(Color.inkTextTertiary)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .background(.ultraThinMaterial, in: Capsule())

                            Button {
                                onExit()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 28))
                                    .foregroundStyle(Color.inkTextTertiary)
                                    .background(Color.inkBackground.opacity(0.8), in: Circle())
                            }
                        }
                        .padding(.bottom, 48)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }
                    Spacer()
                }
            }
            .animation(.easeInOut(duration: 0.2), value: showControls)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 1) {
            withAnimation { showControls.toggle() }
        }
        .onAppear { text = document.contentMarkdown }
        .onChange(of: text) { _, newValue in
            document.contentMarkdown = newValue
            document.modifiedAt = Date()
            try? modelContext.save()
        }
    }

    private var wordCount: Int {
        text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count
    }
}

// MARK: - Share Sheet Bridge
struct ActivityViewController: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Inspector Pane (ink-styled)
struct InspectorPane: View {
    let document: SDManuscriptDocument
    let allAnnotations: [SDAnnotation]

    private var attachedNotes: [SDAnnotation] {
        allAnnotations.filter { document.attachedNoteIDs.contains($0.id.uuidString) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "pin.fill")
                    .font(.caption)
                    .foregroundStyle(Color.inkAccentKnowledge)
                Text("Pinned Research")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.inkTextPrimary)
                Spacer()
                Text("\(attachedNotes.count)")
                    .font(.caption.bold())
                    .foregroundStyle(Color.inkTextTertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color.inkSurfaceElevated)

            Divider()

            if attachedNotes.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "pin.slash")
                        .font(.system(size: 30))
                        .foregroundStyle(Color.inkTextTertiary)
                    Text("No pinned notes")
                        .font(.subheadline.bold())
                        .foregroundStyle(Color.inkTextSecondary)
                    Text("Pin highlights from the Zettelkasten Hub to this chapter.")
                        .font(.caption)
                        .foregroundStyle(Color.inkTextTertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                }
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(attachedNotes) { note in
                            InspectorNoteCard(note: note)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .background(Color.inkBackground)
    }
}

// MARK: - Inspector Note Card (ink-styled)
struct InspectorNoteCard: View {
    let note: SDAnnotation

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle()
                    .fill(Color(hex: note.colorHex ?? "#FFD60A"))
                    .frame(width: 7, height: 7)
                Text(note.readwiseBookTitle ?? "Source Note")
                    .font(.caption.bold())
                    .foregroundStyle(Color.inkTextSecondary)
                    .lineLimit(1)
                Spacer()
            }

            if let text = note.selectedText, !text.isEmpty {
                Text(text)
                    .font(.system(.caption, design: .serif))
                    .foregroundStyle(Color.inkTextPrimary)
                    .lineLimit(4)
            }

            if let userNote = note.noteText, !userNote.isEmpty {
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "pencil")
                        .font(.caption2)
                        .foregroundStyle(Color.inkAccentKnowledge)
                    Text(userNote)
                        .font(.caption)
                        .italic()
                        .foregroundStyle(Color.inkTextSecondary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .inkCard(radius: InkRadius.thumbnail)
    }
}

// MARK: - Markdown Preview Pane
// Renders contentMarkdown as native AttributedString — same visual quality as Ulysses Preview.
struct MarkdownPreviewPane: View {
    let markdown: String

    var body: some View {
        ScrollView {
            if markdown.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "text.quote")
                        .font(.system(size: 36))
                        .foregroundStyle(Color.inkTextTertiary)
                    Text("Nothing to preview yet.\nSwitch to Write to start your chapter.")
                        .font(.subheadline)
                        .foregroundStyle(Color.inkTextTertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, 80)
            } else {
                renderedContent
                    .padding(.horizontal, 28)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color.inkBackground)
    }

    @ViewBuilder
    private var renderedContent: some View {
        if let attributed = try? AttributedString(
            markdown: markdown,
            options: AttributedString.MarkdownParsingOptions(
                allowsExtendedAttributes: true,
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        ) {
            Text(attributed)
                .font(.system(size: 17, weight: .regular, design: .serif))
                .foregroundStyle(Color.inkTextPrimary)
                .lineSpacing(7)
                .textSelection(.enabled)
        } else {
            // Fallback: plain text if markdown parsing fails
            Text(markdown)
                .font(.system(size: 17, weight: .regular, design: .serif))
                .foregroundStyle(Color.inkTextPrimary)
                .lineSpacing(7)
                .textSelection(.enabled)
        }
    }
}
