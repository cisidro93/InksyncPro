import SwiftUI
import WebKit
import PDFKit
import ZIPFoundation
import CoreTransferable
import UIKit
import SwiftData


@MainActor


struct SearchResult: Identifiable {
    let id = UUID()
    let chapterIndex: Int
    let chapterTitle: String
    let snippet: String
}

@MainActor
class BookReaderViewModel: NSObject, ObservableObject, WKNavigationDelegate {
    @Published var isLoading = true
    @Published var currentChapterHTML: String = ""
    @Published var chapterHtmlFiles: [URL] = []
    @Published var currentChapterIndex = 0
    @Published var metadata: EBookMetadata?
    @Published var tocItems: [EBookMetadata.SpineItem] = []
    
    @Published var isSearching = false
    @Published var searchResults: [SearchResult] = []
    private var searchIndex: [String: Set<Int>]?
    
    let pdf: ConvertedPDF
    private let fileManager = FileManager.default
    nonisolated let tempDirURL: URL
    
    init(pdf: ConvertedPDF) {
        self.pdf = pdf
        self.tempDirURL = FileManager.default.temporaryDirectory.appendingPathComponent(pdf.id.uuidString)
        super.init()
        unpackEPUB()
    }
    
    deinit {
        let path = tempDirURL.path
        Task.detached(priority: .background) {
            let fm = FileManager.default
            if fm.fileExists(atPath: path) {
                try? fm.removeItem(atPath: path)
            }
        }
    }
    
    private func unpackEPUB() {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let fm = FileManager.default
            let tempDir = self.tempDirURL
            let sourcePDF = self.pdf

            // Linked Library: resolve security-scoped URL for linked files.
            // We only need the scope open during the unpack step — chapters are read
            // from the sandbox temp directory afterward, so scope is stopped after extraction.
            let pdfURL: URL
            var accessedURL: URL? = nil
            if case .linked(let bm) = sourcePDF.sourceMode,
               let url = try? BookmarkResolver.shared.resolve(bm) {
                let didAccess = url.startAccessingSecurityScopedResource()
                pdfURL = url
                if didAccess { accessedURL = url }
            } else {
                pdfURL = sourcePDF.url
            }

            if !fm.fileExists(atPath: tempDir.path) {
                try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
                guard let archive = try? Archive(url: pdfURL, accessMode: .read, pathEncoding: .utf8) else {
                    // Stop scope before early return
                    accessedURL?.stopAccessingSecurityScopedResource()
                    await MainActor.run { self.isLoading = false }
                    return
                }
                for entry in archive {
                    let dest = tempDir.appendingPathComponent(entry.path)
                    try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    _ = try? archive.extract(entry, to: dest)
                }
            }
            // Extraction done — stop security scope. parseNCXOrSpine reads from tempDir (sandbox).
            let parsedMetadata = await EBookParser.shared.parse(epub: pdfURL)
            accessedURL?.stopAccessingSecurityScopedResource()
            await self.parseNCXOrSpine(tempDir: tempDir, parsedMetadata: parsedMetadata)
        }
    }
    
    private func parseNCXOrSpine(tempDir: URL, parsedMetadata: EBookMetadata?) async {
        // Walk the unpacked EPUB directory on a background thread
        let htmlFiles: [URL] = await Task.detached(priority: .userInitiated) {
            if let spine = parsedMetadata?.spineItems, !spine.isEmpty {
                return spine.compactMap { item in
                    let dest = tempDir.appendingPathComponent(item.href)
                    return FileManager.default.fileExists(atPath: dest.path) ? dest : nil
                }
            } else {
                guard let enumerator = FileManager.default.enumerator(at: tempDir, includingPropertiesForKeys: nil) else { return [] }
                var htmls: [URL] = []
                while let file = enumerator.nextObject() as? URL {
                    let ext = file.pathExtension.lowercased()
                    if ext == "html" || ext == "xhtml" { htmls.append(file) }
                }
                htmls.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                return htmls
            }
        }.value

        // Back on @MainActor — safe to mutate @Published properties
        self.metadata = parsedMetadata
        self.tocItems = parsedMetadata?.spineItems ?? []
        self.chapterHtmlFiles = htmlFiles
        if !htmlFiles.isEmpty {
            self.loadChapter(index: self.currentChapterIndex)
            self.buildOrLoadSearchIndex()
        } else {
            self.isLoading = false
        }
    }
    
    private func buildOrLoadSearchIndex() {
        let indexURL = tempDirURL.appendingPathComponent("search_index.json")
        if let data = try? Data(contentsOf: indexURL),
           let decoded = try? JSONDecoder().decode([String: Set<Int>].self, from: data) {
            self.searchIndex = decoded
            return
        }
        
        let files = self.chapterHtmlFiles
        Task.detached(priority: .background) { [weak self] in
            var newIndex: [String: Set<Int>] = [:]
            
            for (idx, url) in files.enumerated() {
                guard let content = try? String(contentsOf: url) else { continue }
                let stripped = content.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression, range: nil)
                
                let words = stripped.components(separatedBy: CharacterSet.alphanumerics.inverted)
                for word in words {
                    guard word.count > 2 else { continue }
                    let lower = word.lowercased()
                    if newIndex[lower] != nil {
                        newIndex[lower]?.insert(idx)
                    } else {
                        newIndex[lower] = [idx]
                    }
                }
            }
            
            if let data = try? JSONEncoder().encode(newIndex) {
                try? data.write(to: indexURL)
            }
            
            guard let strongSelf = self else { return }
            await MainActor.run {
                strongSelf.searchIndex = newIndex
            }
        }
    }
    
    func loadChapter(index: Int) {
        guard index >= 0 && index < chapterHtmlFiles.count else { return }
        currentChapterIndex = index
        isLoading = true
        let url = chapterHtmlFiles[index]
        // Dispatch synchronous file I/O off the main thread to prevent UI freeze.
        // Large chapters (500KB–2MB) would stall the 120Hz render loop otherwise.
        Task {
            let rawHTML: String? = await Task.detached(priority: .userInitiated) {
                var enc: String.Encoding = .utf8
                if let html = try? String(contentsOf: url, usedEncoding: &enc) { return html }
                if let data = try? Data(contentsOf: url) {
                    return String(data: data, encoding: .isoLatin1) ?? String(data: data, encoding: .ascii)
                }
                return nil
            }.value

            guard var html = rawHTML else {
                self.isLoading = false
                return
            }
            // Normalise charset declaration so WKWebView always uses UTF-8
            let pattern = "<meta[^>]*charset[^>]*>"
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                html = regex.stringByReplacingMatches(in: html, options: [], range: NSRange(html.startIndex..., in: html), withTemplate: "<meta charset=\\\"utf-8\\\">")
            }
            // Update @Published properties directly on MainActor
            self.currentChapterHTML = html
            self.isLoading = false
        }
    }
    
    func search(query: String) async {
        guard !query.isEmpty else {
            await MainActor.run { self.searchResults = [] }
            return
        }
        await MainActor.run { self.isSearching = true }
        
        let files = chapterHtmlFiles
        let items = tocItems
        let localIndex = searchIndex
        
        let results = await Task.detached(priority: .userInitiated) {
            var found: [SearchResult] = []
            let lowerQuery = query.lowercased()
            
            // 1. O(1) Pre-filtering using Inverted Index
            var chaptersToSearch: [Int] = []
            if let index = localIndex {
                let queryWords = lowerQuery.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 2 }
                if queryWords.isEmpty {
                    chaptersToSearch = Array(0..<files.count)
                } else {
                    var intersection: Set<Int>?
                    for word in queryWords {
                        let matches = index[word] ?? []
                        if intersection == nil { intersection = matches }
                        else { intersection?.formIntersection(matches) }
                    }
                    chaptersToSearch = Array(intersection ?? [])
                }
            } else {
                chaptersToSearch = Array(0..<files.count)
            }
            
            // 2. Exact Regex extraction ONLY in matching chapters
            for idx in chaptersToSearch.sorted() {
                guard files.indices.contains(idx) else { continue }
                guard let content = try? String(contentsOf: files[idx]) else { continue }
                
                // Strip HTML tags roughly for searching
                let stripped = content.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression, range: nil)
                
                let lowerContent = stripped.lowercased()
                let lowerQuery = query.lowercased()
                
                var searchRange = lowerContent.startIndex..<lowerContent.endIndex
                while let range = lowerContent.range(of: lowerQuery, options: [], range: searchRange) {
                    let snippetStart = stripped.index(max(stripped.startIndex, range.lowerBound), offsetBy: -40, limitedBy: stripped.startIndex) ?? stripped.startIndex
                    let snippetEnd = stripped.index(min(stripped.endIndex, range.upperBound), offsetBy: 40, limitedBy: stripped.endIndex) ?? stripped.endIndex
                    
                    let snippet = String(stripped[snippetStart..<snippetEnd])
                        .replacingOccurrences(of: "\n", with: " ")
                        .trimmingCharacters(in: .whitespaces)
                    
                    let title = items.indices.contains(idx) ? items[idx].label : "Chapter \(idx + 1)"
                    
                    found.append(SearchResult(chapterIndex: idx, chapterTitle: title, snippet: "... \(snippet) ..."))
                    
                    searchRange = range.upperBound..<lowerContent.endIndex
                    if found.count > 100 { break } // Limit global results
                }
                if found.count > 100 { break }
            }
            return found
        }.value
        
        await MainActor.run {
            self.searchResults = results
            self.isSearching = false
        }
    }
}

