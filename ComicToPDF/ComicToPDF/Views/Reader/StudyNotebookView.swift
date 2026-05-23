import SwiftUI
import SwiftData
import CryptoKit
import PencilKit

struct StudyNotebookView: View {
    let bookID: String       // the ConvertedPDF's UUID string
    let bookTitle: String    // human-readable title shown in the Zettelkasten Hub
    var fileURL: URL? = nil  // Optional source file URL for page preview generation

    // Phase 1: Native Zettelkasten Integration
    @Environment(\.modelContext) private var modelContext
    @State private var activeNoteAnnotation: SDAnnotation?
    
    @Environment(\.colorScheme) var colorScheme
    @State private var isFocused: Bool = false
    
    @State private var localNotes: String = ""
    @State private var saveTask: Task<Void, Never>? = nil
    
    // ✅ Phase 2: PencilKit Integration
    enum InputMode: String {
        case markdown = "Text"
        case handwriting = "Pencil"
    }
    @AppStorage("studyNotebookInputMode") private var inputMode: InputMode = .markdown
    @AppStorage("studyNotebookPaperStyle") private var paperStyle: PaperStyle = .plain
    @State private var canvasView = PKCanvasView()
    
    // ✅ Phase 3: Highlights Drawer
    @State private var showHighlightsDrawer = false
    @State private var bookHighlights: [SDAnnotation] = []
    
    // Pro Search & Filter State
    @State private var highlightSearchQuery = ""
    @State private var highlightSortNewest = true
    
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
            Color(UIColor.systemBackground).ignoresSafeArea()
            
