import SwiftUI
import WebKit
import PDFKit
import ZIPFoundation
import AVFoundation
import CoreTransferable

struct TypographySettings: Codable, Equatable {
    var fontFamily: String = "Georgia"
    var fontSize: CGFloat = 18
    var lineSpacing: CGFloat = 1.6
    var marginWidth: CGFloat = 40
    var themeHex: String = "#ffffff"
    var textHex: String = "#000000"
}
@MainActor
class TTSManager: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    static let shared = TTSManager()
    let synthesizer = AVSpeechSynthesizer()
    @Published var isSpeaking = false
    
    override init() {
        super.init()
        synthesizer.delegate = self
    }
    
    func speak(text: String) {
        if synthesizer.isSpeaking { stop() }
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = 0.5
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        synthesizer.speak(utterance)
        isSpeaking = true
    }
    
    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
        try? AVAudioSession.sharedInstance().setActive(false)
    }
    
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }
}

@MainActor
class BookReaderViewModel: NSObject, ObservableObject, WKNavigationDelegate {
    @Published var isLoading = true
    @Published var currentChapterHTML: String = ""
    @Published var chapterHtmlFiles: [URL] = []
    @Published var currentChapterIndex = 0
    @Published var isPlayingTTS = false
    
    let pdf: ConvertedPDF
    private let fileManager = FileManager.default
    private lazy var tempDir: URL = { fileManager.temporaryDirectory.appendingPathComponent(pdf.id.uuidString) }()
    
    // TTS
    private let speechSynthesizer = AVSpeechSynthesizer()
    
    init(pdf: ConvertedPDF) {
        self.pdf = pdf
        super.init()
        unpackEPUB()
    }
    
    private func unpackEPUB() {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let fm = FileManager.default
            let tempDir = await self.tempDir
            let pdfURL = await self.pdf.url

            if !fm.fileExists(atPath: tempDir.path) {
                try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
                guard let archive = try? Archive(url: pdfURL, accessMode: .read, pathEncoding: .utf8) else {
                    await MainActor.run { self.isLoading = false }
                    return
                }
                for entry in archive {
                    let dest = tempDir.appendingPathComponent(entry.path)
                    try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    _ = try? archive.extract(entry, to: dest)
                }
            }
            await self.parseNCXOrSpine(tempDir: tempDir)
        }
    }
    
    private func parseNCXOrSpine(tempDir: URL) async {
        // Walk the unpacked EPUB directory on a background thread
        let htmlFiles: [URL] = await Task.detached(priority: .userInitiated) {
            guard let enumerator = FileManager.default.enumerator(at: tempDir, includingPropertiesForKeys: nil) else { return [] }
            var htmls: [URL] = []
            while let file = enumerator.nextObject() as? URL {
                let ext = file.pathExtension.lowercased()
                if ext == "html" || ext == "xhtml" { htmls.append(file) }
            }
            htmls.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            return htmls
        }.value

        // Back on @MainActor — safe to mutate @Published properties
        chapterHtmlFiles = htmlFiles
        if !htmlFiles.isEmpty {
            loadChapter(index: currentChapterIndex)
        } else {
            isLoading = false
        }
    }
    
    func loadChapter(index: Int) {
        guard index >= 0 && index < chapterHtmlFiles.count else { return }
        currentChapterIndex = index
        let url = chapterHtmlFiles[index]
                var rawHTML: String?
        var usedEncoding: String.Encoding = .utf8
        if let html = try? String(contentsOf: url, usedEncoding: &usedEncoding) {
            rawHTML = html
        } else if let data = try? Data(contentsOf: url) {
            rawHTML = String(data: data, encoding: .isoLatin1) ?? String(data: data, encoding: .ascii)
        }
        
        if var html = rawHTML {
            let pattern = "<meta[^>]*charset[^>]*>"
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                html = regex.stringByReplacingMatches(in: html, options: [], range: NSRange(html.startIndex..., in: html), withTemplate: "<meta charset=\\\"utf-8\\\">")
            }
            self.currentChapterHTML = html
            self.isLoading = false
        }
    }
    
    // MARK: TTS
    
    func toggleTTS(text: String) {
        if isPlayingTTS {
            speechSynthesizer.pauseSpeaking(at: .immediate)
            isPlayingTTS = false
        } else {
            if speechSynthesizer.isPaused {
                speechSynthesizer.continueSpeaking()
            } else {
                let utterance = AVSpeechUtterance(string: text)
                utterance.rate = AVSpeechUtteranceDefaultSpeechRate
                utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
                speechSynthesizer.speak(utterance)
            }
            isPlayingTTS = true
        }
    }
}