struct EPUBWebView: View {
    @Binding var htmlContent: String
    @Binding var baseUrl: URL
    @ObservedObject var prefs: EBookPreferences
    @Binding var scrollToLastPageOnLoad: Bool
    var initialScrollFraction: Double = 0.0
    var onScrollFractionChanged: ((Double) -> Void)? = nil
    @Binding var webViewRef: WKWebView?
    let pdf: ConvertedPDF
    @Binding var currentPage: Int
    @Binding var totalPages: Int
    var onHighlightCreated: ((String, String) -> Void)?
    var onPageLoaded: ((WKWebView) -> Void)?
    var onCenterTap: (() -> Void)? = nil
    var onLeftTap: (() -> Void)? = nil
    var onRightTap: (() -> Void)? = nil
    var onNextChapter: (() -> Void)? = nil
    var onPrevChapter: (() -> Void)? = nil
    var onFootnoteTapped: ((String) -> Void)? = nil

    @State private var isLoading: Bool = false
    @State private var progress: Double = 0.0
    @State private var styledHTML: String = ""
    @State private var initialPinchFontSize: Double = 16.0

    var body: some View {
        WebView(
            html: styledHTML,
            baseURL: baseUrl,
            isLoading: $isLoading,
            progress: $progress,
            webViewRef: $webViewRef,
            onNavigate: { url, webView in
                if url.scheme == "http" || url.scheme == "https" {
                    UIApplication.shared.open(url)
                    return false
                } else if let fragment = url.fragment {
                    let js = """
                    (function() {
                        var el = document.getElementById('\(fragment)') || document.getElementsByName('\(fragment)')[0];
                        if (el) {
                            var text = el.innerText || el.textContent;
                            if (text && text.trim().length > 0) {
                                window.webkit.messageHandlers.footnote.postMessage({ "id": '\(fragment)', "text": text.trim() });
                            }
                        }
                    })();
                    """
                    webView.evaluateJavaScript(js, completionHandler: nil)
                    return false
                }
                return true
            },
            messageHandler: { message in
                if message.name == "highlightHandler", let dict = message.body as? [String: String] {
                    if let text = dict["text"], let html = dict["html"] {
                        self.onHighlightCreated?(text, html)
                    }
                } else if message.name == "nav", let body = message.body as? String {
                    switch body {
                    case "center": self.onCenterTap?()
                    case "left":   self.onLeftTap?()
                    case "right":  self.onRightTap?()
                    case "next":   self.onNextChapter?()
                    case "prev":   self.onPrevChapter?()
                    default: break
                    }
                } else if message.name == "scrollFraction", let fraction = message.body as? Double {
                    self.onScrollFractionChanged?(fraction)
                } else if message.name == "metrics", let body = message.body as? [String: Int] {
                    self.currentPage = body["current"] ?? 0
                    self.totalPages = body["total"] ?? 1
                } else if message.name == "footnote", let body = message.body as? [String: String], let text = body["text"] {
                    self.onFootnoteTapped?(text)
                }
            },
            onHighlight: {
                if let wv = webViewRef {
                    wv.evaluateJavaScript("window.getSelection().toString()") { (result, error) in
                        if let text = result as? String, !text.isEmpty {
                            self.onHighlightCreated?(text, "<mark>\(text)</mark>")
                        }
                    }
                }
            },
            didFinishNavigation: { webView in
                self.onPageLoaded?(webView)
                
                let isPaged = self.prefs.paginationMode == EBookPaginationMode.paged.rawValue
                if self.scrollToLastPageOnLoad {
                    self.scrollToLastPageOnLoad = false
                    let js = """
                    setTimeout(function() {
                        var sv = document.scrollingElement || document.documentElement;
                        var isHoriz = \(isPaged);
                        if (isHoriz) {
                            var maxScroll = sv.scrollWidth - window.innerWidth;
                            window.scrollTo({ left: maxScroll, behavior: 'instant' });
                        } else {
                            var maxScroll = sv.scrollHeight - window.innerHeight;
                            window.scrollTo({ top: maxScroll, behavior: 'instant' });
                        }
                    }, 100);
                    """
                    webView.evaluateJavaScript(js, completionHandler: nil)
                } else {
                    let fraction = self.initialScrollFraction
                    if fraction > 0.01 {
                        let restoreJS = """
                        setTimeout(function() {
                            var sv = document.scrollingElement || document.documentElement;
                            var isHoriz = \(isPaged);
                            if (isHoriz) {
                                var pageIndex = Math.round(\(fraction) * (sv.scrollWidth / window.innerWidth - 1));
                                window.scrollTo({ left: pageIndex * window.innerWidth, behavior: 'instant' });
                            } else {
                                window.scrollTo({ top: sv.scrollHeight * \(fraction), behavior: 'instant' });
                            }
                        }, 150);
                        """
                        webView.evaluateJavaScript(restoreJS, completionHandler: nil)
                    }
                }
            },
            scrollViewDidEndDragging: { scrollView, decelerate in
                let isPaged = self.prefs.paginationMode == EBookPaginationMode.paged.rawValue
                guard isPaged else { return }
                
                let offset = scrollView.contentOffset.x
                let maxOffset = scrollView.contentSize.width - scrollView.bounds.width
                let threshold: CGFloat = 50.0
                
                if offset > maxOffset + threshold {
                    self.onNextChapter?()
                } else if offset < -threshold {
                    self.onPrevChapter?()
                }
            },
            processDidTerminate: { webView in
                Logger.shared.log("WebKit process terminated (OOM Jetsam crash). Reloading EPUB chapter.", category: "EPUBWebView", type: .error)
                webView.reload()
            }
        )
        .gesture(
            MagnificationGesture()
                .onChanged { value in
                    if initialPinchFontSize == 0 {
                        initialPinchFontSize = prefs.fontSize
                    }
                    let newSize = initialPinchFontSize * Double(value)
                    let roundedSize = round(max(12.0, min(80.0, newSize)))
                    if prefs.fontSize != roundedSize {
                        prefs.fontSize = roundedSize
                    }
                }
                .onEnded { _ in
                    initialPinchFontSize = 0
                    if prefs.isTypographyLockedForBook(pdf.id.uuidString) {
                        prefs.lockTypographyForBook(pdf.id.uuidString)
                    }
                }
        )
        .task(id: htmlContent) {
            await loadChapter()
        }
        .onChange(of: prefs.fontSize) { _, _ in updateLiveCSS() }
        .onChange(of: prefs.themeRaw) { _, _ in updateLiveCSS() }
        .onChange(of: prefs.paginationMode) { _, _ in updateLiveCSS() }
    }

