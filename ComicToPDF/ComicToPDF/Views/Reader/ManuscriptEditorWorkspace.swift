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

    // Workspace View Mode selector
    enum WorkspaceViewMode: String, CaseIterable { case editor = "Editor"; case corkboard = "Corkboard" }
    @State private var workspaceViewMode: WorkspaceViewMode = .editor

    private func handleDroppedNoteID(_ uuidString: String, onto document: SDManuscriptDocument) {
        guard let uuid = UUID(uuidString: uuidString) else { return }
        let fetchDescriptor = FetchDescriptor<SDAnnotation>()
        guard let all = try? modelContext.fetch(fetchDescriptor),
              let note = all.first(where: { $0.id == uuid }) else { return }
        
        let text = note.selectedText ?? note.drawingOCRText ?? ""
        let author = note.readwiseAuthor ?? "Unknown Author"
        let book = note.readwiseBookTitle ?? note.chapterTitle ?? "Unknown Book"
        let page = note.pageIndex + 1
        
        let blockquote = "\n\n> \"\(text)\"\n> — \(author), _\(book)_ (p. \(page))\n\n"
        
        document.contentMarkdown += blockquote
        document.modifiedAt = Date()
        try? modelContext.save()
    }

    // Export
    @State private var showExportMenu = false
    @State private var exportItems: [Any] = []
    @State private var showShareSheet = false
    @State private var isExporting = false
    @State private var exportError: String?
    @State private var showExportError = false

    // ✅ Speech-to-Text Subsystem
    @StateObject private var speechManager = SpeechRecognitionManager.shared

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
        .supportPencilDoubleTap {
            if editorMode == .write && !isFocusMode {
                toggleSpeechDictation()
            }
        }
    }

    // MARK: - Split View (Normal Mode)

    private var splitView: some View {
        NavigationSplitView {
            binderList
        } detail: {
            if workspaceViewMode == .corkboard {
                CorkboardView(project: project, selectedDocumentID: Binding(
                    get: { selectedDocumentID },
                    set: { newID in
                        selectedDocumentID = newID
                        if newID != nil {
                            workspaceViewMode = .editor
                        }
                    }
                ))
            } else if let document = selectedDocument {
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
                Picker("View Mode", selection: $workspaceViewMode) {
                    Image(systemName: "doc.text").tag(WorkspaceViewMode.editor)
                    Image(systemName: "square.grid.2x2").tag(WorkspaceViewMode.corkboard)
                }
                .pickerStyle(.segmented)
                .frame(width: 90)

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
            ZStack(alignment: .bottom) {
                VStack(spacing: 0) {
                    editorHeader(document: document)
                    Divider()
                    if editorMode == .write {
                        InkTextEditor(document: document, modelContext: modelContext) { droppedNoteID in
                            handleDroppedNoteID(droppedNoteID, onto: document)
                        }
                    } else {
                        MarkdownPreviewPane(markdown: document.contentMarkdown)
                    }
                }
                
                if speechManager.isRecording {
                    SpeechDictationBar { text in
                        appendSpeechText(text, to: document)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 20)
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

            if editorMode == .write {
                Button {
                    toggleSpeechDictation()
                } label: {
                    Image(systemName: speechManager.isRecording ? "mic.fill" : "mic")
                        .foregroundStyle(speechManager.isRecording ? Color.red : Color.inkAccentKnowledge)
                }
                .keyboardShortcut("d", modifiers: [.command])
            }

            // Word count chip
            Text("\(document.wordCount) Words")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Color.inkTextSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.inkSurfaceRaised, in: Capsule())

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

    private func appendSpeechText(_ text: String, to document: SDManuscriptDocument) {
        let originalText = document.contentMarkdown
        let cleanedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedText.isEmpty else { return }
        
        let newContent: String
        if originalText.isEmpty {
            newContent = cleanedText
        } else {
            if originalText.hasSuffix("\n") {
                newContent = originalText + cleanedText
            } else {
                newContent = originalText + " " + cleanedText
            }
        }
        
        document.contentMarkdown = newContent
        document.modifiedAt = Date()
        try? modelContext.save()
    }

    private func toggleSpeechDictation() {
        let manager = SpeechRecognitionManager.shared
        if manager.isRecording {
            manager.stopDictation(commit: true)
        } else {
            Task {
                let granted = await manager.requestPermissions()
                if granted {
                    do {
                        try manager.startDictation()
                    } catch {
                        // Handle error
                    }
                }
            }
        }
    }
}

// MARK: - Wikilink-Aware Text Editor
// Renders [[ChapterTitle]] tokens as tappable highlighted chips over the native TextEditor.
// Tap navigates to the matching chapter; unresolved links appear with a warning tint.
struct WikilinkAwareEditor: View {
    let document: SDManuscriptDocument
    let modelContext: ModelContext
    /// All chapters in the project — used for wikilink resolution.
    let allDocuments: [SDManuscriptDocument]
    /// Called when the user taps a resolved wikilink.
    var onNavigate: (UUID) -> Void = { _ in }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // ── Layer 1: Native TextEditor (keyboard, undo, autocorrect) ──
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

            // ── Layer 2: Wikilink chip overlay (non-interactive for text, interactive for chips) ──
            WikilinkChipOverlay(
                text: document.contentMarkdown,
                allDocuments: allDocuments,
                onNavigate: onNavigate
            )
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .allowsHitTesting(true) // chips intercept taps; text beneath handles keyboard
        }
    }
}

// MARK: - Wikilink Chip Overlay
// Parses [[text]] tokens and renders tappable chips at approximate text positions.
// Uses a GeometryReader + TextKit-style measurement to stay aligned with TextEditor content.
private struct WikilinkChipOverlay: View {
    let text: String
    let allDocuments: [SDManuscriptDocument]
    var onNavigate: (UUID) -> Void

    private var links: [WikilinkToken] {
        WikilinkParser.parse(text, against: allDocuments)
    }

    var body: some View {
        // Render chips in a flowing layout that mirrors the text paragraph flow
        FlowLayout(tokens: links, onNavigate: onNavigate)
    }
}

// MARK: - Wikilink Token
private struct WikilinkToken: Identifiable {
    let id = UUID()
    let displayText: String       // text inside [[ ]]
    let resolvedDocumentID: UUID? // nil = unresolved
}

// MARK: - Wikilink Parser
private enum WikilinkParser {
    private static let pattern = try? NSRegularExpression(
        pattern: #"\[\[([^\]]+)\]\]"#,
        options: []
    )

    static func parse(_ text: String, against docs: [SDManuscriptDocument]) -> [WikilinkToken] {
        guard let pattern else { return [] }
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        return pattern.matches(in: text, range: range).map { match in
            let inner = nsText.substring(with: match.range(at: 1))
            let resolved = docs.first {
                $0.title.localizedCaseInsensitiveCompare(inner) == .orderedSame
            }?.id
            return WikilinkToken(displayText: inner, resolvedDocumentID: resolved)
        }
    }
}

// MARK: - Flow Layout for Wikilink Chips
// Simple horizontal wrapping layout — chips appear inline below the text block.
private struct FlowLayout: View {
    let tokens: [WikilinkToken]
    let onNavigate: (UUID) -> Void

    var body: some View {
        if tokens.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Wikilinks in this chapter")
                    .font(.caption2.uppercaseSmallCaps())
                    .foregroundStyle(Color.inkTextTertiary)
                    .padding(.top, 8)

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 90, maximum: 200), spacing: 6)],
                    alignment: .leading,
                    spacing: 6
                ) {
                    ForEach(tokens) { token in
                        WikilinkChip(token: token, onNavigate: onNavigate)
                    }
                }
            }
            // Anchor the overlay to the bottom of the editor so it doesn't obscure typed text
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(.bottom, 8)
        }
    }
}

