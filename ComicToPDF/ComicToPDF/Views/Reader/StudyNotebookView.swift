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
    @EnvironmentObject var conversionManager: ConversionManager
    @EnvironmentObject var settingsManager: AppSettingsManager
    @State private var activeNoteAnnotation: SDAnnotation?
    @ObservedObject private var progressTracker = ReaderProgressTracker.shared
    @State private var referencedPageIndices: Set<Int> = []
    @StateObject private var speechEngine = NotebookSpeechNarrationEngine.shared

    private var activeReaderPageIndex: Int? {
        var targetUUID: UUID? = UUID(uuidString: bookID)
        if targetUUID == nil {
            targetUUID = resolvedPDF?.id
        }
        guard let pdfID = targetUUID else { return nil }
        return progressTracker.progress(for: pdfID)?.currentPageIndex
    }

    private func jumpToPage(_ pageIndex: Int) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        NotificationCenter.default.post(
            name: .readerJumpToPage,
            object: nil,
            userInfo: ["pageIndex": pageIndex, "page": pageIndex]
        )
        Logger.shared.log("Smart Notebook: Jumped open reader to page \(pageIndex + 1)", category: "Notebook", type: .info)
    }

    private func jumpToHighlight(_ highlight: SDAnnotation) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        var info: [String: Any] = [
            "pageIndex": highlight.pageIndex,
            "chapterPage": highlight.pageIndex,
            "page": highlight.pageIndex
        ]
        if let chap = highlight.chapterTitle {
            info["chapterTitle"] = chap
        }
        if let text = highlight.selectedText {
            info["selectedText"] = text
        }
        NotificationCenter.default.post(
            name: .readerJumpToPage,
            object: nil,
            userInfo: info
        )
        Logger.shared.log("Smart Notebook: Jumped open reader to highlight on page \(highlight.pageIndex + 1)", category: "Notebook", type: .info)
    }

    private func stampCurrentPageLink() {
        guard let pageIdx = activeReaderPageIndex else { return }
        let displayPage = pageIdx + 1
        let stampTag = " [📍 Page \(displayPage)](page:\(pageIdx)) "
        self.localNotes += stampTag
        self.referencedPageIndices.insert(pageIdx)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        debounceSave()
    }
    
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
    
    enum NoteTakingSystem: String, CaseIterable, Identifiable {
        case zettelkasten = "Zettelkasten"
        case cornell      = "Cornell"
        case para         = "PARA"
        case marginalia   = "Marginalia"
        
        var id: String { rawValue }
        
        var icon: String {
            switch self {
            case .zettelkasten: return "tree.fill"
            case .cornell:      return "doc.text.fill"
            case .para:         return "rocket.fill"
            case .marginalia:   return "scribble.variable"
            }
        }
    }
    
    @AppStorage("studyNotebookSystem") private var noteSystem: NoteTakingSystem = .zettelkasten
    @AppStorage("studyNotebookInputMode") private var inputMode: InputMode = .markdown
    @State private var paperStyle: PaperStyle = .plain
    @State private var paperSpacing: CGFloat = 24.0
    @State private var selectedBookForReader: ConvertedPDF? = nil
    @State private var isShowingBookPicker = false
    @AppStorage("studyNotebookPlacement") private var notebookPlacement: SidebarPlacement = .right
    @State private var canvasView = PKCanvasView()
    
    // Cornell Method state
    @State private var cornellCuesText: String = ""
    @State private var cornellSummaryText: String = ""
    @State private var isCoveredForRecitation: Bool = false

    // Kindle & Export state
    @AppStorage("kindleEmail") private var kindleEmail: String = ""
    @State private var isShowingBookSavedToast: Bool = false
    @State private var savedBookURL: URL? = nil

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
    @State private var expandedHighlightIDs = Set<UUID>()
    
    // Pro Search & Filter State
    @State private var highlightSearchQuery = ""
    @State private var highlightSortNewest = true
    @State private var selectedTagFilter: String? = nil
    @State private var selectedColorFilter: String? = nil
    @State private var copiedHighlightID: UUID? = nil
    @State private var activeHighlightToEdit: SDAnnotation? = nil
    @State private var highlightPendingDelete: SDAnnotation? = nil
    @State private var showDeleteHighlightAlert: Bool = false
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
        GeometryReader { notebookGeo in
            let availableWidth = notebookGeo.size.width
            
            let inputPicker = HStack(spacing: 0) {
                Button {
                    HapticEngine.light()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        inputMode = .markdown
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 11, weight: .bold))
                        Text("Text")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                    }
                    .foregroundColor(inputMode == .markdown ? .white : .primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Group {
                            if inputMode == .markdown {
                                LinearGradient(colors: [Theme.blue, Color.purple], startPoint: .leading, endPoint: .trailing)
                                    .clipShape(Capsule())
                                    .shadow(color: Theme.blue.opacity(0.3), radius: 4, x: 0, y: 2)
                            } else {
                                Color.clear
                            }
                        }
                    )
                }
                .buttonStyle(.plain)

                Button {
                    HapticEngine.light()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        inputMode = .handwriting
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "applepencil")
                            .font(.system(size: 11, weight: .bold))
                        Text("Pencil")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                    }
                    .foregroundColor(inputMode == .handwriting ? .white : .primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Group {
                            if inputMode == .handwriting {
                                LinearGradient(colors: [.orange, .red], startPoint: .leading, endPoint: .trailing)
                                    .clipShape(Capsule())
                                    .shadow(color: .orange.opacity(0.3), radius: 4, x: 0, y: 2)
                            } else {
                                Color.clear
                            }
                        }
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(2)
            .background(Color.primary.opacity(0.06), in: Capsule())
            .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 0.8))
            
            let micButton = Button {
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
            
            let readAloudButton = Button {
                toggleNotebookNarration()
            } label: {
                Image(systemName: speechEngine.isPlaying ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(speechEngine.isActive ? .white : .primary)
                    .padding(8)
                    .background(
                        speechEngine.isActive
                        ? AnyShapeStyle(LinearGradient(colors: [.purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                        : AnyShapeStyle(Color.primary.opacity(0.08))
                    )
                    .clipShape(Circle())
            }
            
            let paperStyleMenu = Menu {
                Section("Paper Style") {
                    Picker("Style", selection: $paperStyle) {
                        ForEach(PaperStyle.allCases) { style in
                            Label(style.rawValue, systemImage: style.icon).tag(style)
                        }
                    }
                }
                if paperStyle != .plain {
                    Section("Line & Grid Size") {
                        Picker("Size", selection: $paperSpacing) {
                            Text("Small (Narrow)").tag(CGFloat(18.0))
                            Text("Medium (Normal)").tag(CGFloat(24.0))
                            Text("Large (Wide)").tag(CGFloat(32.0))
                        }
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
            
            let summaryButton = Button {
                generateAISummary()
            } label: {
                Image(systemName: "sparkles")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.purple)
                    .padding(8)
                    .background(Color.purple.opacity(0.1))
                    .clipShape(Circle())
            }
            
            let writingAssistantButton = Button {
                showWritingAssistant = true
            } label: {
                Image(systemName: "checkmark.bubble.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.blue)
                    .padding(8)
                    .background(Color.blue.opacity(0.1))
                    .clipShape(Circle())
            }
            
            let studyButton = Button {
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
                    if availableWidth > 480 {
                        Text("Study")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                    }
                }
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    LinearGradient(colors: [Theme.blue, Color.purple], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: Capsule()
                )
            }
            
            let pasteButton = Button {
                pasteFromClipboard()
            } label: {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.orange)
                    .padding(8)
                    .background(Color.orange.opacity(0.12))
                    .clipShape(Circle())
            }
            .help("Paste copied text or web article from clipboard")

            let exportMenu = Menu {
                Section("Document & Kindle Export") {
                    Button { exportNotes(as: .pdf) } label: { Label("Export as PDF (.pdf)", systemImage: "doc.richtext") }
                    Button { sendToKindle() } label: { Label("Send to Kindle", systemImage: "paperplane") }
                    Button { saveToLibraryAsBook() } label: { Label("Save as Book in Library", systemImage: "book.badge.plus") }
                }
                Section("Raw Formats") {
                    Button { exportNotes(as: .markdown) } label: { Label("Export Markdown (.md)", systemImage: "arrow.down.doc") }
                    Button { exportNotes(as: .plainText) } label: { Label("Export Plain Text (.txt)", systemImage: "doc.text") }
                    Button { exportZettelkastenZip() } label: { Label("Export Zettelkasten Zip (Obsidian)", systemImage: "archivebox") }
                    Button { shareNotes() } label: { Label("Share Note...", systemImage: "square.and.arrow.up") }
                }
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.primary)
                    .padding(8)
                    .background(Color.primary.opacity(0.08))
                    .clipShape(Circle())
            }
            
            let linkBookButton = Group {
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
                } else {
                    Button {
                        HapticEngine.light()
                        isShowingBookPicker = true
                    } label: {
                        Image(systemName: "book.badge.plus")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.primary)
                            .padding(8)
                            .background(Color.primary.opacity(0.08))
                            .clipShape(Circle())
                    }
                }
            }
            
            let highlighterButton = Button {
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
            
            let statsMenu = Menu {
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

            ZStack(alignment: .bottom) {
                // MARK: Premium Background Base
                Color.inkBackground.ignoresSafeArea()
                
                VStack(spacing: 0) {
                    // MARK: Glassmorphic Header
                    HStack(spacing: availableWidth > 400 ? 12 : 8) {
                        if showBackButton {
                            Button {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                dismiss()
                            } label: {
                                HStack(spacing: 2) {
                                    Image(systemName: "chevron.left")
                                    if availableWidth > 450 {
                                        Text("Back")
                                            .font(.system(size: 15, weight: .bold, design: .rounded))
                                    }
                                }
                                .foregroundColor(.orange)
                            }
                            .buttonStyle(.plain)
                        }
                        
                        Image(systemName: "notebook.toptab.fill")
                            .foregroundStyle(LinearGradient(colors: [Theme.blue, Color.purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .font(.system(size: 18, weight: .bold))
                        
                        Text(availableWidth > 450 ? "Study Notebook" : "Notes")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundColor(.primary)
                        
                        Spacer()
                        
                        if availableWidth > 550 {
                            // WIDE TOOLBAR
                            inputPicker
                            pasteButton
                            
                            if inputMode == .markdown {
                                micButton
                            }
                            readAloudButton
                            
                            paperStyleMenu
                            summaryButton
                            writingAssistantButton
                            
                            if !bookHighlights.isEmpty {
                                studyButton
                            }
                            
                            exportMenu
                            
                            if showBackButton {
                                linkBookButton
                            }
                            
                            highlighterButton
                            statsMenu
                        } else if availableWidth > 380 {
                            // MEDIUM TOOLBAR
                            inputPicker
                            pasteButton
                            highlighterButton
                            
                            Menu {
                                Section("Tools") {
                                    if !bookHighlights.isEmpty {
                                        Button {
                                            studyCards = bookHighlights
                                            currentCardIndex = 0
                                            isAnswerRevealed = false
                                            isStudyModeActive = true
                                        } label: { Label("Study Flashcards", systemImage: "play.rectangle.on.rectangle") }
                                    }
                                    Button { generateAISummary() } label: { Label("Generate AI Summary", systemImage: "sparkles") }
                                    Button { showWritingAssistant = true } label: { Label("Writing Assistant", systemImage: "checkmark.bubble") }
                                    Button { toggleNotebookNarration() } label: { Label(speechEngine.isActive ? "Stop Read Aloud" : "Read Notes Aloud", systemImage: "speaker.wave.2") }
                                    if inputMode == .markdown {
                                        Button { toggleSpeechDictation() } label: { Label(speechManager.isRecording ? "Stop Dictation" : "Start Dictation", systemImage: "mic") }
                                    }
                                }
                                
                                Section("Settings & Export") {
                                    Menu("Paper Style...") {
                                        Picker("Style", selection: $paperStyle) {
                                            ForEach(PaperStyle.allCases) { style in
                                                Label(style.rawValue, systemImage: style.icon).tag(style)
                                            }
                                        }
                                    }
                                    Menu("Export...") {
                                        Button { exportNotes(as: .pdf) } label: { Label("Export as PDF (.pdf)", systemImage: "doc.richtext") }
                                        Button { sendToKindle() } label: { Label("Send to Kindle", systemImage: "paperplane") }
                                        Button { saveToLibraryAsBook() } label: { Label("Save as Book in Library", systemImage: "book.badge.plus") }
                                        Divider()
                                        Button { exportNotes(as: .markdown) } label: { Label("Export Markdown (.md)", systemImage: "arrow.down.doc") }
                                        Button { exportNotes(as: .plainText) } label: { Label("Export Plain Text (.txt)", systemImage: "doc.text") }
                                        Button { exportZettelkastenZip() } label: { Label("Export Zettelkasten Zip", systemImage: "archivebox") }
                                        Button { shareNotes() } label: { Label("Share Note...", systemImage: "square.and.arrow.up") }
                                    }
                                    Button { isShowingBookPicker = true } label: { Label("Link Backing Book", systemImage: "book.badge.plus") }
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(.primary)
                                    .padding(8)
                                    .background(Color.primary.opacity(0.08))
                                    .clipShape(Circle())
                            }
                        } else {
                            // COMPACT TOOLBAR
                            Button {
                                inputMode = (inputMode == .markdown) ? .handwriting : .markdown
                            } label: {
                                Image(systemName: inputMode == .markdown ? "keyboard" : "applepencil")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(.orange)
                                    .padding(6)
                                    .background(Color.orange.opacity(0.12))
                                    .clipShape(Circle())
                            }
                            
                            pasteButton
                            highlighterButton
                            
                            Menu {
                                Section("Tools") {
                                    Button { generateAISummary() } label: { Label("Generate AI Summary", systemImage: "sparkles") }
                                    Button { showWritingAssistant = true } label: { Label("Writing Assistant", systemImage: "checkmark.bubble") }
                                    Button { toggleNotebookNarration() } label: { Label(speechEngine.isActive ? "Stop Read Aloud" : "Read Notes Aloud", systemImage: "speaker.wave.2") }
                                    if inputMode == .markdown {
                                        Button { toggleSpeechDictation() } label: { Label(speechManager.isRecording ? "Stop Dictation" : "Start Dictation", systemImage: "mic") }
                                    }
                                }
                                Section("Settings & Export") {
                                    Menu("Paper Style...") {
                                        Picker("Style", selection: $paperStyle) {
                                            ForEach(PaperStyle.allCases) { style in
                                                Label(style.rawValue, systemImage: style.icon).tag(style)
                                            }
                                        }
                                    }
                                    Menu("Export...") {
                                        Button { exportNotes(as: .markdown) } label: { Label("Export Markdown (.md)", systemImage: "arrow.down.doc") }
                                        Button { exportNotes(as: .plainText) } label: { Label("Export Plain Text (.txt)", systemImage: "doc.text") }
                                        Button { exportZettelkastenZip() } label: { Label("Export Zettelkasten Zip", systemImage: "archivebox") }
                                        Button { shareNotes() } label: { Label("Share Note...", systemImage: "square.and.arrow.up") }
                                    }
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(.primary)
                                    .padding(8)
                                    .background(Color.primary.opacity(0.08))
                                    .clipShape(Circle())
                            }
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
                        
                        // Quick Flip side button
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
                    
                    // ── Multi-Modal System Selector Bar (Zettelkasten / Cornell / PARA / Marginalia) ──
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(NoteTakingSystem.allCases) { sys in
                                Button {
                                    HapticEngine.light()
                                    withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                                        noteSystem = sys
                                    }
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: sys.icon)
                                            .font(.system(size: 10, weight: .bold))
                                        Text(sys.rawValue)
                                            .font(.system(size: 11, weight: .bold, design: .rounded))
                                    }
                                    .fixedSize(horizontal: true, vertical: false)
                                    .foregroundColor(noteSystem == sys ? .white : Theme.textSecondary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(
                                        noteSystem == sys
                                            ? AnyShapeStyle(Color(hex: "#7B5EA7"))
                                            : AnyShapeStyle(Color.primary.opacity(0.05))
                                    )
                                    .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 12)
                    }
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.02))
                    .overlay(Rectangle().frame(height: 0.5).foregroundColor(Color.primary.opacity(0.05)), alignment: .bottom)
                    
                    smartPageIndexBar
                    
                    if inputMode == .handwriting {
                        canvasToolbar
                    }
                    
                    // MARK: Notebook Canvas
                    ZStack(alignment: .trailing) {
                        if noteSystem == .cornell {
                            CornellNotesZoneView(
                                notebookWidth: notebookGeo.size.width,
                                isCoveredForRecitation: $isCoveredForRecitation,
                                cornellCuesText: $cornellCuesText,
                                cornellSummaryText: $cornellSummaryText,
                                isMarkdownMode: inputMode == .markdown,
                                paperStyle: paperStyle,
                                paperSpacing: paperSpacing,
                                localNotes: $localNotes,
                                isFocused: $isFocused,
                                canvasView: $canvasView,
                                isSmartShapesEnabled: $isSmartShapesEnabled,
                                onLinkTapped: handleLinkTapped,
                                onCanvasSaved: debounceSave,
                                onGenerateCues: generateCornellCues,
                                onGenerateSummary: generateCornellSummary
                            )
                            .onChange(of: cornellCuesText) { _, _ in debounceSave() }
                            .onChange(of: cornellSummaryText) { _, _ in debounceSave() }
                        } else if inputMode == .markdown {
                            ZStack {
                                NotebookPaperBackground(style: paperStyle, spacing: paperSpacing, colorScheme: colorScheme)
                                MarkdownTextEditor(text: $localNotes, isFocused: $isFocused, paperStyle: paperStyle, onLinkTapped: handleLinkTapped)
                                
                                if localNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    VStack(spacing: 14) {
                                        Image(systemName: "doc.on.clipboard")
                                            .font(.system(size: 38))
                                            .foregroundColor(.orange)
                                        
                                        Text("Notebook is Empty")
                                            .font(.system(size: 16, weight: .bold, design: .rounded))
                                            .foregroundColor(.inkTextPrimary)
                                        
                                        Text("Type your thoughts, or paste a copied article or text to read and annotate later.")
                                            .font(.system(size: 12))
                                            .foregroundColor(.inkTextSecondary)
                                            .multilineTextAlignment(.center)
                                            .padding(.horizontal, 24)
                                        
                                        Button {
                                            pasteFromClipboard()
                                        } label: {
                                            HStack(spacing: 6) {
                                                Image(systemName: "doc.on.clipboard.fill")
                                                Text("Paste from Clipboard")
                                                    .font(.system(size: 13, weight: .bold, design: .rounded))
                                            }
                                            .foregroundColor(.white)
                                            .padding(.horizontal, 18)
                                            .padding(.vertical, 9)
                                            .background(
                                                LinearGradient(colors: [Color.orange, Color.purple], startPoint: .leading, endPoint: .trailing),
                                                in: Capsule()
                                            )
                                            .shadow(color: Color.orange.opacity(0.3), radius: 4, x: 0, y: 2)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .padding(24)
                                    .background(Color.inkSurfaceRaised.opacity(0.9).background(.ultraThinMaterial))
                                    .cornerRadius(16)
                                    .shadow(color: Color.black.opacity(0.1), radius: 12, y: 4)
                                    .padding(.horizontal, 32)
                                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                                }
                            }
                            .onChange(of: localNotes) { _, _ in debounceSave() }
                        } else {
                            ZStack {
                                NotebookPaperBackground(style: paperStyle, spacing: paperSpacing, colorScheme: colorScheme)
                                StudyCanvasView(canvasView: $canvasView, isSmartShapesEnabled: $isSmartShapesEnabled, onSaved: debounceSave)
                            }
                            .padding(.top, 8)
                            .onAppear {
                                updateCanvasTool()
                            }
                        }
                        
                        // MARK: Highlights Drawer Overlay
                        if showHighlightsDrawer {
                            highlightsDrawer(notebookWidth: notebookGeo.size.width)
                        }
                    }

                    // Toast Banner when book is saved to library
                    if isShowingBookSavedToast {
                        HStack(spacing: 12) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 20))
                                .foregroundColor(.green)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Saved to Library")
                                    .font(.system(size: 13, weight: .bold, design: .rounded))
                                    .foregroundColor(.inkTextPrimary)
                                Text("Book added to InksyncPro for highlighting and reading.")
                                    .font(.system(size: 11))
                                    .foregroundColor(.inkTextSecondary)
                            }
                            
                            Spacer()
                            
                            Button("Open") {
                                withAnimation { isShowingBookSavedToast = false }
                                if let savedURL = savedBookURL,
                                   let book = conversionManager.convertedPDFs.first(where: { $0.url == savedURL }) ?? conversionManager.convertedPDFs.first(where: { $0.name == savedURL.deletingPathExtension().lastPathComponent }) {
                                    selectedBookForReader = book
                                    AppRouter.shared.presentFullScreen(.read(book))
                                }
                            }
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.green, in: Capsule())
                        }
                        .padding(14)
                        .background(Color.inkSurfaceRaised.opacity(0.95).background(.ultraThinMaterial))
                        .cornerRadius(14)
                        .shadow(color: Color.black.opacity(0.2), radius: 10, y: 4)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                                withAnimation { isShowingBookSavedToast = false }
                            }
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
                
                if speechEngine.isActive {
                    NotebookSpeechHUDView(engine: speechEngine) {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            speechEngine.stop()
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 20)
                    .zIndex(40)
                }
                
                // MARK: Interactive Page Preview Modal Overlay
                if showPreviewModal {
                    pagePreviewModalOverlay
                }
                
                if isStudyModeActive {
                    StudyFlashcardDeckOverlay(
                        isStudyModeActive: $isStudyModeActive,
                        studyCards: studyCards,
                        currentCardIndex: $currentCardIndex,
                        isAnswerRevealed: $isAnswerRevealed,
                        correctAnswersCount: correctAnswersCount,
                        onGrade: { correct in
                            gradeCard(correct: correct)
                        }
                    )
                }
            }
            .frame(width: notebookGeo.size.width, height: notebookGeo.size.height)
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
            .alert("Delete Highlight?", isPresented: $showDeleteHighlightAlert, presenting: highlightPendingDelete) { highlight in
                Button("Delete", role: .destructive) {
                    deleteHighlightCompletely(highlight)
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("This will permanently remove the highlight from the document and your study notes.")
            }
            .sheet(isPresented: $showWritingAssistant) {
                WritingAssistantSheet(text: $localNotes)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .fullScreenCover(item: $selectedBookForReader) { pdf in
                UnifiedReaderView(pdf: pdf, startWithNotebookOpen: true)
                    .environmentObject(conversionManager)
                    .environmentObject(settingsManager)
            }
            .sheet(isPresented: $isShowingBookPicker) {
                BookPickerSheet { selectedBook in
                    linkBookToNotebook(selectedBook)
                    selectedBookForReader = selectedBook
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .inkTabGoToLibraryRoot)) { _ in
                selectedBookForReader = nil
            }
            .onReceive(NotificationCenter.default.publisher(for: .annotationsDidChange)) { notification in
                if let targetPDFID = notification.userInfo?["pdfID"] as? UUID,
                   let bookUUID = UUID(uuidString: bookID),
                   targetPDFID == bookUUID {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        refreshHighlights()
                    }
                } else if notification.userInfo?["pdfID"] == nil {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        refreshHighlights()
                    }
                }
            }
            .onAppear {
                Logger.shared.log("StudyNotebook appeared for book: '\(bookTitle)'", category: "Notebook", type: .info)
                initializeSDAnnotation()
            }
            .onDisappear {
                flushSave()
            }
            .onChange(of: paperStyle) { _, newStyle in
                if let nb = getOrCreateNotebook() {
                    nb.templateStyle = newStyle.rawValue
                    try? modelContext.save()
                    Logger.shared.log("Persisted paper style '\(newStyle.rawValue)' to notebook '\(bookTitle)'", category: "Notebook", type: .success)
                }
            }
            .onChange(of: paperSpacing) { _, newSpacing in
                if let nb = getOrCreateNotebook() {
                    nb.templateSize = Double(newSpacing)
                    try? modelContext.save()
                    Logger.shared.log("Persisted paper size '\(newSpacing)' to notebook '\(bookTitle)'", category: "Notebook", type: .success)
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
                speechEngine.stop()
                // Final explicit sync flush layer
                Logger.shared.log("StudyNotebook disappearing — flushing note to SwiftData for '\(bookTitle)'", category: "Notebook", type: .info)
                saveTask?.cancel()
                ocrTask?.cancel()
                let note = localNotes
                let drawing = canvasView.drawing
                let drawingData = drawing.dataRepresentation()
                
                activeNoteAnnotation?.noteText = note
                activeNoteAnnotation?.cornellCueText = cornellCuesText
                activeNoteAnnotation?.cornellSummaryText = cornellSummaryText
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
    }
    
    // MARK: - Core Execution
    
    /// Binds the StudyNotebook to the Global Zettelkasten Hub's SwiftData Engine natively.
    private func initializeSDAnnotation() {
        var resolvedBookUUID = UUID()
        if let actualUUID = UUID(uuidString: bookID) {
            resolvedBookUUID = actualUUID
            let nbDesc = FetchDescriptor<SDNotebook>(predicate: #Predicate { $0.id == actualUUID })
            if let nb = try? modelContext.fetch(nbDesc).first, let linked = nb.linkedBookID {
                resolvedBookUUID = linked
            }
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
            let loadedText = existing.noteText ?? ""
            self.localNotes = loadedText
            self.cornellCuesText = existing.cornellCueText ?? ""
            self.cornellSummaryText = existing.cornellSummaryText ?? ""
            let wordCount = loadedText.split { $0.isWhitespace }.count
            Logger.shared.log("Loaded existing note for '\(bookTitle)' (\(wordCount) words, Cornell cues: \(self.cornellCuesText.count) chars, summary: \(self.cornellSummaryText.count) chars)", category: "Notebook", type: .success)
            
            if existing.pageIndex >= 0 {
                self.referencedPageIndices.insert(existing.pageIndex)
            }
            
            let linkRegexPattern = #"\((?:page:|inksync://page/)(\d+)\)"#
            if let regex = try? NSRegularExpression(pattern: linkRegexPattern) {
                let nsText = loadedText as NSString
                let matches = regex.matches(in: loadedText, range: NSRange(location: 0, length: nsText.length))
                for match in matches {
                    if match.numberOfRanges > 1, let pIdx = Int(nsText.substring(with: match.range(at: 1))) {
                        self.referencedPageIndices.insert(pIdx)
                    }
                }
            }
            
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
            self.cornellCuesText = ""
            self.cornellSummaryText = ""
            Logger.shared.log("New note created, inserted and saved for '\(bookTitle)'", category: "Notebook", type: .success)
        }
        
        // Fetch paper style from SDNotebook if it exists
        if let nb = getOrCreateNotebook() {
            self.paperStyle = PaperStyle(rawValue: nb.templateStyle) ?? .plain
            self.paperSpacing = CGFloat(nb.templateSize ?? 24.0)
            Logger.shared.log("Loaded template style '\(nb.templateStyle)' and spacing \(self.paperSpacing) for notebook '\(bookTitle)'", category: "Notebook", type: .success)
        }
        
        // Fetch existing highlights for this book
        let hDescriptor = FetchDescriptor<SDAnnotation>(predicate: #Predicate { ($0.kindRaw == "highlight" || $0.kindRaw == "underline" || $0.kindRaw == "strikeOut") && $0.pdfID == targetPDFID })
        if let h = try? modelContext.fetch(hDescriptor) {
            self.bookHighlights = h.sorted { $0.createdAt > $1.createdAt }
            Logger.shared.log("Fetched \(h.count) highlight(s) for '\(bookTitle)'", category: "Notebook", type: .info)
        } else {
            Logger.shared.log("Highlights fetch failed for '\(bookTitle)'", category: "Notebook", type: .warning)
        }
        
        // Auto-sync fallback from AnnotationStore
        let storeAnns = AnnotationStore.shared.annotations(for: targetPDFID)
            .filter { $0.kind == .highlight || $0.kind == .underline || $0.kind == .strikeOut }
        if !storeAnns.isEmpty {
            var didImport = false
            for ann in storeAnns {
                let annID = ann.id
                let checkDesc = FetchDescriptor<SDAnnotation>(predicate: #Predicate { $0.id == annID })
                if (try? modelContext.fetch(checkDesc).first) == nil {
                    let sd = SDAnnotation(from: ann)
                    modelContext.insert(sd)
                    didImport = true
                }
            }
            if didImport {
                try? modelContext.save()
                if let refreshed = try? modelContext.fetch(hDescriptor) {
                    self.bookHighlights = refreshed.sorted { $0.createdAt > $1.createdAt }
                }
            }
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
            let nbDesc = FetchDescriptor<SDNotebook>(predicate: #Predicate { $0.id == actualUUID })
            if let nb = try? modelContext.fetch(nbDesc).first, let linked = nb.linkedBookID {
                targetPDFID = linked
            }
        }
        let hDescriptor = FetchDescriptor<SDAnnotation>(predicate: #Predicate { ($0.kindRaw == "highlight" || $0.kindRaw == "underline" || $0.kindRaw == "strikeOut") && $0.pdfID == targetPDFID })
        if let h = try? modelContext.fetch(hDescriptor) {
            self.bookHighlights = h.sorted { $0.createdAt > $1.createdAt }
        }
    }
    
    private func flushSave() {
        saveTask?.cancel()
        saveTask = nil
        ocrTask?.cancel()
        ocrTask = nil

        let note = self.localNotes
        let cues = self.cornellCuesText
        let summary = self.cornellSummaryText
        let drawing = self.canvasView.drawing
        let drawingData = drawing.dataRepresentation()

        if let activePage = self.activeReaderPageIndex {
            self.activeNoteAnnotation?.pageIndex = activePage
            self.referencedPageIndices.insert(activePage)
        }
        self.activeNoteAnnotation?.noteText = note
        self.activeNoteAnnotation?.cornellCueText = cues
        self.activeNoteAnnotation?.cornellSummaryText = summary
        self.activeNoteAnnotation?.drawingData = drawingData
        self.activeNoteAnnotation?.modifiedAt = Date()
        if let annotation = self.activeNoteAnnotation {
            SpotlightIndexer.shared.indexAnnotation(annotation)
        }
        try? self.modelContext.save()

        if speechEngine.isPlaying {
            speechEngine.stop()
        }
    }

    private func debounceSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000) // 1.2 seconds for data saving debounce
            if !Task.isCancelled {
                let note = self.localNotes
                let cues = self.cornellCuesText
                let summary = self.cornellSummaryText
                let drawing = self.canvasView.drawing
                let drawingData = drawing.dataRepresentation()
                
                await MainActor.run {
                    if let activePage = self.activeReaderPageIndex {
                        self.activeNoteAnnotation?.pageIndex = activePage
                        self.referencedPageIndices.insert(activePage)
                    }
                    self.activeNoteAnnotation?.noteText = note
                    self.activeNoteAnnotation?.cornellCueText = cues
                    self.activeNoteAnnotation?.cornellSummaryText = summary
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

    private var allColorsInHighlights: [String] {
        let all = bookHighlights.compactMap { $0.colorHex }
        return Array(Set(all)).sorted()
    }

    private var filteredHighlights: [SDAnnotation] {
        var h = bookHighlights
        if let filter = selectedTagFilter {
            h = h.filter { $0.tags?.contains(filter) ?? false }
        }
        if let colorFilter = selectedColorFilter {
            h = h.filter { ($0.colorHex ?? "").localizedCaseInsensitiveContains(colorFilter) }
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

    private func deleteHighlightCompletely(_ highlight: SDAnnotation) {
        let pid = highlight.pdfID
        let highlightID = highlight.id
        let selectedText = highlight.selectedText ?? ""
        
        AnnotationStore.shared.delete(id: highlightID, pdfID: pid)
        modelContext.delete(highlight)
        try? modelContext.save()
        
        // Post broadcast so live readers (PDF and EPUB) immediately unhighlight in their canvas/DOM
        NotificationCenter.default.post(
            name: .annotationsDidChange,
            object: nil,
            userInfo: [
                "pdfID": pid,
                "deletedID": highlightID,
                "text": selectedText
            ]
        )
        
        refreshHighlights()
        HapticEngine.selection()
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
        var resolvedPageIndex: Int? = nil
        if url.scheme == "inksync", url.host == "page", let lastComp = url.pathComponents.last, let idx = Int(lastComp) {
            resolvedPageIndex = idx
        } else if url.scheme == "page" {
            let spec = url.absoluteString.replacingOccurrences(of: "page:", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if let idx = Int(spec) {
                resolvedPageIndex = idx
            }
        }
        
        guard let pageIndex = resolvedPageIndex else { return }
        
        Logger.shared.log("Page link tapped: jumping open reader & preview to page index \(pageIndex)", category: "Notebook", type: .info)
        
        jumpToPage(pageIndex)
        
        self.previewPageIndex = pageIndex
        self.previewImage = nil
        self.isExtractingPreviewImage = true
        withAnimation(.easeOut(duration: 0.2)) {
            self.showPreviewModal = true
        }
        
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        
        var targetURL = fileURL ?? resolvedPDF?.url
        if let resolvedPDF = resolvedPDF,
           case .linked(let bm) = resolvedPDF.sourceMode,
           let resolved = try? BookmarkResolver.shared.resolve(bm) {
            targetURL = resolved
        }
        
        if let bookURL = targetURL {
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
                            name: .readerJumpToPage,
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

    private func toggleNotebookNarration() {
        if speechEngine.isActive {
            speechEngine.stop()
        } else {
            speechEngine.startReading(text: localNotes, title: bookTitle)
        }
    }

    enum ExportType {
        case markdown, plainText, pdf
    }
    
    private func pasteFromClipboard() {
        guard let clipboardString = UIPasteboard.general.string, !clipboardString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            HapticEngine.error()
            return
        }
        
        HapticEngine.success()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            inputMode = .markdown
        }
        
        let trimmed = clipboardString.trimmingCharacters(in: .whitespacesAndNewlines)
        if localNotes.isEmpty {
            localNotes = trimmed
        } else {
            localNotes += "\n\n" + trimmed
        }
        debounceSave()
    }
    
    private func exportNotes(as type: ExportType) {
        if type == .pdf {
            do {
                let pdfURL = try NotebookDocumentExporter.shared.exportPDF(title: bookTitle, content: localNotes)
                let activityVC = UIActivityViewController(activityItems: [pdfURL], applicationActivities: nil)
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
                Logger.shared.log("exportNotes(.pdf) FAILED for '\(bookTitle)': \(error.localizedDescription)", category: "Notebook", type: .error)
            }
            return
        }
        
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
        case .pdf:
            return
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
    
    private func sendToKindle() {
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = windowScene.windows.first?.rootViewController {
            NotebookDocumentExporter.shared.presentKindleExport(
                title: bookTitle,
                content: localNotes,
                from: rootVC,
                kindleEmail: kindleEmail.isEmpty ? nil : kindleEmail
            )
        }
    }
    
    private func saveToLibraryAsBook() {
        Task {
            do {
                let savedURL = try await NotebookDocumentExporter.shared.saveToLibraryAsBook(
                    title: bookTitle.isEmpty ? "Notebook Article" : bookTitle,
                    content: localNotes
                )
                await MainActor.run {
                    self.savedBookURL = savedURL
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        self.isShowingBookSavedToast = true
                    }
                    HapticEngine.success()
                }
            } catch {
                Logger.shared.log("saveToLibraryAsBook FAILED for '\(bookTitle)': \(error.localizedDescription)", category: "Notebook", type: .error)
            }
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
    private func highlightsDrawer(notebookWidth: CGFloat) -> some View {
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
                    
                    // Color filters row
                    let availableColors = ["#FFD60A", "#30D158", "#0A84FF", "#FF375F", "#FF9F0A", "#BF5AF2"]
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            Button {
                                withAnimation { selectedColorFilter = nil }
                            } label: {
                                Text("All Colors")
                                    .font(.system(size: 9, weight: selectedColorFilter == nil ? .bold : .medium))
                                    .foregroundColor(selectedColorFilter == nil ? .white : .primary)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(selectedColorFilter == nil ? Theme.blue : Color.primary.opacity(0.06), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            
                            ForEach(availableColors, id: \.self) { hex in
                                Button {
                                    withAnimation {
                                        if selectedColorFilter == hex {
                                            selectedColorFilter = nil
                                        } else {
                                            selectedColorFilter = hex
                                        }
                                    }
                                } label: {
                                    ZStack {
                                        Circle()
                                            .fill(Color(hex: hex))
                                            .frame(width: 16, height: 16)
                                        if selectedColorFilter == hex {
                                            Circle()
                                                .stroke(Color.white, lineWidth: 2)
                                                .frame(width: 18, height: 18)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 2)
                    }

                    // Tag filters scroll list
                    let tagsList = allTagsInHighlights
                    if !tagsList.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                Button {
                                    withAnimation { selectedTagFilter = nil }
                                } label: {
                                    Text("All Tags")
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
                                            .fixedSize(horizontal: true, vertical: false)
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
                                    // Header: Page Index with Jump Navigation & Chapter
                                    HStack {
                                        Button {
                                            jumpToHighlight(highlight)
                                        } label: {
                                            HStack(spacing: 4) {
                                                Image(systemName: "arrow.right.circle.fill")
                                                    .font(.system(size: 9))
                                                Text("Page \(highlight.pageIndex + 1)")
                                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                            }
                                            .foregroundColor(Theme.blue)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Theme.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                                        }
                                        .buttonStyle(.plain)
                                        
                                        if let chap = highlight.chapterTitle, !chap.isEmpty {
                                            Text(chap)
                                                .font(.system(size: 9, weight: .medium))
                                                .foregroundColor(.secondary)
                                                .lineLimit(1)
                                                .truncationMode(.tail)
                                        }
                                        
                                        Spacer()
                                        
                                        let accentColor = Color(hex: highlight.colorHex ?? "#FFD60A")
                                        Circle()
                                            .fill(accentColor)
                                            .frame(width: 8, height: 8)
                                            .shadow(color: accentColor.opacity(0.6), radius: 2)
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
                                            .lineLimit(expandedHighlightIDs.contains(highlight.id) ? nil : 3)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .background(
                                                RoundedRectangle(cornerRadius: 4)
                                                    .fill(accentColor.opacity(0.10))
                                            )
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 4)
                                                    .stroke(accentColor.opacity(0.18), lineWidth: 0.6)
                                            )
                                            .contentShape(Rectangle())
                                            .onTapGesture {
                                                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                                    if expandedHighlightIDs.contains(highlight.id) {
                                                        expandedHighlightIDs.remove(highlight.id)
                                                    } else {
                                                        expandedHighlightIDs.insert(highlight.id)
                                                    }
                                                }
                                            }
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
                                    
                                    // Tags list (horizontally scrollable chips with fixed size to prevent vertical squishing)
                                    if let tags = highlight.tags, !tags.isEmpty {
                                        ScrollView(.horizontal, showsIndicators: false) {
                                            HStack(spacing: 5) {
                                                ForEach(tags, id: \.self) { tag in
                                                    Text("#\(tag)")
                                                        .font(.system(size: 9, weight: .bold))
                                                        .foregroundColor(Theme.blue)
                                                        .padding(.horizontal, 6)
                                                        .padding(.vertical, 2.5)
                                                        .background(Theme.blue.opacity(0.12), in: Capsule())
                                                        .fixedSize(horizontal: true, vertical: false)
                                                }
                                            }
                                            .padding(.vertical, 2)
                                        }
                                    }
                                    
                                    // Action buttons
                                    HStack(spacing: 8) {
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
                                        
                                        if let text = highlight.selectedText, !text.isEmpty {
                                            Button {
                                                UIPasteboard.general.string = text
                                                HapticEngine.selection()
                                                withAnimation { copiedHighlightID = highlight.id }
                                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                                    withAnimation {
                                                        if copiedHighlightID == highlight.id {
                                                            copiedHighlightID = nil
                                                        }
                                                    }
                                                }
                                            } label: {
                                                HStack(spacing: 3) {
                                                    Image(systemName: copiedHighlightID == highlight.id ? "checkmark" : "doc.on.doc")
                                                    Text(copiedHighlightID == highlight.id ? "Copied" : "Copy")
                                                }
                                                .font(.system(size: 11, weight: .bold))
                                                .foregroundColor(copiedHighlightID == highlight.id ? .green : .secondary)
                                            }
                                            .buttonStyle(.borderless)
                                        }
                                        
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
                                        
                                        Button {
                                            highlightPendingDelete = highlight
                                            showDeleteHighlightAlert = true
                                        } label: {
                                            Image(systemName: "trash")
                                                .font(.system(size: 11, weight: .bold))
                                                .foregroundColor(.red.opacity(0.85))
                                                .padding(4)
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
            .frame(width: UIDevice.current.userInterfaceIdiom == .phone ? min(280, notebookWidth - 60) : 250)
            .background(.ultraThinMaterial)
            .shadow(color: .black.opacity(0.1), radius: 10, x: -5, y: 0)
        }
        .transition(.move(edge: .trailing))
    }
    
    private func fetchBackingBook() -> ConvertedPDF? {
        if let uuid = UUID(uuidString: bookID) {
            // 1. Direct match with a book
            let descriptor = FetchDescriptor<SDConvertedPDF>(predicate: #Predicate { $0.id == uuid })
            if let sdBook = try? modelContext.fetch(descriptor).first {
                return sdBook.toDTO()
            }
            
            // 2. If it's a notebook ID, check if it's linked to a book
            let nbDescriptor = FetchDescriptor<SDNotebook>(predicate: #Predicate { $0.id == uuid })
            if let nb = try? modelContext.fetch(nbDescriptor).first,
               let linkedID = nb.linkedBookID {
                let linkedDescriptor = FetchDescriptor<SDConvertedPDF>(predicate: #Predicate { $0.id == linkedID })
                if let sdBook = try? modelContext.fetch(linkedDescriptor).first {
                    return sdBook.toDTO()
                }
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

extension StudyNotebookView {
    // MARK: - Smart Split-Screen Page Index Bar (Jump Chips)
    @ViewBuilder
    private var smartPageIndexBar: some View {
        let activePage = activeReaderPageIndex
        let activeSet: Set<Int> = activePage != nil ? [activePage!] : []
        let allPages = Array(referencedPageIndices.union(activeSet)).sorted()

        
        if !allPages.isEmpty || activePage != nil {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if let current = activePage {
                        Button {
                            jumpToPage(current)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "mappin.and.ellipse")
                                    .font(.system(size: 11, weight: .bold))
                                Text("Active: Page \(current + 1)")
                                    .font(.system(size: 12, weight: .bold, design: .rounded))
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                LinearGradient(colors: [.orange, .red], startPoint: .leading, endPoint: .trailing),
                                in: Capsule()
                            )
                            .shadow(color: .orange.opacity(0.3), radius: 4, x: 0, y: 2)
                        }
                        .buttonStyle(.plain)
                    }
                    
                    ForEach(allPages, id: \.self) { pageIdx in
                        if pageIdx != activePage {
                            Button {
                                jumpToPage(pageIdx)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "book.pages")
                                        .font(.system(size: 10, weight: .semibold))
                                    Text("p. \(pageIdx + 1)")
                                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                                }
                                .foregroundColor(.primary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.primary.opacity(0.08), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    
                    if inputMode == .markdown && activePage != nil {
                        Button {
                            stampCurrentPageLink()
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 10, weight: .bold))
                                Text("Stamp Link")
                                    .font(.system(size: 11, weight: .bold, design: .rounded))
                            }
                            .foregroundColor(.orange)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.orange.opacity(0.12), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .background(Color.inkSurfaceRaised.opacity(0.3).background(.ultraThinMaterial))
            .overlay(Rectangle().frame(height: 1).foregroundColor(Color.primary.opacity(0.05)), alignment: .bottom)
        }
    }

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
            card.modifiedAt = Date()
            correctAnswersCount += 1
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        } else {
            card.reviewCount = 0
            card.easeFactor = max(1.3, card.easeFactor - 0.2)
            card.nextReviewDate = Calendar.current.date(byAdding: .day, value: 1, to: Date())
            card.modifiedAt = Date()
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
        
        try? modelContext.save()
        
        withAnimation(.spring()) {
            isAnswerRevealed = false
            currentCardIndex += 1
        }
    }

    private func getOrCreateNotebook() -> SDNotebook? {
        guard let actualUUID = UUID(uuidString: bookID) else { return nil }
        
        let nbFetch = FetchDescriptor<SDNotebook>(predicate: #Predicate { $0.id == actualUUID || $0.linkedBookID == actualUUID })
        if let existing = try? modelContext.fetch(nbFetch).first {
            return existing
        }
        
        // Auto-create notebook record for this book so we can persist its properties (like templateStyle and templateSize)
        let newNb = SDNotebook(
            id: UUID(),
            title: bookTitle.isEmpty ? "Notebook" : bookTitle,
            templateStyle: "plain",
            linkedBookID: actualUUID,
            templateSize: 24.0
        )
        modelContext.insert(newNb)
        try? modelContext.save()
        Logger.shared.log("Auto-created SDNotebook for book: '\(bookTitle)' to persist template properties", category: "Notebook", type: .success)
        return newNb
    }

    private func linkBookToNotebook(_ book: ConvertedPDF) {
        if let actualUUID = UUID(uuidString: bookID) {
            let nbFetch = FetchDescriptor<SDNotebook>(predicate: #Predicate { $0.id == actualUUID })
            if let nb = try? modelContext.fetch(nbFetch).first {
                nb.linkedBookID = book.id
                try? modelContext.save()
                Logger.shared.log("Successfully linked book '\(book.name)' to notebook '\(bookTitle)'", category: "Notebook", type: .success)
            }
        }
    }



    private func generateCornellCues() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        let lines = localNotes.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        var cues: [String] = []
        for line in lines.prefix(6) {
            if line.starts(with: "#") {
                cues.append("❓ What is " + line.replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespaces) + "?")
            } else if line.count > 25 {
                let snippet = String(line.prefix(20))
                cues.append("• " + snippet + "...")
            }
        }
        if cues.isEmpty {
            cues = ["❓ Key question 1", "❓ Main thesis", "❓ Critical evidence"]
        }
        cornellCuesText = cues.joined(separator: "\n\n")
    }

    private func generateCornellSummary() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        let snippet = localNotes.prefix(150).trimmingCharacters(in: .whitespacesAndNewlines)
        if !snippet.isEmpty {
            cornellSummaryText = "Summary: " + snippet + "..."
        } else {
            cornellSummaryText = "Summary: Core concepts reviewed and recorded."
        }
    }
}
