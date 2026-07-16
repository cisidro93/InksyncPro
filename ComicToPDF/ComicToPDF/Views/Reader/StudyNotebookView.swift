import SwiftUI
import SwiftData
import CryptoKit
import PencilKit

struct StudyNotebookView: View {
    let bookID: String       // the ConvertedPDF's UUID string
    let bookTitle: String    // human-readable title shown in the Zettelkasten Hub
    var fileURL: URL? = nil  // Optional source file URL for page preview generation
    var showBackButton: Bool = false
    
    @Environment(\.dismiss) private var dismiss

    init(bookID: String, bookTitle: String, fileURL: URL? = nil, showBackButton: Bool = false) {
        self.bookID = bookID
        self.bookTitle = bookTitle
        self.fileURL = fileURL
        self.showBackButton = showBackButton
    }

    // Phase 1: Native Zettelkasten Integration
    @Environment(\.modelContext) private var modelContext
    @State private var activeNoteAnnotation: SDAnnotation?
    
    @Environment(\.colorScheme) var colorScheme
    @State private var isFocused: Bool = false
    
    @State private var localNotes: String = ""
    @State private var saveTask: Task<Void, Never>? = nil
    @State private var ocrTask: Task<Void, Never>? = nil
    
    // ✅ Phase 2: PencilKit Integration
    enum InputMode: String {
        case markdown = "Text"
        case handwriting = "Pencil"
    }
    @AppStorage("studyNotebookInputMode") private var inputMode: InputMode = .markdown
    @State private var paperStyle: PaperStyle = .plain
    @State private var selectedBookForReader: ConvertedPDF? = nil
    @AppStorage("studyNotebookPlacement") private var notebookPlacement: SidebarPlacement = .right
    @State private var canvasView = PKCanvasView()
    
    // Custom drawing tools states
    @State private var activeDrawingTool: DrawingTool = .pen
    @State private var strokeColor: Color = .primary
    @State private var strokeWidth: CGFloat = 4.0
    @State private var isRulerActive = false
    @State private var isSmartShapesEnabled = true
    @State private var eraserType: PKEraserTool.EraserType = .vector
    @State private var lastActiveWritingTool: DrawingTool = .pen
    
    // Spaced Repetition Study Deck states
    @State private var isStudyModeActive = false
    @State private var currentCardIndex = 0
    @State private var isAnswerRevealed = false
    @State private var studyCards: [SDAnnotation] = []
    @State private var correctAnswersCount = 0

    enum DrawingTool: String, CaseIterable, Identifiable {
        case pen = "Pen"
        case pencil = "Pencil"
        case highlighter = "Highlighter"
        case eraser = "Eraser"
        case lasso = "Lasso"
        
        var id: String { rawValue }
        
        var icon: String {
            switch self {
            case .pen: return "pencil.tip"
            case .pencil: return "pencil"
            case .highlighter: return "highlighter"
            case .eraser: return "eraser.line.dashed"
            case .lasso: return "lasso"
            }
        }
    }
    
    private let drawingColors: [Color] = [.primary, .red, .blue, .green, .orange]
    
    private func updateCanvasTool() {
        switch activeDrawingTool {
        case .pen:
            canvasView.tool = PKInkingTool(.pen, color: UIColor(strokeColor), width: strokeWidth)
        case .pencil:
            canvasView.tool = PKInkingTool(.pencil, color: UIColor(strokeColor), width: strokeWidth)
        case .highlighter:
            canvasView.tool = PKInkingTool(.marker, color: UIColor(strokeColor).withAlphaComponent(0.35), width: strokeWidth * 2.5)
        case .eraser:
            canvasView.tool = PKEraserTool(eraserType)
        case .lasso:
            canvasView.tool = PKLassoTool()
        }
        canvasView.isRulerActive = isRulerActive
    }
    
    // ✅ Phase 3: Highlights Drawer
    @State private var showHighlightsDrawer = false
    @State private var bookHighlights: [SDAnnotation] = []
    
    // Pro Search & Filter State
    @State private var highlightSearchQuery = ""
    @State private var highlightSortNewest = true
    @State private var selectedTagFilter: String? = nil
    @State private var activeHighlightToEdit: SDAnnotation? = nil
    @State private var showWritingAssistant = false
    
    // ✅ Speech-to-Text Subsystem
    @StateObject private var speechManager = SpeechRecognitionManager.shared
    
    // ✅ Phase 4: Page Link Previews
    @State private var resolvedPDF: SDConvertedPDF? = nil
    @State private var previewPageIndex: Int? = nil
    @State private var previewImage: UIImage? = nil
    @State private var showPreviewModal = false
    @State private var isExtractingPreviewImage = false
    
    var body: some View {
        ZStack(alignment: .bottom) {
            // MARK: Premium Background Base
            Color.inkBackground.ignoresSafeArea()
            
            VStack(spacing: 0) {
                // MARK: Glassmorphic Header
                HStack(spacing: 12) {
                    if showBackButton {
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            dismiss()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.left")
                                Text("Back")
                                    .font(.system(size: 15, weight: .bold, design: .rounded))
                            }
                            .foregroundColor(.orange)
                        }
                        .buttonStyle(.plain)
                    }
                    
                    Image(systemName: "notebook.toptab.fill")
                        .foregroundStyle(LinearGradient(colors: [Theme.blue, Color.purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .font(.system(size: 18, weight: .bold))
                    
                    Text("Study Notebook")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundColor(.primary)
                    
                    Spacer()
                    
                    // Input Mode Toggle
                    Picker("Input", selection: $inputMode) {
                        Image(systemName: "keyboard").tag(InputMode.markdown)
                        Image(systemName: "applepencil").tag(InputMode.handwriting)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 110)
                    
                    if inputMode == .markdown {
                        Button {
                            toggleSpeechDictation()
                        } label: {
                            Image(systemName: speechManager.isRecording ? "mic.fill" : "mic")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(speechManager.isRecording ? .red : .primary)
                                .padding(8)
                                .background(speechManager.isRecording ? Color.red.opacity(0.15) : Color.primary.opacity(0.08))
                                .clipShape(Circle())
                        }
                        .keyboardShortcut("d", modifiers: [.command])
                    }
                    
                    // Paper Style Menu (Available in both modes)
                    Menu {
                        Picker("Paper Style", selection: $paperStyle) {
                            ForEach(PaperStyle.allCases) { style in
                                Label(style.rawValue, systemImage: style.icon).tag(style)
                            }
                        }
                    } label: {
                        Image(systemName: "doc.plaintext")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.primary)
                            .padding(8)
                            .background(Color.primary.opacity(0.08))
                            .clipShape(Circle())
                    }
                    
                    // Smart Summary Helper
                    Button {
                        generateAISummary()
                    } label: {
                        Image(systemName: "sparkles")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.purple)
                            .padding(8)
                            .background(Color.purple.opacity(0.1))
                            .clipShape(Circle())
                    }
                    
                    // Spelling & Grammar Assistant
                    Button {
                        showWritingAssistant = true
                    } label: {
                        Image(systemName: "checkmark.bubble.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.blue)
                            .padding(8)
                            .background(Color.blue.opacity(0.1))
                            .clipShape(Circle())
                    }
                    
                    if !bookHighlights.isEmpty {
                        Button {
                            HapticEngine.light()
                            studyCards = bookHighlights
                            currentCardIndex = 0
                            isAnswerRevealed = false
                            withAnimation(.spring()) {
                                isStudyModeActive = true
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "play.rectangle.on.rectangle.fill")
                                Text("Study")
                                    .font(.system(size: 13, weight: .bold, design: .rounded))
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                LinearGradient(colors: [Theme.blue, Color.purple], startPoint: .topLeading, endPoint: .bottomTrailing),
                                in: Capsule()
                            )
                        }
                    }
                    
                    // Export Suite Menu
                    Menu {
                        Button { exportNotes(as: .markdown) } label: { Label("Export Markdown (.md)", systemImage: "arrow.down.doc") }
                        Button { exportNotes(as: .plainText) } label: { Label("Export Plain Text (.txt)", systemImage: "doc.text") }
                        Button { exportZettelkastenZip() } label: { Label("Export Zettelkasten Zip (Obsidian)", systemImage: "archivebox") }
                        Button { shareNotes() } label: { Label("Share Note...", systemImage: "square.and.arrow.up") }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.primary)
                            .padding(8)
                            .background(Color.primary.opacity(0.08))
                            .clipShape(Circle())
                    }

                    if showBackButton {
                        if let matchedPDF = fetchBackingBook() {
                            Button {
                                HapticEngine.light()
                                selectedBookForReader = matchedPDF
                            } label: {
                                Image(systemName: "book")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(.primary)
                                    .padding(8)
                                    .background(Color.primary.opacity(0.08))
                                    .clipShape(Circle())
                            }
                        }
                    }

                    // Highlights Drawer Toggle
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            showHighlightsDrawer.toggle()
                        }
                    } label: {
                        Image(systemName: "highlighter")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(showHighlightsDrawer ? Theme.blue : .primary)
                            .padding(8)
                            .background(showHighlightsDrawer ? Theme.blue.opacity(0.1) : Color.primary.opacity(0.08))
                            .clipShape(Circle())
                    }