// MARK: - Wikilink Chip
private struct WikilinkChip: View {
    let token: WikilinkToken
    let onNavigate: (UUID) -> Void

    private var isResolved: Bool { token.resolvedDocumentID != nil }

    var body: some View {
        Button {
            if let id = token.resolvedDocumentID { onNavigate(id) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isResolved ? "link" : "questionmark")
                    .font(.system(size: 10, weight: .semibold))
                Text("[[\(token.displayText)]]")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .lineLimit(1)
            }
            .foregroundStyle(isResolved ? Color.inkAccentKnowledge : Color.inkRed)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                (isResolved ? Color.inkAccentKnowledge : Color.inkRed).opacity(0.12),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(
                        (isResolved ? Color.inkAccentKnowledge : Color.inkRed).opacity(0.3),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(!isResolved)
        .opacity(isResolved ? 1.0 : 0.6)
    }
}

// MARK: - Legacy InkTextEditor (plain, no wikilink support — kept for compatibility)
struct InkTextEditor: View {
    let document: SDManuscriptDocument
    let modelContext: ModelContext
    var onDropReceived: ((String) -> Void)? = nil

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
        .onDrop(of: [.text], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: String.self) { string, error in
                    if let noteID = string {
                        DispatchQueue.main.async {
                            onDropReceived?(noteID)
                        }
                    }
                }
            }
            return true
        }
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

    // ✅ Speech-to-Text Subsystem
    @StateObject private var speechManager = SpeechRecognitionManager.shared

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
                            HStack(spacing: 8) {
                                Text("\(wordCount) words")
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                    .foregroundStyle(Color.inkTextTertiary)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 6)
                                    .background(.ultraThinMaterial, in: Capsule())
                                
                                Button {
                                    toggleSpeechDictation()
                                } label: {
                                    Image(systemName: speechManager.isRecording ? "mic.fill" : "mic")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(speechManager.isRecording ? Color.red : Color.inkTextTertiary)
                                        .padding(8)
                                        .background(.ultraThinMaterial, in: Circle())
                                }
                                .keyboardShortcut("d", modifiers: [.command])
                            }

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
            
            // Dictation Bar Overlay
            if speechManager.isRecording {
                SpeechDictationBar { transcribedText in
                    appendSpeechText(transcribedText)
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 24)
            }
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
        .supportPencilDoubleTap {
            toggleSpeechDictation()
        }
    }

    private var wordCount: Int {
        text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count
    }

    private func appendSpeechText(_ newText: String) {
        let cleanedText = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedText.isEmpty else { return }
        
        if text.isEmpty {
            text = cleanedText
        } else {
            if text.hasSuffix("\n") {
                text += cleanedText
            } else {
                text += " " + cleanedText
            }
        }
    }

    private func toggleSpeechDictation() {
        let manager = SpeechRecognitionManager.shared
        if manager.isRecording {
            manager.stopDictation(commit: true)
        } else {
            Task {
                let granted = await manager.requestPermissions()
                if granted {
                    do {
                        try manager.startDictation()
                    } catch {
                        // Handle error
                    }
                }
            }
        }
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
            .background(Color.inkSurfaceRaised)

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
        .onDrag {
            NSItemProvider(object: note.id.uuidString as NSString)
        }
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
