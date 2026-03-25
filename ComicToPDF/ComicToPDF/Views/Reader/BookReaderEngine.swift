import SwiftUI
import WebKit
import PDFKit
import ZIPFoundation
import AVFoundation

struct TypographySettings: Codable, Equatable {
    var fontFamily: String = "Georgia"
    var fontSize: CGFloat = 18
    var lineSpacing: CGFloat = 1.6
    var marginWidth: CGFloat = 40
    var themeHex: String = "#ffffff"
    var textHex: String = "#000000"
}
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
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.isSpeaking = false }
    }
}

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
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            if !self.fileManager.fileExists(atPath: self.tempDir.path) {
                try? self.fileManager.createDirectory(at: self.tempDir, withIntermediateDirectories: true)
                guard let archive = Archive(url: self.pdf.url, accessMode: .read) else {
                    DispatchQueue.main.async { self.isLoading = false }
                    return
                }
                
                for entry in archive {
                    let dest = self.tempDir.appendingPathComponent(entry.path)
                    try? self.fileManager.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    _ = try? archive.extract(entry, to: dest)
                }
            }
            
            self.parseNCXOrSpine()
        }
    }
    
    private func parseNCXOrSpine() {
        // Look for .opf or .html files quickly in temp dir
        if let enumerator = fileManager.enumerator(at: tempDir, includingPropertiesForKeys: nil) {
            var htmls: [URL] = []
            while let file = enumerator.nextObject() as? URL {
                if file.pathExtension.lowercased() == "html" || file.pathExtension.lowercased() == "xhtml" {
                    htmls.append(file)
                }
            }
            htmls.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            
            DispatchQueue.main.async {
                self.chapterHtmlFiles = htmls
                if !htmls.isEmpty {
                    self.loadChapter(index: self.currentChapterIndex)
                } else {
                    self.isLoading = false
                }
            }
        }
    }
    
    func loadChapter(index: Int) {
        guard index >= 0 && index < chapterHtmlFiles.count else { return }
        currentChapterIndex = index
        let url = chapterHtmlFiles[index]
        if let html = try? String(contentsOf: url, encoding: .utf8) {
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
        // Allow Copy alongside Highlight
        if action == #selector(copy(_:)) {
            return true
        }
        return false // Hide definition, share, etc. for cleaner UI
    }
    
    @objc func customHighlightAction(_ sender: Any?) {
        onHighlightRequested?()
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
                }
                img { max-width: 100% !important; height: auto !important; }
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
        let highlightMenuItem = UIMenuItem(title: "Highlight", action: #selector(HighlightableWebView.customHighlightAction(_:)))
        UIMenuController.shared.menuItems = [highlightMenuItem]
        
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
    @StateObject private var tts = TTSManager.shared
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
i m p o r t   S w i f t U I  
 i m p o r t   C o r e T r a n s f e r a b l e  
  
 s t r u c t   A n n o t a t i o n L i s t V i e w :   V i e w   {  
         l e t   p d f I D :   U U I D  
         l e t   d o c u m e n t T i t l e :   S t r i n g  
          
         @ S t a t e O b j e c t   p r i v a t e   v a r   s t o r e   =   A n n o t a t i o n S t o r e . s h a r e d  
         @ E n v i r o n m e n t ( \ . d i s m i s s )   v a r   d i s m i s s  
         @ S t a t e   p r i v a t e   v a r   e x p o r t U R L :   U R L ?  
          
         v a r   b o d y :   s o m e   V i e w   {  
                 N a v i g a t i o n S t a c k   {  
                         L i s t   {  
                                 l e t   i t e m s   =   s t o r e . a n n o t a t i o n s ( f o r :   p d f I D ) . s o r t e d   {   $ 0 . p a g e I n d e x   <   $ 1 . p a g e I n d e x   }  
                                  
                                 i f   i t e m s . i s E m p t y   {  
                                         T e x t ( " N o   h i g h l i g h t s   o r   n o t e s   y e t . \ n \ n S e l e c t   t e x t   i n   t h e   b o o k   t o   c r e a t e   h i g h l i g h t s . " )  
                                                 . f o r e g r o u n d C o l o r ( . s e c o n d a r y )  
                                                 . m u l t i l i n e T e x t A l i g n m e n t ( . c e n t e r )  
                                                 . p a d d i n g ( )  
                                                 . f r a m e ( m a x W i d t h :   . i n f i n i t y ,   a l i g n m e n t :   . c e n t e r )  
                                                 . l i s t R o w B a c k g r o u n d ( C o l o r . c l e a r )  
                                 }   e l s e   {  
                                         S e c t i o n   {  
                                                 i f   l e t   u r l   =   s t o r e . e x p o r t ( f o r :   p d f I D ,   d o c u m e n t T i t l e :   d o c u m e n t T i t l e ,   f o r m a t :   . m a r k d o w n )   {  
                                                         S h a r e L i n k ( i t e m :   u r l )   {  
                                                                 L a b e l ( " E x p o r t   t o   R e a d w i s e   ( O b s i d i a n / . m d ) " ,   s y s t e m I m a g e :   " s q u a r e . a n d . a r r o w . u p " )  
                                                                         . f o n t ( . h e a d l i n e )  
                                                                         . f o r e g r o u n d C o l o r ( . w h i t e )  
                                                                         . f r a m e ( m a x W i d t h :   . i n f i n i t y )  
                                                                         . p a d d i n g ( . v e r t i c a l ,   8 )  
                                                         }  
                                                         . l i s t R o w B a c k g r o u n d ( C o l o r . b l u e )  
                                                 }  
                                         }  
                                          
                                         F o r E a c h ( i t e m s )   {   a n n o t a t i o n   i n  
                                                 V S t a c k ( a l i g n m e n t :   . l e a d i n g ,   s p a c i n g :   8 )   {  
                                                         H S t a c k   {  
                                                                 T e x t ( a n n o t a t i o n . c h a p t e r T i t l e   ? ?   " P a g e   \ ( a n n o t a t i o n . p a g e I n d e x   +   1 ) " )  
                                                                         . f o n t ( . c a p t i o n )  
                                                                         . f o r e g r o u n d C o l o r ( . s e c o n d a r y )  
                                                                         . t e x t C a s e ( . u p p e r c a s e )  
                                                                  
                                                                 S p a c e r ( )  
                                                                  
                                                                 i f   l e t   c o l o r   =   a n n o t a t i o n . c o l o r H e x   {  
                                                                         C i r c l e ( )  
                                                                                 . f i l l ( C o l o r ( h e x :   c o l o r )   ? ?   . y e l l o w )  
                                                                                 . f r a m e ( w i d t h :   1 2 ,   h e i g h t :   1 2 )  
                                                                 }  
                                                         }  
                                                          
                                                         i f   l e t   t e x t   =   a n n o t a t i o n . s e l e c t e d T e x t   {  
                                                                 T e x t ( " \ " \ ( t e x t ) \ " " )  
                                                                         . f o n t ( . s y s t e m ( . b o d y ,   d e s i g n :   . s e r i f ) )  
                                                                         . i t a l i c ( )  
                                                                         . l i n e L i m i t ( 4 )  
                                                         }  
                                                          
                                                         i f   l e t   n o t e   =   a n n o t a t i o n . n o t e T e x t ,   ! n o t e . i s E m p t y   {  
                                                                 H S t a c k ( a l i g n m e n t :   . t o p )   {  
                                                                         I m a g e ( s y s t e m N a m e :   " p e n c i l . l i n e " )  
                                                                                 . f o r e g r o u n d C o l o r ( . o r a n g e )  
                                                                         T e x t ( n o t e )  
                                                                                 . f o n t ( . s u b h e a d l i n e )  
                                                                                 . f o r e g r o u n d C o l o r ( . p r i m a r y )  
                                                                 }  
                                                                 . p a d d i n g ( . t o p ,   4 )  
                                                         }  
                                                 }  
                                                 . p a d d i n g ( . v e r t i c a l ,   4 )  
                                                 . s w i p e A c t i o n s ( e d g e :   . t r a i l i n g ,   a l l o w s F u l l S w i p e :   t r u e )   {  
                                                         B u t t o n ( r o l e :   . d e s t r u c t i v e )   {  
                                                                 s t o r e . d e l e t e ( i d :   a n n o t a t i o n . i d ,   p d f I D :   p d f I D )  
                                                         }   l a b e l :   {  
                                                                 L a b e l ( " D e l e t e " ,   s y s t e m I m a g e :   " t r a s h " )  
                                                         }  
                                                 }  
                                         }  
                                 }  
                         }  
                         . n a v i g a t i o n T i t l e ( " H i g h l i g h t s " )  
                         . n a v i g a t i o n B a r T i t l e D i s p l a y M o d e ( . i n l i n e )  
                         . t o o l b a r   {  
                                 T o o l b a r I t e m ( p l a c e m e n t :   . c a n c e l l a t i o n A c t i o n )   {  
                                         B u t t o n ( " D o n e " )   {   d i s m i s s ( )   }  
                                 }  
                         }  
                 }  
         }  
 }  
 