                    // Stats Menu HUD
                    Menu {
                        Section("Note Stats") {
                            Button(action: {}) { Label("\(localNotes.count) Characters", systemImage: "text.alignleft") }.disabled(true)
                            Button(action: {}) { Label("\(localNotes.split { $0.isWhitespace || $0.isNewline }.count) Words", systemImage: "character.textbox") }.disabled(true)
                            Button(action: {}) {
                                let lines = localNotes.components(separatedBy: .newlines).filter { !$0.isEmpty }.count
                                Label("\(lines) Paragraphs", systemImage: "text.justify.left")
                            }.disabled(true)
                            Button(action: {}) {
                                let wCount = localNotes.split { $0.isWhitespace || $0.isNewline }.count
                                let readingTime = max(1, Int(ceil(Double(wCount) / 200.0)))
                                Label("\(readingTime) min read", systemImage: "clock")
                            }.disabled(true)
                        }
                    } label: {
                        HStack(spacing: 3) {
                            let words = localNotes.split { $0.isWhitespace || $0.isNewline }.count
                            Text("\(words)w")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                            Image(systemName: "info.circle")
                                .font(.system(size: 9))
                        }
                        .foregroundColor(Theme.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                    }

                    if isFocused {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 8))
                            .foregroundColor(Theme.blue)
                            .symbolEffect(.pulse)
                    } else {
                        Button {
                            isFocused = false
                        } label: {
                            Image(systemName: "keyboard.chevron.compact.down")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.primary)
                                .padding(8)
                                .background(Color.primary.opacity(0.08))
                                .clipShape(Circle())
                        }
                    }
                    
                    // Quick Flip side button (Left/Right handed mode)
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            notebookPlacement = (notebookPlacement == .right) ? .left : .right
                        }
                    } label: {
                        Image(systemName: notebookPlacement == .right ? "sidebar.left" : "sidebar.right")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.primary)
                            .padding(8)
                            .background(Color.primary.opacity(0.08))
                            .clipShape(Circle())
                    }
                    
                    Button {
                        NotificationCenter.default.post(name: .hideStudyNotebook, object: nil)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.primary)
                            .padding(8)
                            .background(Color.primary.opacity(0.08))
                            .clipShape(Circle())
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    Color.inkBackground.opacity(0.85)
                        .background(.ultraThinMaterial)
                )
                .overlay(Rectangle().frame(height: 1).foregroundColor(Color.primary.opacity(0.05)), alignment: .bottom)
                
                if inputMode == .handwriting {
                    canvasToolbar
                }
                
                // MARK: Notebook Canvas
                ZStack(alignment: .trailing) {
                    if inputMode == .markdown {
                        ZStack {
                            NotebookPaperBackground(style: paperStyle, colorScheme: colorScheme)
                            MarkdownTextEditor(text: $localNotes, isFocused: $isFocused, paperStyle: paperStyle, onLinkTapped: handleLinkTapped)
                        }
                        .onChange(of: localNotes) { _, _ in debounceSave() }
                    } else {
                        ZStack {
                            NotebookPaperBackground(style: paperStyle, colorScheme: colorScheme)
                            StudyCanvasView(canvasView: $canvasView, isSmartShapesEnabled: $isSmartShapesEnabled, onSaved: debounceSave)
                        }
                        .padding(.top, 8)
                        .onAppear {
                            updateCanvasTool()
                        }
                    }
                    
                    // MARK: Highlights Drawer Overlay
                    if showHighlightsDrawer {
                        highlightsDrawer
                    }
                }
            }
            
            if speechManager.isRecording {
                SpeechDictationBar { text in
                    NotificationCenter.default.post(name: .insertDictatedText, object: nil, userInfo: ["text": text])
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
            }
            
            // MARK: Interactive Page Preview Modal Overlay
            if showPreviewModal {
                pagePreviewModalOverlay
            }
            
            if isStudyModeActive {
                studyFlashcardOverlay
            }
        }
        .sheet(item: $activeHighlightToEdit) { annotation in
            AnnotationEditSheet(annotation: annotation)
                .presentationDetents([.height(180), .medium])
                .presentationDragIndicator(.visible)
        }
        .onChange(of: activeHighlightToEdit) { _, newVal in
            if newVal == nil {
                refreshHighlights()
            }
        }
        .sheet(isPresented: $showWritingAssistant) {
            WritingAssistantSheet(text: $localNotes)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .fullScreenCover(item: $selectedBookForReader) { pdf in
            UnifiedReaderView(pdf: pdf)
        }
        .onAppear {
            Logger.shared.log("StudyNotebook appeared for book: '\(bookTitle)'", category: "Notebook", type: .info)
            initializeSDAnnotation()
        }
        .onChange(of: paperStyle) { _, newStyle in
            if let actualUUID = UUID(uuidString: bookID) {
                let nbFetch = FetchDescriptor<SDNotebook>(predicate: #Predicate { $0.id == actualUUID })
                if let nb = try? modelContext.fetch(nbFetch).first {
                    nb.templateStyle = newStyle.rawValue
                    try? modelContext.save()
                    Logger.shared.log("Persisted paper style '\(newStyle.rawValue)' to notebook '\(bookTitle)'", category: "Notebook", type: .success)
                }
            }
        }
        .supportPencilDoubleTap {
            if inputMode == .markdown {
                toggleSpeechDictation()
            } else if inputMode == .handwriting {
                HapticEngine.light()
                if activeDrawingTool == .eraser {
                    activeDrawingTool = lastActiveWritingTool
                } else {
                    lastActiveWritingTool = activeDrawingTool
                    activeDrawingTool = .eraser
                }
                updateCanvasTool()
            }
        }
        .onDisappear {
            // Final explicit sync flush layer
            Logger.shared.log("StudyNotebook disappearing — flushing note to SwiftData for '\(bookTitle)'", category: "Notebook", type: .info)
            saveTask?.cancel()
            ocrTask?.cancel()
            let note = localNotes
            let drawing = canvasView.drawing
            let drawingData = drawing.dataRepresentation()
            
            activeNoteAnnotation?.noteText = note
            activeNoteAnnotation?.drawingData = drawingData
            activeNoteAnnotation?.modifiedAt = Date()
            do {
                try modelContext.save()
                Logger.shared.log("Flush save succeeded for '\(bookTitle)'", category: "Notebook", type: .success)
                if let annotation = activeNoteAnnotation {
                    SpotlightIndexer.shared.indexAnnotation(annotation)
                }
            } catch {
                Logger.shared.log("Flush save FAILED for '\(bookTitle)': \(error.localizedDescription)", category: "Notebook", type: .error)
            }
            
            if !drawing.bounds.isEmpty {
                Task.detached(priority: .background) {
                    if let ocrText = await HandwritingOCRManager.shared.recognizeHandwriting(in: drawing) {
                        await MainActor.run {
                            if let active = self.activeNoteAnnotation, active.drawingOCRText != ocrText {
                                active.drawingOCRText = ocrText
                                active.modifiedAt = Date()
                                try? self.modelContext.save()
                                Logger.shared.log("Flush Handwriting OCR updated for '\(self.bookTitle)': \(ocrText.prefix(40))...", category: "OCR", type: .success)
                                SpotlightIndexer.shared.indexAnnotation(active)
                            }
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - Core Execution
    
    /// Binds the StudyNotebook to the Global Zettelkasten Hub's SwiftData Engine natively.
    private func initializeSDAnnotation() {
        var resolvedBookUUID = UUID()
        if let actualUUID = UUID(uuidString: bookID) {
            resolvedBookUUID = actualUUID
        } else {
            let hash = Insecure.MD5.hash(data: Data(bookID.utf8))
            resolvedBookUUID = hash.withUnsafeBytes { ptr -> UUID in
                let bytes = ptr.bindMemory(to: UInt8.self).baseAddress!
                return UUID(uuid: (
                    bytes[0], bytes[1], bytes[2], bytes[3],
                    bytes[4], bytes[5], bytes[6], bytes[7],
                    bytes[8], bytes[9], bytes[10], bytes[11],
                    bytes[12], bytes[13], bytes[14], bytes[15]
                ))
            }
        }
        
        let targetPDFID = resolvedBookUUID
        let fetchDescriptor = FetchDescriptor<SDAnnotation>(predicate: #Predicate { $0.kindRaw == "note" })
        
        if let allNotes = try? modelContext.fetch(fetchDescriptor),
           let existing = allNotes.first(where: { $0.pdfID == targetPDFID }) {
            self.activeNoteAnnotation = existing
            self.localNotes = existing.noteText ?? ""
            let wordCount = (existing.noteText ?? "").split { $0.isWhitespace }.count
            Logger.shared.log("Loaded existing note for '\(bookTitle)' (\(wordCount) words)", category: "Notebook", type: .success)
            if let dData = existing.drawingData, let drawing = try? PKDrawing(data: dData) {
                self.canvasView.drawing = drawing
                Logger.shared.log("Restored PencilKit drawing for '\(bookTitle)'", category: "Notebook", type: .info)
            }
        } else {
            Logger.shared.log("No existing note found for '\(bookTitle)' — creating new SDAnnotation", category: "Notebook", type: .info)
            let newNote = SDAnnotation(
                id: UUID(),
                pdfID: targetPDFID.uuidString,
                pageIndex: 0,
                text: nil,
                note: "",
                isReadwiseImport: false,
                readwiseBookTitle: bookTitle.isEmpty ? nil : bookTitle,
                readwiseAuthor: nil,
                createdAt: Date()
            )
            newNote.kindRaw = "note"
             modelContext.insert(newNote)
             try? modelContext.save()
             self.activeNoteAnnotation = newNote
             self.localNotes = ""
             Logger.shared.log("New note created, inserted and saved for '\(bookTitle)'", category: "Notebook", type: .success)
         }
        
        // Fetch paper style from SDNotebook if it exists
        if let actualUUID = UUID(uuidString: bookID) {
            let nbFetch = FetchDescriptor<SDNotebook>(predicate: #Predicate { $0.id == actualUUID })
            if let nb = try? modelContext.fetch(nbFetch).first {
                self.paperStyle = PaperStyle(rawValue: nb.templateStyle) ?? .plain
                Logger.shared.log("Loaded template style '\(nb.templateStyle)' for notebook '\(bookTitle)'", category: "Notebook", type: .success)
            }
        }
        
        // Fetch existing highlights for this book
        let hDescriptor = FetchDescriptor<SDAnnotation>(predicate: #Predicate { $0.kindRaw == "highlight" && $0.pdfID == targetPDFID })
        if let h = try? modelContext.fetch(hDescriptor) {
            self.bookHighlights = h.sorted { $0.createdAt > $1.createdAt }
            Logger.shared.log("Fetched \(h.count) highlight(s) for '\(bookTitle)'", category: "Notebook", type: .info)
        } else {
            Logger.shared.log("Highlights fetch failed for '\(bookTitle)'", category: "Notebook", type: .warning)
        }
        
        // Fetch and resolve the SDConvertedPDF for page preview generation
        if let allBooks = try? modelContext.fetch(FetchDescriptor<SDConvertedPDF>()),
           let book = allBooks.first(where: { $0.id == targetPDFID }) {
            self.resolvedPDF = book
            Logger.shared.log("StudyNotebookView: resolved SDConvertedPDF '\(book.name)' from SwiftData", category: "Notebook", type: .success)
        } else {
            Logger.shared.log("StudyNotebookView: could not resolve SDConvertedPDF for UUID \(targetPDFID)", category: "Notebook", type: .warning)
        }
    }

    private func refreshHighlights() {
        var targetPDFID = UUID()
        if let actualUUID = UUID(uuidString: bookID) {
            targetPDFID = actualUUID
        }
        let hDescriptor = FetchDescriptor<SDAnnotation>(predicate: #Predicate { $0.kindRaw == "highlight" && $0.pdfID == targetPDFID })
        if let h = try? modelContext.fetch(hDescriptor) {
            self.bookHighlights = h.sorted { $0.createdAt > $1.createdAt }
        }
    }
    
    private func debounceSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000) // 1.2 seconds for data saving debounce
            if !Task.isCancelled {
                let note = self.localNotes
                let drawing = self.canvasView.drawing
                let drawingData = drawing.dataRepresentation()
                
                await MainActor.run {
                    self.activeNoteAnnotation?.noteText = note
                    self.activeNoteAnnotation?.drawingData = drawingData
                    self.activeNoteAnnotation?.modifiedAt = Date()
                    if let annotation = self.activeNoteAnnotation {
                        SpotlightIndexer.shared.indexAnnotation(annotation)
                    }
                    try? self.modelContext.save()
                }
                
                // Decouple and high-duration debounce expensive Vision OCR tasks to save battery
                ocrTask?.cancel()
                ocrTask = Task {
                    try? await Task.sleep(nanoseconds: 5_000_000_000) // 5.0 seconds of absolute pause before running OCR
                    guard !Task.isCancelled else { return }
                    
                    if !drawing.bounds.isEmpty {
                        Task.detached(priority: .background) {
                            if let ocrText = await HandwritingOCRManager.shared.recognizeHandwriting(in: drawing) {
                                await MainActor.run {
                                    if let active = self.activeNoteAnnotation, active.drawingOCRText != ocrText {
                                        active.drawingOCRText = ocrText
                                        active.modifiedAt = Date()
                                        Logger.shared.log("Handwriting OCR updated (debounced 5s) for '\(self.bookTitle)': \(ocrText.prefix(40))...", category: "OCR", type: .success)
                                        SpotlightIndexer.shared.indexAnnotation(active)
                                        try? self.modelContext.save()
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var allTagsInHighlights: [String] {
        let all = bookHighlights.flatMap { $0.tags ?? [] }
        return Array(Set(all)).sorted()
    }

    private var filteredHighlights: [SDAnnotation] {
        var h = bookHighlights
        if let filter = selectedTagFilter {
            h = h.filter { $0.tags?.contains(filter) ?? false }
        }
        if !highlightSearchQuery.isEmpty {
            h = h.filter { $0.selectedText?.localizedCaseInsensitiveContains(highlightSearchQuery) ?? false }
        }
        if highlightSortNewest {
            return h.sorted { $0.createdAt > $1.createdAt }
        } else {
            return h.sorted { $0.pageIndex < $1.pageIndex }
        }
    }

    private func formatHighlightForInsertion(_ highlight: SDAnnotation) -> String {
        guard let text = highlight.selectedText else { return "" }
        let pageLink = "[Page \(highlight.pageIndex + 1)](inksync://reader/jump?page=\(highlight.pageIndex))"
        var md = "\n\n> \(text) (\(pageLink))"
        if let note = highlight.noteText, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            md += "\n> *Thoughts:* \(note)"
        }
        if let tags = highlight.tags, !tags.isEmpty {
            let tagStrs = tags.map { "#\($0)" }.joined(separator: " ")
            md += "\n> \(tagStrs)"
        }
        md += "\n\n"
        return md
    }

    private func insertHighlightIntoNote(_ highlight: SDAnnotation) {
        let citation = formatHighlightForInsertion(highlight)
        guard !citation.isEmpty else { return }
        withAnimation {
            localNotes += citation
            debounceSave()
        }
        Logger.shared.log("Inserted formatted highlight citation into note for '\(bookTitle)'", category: "Notebook", type: .info)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func generateAISummary() {
        Logger.shared.log("generateAISummary called for '\(bookTitle)' (\(bookHighlights.count) highlights available)", category: "Notebook", type: .info)
        if bookHighlights.isEmpty {
            Logger.shared.log("generateAISummary: no highlights found — inserting placeholder for '\(bookTitle)'", category: "Notebook", type: .warning)
            localNotes += "\n\n### 💡 Smart Summary\nNo highlights available to summarize. Add some highlights in the reader first!"
            return
        }
        
        let pageLinks = Array(Set(bookHighlights.map { $0.pageIndex + 1 }))
            .sorted()
            .map { "[[Page \($0)]]" }
            .joined(separator: ", ")
            
        let prompt = """
        
        ### 💡 Smart Highlights Summary
        *Generated on \(Date().formatted(date: .abbreviated, time: .shortened))*
        
        **Key Takeaways:**
        - This document discusses several core themes. Based on your \(bookHighlights.count) highlights, the primary focal points relate to:
        \(bookHighlights.prefix(3).map { "  * " + ($0.selectedText?.prefix(80).appending("...") ?? "") }.joined(separator: "\n"))
        
        **Action Items & Key Insights:**
        - Review highlighted sections on page(s) \(pageLinks).
        - Synthesize these key passages into your core Zettelkasten card collection.
        """
        
        withAnimation {
            localNotes += prompt
            debounceSave()
        }
        Logger.shared.log("Smart summary generated for '\(bookTitle)' using \(bookHighlights.count) highlight(s)", category: "Notebook", type: .success)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func handleLinkTapped(_ url: URL) {
        guard url.scheme == "inksync",
              url.host == "page",
              let lastComponent = url.pathComponents.last,
              let pageIndex = Int(lastComponent) else { return }
        
        Logger.shared.log("Page link tapped: page index \(pageIndex)", category: "Notebook", type: .info)
        
        self.previewPageIndex = pageIndex
        self.previewImage = nil
        self.isExtractingPreviewImage = true
        withAnimation(.easeOut(duration: 0.2)) {
            self.showPreviewModal = true
        }
        
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        
        if let bookURL = fileURL ?? resolvedPDF?.url {
            Task {
                let img = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                    return PhysicalFileSystemRouter.extractPageImage(from: bookURL, pageIndex: pageIndex)
                }.value
                
                await MainActor.run {
                    self.previewImage = img
                    self.isExtractingPreviewImage = false
                    if img == nil {
                        Logger.shared.log("Failed to extract page image for index \(pageIndex)", category: "Notebook", type: .error)
                    }
                }
            }
        } else {
            self.isExtractingPreviewImage = false
            Logger.shared.log("No resolved PDF or URL available to extract page preview.", category: "Notebook", type: .warning)
        }
    }

    @ViewBuilder
    private var pagePreviewModalOverlay: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.easeOut(duration: 0.2)) {
                        showPreviewModal = false
                        previewPageIndex = nil
                        previewImage = nil
                    }
                }
            
            VStack(spacing: 0) {
                HStack {
                    if let pageIndex = previewPageIndex {
                        Text("Page \(pageIndex + 1)")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundColor(Theme.text)
                    } else {
                        Text("Page Preview")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundColor(Theme.text)
                    }
                    
                    Spacer()
                    
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) {
                            showPreviewModal = false
                            previewPageIndex = nil
                            previewImage = nil
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundColor(Theme.textSecondary)
                            .symbolRenderingMode(.hierarchical)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .background(Color.primary.opacity(0.04))
                
                Divider()
                
                ZStack {
                    if isExtractingPreviewImage {
                        VStack(spacing: 12) {
                            ProgressView()
                                .scaleEffect(1.2)
                            Text("Loading preview...")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(Theme.textSecondary)
                        }
                        .frame(maxHeight: .infinity)
                    } else if let image = previewImage {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .cornerRadius(8)
                            .shadow(color: Color.black.opacity(0.15), radius: 8, x: 0, y: 4)
                            .padding(16)
                            .frame(maxHeight: .infinity)
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 32))
                                .foregroundColor(.red.opacity(0.8))
                            Text("No preview available")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(Theme.textSecondary)
                        }
                        .frame(maxHeight: .infinity)
                    }
                }
                .frame(height: 380)
                .background(Color.black.opacity(0.03))
                
                Divider()
                
                if let pageIndex = previewPageIndex {
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) {
                            showPreviewModal = false
                            previewPageIndex = nil
                            previewImage = nil
                        }
                        NotificationCenter.default.post(
                            name: NSNotification.Name("Reader_JumpToPage"),
                            object: nil,
                            userInfo: ["pageIndex": pageIndex]
                        )
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                    } label: {
                        Text("Jump to Page \(pageIndex + 1)")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(
                                LinearGradient(colors: [Theme.blue, Theme.purple], startPoint: .leading, endPoint: .trailing)
                            )
                            .cornerRadius(10)
                            .shadow(color: Theme.blue.opacity(0.3), radius: 6, x: 0, y: 3)
                    }
                    .padding(16)
                }
            }
            .frame(width: 320)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.inkSurface.opacity(0.85))
                    .background(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.25), radius: 20, x: 0, y: 10)
            .transition(.asymmetric(
                insertion: .scale(scale: 0.95).combined(with: .opacity).animation(.spring(response: 0.3, dampingFraction: 0.75)),
                removal: .opacity.animation(.easeOut(duration: 0.15))
            ))
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
                        Logger.shared.log("Failed to start dictation: \(error.localizedDescription)", category: "STT", type: .error)
                    }
                }
            }
        }
    }

    enum ExportType {
        case markdown, plainText
    }
    
    private func exportNotes(as type: ExportType) {
        let content: String
        let filename: String
        let formatLabel: String
        
        switch type {
        case .markdown:
            content = localNotes
            filename = "\(bookTitle.isEmpty ? "StudyNotes" : bookTitle.replacingOccurrences(of: " ", with: "_"))_Notes.md"
            formatLabel = "Markdown"
        case .plainText:
            content = localNotes
            filename = "\(bookTitle.isEmpty ? "StudyNotes" : bookTitle.replacingOccurrences(of: " ", with: "_"))_Notes.txt"
            formatLabel = "Plain Text"
        }
        
        Logger.shared.log("exportNotes(\(formatLabel)) called for '\(bookTitle)' — \(content.count) chars to \(filename)", category: "Notebook", type: .info)
        
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent(filename)
        
        do {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            Logger.shared.log("Note export file written: \(filename)", category: "Notebook", type: .success)
            let activityVC = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let rootVC = windowScene.windows.first?.rootViewController {
                if let popover = activityVC.popoverPresentationController {
                    popover.sourceView = rootVC.view
                    popover.sourceRect = CGRect(x: rootVC.view.bounds.midX, y: rootVC.view.bounds.midY, width: 0, height: 0)
                    popover.permittedArrowDirections = []
                }
                rootVC.present(activityVC, animated: true)
            }
        } catch {
            Logger.shared.log("exportNotes(\(formatLabel)) FAILED for '\(bookTitle)': \(error.localizedDescription)", category: "Notebook", type: .error)
        }
    }

    private func exportZettelkastenZip() {
        Task {
            do {
                let allPDFs = try? modelContext.fetch(FetchDescriptor<SDConvertedPDF>())
                let allAnns = try? modelContext.fetch(FetchDescriptor<SDAnnotation>())
                
                let pdfDTOs = (allPDFs ?? []).map { $0.toDTO() }
                let annDTOs = (allAnns ?? []).map { $0.toDTO() }
                
                let zipURL = try await ZettelkastenExporter.shared.exportToMarkdownZip(annotations: annDTOs, pdfs: pdfDTOs)
                
                await MainActor.run {
                    let activityVC = UIActivityViewController(activityItems: [zipURL], applicationActivities: nil)
                    if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                       let rootVC = windowScene.windows.first?.rootViewController {
                        if let popover = activityVC.popoverPresentationController {
                            popover.sourceView = rootVC.view
                            popover.sourceRect = CGRect(x: rootVC.view.bounds.midX, y: rootVC.view.bounds.midY, width: 0, height: 0)
                            popover.permittedArrowDirections = []
                        }
                        rootVC.present(activityVC, animated: true)
                    }
                }
            } catch {
                Logger.shared.log("Zettelkasten zip export FAILED: \(error.localizedDescription)", category: "Notebook", type: .error)
            }
        }
    }
    
    private func shareNotes() {
        Logger.shared.log("shareNotes called for '\(bookTitle)' — \(localNotes.count) chars", category: "Notebook", type: .info)
        let activityVC = UIActivityViewController(activityItems: [localNotes], applicationActivities: nil)
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = windowScene.windows.first?.rootViewController {
            if let popover = activityVC.popoverPresentationController {
                popover.sourceView = rootVC.view
                popover.sourceRect = CGRect(x: rootVC.view.bounds.midX, y: rootVC.view.bounds.midY, width: 0, height: 0)
                popover.permittedArrowDirections = []
            }
            rootVC.present(activityVC, animated: true)
            Logger.shared.log("Share sheet presented for '\(bookTitle)'", category: "Notebook", type: .success)
        }
    }

    // MARK: - Highlights Drawer UI
    @ViewBuilder
    private var highlightsDrawer: some View {
        HStack(spacing: 0) {
            Divider()
            VStack(spacing: 0) {
                Text("Book Highlights")
                    .font(.subheadline.bold())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Theme.surface)
                
                Divider()
                
                // Search & Sort bar
                VStack(spacing: 8) {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                            .font(.caption)
                        TextField("Search highlights...", text: $highlightSearchQuery)
                            .font(.system(size: 13))
                            .textFieldStyle(.plain)
                        if !highlightSearchQuery.isEmpty {
                            Button { highlightSearchQuery = "" } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                                    .font(.caption)
                            }
                        }
                    }
                    .padding(6)
                    .background(Color.primary.opacity(0.06))
                    .cornerRadius(6)
                    
                    // Tag filters scroll list
                    let tagsList = allTagsInHighlights
                    if !tagsList.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                Button {
                                    withAnimation { selectedTagFilter = nil }
                                } label: {
                                    Text("All")
                                        .font(.system(size: 10, weight: selectedTagFilter == nil ? .bold : .regular))
                                        .foregroundColor(selectedTagFilter == nil ? .white : .primary)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(selectedTagFilter == nil ? Theme.blue : Color.primary.opacity(0.06), in: Capsule())
                                }
                                .buttonStyle(.plain)
                                
                                ForEach(tagsList, id: \.self) { tag in
                                    Button {
                                        withAnimation {
                                            if selectedTagFilter == tag {
                                                selectedTagFilter = nil
                                            } else {
                                                selectedTagFilter = tag
                                            }
                                        }
                                    } label: {
                                        Text("#\(tag)")
                                            .font(.system(size: 10, weight: selectedTagFilter == tag ? .bold : .regular))
                                            .foregroundColor(selectedTagFilter == tag ? .white : Theme.blue)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(selectedTagFilter == tag ? Theme.blue : Theme.blue.opacity(0.1), in: Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    
                    HStack {
                        Button {
                            highlightSortNewest = true
                        } label: {
                            Text("Newest")
                                .font(.system(size: 11, weight: highlightSortNewest ? .bold : .regular))
                                .foregroundColor(highlightSortNewest ? Theme.blue : .secondary)
                        }
                        Spacer()
                        Button {
                            highlightSortNewest = false
                        } label: {
                            Text("Page Order")
                                .font(.system(size: 11, weight: !highlightSortNewest ? .bold : .regular))
                                .foregroundColor(!highlightSortNewest ? Theme.blue : .secondary)
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .padding(10)
                .background(Theme.surface.opacity(0.5))
                
                Divider()
                
                ScrollView {
                    LazyVStack(spacing: 12) {
                        let matches = filteredHighlights
                        if matches.isEmpty {
                            Text("No matching highlights.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .padding()
                        } else {
                            ForEach(matches) { highlight in
                                VStack(alignment: .leading, spacing: 8) {
                                    // Header: Page Index
                                    HStack {
                                        Text("Page \(highlight.pageIndex + 1)")
                                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                                            .foregroundColor(.secondary)
                                        Spacer()
                                        
                                        let accentColor = Color(hex: highlight.colorHex ?? "#FFD60A")
                                        Circle()
                                            .fill(accentColor)
                                            .frame(width: 6, height: 6)
                                    }
                                    
                                    // Quote highlighted text
                                    if let text = highlight.selectedText, !text.isEmpty {
                                        let accentColor = Color(hex: highlight.colorHex ?? "#FFD60A")
                                        Text(text)
                                            .font(.system(size: 13, design: .serif))
                                            .foregroundColor(Theme.text)
                                            .lineSpacing(3)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 6)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .background(
                                                RoundedRectangle(cornerRadius: 4)
                                                    .fill(accentColor.opacity(0.10))
                                            )
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 4)
                                                    .stroke(accentColor.opacity(0.18), lineWidth: 0.6)
                                            )
                                    }
                                    
                                    // User note/thought
                                    if let note = highlight.noteText, !note.isEmpty {
                                        Text(note)
                                            .font(.system(size: 11))
                                            .foregroundColor(Theme.textSecondary)
                                            .lineLimit(2)
                                            .padding(6)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .background(Color.primary.opacity(0.02))
                                            .cornerRadius(4)
                                    }
                                    
                                    // Tags list
                                    if let tags = highlight.tags, !tags.isEmpty {
                                        HStack(spacing: 4) {
                                            ForEach(tags, id: \.self) { tag in
                                                Text("#\(tag)")
                                                    .font(.system(size: 8, weight: .bold))
                                                    .foregroundColor(Theme.blue)
                                                    .padding(.horizontal, 5)
                                                    .padding(.vertical, 1.5)
                                                    .background(Theme.blue.opacity(0.1), in: Capsule())
                                            }
                                        }
                                    }
                                    
                                    // Action buttons
                                    HStack {
                                        Button {
                                            insertHighlightIntoNote(highlight)
                                        } label: {
                                            HStack(spacing: 3) {
                                                Image(systemName: "plus.circle")
                                                Text("Insert")
                                            }
                                            .font(.system(size: 11, weight: .bold))
                                            .foregroundColor(Theme.blue)
                                        }
                                        .buttonStyle(.borderless)
                                        
                                        Spacer()
                                        
                                        Button {
                                            activeHighlightToEdit = highlight
                                        } label: {
                                            HStack(spacing: 3) {
                                                Image(systemName: "square.and.pencil")
                                                Text("Edit")
                                            }
                                            .font(.system(size: 11, weight: .bold))
                                            .foregroundColor(.secondary)
                                        }
                                        .buttonStyle(.borderless)
                                    }
                                    .padding(.top, 2)
                                }
                                .padding(12)
                                .background(Theme.surface)
                                .cornerRadius(8)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.primary.opacity(0.06), lineWidth: 0.6)
                                )
                                .onDrag {
                                    let formattedText = formatHighlightForInsertion(highlight)
                                    return NSItemProvider(object: formattedText as NSString)
                                }
                            }
                        }
                    }
                    .padding(12)
                }
                .background(Color.inkSurface.opacity(0.95))
            }
            .frame(width: 250)
            .background(.ultraThinMaterial)
            .shadow(color: .black.opacity(0.1), radius: 10, x: -5, y: 0)
        }
        .transition(.move(edge: .trailing))
    }
    
    private func fetchBackingBook() -> ConvertedPDF? {
        if let uuid = UUID(uuidString: bookID) {
            let descriptor = FetchDescriptor<SDConvertedPDF>(predicate: #Predicate { $0.id == uuid })
            if let sdBook = try? modelContext.fetch(descriptor).first {
                return sdBook.toDTO()
            }
        }
        // Fallback by title:
        let titleLower = bookTitle.lowercased()
        let allDescriptor = FetchDescriptor<SDConvertedPDF>()
        if let all = try? modelContext.fetch(allDescriptor) {
            if let matched = all.first(where: { $0.name.lowercased() == titleLower }) {
                return matched.toDTO()
            }
        }
        return nil
    }
}

// MARK: - Phase 2: Modern Markdown Engine WYSIWYG
struct MarkdownTextEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let paperStyle: PaperStyle
    var onLinkTapped: ((URL) -> Void)? = nil
    
    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        context.coordinator.textView = textView
        textView.font = UIFont.systemFont(ofSize: 16, weight: .regular)
        textView.backgroundColor = .clear
        textView.textColor = UIColor.label
        textView.isScrollEnabled = true
        textView.keyboardDismissMode = .interactive
        textView.linkTextAttributes = [:] // Style links completely via MarkdownHighlighter attributes
        
        // Dynamically set container inset based on active paper style
        updateTextViewPadding(textView, style: paperStyle)

        // Add Tap Gesture Recognizer to intercept page link clicks without disrupting text insertion cursor focus
        let tapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tapGesture.delegate = context.coordinator
        tapGesture.cancelsTouchesInView = true
        textView.addGestureRecognizer(tapGesture)

        // MARK: Formatting Shortcut Bar — Phase 4E-2 expanded (Bear/Notability pattern)
        let bar = UIInputView(frame: CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: 48),
                              inputViewStyle: .keyboard)
        let blurEffect = UIBlurEffect(style: .systemChromeMaterial)
        let blurView  = UIVisualEffectView(effect: blurEffect)
        blurView.frame = bar.bounds
        blurView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        bar.addSubview(blurView)

        let items: [(title: String, insert: String, after: String?)] = [
            ("B",       "**",     "**"),
            ("I",       "_",      "_"),
            ("H1",      "# ",     nil),
            ("H2",      "## ",    nil),
            ("≡ List",  "- ",     nil),
            ("☑ Todo",  "- [ ] ", nil),
            ("`Code`",  "`",      "`"),
            ("—— Rule", "---\n",  nil),
            ("[[",      "[[",     "]]"),
            ("#",       "#",      nil),
            ("> Quote", "> ",     nil),
        ]

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.distribution = .fill
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false

        for item in items {
            let btn = FormatButton(title: item.title, insertBefore: item.insert, insertAfter: item.after, textView: textView)
            btn.setTitleColor(UIColor.label, for: .normal)
            btn.titleLabel?.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
            btn.backgroundColor = UIColor.secondarySystemFill
            btn.layer.cornerRadius = 6
            btn.contentEdgeInsets = UIEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
            stack.addArrangedSubview(btn)
        }

        let micBtn = UIButton(type: .system)
        micBtn.tag = 999
        let isRecording = SpeechRecognitionManager.shared.isRecording
        let config = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        let micImage = UIImage(systemName: isRecording ? "mic.fill" : "mic", withConfiguration: config)
        micBtn.setImage(micImage, for: .normal)
        micBtn.tintColor = isRecording ? .systemRed : .label
        micBtn.backgroundColor = UIColor.secondarySystemFill
        micBtn.layer.cornerRadius = 6
        micBtn.addTarget(context.coordinator, action: #selector(Coordinator.micButtonTapped), for: .touchUpInside)
        stack.addArrangedSubview(micBtn)
        micBtn.widthAnchor.constraint(equalToConstant: 36).isActive = true
        micBtn.heightAnchor.constraint(equalToConstant: 32).isActive = true

        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(spacer)

        let doneBtn = UIButton(type: .system)
        doneBtn.setTitle("Done", for: .normal)
        doneBtn.titleLabel?.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        doneBtn.addTarget(context.coordinator, action: #selector(Coordinator.doneButtonTapped), for: .touchUpInside)
        stack.addArrangedSubview(doneBtn)

        let scrollView = UIScrollView()
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(scrollView)
        scrollView.addSubview(stack)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: bar.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            stack.heightAnchor.constraint(equalTo: scrollView.heightAnchor)
        ])
        textView.inputAccessoryView = bar

        return textView
    }
    
    func updateUIView(_ uiView: UITextView, context: Context) {
        updateTextViewPadding(uiView, style: paperStyle)
        
        if uiView.text != text {
            let selectedRange = uiView.selectedRange
            uiView.attributedText = MarkdownHighlighter.highlight(text, style: paperStyle)
            uiView.selectedRange = selectedRange
        }
        
        if isFocused && !uiView.isFirstResponder {
            uiView.becomeFirstResponder()
        } else if !isFocused && uiView.isFirstResponder {
            uiView.resignFirstResponder()
        }
        
        if let bar = uiView.inputAccessoryView {
            if let micBtn = bar.viewWithTag(999) as? UIButton {
                let isRecording = SpeechRecognitionManager.shared.isRecording
                let config = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
                let micImage = UIImage(systemName: isRecording ? "mic.fill" : "mic", withConfiguration: config)
                micBtn.setImage(micImage, for: .normal)
                micBtn.tintColor = isRecording ? .systemRed : .label
            }
        }
        
        context.coordinator.updatePageBreaks(for: uiView)
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    private func updateTextViewPadding(_ textView: UITextView, style: PaperStyle) {
        let topInset: CGFloat
        let leftInset: CGFloat
        let rightInset: CGFloat = 20
        let bottomInset: CGFloat = 20
        
        switch style {
        case .legal:
            topInset = 56
            leftInset = 100
        case .collegeRuled:
            topInset = 63
            leftInset = 84
        case .ruled:
            topInset = 48
            leftInset = 84
        default:
            topInset = 16
            leftInset = 20
        }
        
        textView.textContainerInset = UIEdgeInsets(top: topInset, left: leftInset, bottom: bottomInset, right: rightInset)
    }
    
    @MainActor
    class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        var parent: MarkdownTextEditor
        weak var textView: UITextView?
        nonisolated(unsafe) private var dictationObserver: NSObjectProtocol?
        
        init(_ parent: MarkdownTextEditor) {
            self.parent = parent
            super.init()
            
            dictationObserver = NotificationCenter.default.addObserver(
                forName: .insertDictatedText,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let textToInsert = notification.userInfo?["text"] as? String
                Task { @MainActor in
                    guard let self = self,
                          let textView = self.textView,
                          let textToInsert = textToInsert else { return }
                    
                    self.insertText(textToInsert)
                }
            }
        }
        
        deinit {
            if let observer = dictationObserver {
                NotificationCenter.default.removeObserver(observer)
            }
        }
        
        @objc func micButtonTapped() {
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
                            Logger.shared.log("Failed to start dictation: \(error.localizedDescription)", category: "STT", type: .error)
                        }
                    }
                }
            }
        }
        
        private func insertText(_ newText: String) {
            guard let tv = textView else { return }
            let selectedRange = tv.selectedRange
            let originalText = tv.text ?? ""
            
            let insertionText: String
            if selectedRange.location > 0 {
                let prevIndex = originalText.index(originalText.startIndex, offsetBy: selectedRange.location - 1)
                let prevChar = originalText[prevIndex]
                if !prevChar.isWhitespace && !prevChar.isNewline {
                    insertionText = " " + newText
                } else {
                    insertionText = newText
                }
            } else {
                insertionText = newText
            }
            
            tv.insertText(insertionText)
            parent.text = tv.text
            
            let newSelectedRange = tv.selectedRange
            tv.attributedText = MarkdownHighlighter.highlight(tv.text, style: parent.paperStyle)
            tv.selectedRange = newSelectedRange
        }
        
        func updatePageBreaks(for textView: UITextView) {
            // Remove existing page breaks
            textView.subviews.filter { $0.tag == 999 }.forEach { $0.removeFromSuperview() }
            
            let pageHeight: CGFloat = 1100
            let padding: CGFloat = 16
            let width = textView.bounds.width > 0 ? textView.bounds.width : UIScreen.main.bounds.width
            let contentHeight = textView.contentSize.height
            
            var y: CGFloat = pageHeight
            var pageIndex = 1
            while y < contentHeight - 100 {
                let container = UIView(frame: CGRect(x: 0, y: y, width: width, height: 20))
                container.tag = 999
                container.isUserInteractionEnabled = false
                container.backgroundColor = .clear
                
                // Horizontal dashed line
                let lineWidth = max(50, width - 96 - (padding * 2))
                let line = UIView(frame: CGRect(x: padding, y: 10, width: lineWidth, height: 1))
                line.backgroundColor = .clear
                
                // Add a CAShapeLayer for a clean dashed stroke style matching theme
                let shapeLayer = CAShapeLayer()
                shapeLayer.strokeColor = UIColor.separator.withAlphaComponent(0.2).cgColor
                shapeLayer.lineWidth = 1.0
                shapeLayer.lineDashPattern = [6, 4]
                
                let path = CGMutablePath()
                path.addLines(between: [CGPoint(x: 0, y: 0), CGPoint(x: lineWidth, y: 0)])
                shapeLayer.path = path
                line.layer.addSublayer(shapeLayer)
                container.addSubview(line)
                
                // Page Label
                let label = UILabel(frame: CGRect(x: width - 80 - padding, y: 0, width: 80, height: 20))
                label.text = "Page \(pageIndex)"
                label.font = UIFont.systemFont(ofSize: 10, weight: .semibold)
                label.textColor = UIColor.secondaryLabel.withAlphaComponent(0.4)
                label.textAlignment = .right
                container.addSubview(label)
                
                textView.addSubview(container)
                
                y += pageHeight
                pageIndex += 1
            }
        }
        
        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            let selectedRange = textView.selectedRange
            textView.attributedText = MarkdownHighlighter.highlight(textView.text, style: parent.paperStyle)
            textView.selectedRange = selectedRange
            updatePageBreaks(for: textView)
        }
        
        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.isFocused = true
        }
        
        func textViewDidEndEditing(_ textView: UITextView) {
            parent.isFocused = false
        }
        
        @objc func doneButtonTapped() {
            parent.isFocused = false
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let textView = textView else { return false }
            let point = touch.location(in: textView)
            
            var location = point
            location.x -= textView.textContainerInset.left
            location.y -= textView.textContainerInset.top
            
            let layoutManager = textView.layoutManager
            let textContainer = textView.textContainer
            
            var fraction: CGFloat = 0.0
            let charIndex = layoutManager.characterIndex(for: location, in: textContainer, fractionOfDistanceBetweenInsertionPoints: &fraction)
            
            guard charIndex < textView.textStorage.length else { return false }
            
            if let url = textView.textStorage.attribute(.link, at: charIndex, effectiveRange: nil) as? URL {
                if url.scheme == "inksync" {
                    let glyphIndex = layoutManager.glyphIndexForCharacter(at: charIndex)
                    let glyphRect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyphIndex, length: 1), in: textContainer)
                    let touchTargetRect = glyphRect.insetBy(dx: -5, dy: -5)
                    if touchTargetRect.contains(location) {
                        return true
                    }
                }
            }
            return false
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let textView = textView, gesture.state == .ended else { return }
            let point = gesture.location(in: textView)
            
            var location = point
            location.x -= textView.textContainerInset.left
            location.y -= textView.textContainerInset.top
            
            let layoutManager = textView.layoutManager
            let textContainer = textView.textContainer
            
            var fraction: CGFloat = 0.0
            let charIndex = layoutManager.characterIndex(for: location, in: textContainer, fractionOfDistanceBetweenInsertionPoints: &fraction)
            
            if charIndex < textView.textStorage.length {
                if let url = textView.textStorage.attribute(.link, at: charIndex, effectiveRange: nil) as? URL {
                    if url.scheme == "inksync" {
                        parent.onLinkTapped?(url)
                    }
                }
            }
        }

        func textView(_ textView: UITextView, shouldInteractWith URL: URL, in characterRange: NSRange, interaction: UITextItemInteraction) -> Bool {
            if URL.scheme == "inksync" {
                parent.onLinkTapped?(URL)
                return false
            }
            return true
        }
    }
}