    private func loadChapter() async {
        let css = buildReaderCSS(prefs: prefs, size: UIScreen.main.bounds.size)
        var html = htmlContent
        
        let cleanArticle = SwiftReadability.parse(html: html)
        html = cleanArticle.content
        
        html = EPUBWebView.wrapHTMLBodyWithViewport(html)
        if let range = html.range(of: "</head>", options: .caseInsensitive) {
            styledHTML = html.replacingCharacters(in: range, with: css + "</head>")
        } else {
            styledHTML = css + html
        }
    }

    private func updateLiveCSS() {
        guard let wv = webViewRef else { return }
        let css = buildReaderCSS(prefs: prefs, size: wv.bounds.size)
        let js = """
        (function() {
            var el = document.getElementById('__inksync_live__');
            if (!el) { el = document.createElement('style'); el.id = '__inksync_live__'; document.head.appendChild(el); }
            el.textContent = `\(css.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "`", with: "\\`"))`;
            if (window.postMetrics) {
                window.postMetrics();
            }
        })();
        """
        wv.evaluateJavaScript(js)
    }

    private static func wrapHTMLBodyWithViewport(_ html: String) -> String {
        var result = html
        let bodyPattern = "<body([^>]*)>"
        if let regex = try? NSRegularExpression(pattern: bodyPattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: result, options: [], range: NSRange(result.startIndex..., in: result)) {
            let bodyTagRange = Range(match.range, in: result)!
            let insertionIndex = bodyTagRange.upperBound
            result.insert(contentsOf: "<div id=\"inksync-viewport\">", at: insertionIndex)
        } else {
            if let bodyIndex = result.range(of: "<body>", options: .caseInsensitive)?.upperBound {
                result.insert(contentsOf: "<div id=\"inksync-viewport\">", at: bodyIndex)
            }
        }
        
        if let closeBodyRange = result.range(of: "</body>", options: .caseInsensitive) {
            result.insert(contentsOf: "</div>", at: closeBodyRange.lowerBound)
        }
        return result
    }

