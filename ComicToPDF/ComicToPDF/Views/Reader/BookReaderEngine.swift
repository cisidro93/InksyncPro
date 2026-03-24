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

// Custom WebView to inject Typography using JS
struct EPUBWebView: UIViewRepresentable {
    @Binding var htmlContent: String
    @Binding var baseUrl: URL
    var settings: TypographySettings
    
    func makeUIView(context: Context) -> WKWebView {
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences = prefs
        
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
            `;
            head.appendChild(style);
            """,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(userScript)
        
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = UIColor(hex: settings.themeHex) ?? .white
        webView.scrollView.backgroundColor = webView.backgroundColor
        
        return webView
    }
    
    func updateUIView(_ webView: WKWebView, context: Context) {
        if webView.url?.absoluteString != baseUrl.absoluteString || webView.title == nil {
            webView.loadHTMLString(htmlContent, baseURL: baseUrl)
        }
        webView.backgroundColor = UIColor(hex: settings.themeHex) ?? .white
        webView.scrollView.backgroundColor = webView.backgroundColor
    }
}

struct BookReaderEngine: View {
    let pdf: ConvertedPDF
    var onDismiss: () -> Void
    
    @StateObject private var vm: BookReaderViewModel
    @State private var chromeVisible = false
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
                    EPUBWebView(htmlContent: $vm.currentChapterHTML, baseUrl: .constant(url), settings: settings)
                        .edgesIgnoringSafeArea(.horizontal)
                        .onTapGesture {
                            chromeVisible.toggle()
                        }
                        // Swipe to change chapters
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
                onAnnotationsToggle: {},
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
                    set: { vm.loadChapter(index: Int($0 * Double(max(1, vm.chapterHtmlFiles.count - 1)))) }
                ),
                totalPages: vm.chapterHtmlFiles.count,
                hasTTS: true,
                onTTSToggle: {
                    vm.toggleTTS(text: "Text to speech requires Javascript text extraction bridge to be fully implemented.")
                }
            )
        }
        .onAppear {
            if let saved = ReaderProgressTracker.shared.progress(for: pdf.id), let ch = saved.currentChapterIndex {
                vm.currentChapterIndex = ch
            }
        }
        .onDisappear {
            ReaderProgressTracker.shared.update(ReadingProgress(
                pdfID: pdf.id, lastOpenedAt: Date(), currentPageIndex: vm.currentChapterIndex,
                currentChapterIndex: vm.currentChapterIndex, currentChapterOffset: 0.0,
                totalPagesRead: 1, completionFraction: Double(vm.currentChapterIndex + 1) / Double(max(1, vm.chapterHtmlFiles.count)),
                readingSessionDates: [Date()], estimatedMinutesRemaining: nil
            ))
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