// Custom WebView subclass to add "Highlight" to the native iOS text selection menu
class HighlightableWebView: WKWebView {
    var onHighlightRequested: (() -> Void)?
    
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(customHighlightAction(_:)) {
            return true
        }
        let actionStr = NSStringFromSelector(action)
        let allowedNativeFunctions = ["copy:", "_lookup:", "_translate:", "share:", "_define:", "speak:"]
        
        if allowedNativeFunctions.contains(actionStr) {
            return true
        }
        
        return super.canPerformAction(action, withSender: sender)
    }
    
    @objc func customHighlightAction(_ sender: Any?) {
        onHighlightRequested?()
    }
    
    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        
        // Dynamically inject the Highlight option into the WKWebView UIMenu selection bounds
        let highlightCommand = UICommand(title: "Highlight", action: #selector(customHighlightAction(_:)))
        let highlightMenu = UIMenu(title: "Inksync", options: .displayInline, children: [highlightCommand])
        
        builder.insertSibling(highlightMenu, afterMenu: .standardEdit)
    }
}

// Custom WebView to inject Typography and JS Bridges
struct EPUBWebView: UIViewRepresentable {
    @Binding var htmlContent: String
    @Binding var baseUrl: URL
    var settings: TypographySettings
    var onHighlightCreated: ((String, String) -> Void)?
    var onPageLoaded: ((WKWebView) -> Void)?
    
    class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: EPUBWebView
        init(_ parent: EPUBWebView) { self.parent = parent }
        
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "highlightHandler", let dict = message.body as? [String: String] {
                if let text = dict["text"], let html = dict["html"] {
                    parent.onHighlightCreated?(text, html)
                }
            }
        }
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.onPageLoaded?(webView)
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    func makeUIView(context: Context) -> WKWebView {
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences = prefs
        
        // Add JS Bridge Listener
        config.userContentController.add(context.coordinator, name: "highlightHandler")
        
        // CSS Injection
        let userScript = WKUserScript(
            source: """
            var meta = document.createElement('meta');
            meta.name = 'viewport';
            meta.content = 'width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no';
            var head = document.getElementsByTagName('head')[0];
            head.appendChild(meta);
            
            var style = document.createElement('style');
            style.innerHTML = `
                body {
                    font-family: '\(settings.fontFamily)', serif !important;
                    font-size: \(settings.fontSize)px !important;
                    line-height: \(settings.lineSpacing) !important;
                    background-color: \(settings.themeHex) !important;
                    color: \(settings.textHex) !important;
                    padding-left: \(settings.marginWidth)px !important;
                    padding-right: \(settings.marginWidth)px !important;
                    padding-top: 40px !important;
                    padding-bottom: 60px !important;
                                        column-count: 1 !important;
                    /* Premium enhancements */
                    text-align: justify !important;
                    -webkit-hyphens: auto !important;
                    hyphens: auto !important;
                }
                img { max-width: 100% !important; height: auto !important; border-radius: 4px; object-fit: contain; }
                .inksync-highlight { background-color: #ffd700; color: #000; border-radius: 3px; }
            `;
            head.appendChild(style);
            
            // Highlight Engine JS
            window.applyInksyncHighlight = function(colorHex) {
                var sel = window.getSelection();
                if (!sel || sel.rangeCount === 0 || sel.isCollapsed) return;
                
                var text = sel.toString();
                document.execCommand("hiliteColor", false, colorHex);
                window.getSelection().removeAllRanges();
                
                // We no longer send thousands of lines of HTML back. We just send the text string!
                window.webkit.messageHandlers.highlightHandler.postMessage({
                    "text": text,
                    "html": "N/A"
                });
            };
            
            // Restores highlights perfectly dynamically on page load without EPUB mutation!
            window.restoreInksyncHighlight = function(textToFind, colorHex) {
                // Save current selection just in case
                var currentSel = window.getSelection();
                var savedRange = currentSel.rangeCount > 0 ? currentSel.getRangeAt(0) : null;
                
                currentSel.removeAllRanges();
                // Find and highlight every instance gracefully
                // window.find(aString, aCaseSensitive, aBackwards, aWrapAround, aWholeWord, aSearchInFrames, aShowDialog);
                var found = window.find(textToFind, true, false, true, false, false, false);
                if(found) {
                    document.execCommand("hiliteColor", false, colorHex);
                }
                
                currentSel.removeAllRanges();
                if(savedRange) currentSel.addRange(savedRange);
            };
            """,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(userScript)
        
        let webView = HighlightableWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = UIColor(hex: settings.themeHex) ?? .white
        webView.scrollView.backgroundColor = webView.backgroundColor
        
        // Setup custom UIMenuController item
        // UIMenuItem deprecated in iOS 16
        
        webView.onHighlightRequested = {
            webView.evaluateJavaScript("window.applyInksyncHighlight('#ffd700');")
        }
        
        return webView
    }
    
    func updateUIView(_ webView: WKWebView, context: Context) {
        if webView.url?.absoluteString != baseUrl.absoluteString || webView.title == nil {
            webView.loadHTMLString(htmlContent, baseURL: baseUrl)
        } else if webView.title != nil {
            // If the swift model's HTML changed (e.g. from an incoming highlight save), we don't reload the whole page to prevent jumping,
            // because the DOM already has the highlight! 
        }
        webView.backgroundColor = UIColor(hex: settings.themeHex) ?? .white
        webView.scrollView.backgroundColor = webView.backgroundColor
    }
}