    private func computeCSS(prefs: EBookPreferences, size: CGSize) -> String {
        let isPaged = prefs.paginationMode == EBookPaginationMode.paged.rawValue

        let bgColor      = prefs.activeTheme.cssBackground
        let textColor    = ColorContrastCalculator.getLegibleTextColor(textHex: prefs.activeTheme.cssText, bgHex: bgColor)
        let linkColor    = prefs.activeTheme.cssLink
        let fontFamily   = prefs.fontFamily
        let fontSize     = Int(prefs.fontSize)
        let lineHeight   = String(format: "%.2f", prefs.lineHeight)
        let letterSpacing = String(format: "%.4fem", prefs.letterSpacing)
        let wordSpacing   = String(format: "%.4fem", prefs.wordSpacing)
        let textAlign     = prefs.textAlign
        let margin        = prefs.textMargin
        let paraSpace     = prefs.paragraphSpacing
        let paraIndent    = prefs.paragraphIndent
        let hyphenCSS     = prefs.hyphenation ? "auto" : "manual"

        let renderWidth = size.width > 0 ? size.width : UIScreen.main.bounds.width
        let renderHeight = size.height > 0 ? size.height : UIScreen.main.bounds.height
        
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        let isLandscape = renderWidth > renderHeight
        let defaultColumns = (isPad && isLandscape) ? 2 : 1
        let cols = prefs.columnCount == 0 ? defaultColumns : prefs.columnCount
        
        let m = isPaged ? max(20.0, margin) : margin
        let gap = 2 * m
        let colWidth = max(100.0, (renderWidth / CGFloat(cols)) - gap)
        
        let pagedCSS = isPaged ? """
            column-width: \(colWidth)px !important;
            column-gap: \(gap)px !important;
            column-fill: auto !important;
            column-rule: none !important;
        """ : ""

        let paddingLeft = m
        let paddingRight = m

        return """
        @font-face {
            font-family: 'Literata';
            src: local('Literata-Regular');
            font-weight: normal;
            font-style: normal;
        }
        @font-face {
            font-family: 'Literata';
            src: local('Literata-Bold');
            font-weight: bold;
            font-style: normal;
        }
        @font-face {
            font-family: 'Literata';
            src: local('Literata-Italic');
            font-weight: normal;
            font-style: italic;
        }
        @font-face {
            font-family: 'Literata';
            src: local('Literata-BoldItalic');
            font-weight: bold;
            font-style: italic;
        }
        @font-face {
            font-family: 'Atkinson Hyperlegible';
            src: local('AtkinsonHyperlegible-Regular');
            font-weight: normal;
            font-style: normal;
        }
        @font-face {
            font-family: 'Atkinson Hyperlegible';
            src: local('AtkinsonHyperlegible-Bold');
            font-weight: bold;
            font-style: normal;
        }
        @font-face {
            font-family: 'Atkinson Hyperlegible';
            src: local('AtkinsonHyperlegible-Italic');
            font-weight: normal;
            font-style: italic;
        }
        @font-face {
            font-family: 'Atkinson Hyperlegible';
            src: local('AtkinsonHyperlegible-BoldItalic');
            font-weight: bold;
            font-style: italic;
        }
        @font-face {
            font-family: 'OpenDyslexic';
            src: local('OpenDyslexic-Regular');
            font-weight: normal;
            font-style: normal;
        }
        @font-face {
            font-family: 'OpenDyslexic';
            src: local('OpenDyslexic-Bold');
            font-weight: bold;
            font-style: normal;
        }
        @font-face {
            font-family: 'OpenDyslexic';
            src: local('OpenDyslexic-Italic');
            font-weight: normal;
            font-style: italic;
        }
        @font-face {
            font-family: 'OpenDyslexic';
            src: local('OpenDyslexic-BoldItalic');
            font-weight: bold;
            font-style: italic;
        }
        @font-face {
            font-family: 'Merriweather';
            src: local('Merriweather-Regular');
            font-weight: normal;
            font-style: normal;
        }
        @font-face {
            font-family: 'Merriweather';
            src: local('Merriweather-Bold');
            font-weight: bold;
            font-style: normal;
        }
        @font-face {
            font-family: 'Merriweather';
            src: local('Merriweather-Italic');
            font-weight: normal;
            font-style: italic;
        }
        @font-face {
            font-family: 'Merriweather';
            src: local('Merriweather-BoldItalic');
            font-weight: bold;
            font-style: italic;
        }
        @font-face {
            font-family: 'Source Serif 4';
            src: local('SourceSerif4-Regular');
            font-weight: normal;
            font-style: normal;
        }
        @font-face {
            font-family: 'Source Serif 4';
            src: local('SourceSerif4-Regular');
            font-weight: bold;
            font-style: normal;
        }
        @font-face {
            font-family: 'Source Serif 4';
            src: local('SourceSerif4-Italic');
            font-weight: normal;
            font-style: italic;
        }
        @font-face {
            font-family: 'Source Serif 4';
            src: local('SourceSerif4-Italic');
            font-weight: bold;
            font-style: italic;
        }
        *, *::before, *::after { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
        html {
            margin: 0 !important; padding: 0 !important;
            width: 100% !important;
            column-width: auto !important;
            touch-action: pan-x pan-y;
            background-color: \(bgColor) !important;
            \(isPaged ? """
            height: 100% !important;
            overflow-x: scroll !important;
            overflow-y: hidden !important;
            """ : """
            height: auto !important;
            overflow-x: hidden !important;
            overflow-y: auto !important;
            """)
        }
        body {
            color: \(textColor) !important;
            font-family: \(fontFamily) !important;
            font-size: \(fontSize)px !important;
            line-height: \(lineHeight) !important;
            text-align: \(textAlign) !important;
            margin: 0 !important;
            width: 100% !important;
            overflow: visible !important;
            background-color: transparent !important;
            word-wrap: break-word;
            -webkit-text-size-adjust: none;
            letter-spacing: \(letterSpacing) !important;
            word-spacing: \(wordSpacing) !important;
            -webkit-hyphens: \(hyphenCSS) !important;
            hyphens: \(hyphenCSS) !important;
            text-rendering: optimizeLegibility !important;
            -webkit-font-variant-ligatures: common-ligatures !important;
            font-variant-ligatures: common-ligatures !important;
            -webkit-font-feature-settings: "kern", "liga" 1 !important;
            font-feature-settings: "kern", "liga" 1 !important;
            \(isPaged ? """
            height: 100% !important;
            """ : """
            height: auto !important;
            """)
        }
        #inksync-viewport {
            margin: 0 !important;
            box-sizing: border-box !important;
            \(isPaged ? """
            display: block !important;
            position: static !important;
            padding-top: 60px !important;
            padding-bottom: 60px !important;
            padding-left: \(paddingLeft)px !important;
            padding-right: \(paddingRight)px !important;
            width: auto !important;
            height: 100% !important;
            \(pagedCSS)
            """ : """
            display: block !important;
            width: 100% !important;
            height: auto !important;
            padding-top: 60px !important;
            padding-bottom: 60px !important;
            padding-left: \(paddingLeft)px !important;
            padding-right: \(paddingRight)px !important;
            """)
        }
        
        /* Prevent nested overflow and positioning containers from breaking horizontal column flow */
        body * {
            max-width: 100% !important;
        }
        \(isPaged ? """
        div, section, article, main, p, span, blockquote {
            max-height: none !important;
            overflow: visible !important;
        }
        div, section, article, main {
            height: auto !important;
        }
        /* CSS Column padding-left/right on all block elements creates margins without shifting */
        p, h1, h2, h3, h4, h5, h6, blockquote, pre, table, ul, ol, dl, figure {
            padding-left: \(margin)px !important;
            padding-right: \(margin)px !important;
        }
        """ : """
        div, section, article, main {
            max-height: none !important;
            height: auto !important;
            overflow: visible !important;
        }
        """)
        
        body, p, span, li, td, th, div, a {
            font-family: \(fontFamily) !important;
        }
        body, p, li, td, th, a {
            font-size: \(fontSize)px !important;
        }
        h1 { font-size: \(Double(fontSize) * 1.5)px !important; font-family: \(fontFamily) !important; }
        h2 { font-size: \(Double(fontSize) * 1.3)px !important; font-family: \(fontFamily) !important; }
        h3 { font-size: \(Double(fontSize) * 1.15)px !important; font-family: \(fontFamily) !important; }
        h4 { font-size: \(Double(fontSize) * 1.05)px !important; font-family: \(fontFamily) !important; }
        h5, h6 { font-size: \(Double(fontSize) * 1.0)px !important; font-family: \(fontFamily) !important; }
        div, section, article {
            column-count: auto !important;
            column-width: auto !important;
        }
        p { margin-bottom: \(paraSpace)em !important; text-indent: \(paraIndent)em !important; }
        p, div, span, li, td, th, h1, h2, h3, h4, h5, h6 { color: \(textColor) !important; }
        img, svg, .page, .chunk-container { display: block !important; margin-left: auto !important; margin-right: auto !important; }
        img {
            max-width: calc(100% - \(margin * 2)px) !important;
            max-height: calc(100vh - 120px) !important;
            height: auto !important;
            border-radius: 4px;
            object-fit: contain !important;
        }
        img.gaiji, img[gaiji], img.inline-image { display: inline-block !important; vertical-align: middle !important; max-height: 1.2em !important; width: auto !important; margin: 0 0.1em !important; }
        a { color: \(linkColor) !important; }
        blockquote { border-left: 3px solid \(linkColor); margin-left: 0; padding-left: 16px; opacity: 0.85; }
        mark.inksync-highlight { background-color: #ffd700; color: inherit; border-radius: 2px; mix-blend-mode: multiply; -webkit-mix-blend-mode: multiply; padding: 0 1px; }
        \(fontSize > 28 ? """
        .dropcap, .drop-cap, span.first-letter {
            float: none !important;
            font-size: 1em !important;
            line-height: inherit !important;
            margin: 0 !important;
            font-weight: inherit !important;
        }
        """ : """
        .dropcap, .drop-cap, span.first-letter {
            float: left !important;
            font-size: 3.2em !important;
            line-height: 0.85em !important;
            margin-top: 0.1em !important;
            margin-right: 0.1em !important;
            margin-bottom: -0.1em !important;
            font-weight: bold !important;
        }
        """)
        """
    }