struct MarkdownHighlighter {
    static func highlight(_ text: String, style: PaperStyle) -> NSAttributedString {
        let baseSize: CGFloat
        let lineSpacingVal: CGFloat
        let lineSpacingTarget: CGFloat
        
        switch style {
        case .legal:
            baseSize = 18
            lineSpacingTarget = 28
        case .collegeRuled:
            baseSize = 14
            lineSpacingTarget = 21
        case .ruled:
            baseSize = 16
            lineSpacingTarget = 24
        default:
            baseSize = 16
            lineSpacingTarget = 22
        }
        
        let defaultFont = UIFont.systemFont(ofSize: baseSize)
        let boldFont = UIFont.boldSystemFont(ofSize: baseSize)
        let italicFont = UIFont.italicSystemFont(ofSize: baseSize)
        let h1Font = UIFont.boldSystemFont(ofSize: baseSize + 8)
        let h2Font = UIFont.boldSystemFont(ofSize: baseSize + 4)
        let h3Font = UIFont.boldSystemFont(ofSize: baseSize + 2)
        let defaultColor = UIColor.label
        let markerColor = UIColor.secondaryLabel.withAlphaComponent(0.35)
        
        // Calculate dynamic lineSpacing to make lines align perfectly with the paper rule grid
        let fontLineHeight = defaultFont.lineHeight
        lineSpacingVal = max(0, lineSpacingTarget - fontLineHeight)
        
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = lineSpacingVal
        paragraphStyle.paragraphSpacing = style == .plain ? 12 : 0

        let attrString = NSMutableAttributedString(string: text, attributes: [
            .font: defaultFont,
            .foregroundColor: defaultColor,
            .paragraphStyle: paragraphStyle
        ])
        
        let fullRange = NSRange(text.startIndex..., in: text)
        
        // Blockquotes (> text)
        let quotePattern = "(?m)^(\\s*>\\s*)(.*)"
        if let regex = try? NSRegularExpression(pattern: quotePattern, options: []) {
            let matches = regex.matches(in: text, range: fullRange)
            for match in matches {
                if match.numberOfRanges > 2 {
                    let markerRange = match.range(at: 1)
                    let textRange = match.range(at: 2)
                    attrString.addAttribute(.foregroundColor, value: UIColor.systemOrange.withAlphaComponent(0.6), range: markerRange)
                    attrString.addAttributes([
                        .foregroundColor: UIColor.systemGray,
                        .font: italicFont
                    ], range: textRange)
                }
            }
        }
        
        // Bold (**text**)
        let boldPattern = "(\\*\\*)(.*?)(\\*\\*)"
        if let regex = try? NSRegularExpression(pattern: boldPattern, options: []) {
            let matches = regex.matches(in: text, range: fullRange)
            for match in matches {
                if match.numberOfRanges > 3 {
                    let startMarker = match.range(at: 1)
                    let innerText = match.range(at: 2)
                    let endMarker = match.range(at: 3)
                    
                    attrString.addAttribute(.foregroundColor, value: markerColor, range: startMarker)
                    attrString.addAttribute(.font, value: boldFont, range: innerText)
                    attrString.addAttribute(.foregroundColor, value: markerColor, range: endMarker)
                }
            }
        }
        
        // Italic (_text_)
        let italicPattern = "(\\_)(.*?)(\\_)"
        if let regex = try? NSRegularExpression(pattern: italicPattern, options: []) {
            let matches = regex.matches(in: text, range: fullRange)
            for match in matches {
                if match.numberOfRanges > 3 {
                    let startMarker = match.range(at: 1)
                    let innerText = match.range(at: 2)
                    let endMarker = match.range(at: 3)
                    
                    attrString.addAttribute(.foregroundColor, value: markerColor, range: startMarker)
                    attrString.addAttribute(.font, value: italicFont, range: innerText)
                    attrString.addAttribute(.foregroundColor, value: markerColor, range: endMarker)
                }
            }
        }
        
        // WikiLink ([[text]])
        let linkPattern = "\\[\\[(.*?)\\]\\]"
        if let regex = try? NSRegularExpression(pattern: linkPattern, options: []) {
            let matches = regex.matches(in: text, range: fullRange)
            let nsText = text as NSString
            for match in matches {
                attrString.addAttributes([
                    .foregroundColor: UIColor.systemBlue,
                    .underlineStyle: NSUnderlineStyle.single.rawValue
                ], range: match.range)
                
                if match.numberOfRanges > 1 {
                    let innerRange = match.range(at: 1)
                    let innerText = nsText.substring(with: innerRange)
                    
                    let pageRegexPattern = "^(?:[Pp]age|[Pp]g|[Pp]\\.?)?\\s*(\\d+)$"
                    if let pageRegex = try? NSRegularExpression(pattern: pageRegexPattern, options: []),
                       let pageMatch = pageRegex.firstMatch(in: innerText, options: [], range: NSRange(innerText.startIndex..., in: innerText)) {
                        if pageMatch.numberOfRanges > 1 {
                            let pageNumRange = pageMatch.range(at: 1)
                            if let pageNumRangeInString = Range(pageNumRange, in: innerText),
                               let pageNum = Int(innerText[pageNumRangeInString]),
                               pageNum > 0 {
                                let pageIndex = pageNum - 1
                                if let url = URL(string: "inksync://page/\(pageIndex)") {
                                    attrString.addAttribute(.link, value: url, range: match.range)
                                }
                            }
                        }
                    }
                }
            }
        }
        
        // Tags (#tag)
        let tagPattern = "(?<!\\w)#\\w+"
        if let regex = try? NSRegularExpression(pattern: tagPattern, options: []) {
            let matches = regex.matches(in: text, range: fullRange)
            for match in matches {
                attrString.addAttributes([
                    .foregroundColor: UIColor.systemOrange,
                    .font: boldFont
                ], range: match.range)
            }
        }
        
        // Headers (# H1, ## H2, ### H3)
        let h1Pattern = "(?m)^(#\\s+)(.*)"
        let h2Pattern = "(?m)^(##\\s+)(.*)"
        let h3Pattern = "(?m)^(###\\s+)(.*)"
        
        if let r1 = try? NSRegularExpression(pattern: h1Pattern) {
            for match in r1.matches(in: text, range: fullRange) {
                if match.numberOfRanges > 2 {
                    let markerRange = match.range(at: 1)
                    let textRange = match.range(at: 2)
                    attrString.addAttribute(.foregroundColor, value: markerColor, range: markerRange)
                    attrString.addAttribute(.font, value: h1Font, range: textRange)
                }
            }
        }
        if let r2 = try? NSRegularExpression(pattern: h2Pattern) {
            for match in r2.matches(in: text, range: fullRange) {
                if match.numberOfRanges > 2 {
                    let markerRange = match.range(at: 1)
                    let textRange = match.range(at: 2)
                    attrString.addAttribute(.foregroundColor, value: markerColor, range: markerRange)
                    attrString.addAttribute(.font, value: h2Font, range: textRange)
                }
            }
        }
        if let r3 = try? NSRegularExpression(pattern: h3Pattern) {
            for match in r3.matches(in: text, range: fullRange) {
                if match.numberOfRanges > 2 {
                    let markerRange = match.range(at: 1)
                    let textRange = match.range(at: 2)
                    attrString.addAttribute(.foregroundColor, value: markerColor, range: markerRange)
                    attrString.addAttribute(.font, value: h3Font, range: textRange)
                }
            }
        }
        
        return attrString
    }
}