struct BookReaderEngine: View {
    let pdf: ConvertedPDF
    var onDismiss: () -> Void
    
    @StateObject private var vm: BookReaderViewModel
    @ObservedObject private var tts = TTSManager.shared
    @State private var webViewReference: WKWebView?
    @State private var chromeVisible = false
    @State private var showAnnotations = false
    @State private var settings = TypographySettings(themeHex: "#1C1C1E", textHex: "#E5E5EA") // Dark default
    @State private var extractedTextParams: String = "Chapter reading is not extracted to string yet."
    
    init(pdf: ConvertedPDF, onDismiss: @escaping () -> Void) {
        self.pdf = pdf
        self.onDismiss = onDismiss
        self._vm = StateObject(wrappedValue: BookReaderViewModel(pdf: pdf))
    }
    
    var body: some View {
        ZStack {
            Color(hex: settings.themeHex).edgesIgnoringSafeArea(.all)
            
            if vm.isLoading {
                ProgressView("Unpacking EPUB...")
                    .foregroundColor(Color(hex: settings.textHex))
            } else {
                if let url = vm.chapterHtmlFiles.isEmpty ? nil : vm.chapterHtmlFiles[0] {
                    EPUBWebView(htmlContent: $vm.currentChapterHTML, baseUrl: .constant(url), settings: settings, onHighlightCreated: { selectedText, _ in
                        
                        let highlight = Annotation(
                            pdfID: pdf.id,
                            pageIndex: vm.currentChapterIndex,
                            chapterTitle: "Chapter \(vm.currentChapterIndex + 1)",
                            kind: .highlight,
                            createdAt: Date(),
                            modifiedAt: Date(),
                            colorHex: "#ffd700",
                            selectedText: selectedText
                        )
                        AnnotationStore.shared.add(highlight)
                        StudyNotesStore.shared.appendHighlight(selectedText, chapter: "Chapter \(vm.currentChapterIndex + 1)")
                        
                    }, onPageLoaded: { webView in
                        self.webViewReference = webView
                        let pageAnnotations = AnnotationStore.shared.annotations(for: pdf.id).filter { $0.pageIndex == vm.currentChapterIndex && $0.kind == .highlight }
                        for ann in pageAnnotations {
                            if let text = ann.selectedText, let color = ann.colorHex {
                                // Escape backticks and standard quotes for JS interpolation
                                let safeText = text.replacingOccurrences(of: "`", with: "\\`")
                                                   .replacingOccurrences(of: "\"", with: "\\\"")
                                                   .replacingOccurrences(of: "\n", with: " ")
                                let js = "window.restoreInksyncHighlight(`\(safeText)`, '\(color)');"
                                webView.evaluateJavaScript(js)
                            }
                        }
                    })
                    .edgesIgnoringSafeArea(.horizontal)
                    .onTapGesture {
                        chromeVisible.toggle()
                    }
                    .gesture(DragGesture(minimumDistance: 50, coordinateSpace: .local)
                        .onEnded { value in
                            if value.translation.width < -50 {
                                vm.loadChapter(index: min(vm.chapterHtmlFiles.count - 1, vm.currentChapterIndex + 1))
                            } else if value.translation.width > 50 {
                                vm.loadChapter(index: max(0, vm.currentChapterIndex - 1))
                            }
                        }
                    )
                }
            }
            
            ReaderChrome(
                pdf: pdf,
                title: pdf.name,
                pageText: "Ch. \(vm.currentChapterIndex + 1) / \(max(1, vm.chapterHtmlFiles.count))",
                isVisible: $chromeVisible,
                onBack: onDismiss,
                onEInkSend: {},
                onBookmark: {
                    let bookmark = Annotation(pdfID: pdf.id, pageIndex: vm.currentChapterIndex, chapterTitle: "Chapter \(vm.currentChapterIndex + 1)", kind: .bookmark, createdAt: Date(), modifiedAt: Date())
                    AnnotationStore.shared.add(bookmark)
                },
                onAnnotationsToggle: {
                    showAnnotations = true
                },
                onSettingsToggle: {
                    // Quick Theme Toggle
                    if settings.themeHex == "#1C1C1E" {
                        settings.themeHex = "#F4F1EA" // Sepia
                        settings.textHex = "#433422"
                    } else {
                        settings.themeHex = "#1C1C1E" // Dark
                        settings.textHex = "#E5E5EA"
                    }
                },
                currentProgress: Binding(
                    get: { Double(vm.currentChapterIndex) / Double(max(1, vm.chapterHtmlFiles.count - 1)) },
                    set: { vm.currentChapterIndex = Int($0 * Double(max(1, vm.chapterHtmlFiles.count - 1))) }
                ),
                totalPages: vm.chapterHtmlFiles.count,
                hasTTS: true,
                isSpeaking: tts.isSpeaking,
                onTTSToggle: {
                    if tts.isSpeaking {
                        tts.stop()
                    } else {
                        webViewReference?.evaluateJavaScript("document.body.innerText") { result, _ in
                            if let text = result as? String, !text.isEmpty {
                                tts.speak(text: text)
                            }
                        }
                    }
                }
            )
        }
        .onAppear {
            if let saved = ReaderProgressTracker.shared.progress(for: pdf.id), let ch = saved.currentChapterIndex {
                vm.currentChapterIndex = ch
            }
        }
        .onDisappear {
            tts.stop()
            ReaderProgressTracker.shared.update(ReadingProgress(
                pdfID: pdf.id, lastOpenedAt: Date(), currentPageIndex: vm.currentChapterIndex,
                currentChapterIndex: vm.currentChapterIndex, currentChapterOffset: 0.0,
                totalPagesRead: 1, completionFraction: Double(vm.currentChapterIndex + 1) / Double(max(1, vm.chapterHtmlFiles.count)),
                readingSessionDates: [Date()], estimatedMinutesRemaining: nil
            ))
        }
        .sheet(isPresented: $showAnnotations) {
            AnnotationListView(pdfID: pdf.id, documentTitle: pdf.name)
        }
    }
}