    private func buildReaderCSS(prefs: EBookPreferences, size: CGSize) -> String {
        let cssContent = computeCSS(prefs: prefs, size: size)
        let isPaged = prefs.paginationMode == EBookPaginationMode.paged.rawValue
        
        return """
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no, viewport-fit=cover">
        <style id="__inksync_live__">
        \(cssContent)
        </style>
        <script>
        document.addEventListener('DOMContentLoaded', function() {
            document.querySelectorAll('[style]').forEach(function(el) {
                el.style.removeProperty('background-color');
                el.style.removeProperty('color');
            });
            var liveStyle = document.getElementById('__inksync_live__');
            if (liveStyle) {
                document.head.appendChild(liveStyle);
            }
        });

        var _currentPage = \(currentPage);
        var _totalPages = 1;
        var _firstRun = true;

        function postFraction() {
            var sv = document.scrollingElement || document.documentElement;
            var isHoriz = \(isPaged);
            var fraction = 0;
            if (isHoriz) {
                var maxScroll = sv.scrollWidth - window.innerWidth;
                if (maxScroll > 0) fraction = sv.scrollLeft / maxScroll;
            } else {
                var maxScroll = sv.scrollHeight - window.innerHeight;
                if (maxScroll > 0) fraction = sv.scrollTop / maxScroll;
            }
            window.webkit.messageHandlers.scrollFraction.postMessage(fraction);
        }

        function updateMetrics() {
            var sv = document.scrollingElement || document.documentElement;
            var pageStep = window.innerWidth;
            var isHoriz = \(isPaged);
            
            if (isHoriz) {
                _totalPages = Math.max(1, Math.round(sv.scrollWidth / pageStep));
                if (_firstRun) {
                    _firstRun = false;
                    if (_currentPage === 99999) {
                        _currentPage = _totalPages - 1;
                    }
                    goToPage(_currentPage, false);
                } else {
                    _currentPage = Math.max(0, Math.min(Math.round(sv.scrollLeft / pageStep), _totalPages - 1));
                }
            } else {
                var pageHeight = window.innerHeight;
                _totalPages = Math.max(1, Math.round(sv.scrollHeight / pageHeight));
                if (_firstRun) {
                    _firstRun = false;
                    goToPage(_currentPage, false);
                } else {
                    _currentPage = Math.max(0, Math.min(Math.round(sv.scrollTop / pageHeight), _totalPages - 1));
                }
            }
            
            window.webkit.messageHandlers.metrics.postMessage({ current: _currentPage, total: _totalPages });
            postFraction();
        }

        function goToPage(page, smooth) {
            _currentPage = Math.max(0, Math.min(page, _totalPages - 1));
            var behavior = smooth ? 'smooth' : 'instant';
            
            var sv = document.scrollingElement || document.documentElement;
            var isHoriz = \(isPaged);
            if (isHoriz) {
                var pageStep = window.innerWidth;
                window.scrollTo({ left: _currentPage * pageStep, behavior: behavior });
            } else {
                window.scrollTo({ top: _currentPage * window.innerHeight, behavior: behavior });
            }
            
            if (!_firstRun) {
                window.webkit.messageHandlers.metrics.postMessage({ current: _currentPage, total: _totalPages });
            }
            postFraction();
        }
        window.goToInksyncPage = goToPage;

        window.onload = function() {
            setTimeout(updateMetrics, 100);
            setTimeout(updateMetrics, 500);
            setTimeout(updateMetrics, 1500);
        };
        window.addEventListener('resize', function() { updateMetrics(); goToPage(_currentPage, false); });

        document.addEventListener('click', function(e) {
            if (e.target.tagName.toLowerCase() === 'a') return;
            if (window.getSelection() && !window.getSelection().isCollapsed) return;
            var x = e.clientX; var w = window.innerWidth;
            var leftEdge = window.__inksync_left_edge || 0.30;
            var rightEdge = window.__inksync_right_edge || 0.70;
            if (x < w * leftEdge) {
                if (_currentPage > 0) goToPage(_currentPage - 1, true);
                else window.webkit.messageHandlers.nav.postMessage('prev');
            } else if (x > w * rightEdge) {
                if (_currentPage < _totalPages - 1) goToPage(_currentPage + 1, true);
                else window.webkit.messageHandlers.nav.postMessage('next');
            } else {
                window.webkit.messageHandlers.nav.postMessage('center');
            }
        });

        document.addEventListener('keydown', function(e) {
            if (e.key === 'ArrowRight' || e.key === 'Space') {
                if (_currentPage < _totalPages - 1) goToPage(_currentPage + 1, true);
                else window.webkit.messageHandlers.nav.postMessage('next');
                e.preventDefault();
            } else if (e.key === 'ArrowLeft') {
                if (_currentPage > 0) goToPage(_currentPage - 1, true);
                else window.webkit.messageHandlers.nav.postMessage('prev');
                e.preventDefault();
            }
        });

        var _scrollTimeout;
        window.addEventListener('scroll', function() {
            clearTimeout(_scrollTimeout);
            _scrollTimeout = setTimeout(function() {
                updateMetrics();
            }, 50);
        });

        // ── Highlight Engine ─────────────────────────────────────────────────
        window.applyInksyncHighlight = function(colorHex) {
            var sel = window.getSelection();
            if (!sel || sel.rangeCount === 0 || sel.isCollapsed) return;
            var text = sel.toString().trim();
            if (!text) return;
            var range = sel.getRangeAt(0);
            var mark = document.createElement('mark');
            mark.style.backgroundColor = colorHex;
            mark.style.color = 'inherit';
            mark.className = 'inksynced-highlight';
            range.surroundContents(mark);
            sel.removeAllRanges();
            window.webkit.messageHandlers.highlightHandler.postMessage({ text: text, html: mark.outerHTML });
        };
        
        window.restoreInksyncHighlight = function(text, colorHex) {
            var body = document.body;
            var walker = document.createTreeWalker(body, NodeFilter.SHOW_TEXT, null, false);
            var node;
            while (node = walker.nextNode()) {
                var idx = node.nodeValue.indexOf(text);
                if (idx !== -1) {
                    var range = document.createRange();
                    range.setStart(node, idx);
                    range.setEnd(node, idx + text.length);
                    var mark = document.createElement('mark');
                    mark.style.backgroundColor = colorHex;
                    mark.style.color = 'inherit';
                    mark.className = 'inksynced-highlight';
                    try {
                        range.surroundContents(mark);
                    } catch(e) {}
                    break;
                }
            }
        };
        </script>
        """
    }

