import SwiftUI
import SwiftData
import CryptoKit
import PencilKit

struct StudyNotebookView: View {
    let bookID: String       // the ConvertedPDF's UUID string
    let bookTitle: String    // human-readable title shown in the Zettelkasten Hub

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
    @State private var canvasView = PKCanvasView()
    
    // ✅ Phase 3: Highlights Drawer
    @State private var showHighlightsDrawer = false
    @State private var bookHighlights: [SDAnnotation] = []
    
    var body: some View {
        ZStack {
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
                    .frame(width: 120)
                    
                    Spacer()
                    
                    // Highlights Drawer Toggle
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            showHighlightsDrawer.toggle()
                        }
                    } label: {
                        Image(systemName: "highlighter")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(showHighlightsDrawer ? Theme.blue : .primary)
                            .padding(8)
                            .background(showHighlightsDrawer ? Theme.blue.opacity(0.1) : Color.primary.opacity(0.08))
                            .clipShape(Circle())
                    }

                    // Live word count (Bear-style)
                    let words = localNotes.split { $0.isWhitespace || $0.isNewline }.count
                    Text("\(words)w")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundColor(Theme.textSecondary)
                        .monospacedDigit()

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
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.primary)
                                .padding(8)
                                .background(Color.primary.opacity(0.08))
                                .clipShape(Circle())
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(
                    Color(UIColor.systemBackground).opacity(0.85)
                        .background(.ultraThinMaterial)
                )
                .overlay(Rectangle().frame(height: 1).foregroundColor(Color.primary.opacity(0.05)), alignment: .bottom)
                
                // MARK: Notebook Canvas
                ZStack(alignment: .trailing) {
                    if inputMode == .markdown {
                        MarkdownTextEditor(text: $localNotes, isFocused: $isFocused)
                            .padding(16)
                            .onChange(of: localNotes) { _, _ in debounceSave() }
                    } else {
                        StudyCanvasView(canvasView: $canvasView, onSaved: debounceSave)
                            .padding(.top, 8)
                    }
                    
                    // MARK: Highlights Drawer Overlay
                    if showHighlightsDrawer {
                        highlightsDrawer
                    }
                }
            }
        }
        .onAppear {
            initializeSDAnnotation()
        }
        .onDisappear {
            // Final explicit sync flush layer
            saveTask?.cancel()
            activeNoteAnnotation?.noteText = localNotes
            activeNoteAnnotation?.drawingData = canvasView.drawing.dataRepresentation()
            activeNoteAnnotation?.modifiedAt = Date()
            try? modelContext.save()
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
            if let dData = existing.drawingData, let drawing = try? PKDrawing(data: dData) {
                self.canvasView.drawing = drawing
            }
        } else {
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
        }
        
        // Fetch existing highlights for this book
        let hDescriptor = FetchDescriptor<SDAnnotation>(predicate: #Predicate { $0.kindRaw == "highlight" && $0.pdfID == targetPDFID })
        if let h = try? modelContext.fetch(hDescriptor) {
            self.bookHighlights = h.sorted { $0.createdAt > $1.createdAt }
        }
    }
    
    private func debounceSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            if !Task.isCancelled {
                await MainActor.run {
                    self.activeNoteAnnotation?.noteText = self.localNotes
                    self.activeNoteAnnotation?.drawingData = self.canvasView.drawing.dataRepresentation()
                    self.activeNoteAnnotation?.modifiedAt = Date()
                    try? self.modelContext.save()
                }
            }
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
                
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if bookHighlights.isEmpty {
                            Text("No highlights yet.\nSelect text in the book to add highlights.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .padding()
                        } else {
                            ForEach(bookHighlights) { highlight in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(highlight.selectedText ?? "Empty Highlight")
                                        .font(.system(size: 14))
                                        .foregroundColor(Theme.text)
                                        .lineSpacing(4)
                                    
                                    HStack {
                                        if let note = highlight.noteText, !note.isEmpty {
                                            Image(systemName: "text.bubble.fill")
                                                .font(.caption2)
                                                .foregroundColor(Theme.blue)
                                        }
                                        Spacer()
                                        Text(highlight.createdAt.formatted(date: .abbreviated, time: .omitted))
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
                                // Standard Drag and Drop for highlights into the text view
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
struct MarkdownTextEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    
    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.font = UIFont.systemFont(ofSize: 16, weight: .regular)
        textView.backgroundColor = .clear
        textView.textColor = UIColor.label
        textView.isScrollEnabled = true
        textView.keyboardDismissMode = .interactive

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
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, UITextViewDelegate {
        var parent: MarkdownTextEditor
        
        init(_ parent: MarkdownTextEditor) {
            self.parent = parent
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
            for match in matches {
                attrString.addAttributes([
                    .foregroundColor: UIColor.systemBlue,
                    .underlineStyle: NSUnderlineStyle.single.rawValue
                ], range: match.range)
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