extension UIColor {
    convenience init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        var rgb: UInt64 = 0

        var r: CGFloat = 0.0
        var g: CGFloat = 0.0
        var b: CGFloat = 0.0
        var a: CGFloat = 1.0

        let length = hexSanitized.count

        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else { return nil }

        if length == 6 {
            r = CGFloat((rgb & 0xFF0000) >> 16) / 255.0
            g = CGFloat((rgb & 0x00FF00) >> 8) / 255.0
            b = CGFloat(rgb & 0x0000FF) / 255.0

        } else if length == 8 {
            r = CGFloat((rgb & 0xFF000000) >> 24) / 255.0
            g = CGFloat((rgb & 0x00FF0000) >> 16) / 255.0
            b = CGFloat((rgb & 0x0000FF00) >> 8) / 255.0
            a = CGFloat(rgb & 0x000000FF) / 255.0

        } else {
            return nil
        }
        self.init(red: r, green: g, blue: b, alpha: a)
    }
}

struct AnnotationListView: View {
    let pdfID: UUID
    let documentTitle: String
    
    @ObservedObject private var store = AnnotationStore.shared
    @Environment(\.dismiss) var dismiss
    @State private var exportURL: URL?
    
    var body: some View {
        NavigationStack {
            List {
                let items = store.annotations(for: pdfID).sorted { $0.pageIndex < $1.pageIndex }
                
                if items.isEmpty {
                    Text("No highlights or notes yet.\n\nSelect text in the book to create highlights.")
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowBackground(Color.clear)
                } else {
                    Section {
                        if let url = store.export(for: pdfID, documentTitle: documentTitle, format: .markdown) {
                            ShareLink(item: url) {
                                Label("Export to Readwise (Obsidian/.md)", systemImage: "square.and.arrow.up")
                                    .font(.headline)
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                            }
                            .listRowBackground(Color.blue)
                        }
                    }
                    
                    ForEach(items) { annotation in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(annotation.chapterTitle ?? "Page \(annotation.pageIndex + 1)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .textCase(.uppercase)
                                
                                Spacer()
                                
                                if let color = annotation.colorHex {
                                    Circle()
                                        .fill(Color(UIColor(hex: color) ?? .yellow))
                                        .frame(width: 12, height: 12)
                                }
                            }
                            
                            if let text = annotation.selectedText {
                                Text("\"\(text)\"")
                                    .font(.system(.body, design: .serif))
                                    .italic()
                                    .lineLimit(4)
                            }
                            
                            if let note = annotation.noteText, !note.isEmpty {
                                HStack(alignment: .top) {
                                    Image(systemName: "pencil.line")
                                        .foregroundColor(.orange)
                                    Text(note)
                                        .font(.subheadline)
                                        .foregroundColor(.primary)
                                }
                                .padding(.top, 4)
                            }
                        }
                        .padding(.vertical, 4)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                store.delete(id: annotation.id, pdfID: pdfID)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Highlights")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}