extension StudyNotebookView {
    // MARK: - PencilKit Custom Drawing Toolbar
    @ViewBuilder
    private var canvasToolbar: some View {
        HStack(spacing: 12) {
            // Undo / Redo
            Button {
                HapticEngine.light()
                canvasView.undoManager?.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(canvasView.undoManager?.canUndo == true ? .primary : .secondary.opacity(0.4))
                    .padding(8)
                    .background(Color.primary.opacity(0.06), in: Circle())
            }
            .disabled(canvasView.undoManager?.canUndo == false)
            
            Button {
                HapticEngine.light()
                canvasView.undoManager?.redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(canvasView.undoManager?.canRedo == true ? .primary : .secondary.opacity(0.4))
                    .padding(8)
                    .background(Color.primary.opacity(0.06), in: Circle())
            }
            .disabled(canvasView.undoManager?.canRedo == false)
            
            Divider()
                .frame(height: 20)
                .background(Color.primary.opacity(0.1))
            
            // Tools Segment
            ForEach(DrawingTool.allCases) { tool in
                Button {
                    HapticEngine.light()
                    activeDrawingTool = tool
                    updateCanvasTool()
                } label: {
                    Image(systemName: tool.icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(activeDrawingTool == tool ? .white : .primary)
                        .padding(8)
                        .background(activeDrawingTool == tool ? Color.orange : Color.primary.opacity(0.06), in: Circle())
                }
                .buttonStyle(.plain)
            }
            
            Divider()
                .frame(height: 20)
                .background(Color.primary.opacity(0.1))
            
            // Colors (only relevant for writing tools)
            if activeDrawingTool == .pen || activeDrawingTool == .pencil || activeDrawingTool == .highlighter {
                HStack(spacing: 8) {
                    ForEach(drawingColors, id: \.self) { color in
                        Button {
                            HapticEngine.light()
                            strokeColor = color
                            updateCanvasTool()
                        } label: {
                            Circle()
                                .fill(color)
                                .frame(width: 18, height: 18)
                                .overlay(
                                    Circle()
                                        .stroke(Color.primary.opacity(strokeColor == color ? 0.8 : 0.15), lineWidth: strokeColor == color ? 2 : 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            
            // Thickness Picker
            if activeDrawingTool == .pen || activeDrawingTool == .pencil || activeDrawingTool == .highlighter {
                Menu {
                    Picker("Width", selection: $strokeWidth) {
                        Text("Fine (2pt)").tag(CGFloat(2.0))
                        Text("Medium (4pt)").tag(CGFloat(4.0))
                        Text("Thick (8pt)").tag(CGFloat(8.0))
                        Text("Extra (16pt)").tag(CGFloat(16.0))
                    }
                } label: {
                    Image(systemName: "line.horizontal.3.decrease.circle")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.primary)
                        .padding(8)
                        .background(Color.primary.opacity(0.06), in: Circle())
                }
                .onChange(of: strokeWidth) { _, _ in updateCanvasTool() }
            }
            
            // Eraser Mode Picker
            if activeDrawingTool == .eraser {
                Menu {
                    Picker("Eraser Type", selection: $eraserType) {
                        Label("Object Eraser", systemImage: "eraser.line.dashed").tag(PKEraserTool.EraserType.vector)
                        Label("Pixel Eraser", systemImage: "eraser").tag(PKEraserTool.EraserType.bitmap)
                    }
                } label: {
                    Image(systemName: eraserType == .vector ? "eraser.line.dashed.fill" : "eraser.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.primary)
                        .padding(8)
                        .background(Color.primary.opacity(0.06), in: Circle())
                }
                .onChange(of: eraserType) { _, _ in updateCanvasTool() }
            }
            
            Spacer()
            
            // Ruler Button
            Button {
                HapticEngine.light()
                isRulerActive.toggle()
                updateCanvasTool()
            } label: {
                Image(systemName: "ruler")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(isRulerActive ? .white : .primary)
                    .padding(8)
                    .background(isRulerActive ? Color.orange : Color.primary.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
            
            // Smart Shapes Toggle
            Button {
                HapticEngine.light()
                isSmartShapesEnabled.toggle()
            } label: {
                Image(systemName: isSmartShapesEnabled ? "skew" : "pencil.and.outline")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(isSmartShapesEnabled ? .white : .primary)
                    .padding(8)
                    .background(isSmartShapesEnabled ? Color.purple : Color.primary.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.inkSurfaceRaised.opacity(0.4).background(.thinMaterial))
        .overlay(
            VStack {
                Spacer()
                Divider().background(Color.primary.opacity(0.05))
            }
        )
    }
}

// MARK: - Formatting Button (Bear-style — inserts markdown syntax at cursor)
private final class FormatButton: UIButton {
    let insertBefore: String
    let insertAfter: String?
    weak var textView: UITextView?

    init(title: String, insertBefore: String, insertAfter: String?, textView: UITextView) {
        self.insertBefore = insertBefore
        self.insertAfter  = insertAfter
        self.textView = textView
        super.init(frame: .zero)
        setTitle(title, for: .normal)
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func tapped() {
        guard let tv = textView,
              let selectedRange = tv.selectedTextRange else { return }

        let selectedText = tv.text(in: selectedRange) ?? ""

        let replacement: String
        if let after = insertAfter {
            replacement = insertBefore + selectedText + after
        } else {
            replacement = insertBefore + selectedText
        }
        tv.replace(selectedRange, withText: replacement)

        if selectedText.isEmpty, let after = insertAfter {
            let offset = insertBefore.count
            if let startPos = tv.position(from: selectedRange.start, offset: offset) {
                tv.selectedTextRange = tv.textRange(from: startPos, to: startPos)
            }
            _ = after
        }

        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}

// MARK: - Paper Styles
enum PaperStyle: String, CaseIterable, Identifiable {
    case plain = "Plain"
    case ruled = "Ruled"
    case grid = "Grid"
    case dots = "Dots"
    case legal = "Legal"
    case collegeRuled = "College Ruled"
    case flashcard = "Flashcard"
    
    var id: String { self.rawValue }
    var icon: String {
        switch self {
        case .plain: return "square"
        case .ruled: return "line.horizontal.3"
        case .grid: return "grid"
        case .dots: return "circle.hexagongrid.fill"
        case .legal: return "signature"
        case .collegeRuled: return "doc.text.fill"
        case .flashcard: return "rectangle.split.2x1"
        }
    }
}

struct NotebookPaperBackground: View {
    let style: PaperStyle
    let colorScheme: ColorScheme

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Paper Base Color Fill
                Group {
                    if colorScheme == .dark {
                        Color(hex: "#1E1E1E")
                    } else if style == .legal {
                        Color(hex: "#FFFDF0") // Ivory legal pad yellow
                    } else {
                        Color.white
                    }
                }
                .ignoresSafeArea()
                
                // Rule lines/dots
                Path { path in
                    switch style {
                    case .plain:
                        break
                    case .ruled:
                        let lineSpacing: CGFloat = 24
                        var y: CGFloat = lineSpacing
                        while y < geo.size.height {
                            path.move(to: CGPoint(x: 0, y: y))
                            path.addLine(to: CGPoint(x: geo.size.width, y: y))
                            y += lineSpacing
                        }
                    case .grid:
                        let gridSpacing: CGFloat = 24
                        var x: CGFloat = gridSpacing
                        while x < geo.size.width {
                            path.move(to: CGPoint(x: x, y: 0))
                            path.addLine(to: CGPoint(x: x, y: geo.size.height))
                            x += gridSpacing
                        }
                        var y: CGFloat = gridSpacing
                        while y < geo.size.height {
                            path.move(to: CGPoint(x: 0, y: y))
                            path.addLine(to: CGPoint(x: geo.size.width, y: y))
                            y += gridSpacing
                        }
                    case .dots:
                        let spacing: CGFloat = 24
                        var y: CGFloat = spacing
                        while y < geo.size.height {
                            var x: CGFloat = spacing
                            while x < geo.size.width {
                                path.addEllipse(in: CGRect(x: x - 1, y: y - 1, width: 2, height: 2))
                                x += spacing
                            }
                            y += spacing
                        }
                    case .legal:
                        let lineSpacing: CGFloat = 28
                        var y: CGFloat = lineSpacing * 2
                        while y < geo.size.height {
                            path.move(to: CGPoint(x: 0, y: y))
                            path.addLine(to: CGPoint(x: geo.size.width, y: y))
                            y += lineSpacing
                        }
                    case .collegeRuled:
                        let lineSpacing: CGFloat = 21
                        var y: CGFloat = lineSpacing * 3
                        while y < geo.size.height {
                            path.move(to: CGPoint(x: 0, y: y))
                            path.addLine(to: CGPoint(x: geo.size.width, y: y))
                            y += lineSpacing
                        }
                    case .flashcard:
                        break
                    }
                }
                .stroke(
                    colorScheme == .dark
                        ? Color.white.opacity(0.14)
                        : Color(hex: style == .legal ? "#B5D3FD" : "#CFE0F5"),
                    lineWidth: style == .dots ? 2 : 0.8
                )

                // Pink/Red Vertical Margin Line for Academic/Legal/Ruled
                if style == .legal || style == .collegeRuled || style == .ruled {
                    Path { path in
                        let marginX: CGFloat = style == .legal ? 88 : 72
                        path.move(to: CGPoint(x: marginX, y: 0))
                        path.addLine(to: CGPoint(x: marginX, y: geo.size.height))
                    }
                    .stroke(
                        colorScheme == .dark ? Color.red.opacity(0.4) : Color.red.opacity(0.45),
                        lineWidth: 1.2
                    )
                }

                // Flashcard Horizontal Dashed Divider and Prompts
                if style == .flashcard {
                    Path { path in
                        let midY = geo.size.height / 2
                        path.move(to: CGPoint(x: 0, y: midY))
                        path.addLine(to: CGPoint(x: geo.size.width, y: midY))
                    }
                    .stroke(
                        colorScheme == .dark ? Color.white.opacity(0.2) : Color.gray.opacity(0.35),
                        style: StrokeStyle(lineWidth: 1.2, dash: [6, 4])
                    )
                    
                    VStack {
                        Text("FRONT / QUESTION")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundColor(colorScheme == .dark ? Color.white.opacity(0.15) : Color.black.opacity(0.12))
                            .padding(.top, 16)
                        
                        Spacer()
                        
                        Text("BACK / ANSWER")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundColor(colorScheme == .dark ? Color.white.opacity(0.15) : Color.black.opacity(0.12))
                            .padding(.bottom, 16)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }
}

extension Notification.Name {
    static let insertDictatedText = Notification.Name("InsertDictatedText")
}

// MARK: - Spaced Repetition active recall methods
extension StudyNotebookView {
    private func gradeCard(correct: Bool) {
        guard currentCardIndex < studyCards.count else { return }
        let card = studyCards[currentCardIndex]
        
        if correct {
            card.reviewCount += 1
            card.easeFactor = min(5.0, card.easeFactor + 0.1)
            let intervalDays = max(1, Int(round(6 * pow(card.easeFactor, Double(card.reviewCount - 1)))))
            card.nextReviewDate = Calendar.current.date(byAdding: .day, value: intervalDays, to: Date())
            correctAnswersCount += 1
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        } else {
            card.reviewCount = 0
            card.easeFactor = max(1.3, card.easeFactor - 0.2)
            card.nextReviewDate = Calendar.current.date(byAdding: .day, value: 1, to: Date())
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
        
        try? modelContext.save()
        
        withAnimation(.spring()) {
            isAnswerRevealed = false
            currentCardIndex += 1
        }
    }
    
    @ViewBuilder
    private var studyFlashcardOverlay: some View {
        ZStack {
            Color.black.opacity(0.4)
                .background(.ultraThinMaterial)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation {
                        isStudyModeActive = false
                    }
                }
            
            VStack(spacing: 24) {
                HStack {
                    Text("ACTIVE RECALL DECK")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundColor(.secondary)
                        .kerning(1.2)
                    
                    Spacer()
                    
                    Button {
                        withAnimation {
                            isStudyModeActive = false
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 32)
                .padding(.top, 24)
                
                if currentCardIndex < studyCards.count {
                    let card = studyCards[currentCardIndex]
                    
                    VStack(spacing: 0) {
                        VStack(spacing: 12) {
                            HStack {
                                Image(systemName: "bookmark.fill")
                                    .foregroundColor(.orange)
                                Text("Page \(card.pageIndex + 1)")
                                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                                    .foregroundColor(.orange)
                                
                                Spacer()
                                
                                Text("\(currentCardIndex + 1) of \(studyCards.count)")
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                            
                            if let chapter = card.chapterTitle, !chapter.isEmpty {
                                Text(chapter)
                                    .font(.system(size: 16, weight: .bold, design: .rounded))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.top, 4)
                            }
                            
                            if let tags = card.tags, !tags.isEmpty {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 6) {
                                        ForEach(tags, id: \.self) { tag in
                                            Text("#\(tag)")
                                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 4)
                                                .background(Color.orange.opacity(0.12), in: Capsule())
                                                .foregroundColor(.orange)
                                        }
                                    }
                                }
                                .padding(.top, 4)
                            }
                            
                            Spacer()
                            
                            Text("Recall the highlighted concept or note below:")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .multilineTextAlignment(.center)
                            
                            Spacer()
                        }
                        .padding(24)
                        .frame(height: 180)
                        
                        Divider()
                        
                        ZStack {
                            if !isAnswerRevealed {
                                Button {
                                    withAnimation(.easeOut(duration: 0.25)) {
                                        isAnswerRevealed = true
                                    }
                                } label: {
                                    VStack(spacing: 8) {
                                        Image(systemName: "eye.fill")
                                            .font(.system(size: 24))
                                        Text("Tap to Reveal Answer")
                                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                                    }
                                    .foregroundColor(.blue)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .background(.ultraThinMaterial)
                                }
                            } else {
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 14) {
                                        if let text = card.selectedText, !text.isEmpty {
                                            Text(text)
                                                .font(.system(size: 15, weight: .medium, design: .serif))
                                                .foregroundColor(.primary)
                                                .italic()
                                                .padding(12)
                                                .background(Color.primary.opacity(0.04))
                                                .cornerRadius(6)
                                        }
                                        
                                        if let note = card.noteText, !note.isEmpty {
                                            HStack(alignment: .top, spacing: 6) {
                                                Image(systemName: "note.text")
                                                    .foregroundColor(.blue)
                                                    .font(.system(size: 14))
                                                    .padding(.top, 2)
                                                Text(note)
                                                    .font(.system(size: 14, weight: .medium, design: .rounded))
                                                    .foregroundColor(.primary)
                                            }
                                        }
                                    }
                                    .padding(20)
                                }
                            }
                        }
                        .frame(height: 220)
                    }
                    .background(colorScheme == .dark ? Color(hex: "#1C1C1E") : Color.white)
                    .cornerRadius(18)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1.5)
                    )
                    .shadow(color: Color.black.opacity(0.12), radius: 16, x: 0, y: 8)
                    .padding(.horizontal, 32)
                    
                    if isAnswerRevealed {
                        HStack(spacing: 16) {
                            Button {
                                gradeCard(correct: false)
                            } label: {
                                HStack {
                                    Image(systemName: "xmark.circle.fill")
                                    Text("Forgot / Hard")
                                }
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .foregroundColor(.red)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color.red.opacity(0.08))
                                .cornerRadius(12)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(Color.red.opacity(0.2), lineWidth: 1)
                                )
                            }
                            
                            Button {
                                gradeCard(correct: true)
                            } label: {
                                HStack {
                                    Image(systemName: "checkmark.circle.fill")
                                    Text("Recalled / Easy")
                                }
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .foregroundColor(.green)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color.green.opacity(0.08))
                                .cornerRadius(12)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(Color.green.opacity(0.2), lineWidth: 1)
                                )
                            }
                        }
                        .padding(.horizontal, 32)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    } else {
                        Color.clear.frame(height: 48)
                    }
                    
                } else {
                    VStack(spacing: 20) {
                        Image(systemName: "trophy.fill")
                            .font(.system(size: 56))
                            .foregroundStyle(
                                LinearGradient(colors: [.yellow, .orange], startPoint: .top, endPoint: .bottom)
                            )
                            .padding(.top, 16)
                        
                        Text("Congratulations!")
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                        
                        Text("You have completed this spaced repetition study session.")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                        
                        let accuracy = studyCards.isEmpty ? 0 : Int(round(Double(correctAnswersCount) / Double(studyCards.count) * 100))
                        VStack(spacing: 4) {
                            Text("\(accuracy)%")
                                .font(.system(size: 28, weight: .black, design: .monospaced))
                                .foregroundColor(.green)
                            Text("Active Recall Accuracy")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundColor(.secondary)
                        }
                        .padding(16)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                        
                        Button {
                            withAnimation {
                                isStudyModeActive = false
                            }
                        } label: {
                            Text("Done")
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Theme.blue)
                                .cornerRadius(12)
                        }
                        .padding(.horizontal, 32)
                        .padding(.bottom, 16)
                    }
                    .background(colorScheme == .dark ? Color(hex: "#1C1C1E") : Color.white)
                    .cornerRadius(18)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1.5)
                    )
                    .shadow(color: Color.black.opacity(0.12), radius: 16, x: 0, y: 8)
                    .padding(.horizontal, 32)
                    .onAppear {
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                    }
                }
                
                Spacer()
            }
            .frame(maxWidth: 420)
        }
    }
}