            VStack(spacing: 0) {
                // MARK: Glassmorphic Header
                HStack(spacing: 12) {
                    Image(systemName: "character.book.closed.fill")
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
                    
                    if inputMode == .handwriting {
                        // Paper Style Menu
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
                    
                    // Export Suite Menu
                    Menu {
                        Button { exportNotes(as: .markdown) } label: { Label("Export Markdown (.md)", systemImage: "arrow.down.doc") }
                        Button { exportNotes(as: .plainText) } label: { Label("Export Plain Text (.txt)", systemImage: "doc.text") }
                        Button { shareNotes() } label: { Label("Share Note...", systemImage: "square.and.arrow.up") }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.primary)
                            .padding(8)
                            .background(Color.primary.opacity(0.08))
                            .clipShape(Circle())
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
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    Color(UIColor.systemBackground).opacity(0.85)
                        .background(.ultraThinMaterial)
                )
                .overlay(Rectangle().frame(height: 1).foregroundColor(Color.primary.opacity(0.05)), alignment: .bottom)
                
                // MARK: Notebook Canvas
                ZStack(alignment: .trailing) {
                    if inputMode == .markdown {
                        MarkdownTextEditor(text: $localNotes, isFocused: $isFocused, onLinkTapped: handleLinkTapped)
                            .padding(16)
                            .onChange(of: localNotes) { _, _ in debounceSave() }
                    } else {
                        ZStack {
                            NotebookPaperBackground(style: paperStyle, colorScheme: colorScheme)
                            StudyCanvasView(canvasView: $canvasView, onSaved: debounceSave)
                        }
                        .padding(.top, 8)
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
        }
        .onAppear {
            Logger.shared.log("StudyNotebook appeared for book: '\(bookTitle)'", category: "Notebook", type: .info)
            initializeSDAnnotation()
        }
        .supportPencilDoubleTap {
            if inputMode == .markdown {
                toggleSpeechDictation()
            }
        }
        .onDisappear {
            // Final explicit sync flush layer
            Logger.shared.log("StudyNotebook disappearing — flushing note to SwiftData for '\(bookTitle)'", category: "Notebook", type: .info)
            saveTask?.cancel()
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
                // Store the real book title so the Zettelkasten Hub can group
                // this note under the correct book name instead of a raw UUID.
                readwiseBookTitle: bookTitle.isEmpty ? nil : bookTitle,
                readwiseAuthor: nil,
                createdAt: Date()
            )
            newNote.kindRaw = "note"
            modelContext.insert(newNote)
            self.activeNoteAnnotation = newNote
            self.localNotes = ""
            Logger.shared.log("New note created and inserted for '\(bookTitle)'", category: "Notebook", type: .success)
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
    
    private func debounceSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            if !Task.isCancelled {
                let note = self.localNotes
                let drawing = self.canvasView.drawing
                let drawingData = drawing.dataRepresentation()
                
                await MainActor.run {
                    self.activeNoteAnnotation?.noteText = note
                    self.activeNoteAnnotation?.drawingData = drawingData
                    self.activeNoteAnnotation?.modifiedAt = Date()
                    do {
                        try self.modelContext.save()
                        Logger.shared.log("Debounce save succeeded for '\(self.bookTitle)'", category: "Notebook", type: .success)
                        if let annotation = self.activeNoteAnnotation {
                            SpotlightIndexer.shared.indexAnnotation(annotation)
                        }
                    } catch {
                        Logger.shared.log("Debounce save FAILED for '\(self.bookTitle)': \(error.localizedDescription)", category: "Notebook", type: .error)
                    }
                }
                
                if !drawing.bounds.isEmpty {
                    Task.detached(priority: .background) {
                        if let ocrText = await HandwritingOCRManager.shared.recognizeHandwriting(in: drawing) {
                            await MainActor.run {
                                if let active = self.activeNoteAnnotation, active.drawingOCRText != ocrText {
                                    active.drawingOCRText = ocrText
                                    active.modifiedAt = Date()
                                    try? self.modelContext.save()
                                    Logger.shared.log("Handwriting OCR updated for '\(self.bookTitle)': \(ocrText.prefix(40))...", category: "OCR", type: .success)
                                    SpotlightIndexer.shared.indexAnnotation(active)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var filteredHighlights: [SDAnnotation] {
        var h = bookHighlights
        if !highlightSearchQuery.isEmpty {
            h = h.filter { $0.selectedText?.localizedCaseInsensitiveContains(highlightSearchQuery) ?? false }
        }
        if highlightSortNewest {
            return h.sorted { $0.createdAt > $1.createdAt }
        } else {
            return h.sorted { $0.pageIndex < $1.pageIndex }
        }
    }

    private func insertHighlightIntoNote(_ highlight: SDAnnotation) {
        guard let text = highlight.selectedText else {
            Logger.shared.log("insertHighlightIntoNote: skipped — highlight has no selectedText (id: \(highlight.id))", category: "Notebook", type: .warning)
            return
        }
        let quote = "\n\n> \(text) [[Page \(highlight.pageIndex + 1)]]\n\n"
        withAnimation {
            localNotes += quote
            debounceSave()
        }
        Logger.shared.log("Inserted highlight citation [[Page \(highlight.pageIndex + 1)]] into note for '\(bookTitle)'", category: "Notebook", type: .info)
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
        
        // Triggers haptic feedback
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        
        // Extract page image in background
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
            // Semi-transparent dimming backdrop to focus on the preview, tapping it dismisses the modal
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.easeOut(duration: 0.2)) {
                        showPreviewModal = false
                        previewPageIndex = nil
                        previewImage = nil
                    }
                }
            
            // Glassmorphic Modal Card
            VStack(spacing: 0) {
                // Header
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
                
                // Page content container
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
                
                // Footer
                if let pageIndex = previewPageIndex {
                    Button {
                        // Dismiss modal
                        withAnimation(.easeOut(duration: 0.2)) {
                            showPreviewModal = false
                            previewPageIndex = nil
                            previewImage = nil
                        }
                        // Jump to page in Reader
                        NotificationCenter.default.post(
                            name: NSNotification.Name("Reader_JumpToPage"),
                            object: nil,
                            userInfo: ["pageIndex": pageIndex]
                        )
                        // Play haptic jump response
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
                    .fill(Color(UIColor.systemBackground).opacity(0.85))
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
                rootVC.present(activityVC, animated: true)
            } else {
                Logger.shared.log("exportNotes: could not find root view controller to present share sheet", category: "Notebook", type: .warning)
            }
        } catch {
            Logger.shared.log("exportNotes(\(formatLabel)) FAILED for '\(bookTitle)': \(error.localizedDescription)", category: "Notebook", type: .error)
        }
    }
    
    private func shareNotes() {
        Logger.shared.log("shareNotes called for '\(bookTitle)' — \(localNotes.count) chars", category: "Notebook", type: .info)
        let activityVC = UIActivityViewController(activityItems: [localNotes], applicationActivities: nil)
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = windowScene.windows.first?.rootViewController {
            rootVC.present(activityVC, animated: true)
            Logger.shared.log("Share sheet presented for '\(bookTitle)'", category: "Notebook", type: .success)
        } else {
            Logger.shared.log("shareNotes: could not find root view controller to present share sheet", category: "Notebook", type: .warning)
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
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(highlight.selectedText ?? "Empty Highlight")
                                        .font(.system(size: 14))
                                        .foregroundColor(Theme.text)
                                        .lineSpacing(4)
                                    
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
                                        Text("p. \(highlight.pageIndex + 1)")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .padding(12)
                                .background(Color(hex: highlight.colorHex ?? "#FFD60A").opacity(0.1))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .strokeBorder(Color(hex: highlight.colorHex ?? "#FFD60A").opacity(0.3), lineWidth: 1)
                                )
                                .cornerRadius(8)
                                .onDrag {
                                    NSItemProvider(object: (highlight.selectedText ?? "") as NSString)
                                }
                            }
                        }
                    }
                    .padding(12)
                }
                .background(Color(UIColor.secondarySystemBackground).opacity(0.95))
            }
            .frame(width: 250)
            .background(.ultraThinMaterial)
            .shadow(color: .black.opacity(0.1), radius: 10, x: -5, y: 0)
        }
        .transition(.move(edge: .trailing))
    }
}

// MARK: - Phase 2: Modern Markdown Engine WYSIWYG
// MARK: - Phase 2: Modern Markdown Engine WYSIWYG
struct MarkdownTextEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
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

        // Add Tap Gesture Recognizer to intercept page link clicks without disrupting text insertion cursor focus
        let tapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tapGesture.delegate = context.coordinator
        tapGesture.cancelsTouchesInView = true
        textView.addGestureRecognizer(tapGesture)

        // MARK: Formatting Shortcut Bar (Bear/Notability pattern)
        // Replaces the plain "Done" toolbar with a 7-button formatting bar.
        let bar = UIInputView(frame: CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: 44),
                              inputViewStyle: .keyboard)
        bar.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.92)

        let items: [(title: String, insert: String, after: String?)] = [
            ("B",   "**",    "**"),
            ("I",   "_",     "_"),
            ("H1",  "# ",    nil),
            ("H2",  "## ",   nil),
            ("[[",  "[[",    "]]"),
            ("#",   "#",     nil),
            (">",   "> ",    nil),
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

        // Add Microphone button (tag 999) to formatting bar
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

        // Spacer + Done button on trailing
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(spacer)

        let doneBtn = UIButton(type: .system)
        doneBtn.setTitle("Done", for: .normal)
        doneBtn.titleLabel?.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        doneBtn.addTarget(context.coordinator, action: #selector(Coordinator.doneButtonTapped), for: .touchUpInside)
        stack.addArrangedSubview(doneBtn)

        bar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: bar.centerYAnchor)
        ])
        textView.inputAccessoryView = bar

        return textView
    }
    
    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.text != text {
            let selectedRange = uiView.selectedRange
            uiView.attributedText = MarkdownHighlighter.highlight(text)
            uiView.selectedRange = selectedRange
        }
        
        if isFocused && !uiView.isFirstResponder {
            uiView.becomeFirstResponder()
        } else if !isFocused && uiView.isFirstResponder {
            uiView.resignFirstResponder()
        }
        
        // Sync custom mic button tag 999
        if let bar = uiView.inputAccessoryView {
            if let micBtn = bar.viewWithTag(999) as? UIButton {
                let isRecording = SpeechRecognitionManager.shared.isRecording
                let config = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
                let micImage = UIImage(systemName: isRecording ? "mic.fill" : "mic", withConfiguration: config)
                micBtn.setImage(micImage, for: .normal)
                micBtn.tintColor = isRecording ? .systemRed : .label
            }
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    @MainActor
    class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        var parent: MarkdownTextEditor
        weak var textView: UITextView?
        private var dictationObserver: NSObjectProtocol?
        
        init(_ parent: MarkdownTextEditor) {
            self.parent = parent
            super.init()
            
            dictationObserver = NotificationCenter.default.addObserver(
                forName: .insertDictatedText,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                Task { @MainActor in
                    guard let self = self,
                          let textView = self.textView,
                          let textToInsert = notification.userInfo?["text"] as? String else { return }
                    
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
            
            // Insert space if needed
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
            
            // Trigger SwiftUI update
            parent.text = tv.text
            
            // Re-apply highlights
            let newSelectedRange = tv.selectedRange
            tv.attributedText = MarkdownHighlighter.highlight(tv.text)
            tv.selectedRange = newSelectedRange
        }
        
        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            
            // Re-apply highlights on the fly for pure WYSIWYG
            let selectedRange = textView.selectedRange
            textView.attributedText = MarkdownHighlighter.highlight(textView.text)
            textView.selectedRange = selectedRange
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

        // MARK: - UIGestureRecognizerDelegate
        
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
    static func highlight(_ text: String) -> NSAttributedString {
        let defaultFont = UIFont.systemFont(ofSize: 16)
        let boldFont = UIFont.boldSystemFont(ofSize: 16)
        let italicFont = UIFont.italicSystemFont(ofSize: 16)
        let h1Font = UIFont.boldSystemFont(ofSize: 24)
        let h2Font = UIFont.boldSystemFont(ofSize: 20)
        let h3Font = UIFont.boldSystemFont(ofSize: 18)
        let defaultColor = UIColor.label
        
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 6
        paragraphStyle.paragraphSpacing = 12

        let attrString = NSMutableAttributedString(string: text, attributes: [
            .font: defaultFont,
            .foregroundColor: defaultColor,
            .paragraphStyle: paragraphStyle
        ])
        
        let fullRange = NSRange(text.startIndex..., in: text)
        
        // Blockquotes (> text)
        let quotePattern = "(?m)^>.*"
        if let regex = try? NSRegularExpression(pattern: quotePattern, options: []) {
            let matches = regex.matches(in: text, range: fullRange)
            for match in matches {
                attrString.addAttributes([
                    .foregroundColor: UIColor.systemGray,
                    .font: italicFont
                ], range: match.range)
            }
        }
        
        // Bold (**text**)
        let boldPattern = "\\*\\*(.*?)\\*\\*"
        if let regex = try? NSRegularExpression(pattern: boldPattern, options: []) {
            let matches = regex.matches(in: text, range: fullRange)
            for match in matches {
                attrString.addAttribute(.font, value: boldFont, range: match.range)
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
        let h1Pattern = "(?m)^#\\s.*"
        let h2Pattern = "(?m)^##\\s.*"
        let h3Pattern = "(?m)^###\\s.*"
        
        if let r1 = try? NSRegularExpression(pattern: h1Pattern) {
            for match in r1.matches(in: text, range: fullRange) {
                attrString.addAttribute(.font, value: h1Font, range: match.range)
            }
        }
        if let r2 = try? NSRegularExpression(pattern: h2Pattern) {
            for match in r2.matches(in: text, range: fullRange) {
                attrString.addAttribute(.font, value: h2Font, range: match.range)
            }
        }
        if let r3 = try? NSRegularExpression(pattern: h3Pattern) {
            for match in r3.matches(in: text, range: fullRange) {
                attrString.addAttribute(.font, value: h3Font, range: match.range)
            }
        }
        
        return attrString
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

        // Move cursor inside wrapping syntax when selection was empty
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
    
    var id: String { self.rawValue }
    var icon: String {
        switch self {
        case .plain: return "square"
        case .ruled: return "line.horizontal.3"
        case .grid: return "grid"
        case .dots: return "circle.hexagongrid.fill"
        }
    }
}

struct NotebookPaperBackground: View {
    let style: PaperStyle
    let colorScheme: ColorScheme

    var body: some View {
        GeometryReader { geo in
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
                }
            }
            .stroke(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.08), lineWidth: style == .dots ? 2 : 0.8)
        }
    }
}

extension Notification.Name {
    static let insertDictatedText = Notification.Name("InsertDictatedText")
}