    private func injectLiveCSS(into webView: WKWebView) {
        let sv = webView.scrollView
        let isHoriz = prefs.paginationMode == EBookPaginationMode.paged.rawValue
        let currentFraction: Double
        if isHoriz {
            let maxScroll = sv.contentSize.width - sv.bounds.width
            currentFraction = maxScroll > 0 ? Double(sv.contentOffset.x / maxScroll) : 0.0
        } else {
            let maxScroll = sv.contentSize.height - sv.bounds.height
            currentFraction = maxScroll > 0 ? Double(sv.contentOffset.y / maxScroll) : 0.0
        }
        let clampedFraction = max(0.0, min(1.0, currentFraction))

        let css = computeCSS(prefs: prefs, size: webView.bounds.size)

        let js = """
        (function() {
            var el = document.getElementById('__inksync_live__');
            if (!el) { el = document.createElement('style'); el.id = '__inksync_live__'; document.head.appendChild(el); }
            el.textContent = `\(css.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "`", with: "\\`"))`;
            if (window.postMetrics) {
                window.postMetrics();
            }
            // Restore scroll position
            setTimeout(function() {
                var sv = document.scrollingElement || document.documentElement;
                var isHoriz = \(isHoriz);
                if (isHoriz) {
                    var maxScroll = sv.scrollWidth - window.innerWidth;
                    window.scrollTo({ left: maxScroll * \(clampedFraction), behavior: 'instant' });
                } else {
                    var maxScroll = sv.scrollHeight - window.innerHeight;
                    window.scrollTo({ top: maxScroll * \(clampedFraction), behavior: 'instant' });
                }
            }, 100);
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }
}




struct BookReaderEngine: View {
    let pdf: ConvertedPDF
    var onDismiss: () -> Void
    var allBooks: [ConvertedPDF] = []
    
    @StateObject private var vm: BookReaderViewModel
    @State private var webViewReference: WKWebView?
    @State private var chromeVisible = false
    @State private var showAnnotations = false
    @State private var showTypographyHUD = false
    @State private var showTOC = false
    @State private var showJumpToPage = false
    @State private var jumpToPageText = ""
    @State private var sessionSeconds: Int = 0
    @State private var sessionTimer: Timer? = nil
    @State private var activeHighlightToEdit: SDAnnotation? = nil
    @ObservedObject private var prefs = EBookPreferences.shared
    @ObservedObject private var sleepTimer = SleepTimerManager.shared
    @State private var scrollToLastPageOnLoad = false
    @State private var annotationForFullEdit: SDAnnotation? = nil
    @State private var initialScrollFraction: Double = 0.0
    @State private var chapterScrollFraction: Double = 0.0
    @State private var chapterPage: Int = 0
    @State private var chapterTotalPages: Int = 1
    @State private var activeFootnoteText: String? = nil
    
    @Environment(\.modelContext) private var modelContext
    @State private var extractedTextParams: String = "Chapter reading is not extracted to string yet."
    @State private var lastBrightnessDragValue: CGFloat = 0
    
    private var formattedSessionTime: String {
        let hours = sessionSeconds / 3600
        let minutes = (sessionSeconds % 3600) / 60
        let seconds = sessionSeconds % 60
        if hours > 0 {
            return String(format: "%dh %dm", hours, minutes)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }
    
    // Custom Toast messages
    @State private var showToast = false
    @State private var toastMessage = ""
    @FocusState private var isReaderFocused: Bool
    
    init(pdf: ConvertedPDF, onDismiss: @escaping () -> Void, allBooks: [ConvertedPDF] = []) {
        self.pdf = pdf
        self.onDismiss = onDismiss
        self.allBooks = allBooks
        self._vm = StateObject(wrappedValue: BookReaderViewModel(pdf: pdf))
    }
    
    var body: some View {
        ZStack {
            Color(prefs.activeTheme.background).edgesIgnoringSafeArea(.all)
            
            if vm.isLoading {
                ProgressView("Unpacking EPUB...")
                    .foregroundColor(prefs.activeTheme.foreground(colorScheme: .light))
            } else {
                if !vm.chapterHtmlFiles.isEmpty {
                    let currentChapterURL = vm.chapterHtmlFiles[vm.currentChapterIndex]
                    EPUBWebView(
                        htmlContent: $vm.currentChapterHTML,
                        baseUrl: .constant(currentChapterURL),
                        prefs: EBookPreferences.shared,
                        scrollToLastPageOnLoad: $scrollToLastPageOnLoad,
                        initialScrollFraction: initialScrollFraction,
                        onScrollFractionChanged: { fraction in
                            chapterScrollFraction = fraction
                            saveProgress()
                        },
                        webViewRef: $webViewReference,
                        pdf: pdf,
                        currentPage: $chapterPage,
                        totalPages: $chapterTotalPages,
                        onHighlightCreated: { selectedText, _ in

                        let rawLabel = vm.tocItems[safe: vm.currentChapterIndex]?.label ?? ""
                        let spineLabel = !rawLabel.isEmpty ? rawLabel : nil
                        let highlight = Annotation(
                            pdfID: pdf.id,
                            pageIndex: vm.currentChapterIndex,
                            chapterTitle: spineLabel,
                            kind: .highlight,
                            createdAt: Date(),
                            modifiedAt: Date(),
                            colorHex: "#ffd700",
                            selectedText: selectedText
                        )
                        AnnotationStore.shared.add(highlight)
                        StudyNotesStore.shared.appendHighlight(selectedText, chapter: spineLabel ?? "Chapter \(vm.currentChapterIndex + 1)")

                        // Zettelkasten Integration: Instantly pop up editor for new highlight
                        let sdAnnotation = SDAnnotation(from: highlight)
                        modelContext.insert(sdAnnotation)
                        try? modelContext.save()
                        self.activeHighlightToEdit = sdAnnotation

                    }, onPageLoaded: { webView in
                        self.webViewReference = webView
                        let pageAnnotations = AnnotationStore.shared.annotations(for: pdf.id).filter { $0.pageIndex == vm.currentChapterIndex && $0.kind == .highlight }
                        for ann in pageAnnotations {
                            if let text = ann.selectedText, let color = ann.colorHex {
                                let safeText = text.replacingOccurrences(of: "`", with: "\\`")
                                                   .replacingOccurrences(of: "\"", with: "\\\"")
                                                   .replacingOccurrences(of: "\n", with: " ")
                                                   let js = "window.restoreInksyncHighlight(`\(safeText)`, '\(color)');"
                                webView.evaluateJavaScript(js)
                            }
                        }
                    },
                    onCenterTap: { chromeVisible.toggle() },
                    onLeftTap: { pageBackward() },
                    onRightTap: { pageForward() },
                    onNextChapter: {
                        let lastIdx = vm.chapterHtmlFiles.count - 1
                        if vm.currentChapterIndex >= lastIdx {
                            // Last chapter — attempt series continuation
                            attemptBookSeriesContinuation()
                        } else {
                            vm.loadChapter(index: min(lastIdx, vm.currentChapterIndex + 1))
                        }
                    },
                    onPrevChapter: {
                        scrollToLastPageOnLoad = true
                        vm.loadChapter(index: max(0, vm.currentChapterIndex - 1))
                    },
                    onFootnoteTapped: { text in
                        activeFootnoteText = text
                    })
                    .ignoresSafeArea()
                    
                    // Edge Brightness Gesture Zones
                    HStack {
                        Color.clear
                            .contentShape(Rectangle())
                            .frame(width: 30)
                            .gesture(
                                DragGesture()
                                    .onChanged { value in
                                        let delta = value.translation.height - lastBrightnessDragValue
                                        lastBrightnessDragValue = value.translation.height
                                        UIScreen.main.brightness -= delta * 0.005
                                    }
                                    .onEnded { _ in lastBrightnessDragValue = 0 }
                            )
                        Spacer()
                        Color.clear
                            .contentShape(Rectangle())
                            .frame(width: 30)
                            .gesture(
                                DragGesture()
                                    .onChanged { value in
                                        let delta = value.translation.height - lastBrightnessDragValue
                                        lastBrightnessDragValue = value.translation.height
                                        UIScreen.main.brightness -= delta * 0.005
                                    }
                                    .onEnded { _ in lastBrightnessDragValue = 0 }
                            )
                    }
                }
            }
            
            ReaderChrome(
                title: pdf.name,
                pageText: "Page \(chapterPage + 1) of \(chapterTotalPages)  •  " + (vm.tocItems.indices.contains(vm.currentChapterIndex) && !vm.tocItems[vm.currentChapterIndex].label.isEmpty ? vm.tocItems[vm.currentChapterIndex].label : "Ch. \(vm.currentChapterIndex + 1) / \(max(1, vm.chapterHtmlFiles.count))"),
                isVisible: $chromeVisible,
                onBack: onDismiss,
                onBookmark: {
                    let rawLabel = vm.tocItems[safe: vm.currentChapterIndex]?.label ?? ""
                    let spineLabel = !rawLabel.isEmpty ? rawLabel : nil
                    let bookmark = Annotation(pdfID: pdf.id, pageIndex: vm.currentChapterIndex, chapterTitle: spineLabel, kind: .bookmark, createdAt: Date(), modifiedAt: Date())
                    AnnotationStore.shared.add(bookmark)
                },
                onSettingsToggle: {
                    withAnimation { showTypographyHUD = true }
                },
                onTOCToggle: { showTOC = true },
                onAnnotationsToggle: { NotificationCenter.default.post(name: .toggleStudyNotebook, object: nil) },
                currentProgress: Binding(
                    get: { Double(vm.currentChapterIndex) / Double(max(1, vm.chapterHtmlFiles.count - 1)) },
                    set: { newVal in
                        // loadChapter() updates currentChapterHTML which drives EPUBWebView.updateUIView.
                        // A direct assignment to currentChapterIndex alone doesn't trigger a reload
                        // because updateUIView hashes currentChapterHTML, not the index.
                        let target = Int(newVal * Double(max(1, vm.chapterHtmlFiles.count - 1)))
                        vm.loadChapter(index: target)
                    }
                ),
                totalPages: vm.chapterHtmlFiles.count,
                onJumpToPage: {
                    jumpToPageText = ""
                    showJumpToPage = true
                },
                hasCopyAction: true,
                onCopyToggle: {
                    webViewReference?.evaluateJavaScript("document.body.innerText") { result, _ in
                        if let text = result as? String, !text.isEmpty {
                            UIPasteboard.general.string = text
                            showToastMessage("Chapter copied to clipboard")
                            Haptics.shared.playImpact(style: .light)
                        }
                    }
                },
                sessionTimeText: formattedSessionTime
            )
            
            if showToast {
                Text(toastMessage)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
                    .padding(.bottom, 110)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(100)
            }
        }
        .onAppear {
            if let saved = ReaderProgressTracker.shared.progress(for: pdf.id), let ch = saved.currentChapterIndex {
                vm.currentChapterIndex = ch
                initialScrollFraction = saved.currentChapterOffset ?? 0.0
            }
            // Apply per-book theme + typography profiles
            prefs.applyBookTheme(bookID: pdf.id.uuidString)
            prefs.applyBookTypography(bookID: pdf.id.uuidString)
            isReaderFocused = true
            sessionSeconds = 0
            sessionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                sessionSeconds += 1
            }
        }
        .onDisappear {
            saveProgress()
            sessionTimer?.invalidate()
            sessionTimer = nil
        }
        .overlay { if prefs.showReadingRuler { ReadingRulerOverlay() } }
        .onChange(of: sleepTimer.didFire) { _, fired in
            if fired { onDismiss() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("Reader_JumpToPage"))) { notification in
            if let pageIndex = notification.userInfo?["pageIndex"] as? Int, pageIndex >= 0, pageIndex < vm.chapterHtmlFiles.count {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    vm.loadChapter(index: pageIndex)
                }
            }
        }
        .popover(item: Binding<FootnoteItem?>(
            get: { activeFootnoteText.map { FootnoteItem(text: $0) } },
            set: { activeFootnoteText = $0?.text }
        )) { item in
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Footnote Reference", systemImage: "info.circle")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundColor(.blue)
                    Spacer()
                }
                ScrollView {
                    Text(item.text)
                        .font(.system(size: 13, weight: .medium, design: .serif))
                        .foregroundColor(.primary)
                        .lineSpacing(4)
                }
            }
            .padding(16)
            .frame(width: 320, height: 180)
            .presentationCompactAdaptation(.popover)
        }

        .popover(item: $activeHighlightToEdit) { annotation in
            HighlightQuickPopoverView(
                annotation: annotation,
                onDelete: {
                    if let webView = webViewReference, let text = annotation.selectedText {
                        let safeText = text.replacingOccurrences(of: "`", with: "\\`").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: " ")
                        webView.evaluateJavaScript("window.removeInksyncHighlight(`\(safeText)`);")
                    }
                    modelContext.delete(annotation)
                    try? modelContext.save()
                    activeHighlightToEdit = nil
                },
                onEditNote: {
                    annotationForFullEdit = annotation
                    activeHighlightToEdit = nil
                },
                onColorSelected: { colorHex in
                    if let webView = webViewReference, let text = annotation.selectedText {
                        let safeText = text.replacingOccurrences(of: "`", with: "\\`").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: " ")
                        webView.evaluateJavaScript("window.updateInksyncHighlightColor(`\(safeText)`, '\(colorHex)');")
                    }
                }
            )
            .presentationCompactAdaptation(.popover)
        }
        .sheet(item: $annotationForFullEdit) { annotation in
            AnnotationEditSheet(annotation: annotation)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showTypographyHUD) {
            EBookSettingsPanel(bookID: pdf.id.uuidString)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showTOC) {
            BookNavigationSheet(vm: vm, showTOC: $showTOC, webView: webViewReference)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .focusable()
        .focused($isReaderFocused)
        .focusEffectDisabled()
        .alert("Go to Chapter", isPresented: $showJumpToPage) {
            TextField("Chapter number (1-\(vm.chapterHtmlFiles.count))", text: $jumpToPageText)
                .keyboardType(.numberPad)
            Button("Cancel", role: .cancel) { }
            Button("Go") {
                if let chapterNum = Int(jumpToPageText), chapterNum >= 1 && chapterNum <= vm.chapterHtmlFiles.count {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        vm.loadChapter(index: chapterNum - 1)
                    }
                }
            }
        } message: {
            Text("Enter a chapter number between 1 and \(vm.chapterHtmlFiles.count).")
        }
        .onKeyPress(.leftArrow) {
            pageBackward()
            return .handled
        }
        .onKeyPress(.rightArrow) {
            pageForward()
            return .handled
        }
        .onKeyPress(.space) {
            pageForward()
            return .handled
        }
        .onKeyPress(.escape) {
            onDismiss()
            return .handled
        }
        .preferredColorScheme(prefs.activeTheme.isDark ? .dark : .light)
    }

    private func showToastMessage(_ message: String) {
        toastMessage = message
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            showToast = true
        }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation(.easeOut(duration: 0.3)) {
                if toastMessage == message {
                    showToast = false
                }
            }
        }
    }


    // MARK: - Navigation helpers

    private func pageForward() {
        guard let webView = webViewReference else { return }
        let scroll = webView.scrollView
        let isPaged = prefs.paginationMode == EBookPaginationMode.paged.rawValue

        if isPaged {
            let width = max(webView.bounds.width, 1)
            let contentWidth = scroll.contentSize.width
            let currentOffset = scroll.contentOffset.x

            // Guard against layout-not-ready (contentSize is 0 briefly after chapter load)
            guard contentWidth > 0 else { return }

            let maxOffset = max(contentWidth - width, 0)
            let targetOffset = currentOffset + width

            // Consider "at last page" if the current offset is already at or beyond maxOffset,
            // OR if the next page would scroll past the end. Both cases → chapter advance.
            let atLastPage = (currentOffset >= maxOffset - 4) || (targetOffset >= contentWidth - 4)

            if atLastPage {
                let lastIdx = vm.chapterHtmlFiles.count - 1
                if vm.currentChapterIndex >= lastIdx {
                    attemptBookSeriesContinuation()
                } else {
                    vm.loadChapter(index: min(lastIdx, vm.currentChapterIndex + 1))
                }
            } else {
                scroll.setContentOffset(CGPoint(x: min(targetOffset, maxOffset), y: 0), animated: true)
            }
        } else {
            let height = max(webView.bounds.height, 1)
            let contentHeight = scroll.contentSize.height
            let currentOffset = scroll.contentOffset.y

            guard contentHeight > 0 else { return }

            let maxOffset = max(contentHeight - height, 0)
            let targetOffset = currentOffset + height * 0.9

            let atLastPage = (currentOffset >= maxOffset - 4) || (targetOffset >= contentHeight - 4)

            if atLastPage {
                let lastIdx = vm.chapterHtmlFiles.count - 1
                if vm.currentChapterIndex >= lastIdx {
                    attemptBookSeriesContinuation()
                } else {
                    vm.loadChapter(index: min(lastIdx, vm.currentChapterIndex + 1))
                }
            } else {
                scroll.setContentOffset(CGPoint(x: 0, y: min(targetOffset, maxOffset)), animated: true)
            }
        }
    }

    private func pageBackward() {
        guard let webView = webViewReference else { return }
        let scroll = webView.scrollView
        let isPaged = prefs.paginationMode == EBookPaginationMode.paged.rawValue

        if isPaged {
            let width = max(webView.bounds.width, 1)
            let currentOffset = scroll.contentOffset.x

            if currentOffset <= 4 {
                if vm.currentChapterIndex > 0 {
                    scrollToLastPageOnLoad = true
                    vm.loadChapter(index: vm.currentChapterIndex - 1)
                }
            } else {
                let targetOffset = currentOffset - width
                scroll.setContentOffset(CGPoint(x: max(0, targetOffset), y: 0), animated: true)
            }
        } else {
            let height = max(webView.bounds.height, 1)
            let currentOffset = scroll.contentOffset.y

            if currentOffset <= 4 {
                if vm.currentChapterIndex > 0 {
                    vm.loadChapter(index: vm.currentChapterIndex - 1)
                }
            } else {
                let targetOffset = currentOffset - height * 0.9
                scroll.setContentOffset(CGPoint(x: 0, y: max(0, targetOffset)), animated: true)
            }
        }
    }

    private func saveProgress() {
        ReaderProgressTracker.shared.update(ReadingProgress(
            pdfID: pdf.id, lastOpenedAt: Date(), currentPageIndex: vm.currentChapterIndex,
            currentChapterIndex: vm.currentChapterIndex, currentChapterOffset: chapterScrollFraction,
            totalPagesRead: 1, completionFraction: Double(vm.currentChapterIndex + 1) / Double(max(1, vm.chapterHtmlFiles.count)),
            readingSessionDates: [Date()], estimatedMinutesRemaining: nil
        ))
    }

    // MARK: - Series Continuation
    /// Posts openMergedBook with the next volume in the series when the user finishes the last chapter.
    private func attemptBookSeriesContinuation() {
        guard let seriesName = pdf.metadata.series, !seriesName.isEmpty else { return }

        // Robust sort: parse issue/volume as Double first (handles "12.1", "0.5");
        // fall back to localizedStandardCompare for non-numeric labels like "HC", "TPB", "#0".
        let siblings = allBooks
            .filter { $0.metadata.series == seriesName && $0.id != pdf.id }
            .sorted { lhs, rhs in
                let lhsNum = Double(lhs.metadata.issueNumber ?? lhs.metadata.volume ?? "")
                let rhsNum = Double(rhs.metadata.issueNumber ?? rhs.metadata.volume ?? "")
                if let l = lhsNum, let r = rhsNum { return l < r }
                let lKey = lhs.metadata.issueNumber ?? lhs.metadata.volume ?? lhs.name
                let rKey = rhs.metadata.issueNumber ?? rhs.metadata.volume ?? rhs.name
                return lKey.localizedStandardCompare(rKey) == .orderedAscending
            }

        let selfKey = pdf.metadata.issueNumber ?? pdf.metadata.volume ?? pdf.name
        // Find the first sibling that sorts strictly after the current book
        guard let currentIdx = siblings.firstIndex(where: { b in
            let bKey = b.metadata.issueNumber ?? b.metadata.volume ?? b.name
            return bKey == selfKey
        }) else {
            // Current book not in sibling list — open the first unread one
            if let first = siblings.first { NotificationCenter.default.post(name: .openMergedBook, object: first) }
            return
        }
        let nextIdx = siblings.index(after: currentIdx)
        guard siblings.indices.contains(nextIdx) else { return }
        NotificationCenter.default.post(name: .openMergedBook, object: siblings[nextIdx])
    }
}

struct BookNavigationSheet: View {
    @ObservedObject var vm: BookReaderViewModel
    @Binding var showTOC: Bool
    var webView: WKWebView?
    @State private var searchQuery = ""
    
    var body: some View {
        NavigationView {
            TabView {
                // Chapters
                List(0..<vm.tocItems.count, id: \.self) { idx in
                    Button(action: {
                        showTOC = false
                        vm.loadChapter(index: idx)
                    }) {
                        HStack {
                            Text(vm.tocItems[idx].label)
                                .foregroundColor(vm.currentChapterIndex == idx ? .blue : .primary)
                            Spacer()
                            if vm.currentChapterIndex == idx {
                                Image(systemName: "checkmark").foregroundColor(.blue)
                            }
                        }
                    }
                }
                .tabItem { Label("Chapters", systemImage: "list.bullet") }
                
                // Search
                VStack {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                        TextField("Search book...", text: $searchQuery)
                            .onSubmit { Task { await vm.search(query: searchQuery) } }
                        if !searchQuery.isEmpty {
                            Button(action: { searchQuery = ""; vm.searchResults = [] }) {
                                Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(8)
                    .background(Color.inkSurface)
                    .cornerRadius(8)
                    .padding()
                    
                    if vm.isSearching {
                        ProgressView().padding()
                        Spacer()
                    } else if vm.searchResults.isEmpty && !searchQuery.isEmpty {
                        Text("No results found.").foregroundColor(.secondary).padding()
                        Spacer()
                    } else {
                        List(vm.searchResults) { result in
                            Button(action: {
                                showTOC = false
                                vm.loadChapter(index: result.chapterIndex)
                                // Dispatch a window.find to highlight the exact text
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                                    let safeQuery = searchQuery.replacingOccurrences(of: "'", with: "\\'")
                                    webView?.evaluateJavaScript("window.find('\(safeQuery)', false, false, true, false, false, false);")
                                }
                            }) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(result.chapterTitle)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text(result.snippet)
                                        .font(.body)
                                        .foregroundColor(.primary)
                                        .lineLimit(3)
                                }
                            }
                        }
                    }
                }
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
            }
            .navigationTitle("Navigation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { showTOC = false }
                }
            }
        }
    }
}

// MARK: - Typography Settings HUD
// Legacy entry point kept for ReaderView compatibility.
// Presentation is now handled by EBookSettingsPanel.
struct TypographySettingsHUD: View {
    @ObservedObject var prefs: EBookPreferences
    var webView: WKWebView?
    var isFixedLayout: Bool = false

    var body: some View {
        EBookSettingsPanel(bookID: nil)
    }
}

struct ThemeButton: View {
    let title: String
    let bgHex: String
    let textHex: String
    let currentBg: String
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Circle()
                .fill(Color(UIColor(hex: bgHex) ?? .white))
                .frame(width: 44, height: 44)
                .overlay(
                    Circle().stroke(Color.blue, lineWidth: currentBg == bgHex ? 3 : 0)
                )
                .shadow(color: .black.opacity(0.1), radius: 3)
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
                                    Image(systemName: "note.text")
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

struct HighlightQuickPopoverView: View {
    @Bindable var annotation: SDAnnotation
    var onDelete: () -> Void
    var onEditNote: () -> Void
    var onColorSelected: (String) -> Void
    
    let colors = [
        ("#FFD60A", Color.yellow),
        ("#30D158", Color.green),
        ("#FF375F", Color.pink),
        ("#0A84FF", Color.blue),
        ("#BF5AF2", Color.purple)
    ]
    
    var body: some View {
        VStack(spacing: 12) {
            // Colors row
            HStack(spacing: 14) {
                ForEach(colors, id: \.0) { item in
                    Circle()
                        .fill(item.1)
                        .frame(width: 28, height: 28)
                        .overlay(
                            Circle()
                                .stroke(Color.primary.opacity(0.3), lineWidth: annotation.colorHex == item.0 ? 3 : 0)
                        )
                        .onTapGesture {
                            annotation.colorHex = item.0
                            annotation.modifiedAt = Date()
                            try? annotation.modelContext?.save()
                            onColorSelected(item.0)
                        }
                }
            }
            .padding(.top, 4)
            
            Divider()
            
            // Actions row
            HStack(spacing: 20) {
                Button(action: onEditNote) {
                    Label("Add Note", systemImage: "square.and.pencil")
                        .font(.subheadline)
                        .foregroundColor(.primary)
                }
                
                Spacer()
                
                Button(action: onDelete) {
                    Label("Delete", systemImage: "trash")
                        .font(.subheadline)
                        .foregroundColor(.red)
                }
            }
            .padding(.horizontal, 4)
        }
        .padding(12)
        .frame(width: 260, height: 110)
    }
}

struct FootnoteItem: Identifiable {
    let id = UUID()
    let text: String
}




