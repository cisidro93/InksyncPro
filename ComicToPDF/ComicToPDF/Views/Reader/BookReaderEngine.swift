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
        let (htmlFiles, spineItems): ([URL], [EBookMetadata.SpineItem]) = await Task.detached(priority: .userInitiated) {
            if let spine = parsedMetadata?.spineItems, !spine.isEmpty {
                var validFiles: [URL] = []
                var validItems: [EBookMetadata.SpineItem] = []
                for item in spine {
                    let dest = tempDir.appendingPathComponent(item.href)
                    if FileManager.default.fileExists(atPath: dest.path) {
                        validFiles.append(dest)
                        validItems.append(item)
                    }
                }
                return (validFiles, validItems)
            } else {
                guard let enumerator = FileManager.default.enumerator(at: tempDir, includingPropertiesForKeys: nil) else { return ([], []) }
                var htmls: [URL] = []
                while let file = enumerator.nextObject() as? URL {
                    let ext = file.pathExtension.lowercased()
                    if ext == "html" || ext == "xhtml" { htmls.append(file) }
                }
                htmls.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                let items = htmls.enumerated().map { idx, url in
                    EBookMetadata.SpineItem(id: "ch_\(idx)", href: url.lastPathComponent, label: "Chapter \(idx + 1)")
                }
                return (htmls, items)
            }
        }.value

        // Back on @MainActor — safe to mutate @Published properties
        self.metadata = parsedMetadata
        self.chapterHtmlFiles = htmlFiles
        
        // Ensure every item has a non-empty fallback label if unlabelled
        var finalItems = spineItems
        for i in 0..<finalItems.count {
            let existingLabel = finalItems[i].label.trimmingCharacters(in: .whitespacesAndNewlines)
            if existingLabel.isEmpty || (existingLabel.hasPrefix("Chapter ") && finalItems[i].tocTitle == nil) {
                let url = htmlFiles[safe: i]
                var heading: String? = nil
                if let url = url, let content = try? String(contentsOf: url) {
                    heading = self.extractFirstHeading(from: content)
                }
                if let h = heading, !h.isEmpty {
                    finalItems[i].label = h
                } else if existingLabel.isEmpty {
                    finalItems[i].label = EBookMetadata.deriveSemanticLabel(fromHref: finalItems[i].href, fallbackIndex: i)
                }
            }
        }
        self.tocItems = finalItems
        if !htmlFiles.isEmpty {
            self.loadChapter(index: self.currentChapterIndex)
            self.buildOrLoadSearchIndex()
        } else {
            self.isLoading = false
        }
    }
    
    private func extractFirstHeading(from html: String) -> String? {
        let pattern = "<h[12][^>]*>(.*?)</h[12]>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: html, options: [], range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else { return nil }
        let raw = String(html[range])
        let stripped = raw.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression, range: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? nil : stripped
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
                html = regex.stringByReplacingMatches(in: html, options: [], range: NSRange(html.startIndex..., in: html), withTemplate: "<meta charset=\"utf-8\">")
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
                }

                let fileName = url.lastPathComponent
                let fragment = url.fragment ?? ""

                if !fileName.isEmpty {
                    NotificationCenter.default.post(
                        name: NSNotification.Name("Reader_JumpToChapterHref"),
                        object: nil,
                        userInfo: ["href": fileName, "fragment": fragment]
                    )
                }

                if !fragment.isEmpty {
                    let js = """
                    (function() {
                        var el = document.getElementById('\(fragment)') || document.getElementsByName('\(fragment)')[0];
                        if (el) {
                            var isFN = el.classList.contains('footnote') || el.getAttribute('epub:type') === 'noteref' || el.getAttribute('rel') === 'footnote' || el.id.toLowerCase().indexOf('fn') === 0;
                            if (isFN) {
                                var text = el.innerText || el.textContent;
                                if (text && text.trim().length > 0) {
                                    window.webkit.messageHandlers.footnote.postMessage({ "id": '\(fragment)', "text": text.trim() });
                                    return;
                                }
                            }
                            el.scrollIntoView({ behavior: 'smooth', block: 'start' });
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
        .onReceive(prefs.objectWillChange) { _ in
            DispatchQueue.main.async {
                updateLiveCSS()
            }
        }
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
        *, *::before, *::after { box-sizing: border-box; -webkit-tap-highlight-color: transparent; scroll-behavior: auto !important; }
        html {
            margin: 0 !important; padding: 0 !important;
            width: 100% !important;
            column-width: auto !important;
            touch-action: pan-x pan-y;
            scroll-behavior: auto !important;
            scroll-snap-type: none !important;
            background-color: transparent !important;
            \(isPaged ? """
            height: 100% !important;
            overflow-x: hidden !important;
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
            width: 100% !important;
            max-width: 100% !important;
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
        #inksync-viewport *, body * {
            max-width: 100% !important;
            box-sizing: border-box !important;
            word-break: break-word !important;
            overflow-wrap: break-word !important;
        }
        /* Force container backgrounds to be transparent so the ambient paper texture is visible */
        #inksync-viewport, #inksync-viewport *:not(mark):not(.inksync-highlight):not(pre):not(code):not(table):not(tr):not(td):not(th) {
            background-color: transparent !important;
            background: transparent !important;
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
                    if (_currentPage >= 99999) {
                        _currentPage = Math.max(0, _totalPages - 1);
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
                    if (_currentPage >= 99999) {
                        _currentPage = Math.max(0, _totalPages - 1);
                    }
                    goToPage(_currentPage, false);
                } else {
                    _currentPage = Math.max(0, Math.min(Math.round(sv.scrollTop / pageHeight), _totalPages - 1));
                }
            }
            
            window.webkit.messageHandlers.metrics.postMessage({ current: _currentPage, total: _totalPages });
            postFraction();
        }

        var _isNavigating = false;
        var _navTimer = null;

        function goToPage(page, smooth) {
            _isNavigating = true;
            if (_navTimer) clearTimeout(_navTimer);
            _currentPage = Math.max(0, Math.min(page, _totalPages - 1));
            var behavior = 'instant';
            
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

            _navTimer = setTimeout(function() {
                _isNavigating = false;
            }, 250);
        }
        window.goToInksyncPage = goToPage;

        window.onload = function() {
            setTimeout(updateMetrics, 100);
            setTimeout(updateMetrics, 500);
            setTimeout(updateMetrics, 1500);
        };

        if (document.fonts && document.fonts.ready) {
            document.fonts.ready.then(function() {
                updateMetrics();
            });
        }
        window.addEventListener('resize', function() { updateMetrics(); goToPage(_currentPage, false); });

        document.addEventListener('click', function(e) {
            if (e.target.tagName.toLowerCase() === 'a') return;
            if (window.getSelection() && !window.getSelection().isCollapsed) return;
            var x = e.clientX; var w = window.innerWidth;
            var leftEdge = window.__inksync_left_edge || 0.30;
            var rightEdge = window.__inksync_right_edge || 0.70;
            if (x < w * leftEdge) {
                window.webkit.messageHandlers.nav.postMessage('left');
            } else if (x > w * rightEdge) {
                window.webkit.messageHandlers.nav.postMessage('right');
            } else {
                window.webkit.messageHandlers.nav.postMessage('center');
            }
        });

        document.addEventListener('keydown', function(e) {
            if (e.key === 'ArrowRight' || e.key === 'Space') {
                window.webkit.messageHandlers.nav.postMessage('right');
                e.preventDefault();
            } else if (e.key === 'ArrowLeft') {
                window.webkit.messageHandlers.nav.postMessage('left');
                e.preventDefault();
            }
        });

        var _scrollTimeout;
        window.addEventListener('scroll', function() {
            if (_isNavigating) return;
            clearTimeout(_scrollTimeout);
            _scrollTimeout = setTimeout(function() {
                if (!_isNavigating) {
                    updateMetrics();
                }
            }, 80);
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
    @State private var showReadingStatsHUD = false
    @State private var showAnnotations = false
    @State private var showTypographyHUD = false
    @State private var showTOC = false
    @State private var showJumpToPage = false
    @State private var jumpToPageText = ""
    @State private var sessionStartTime: Date? = nil
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
    
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var modelContext
    @State private var extractedTextParams: String = "Chapter reading is not extracted to string yet."
    @State private var lastBrightnessDragValue: CGFloat = 0
    

    
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
    
    var isMangaMode: Bool { pdf.metadata.isManga == true || pdf.contentType == .manga }

private func computeColumnCount(for size: CGSize) -> Int {
        let renderWidth = size.width > 0 ? size.width : UIScreen.main.bounds.width
        let renderHeight = size.height > 0 ? size.height : UIScreen.main.bounds.height
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        let isLandscape = renderWidth > renderHeight
        let defaultColumns = (isPad && isLandscape) ? 2 : 1
        return prefs.columnCount == 0 ? defaultColumns : prefs.columnCount
    }

    private var currentProgressBinding: Binding<Double> {
        Binding(
            get: {
                let count = max(1, vm.chapterHtmlFiles.count - 1)
                return Double(vm.currentChapterIndex) / Double(count)
            },
            set: { newVal in
                let count = max(1, vm.chapterHtmlFiles.count - 1)
                let target = Int(newVal * Double(count))
                vm.loadChapter(index: target)
            }
        )
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                AmbientReaderBackground(theme: prefs.activeTheme)
                    .ignoresSafeArea()
                
                if vm.isLoading {
                    ProgressView("Unpacking EPUB...")
                        .foregroundColor(prefs.activeTheme.foreground(colorScheme: .light))
                } else {
                    if !vm.chapterHtmlFiles.isEmpty {
                        let currentChapterURL = vm.chapterHtmlFiles[vm.currentChapterIndex]
                        ZStack {
                            if prefs.paginationMode == EBookPaginationMode.paged.rawValue {
                                // Native UIPageViewController(.pageCurl) for EPUB paged mode
                                EBookPageCurlReader(
                                    spineItem: EBookMetadata.SpineItem(
                                        id: currentChapterURL.lastPathComponent,
                                        href: currentChapterURL.lastPathComponent,
                                        label: vm.tocItems[safe: vm.currentChapterIndex]?.label ?? ""
                                    ),
                                    unzipDir: currentChapterURL.deletingLastPathComponent(),
                                    prefs: prefs,
                                    colorScheme: colorScheme,
                                    currentPage: $chapterPage,
                                    initialPage: chapterPage,
                                    totalPages: $chapterTotalPages,
                                    onNext: {
                                        let lastIdx = vm.chapterHtmlFiles.count - 1
                                        if vm.currentChapterIndex >= lastIdx {
                                            attemptBookSeriesContinuation()
                                        } else {
                                            scrollToLastPageOnLoad = false
                                            initialScrollFraction = 0.0
                                            chapterPage = 0
                                            vm.loadChapter(index: min(lastIdx, vm.currentChapterIndex + 1))
                                        }
                                    },
                                    onPrev: {
                                        scrollToLastPageOnLoad = true
                                        initialScrollFraction = 1.0
                                        chapterPage = 99999
                                        vm.loadChapter(index: max(0, vm.currentChapterIndex - 1))
                                    },
                                    onCenterTap: { chromeVisible.toggle() },
                                    onHighlightCreated: { selectedText in
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

                                        let sdAnnotation = SDAnnotation(from: highlight)
                                        modelContext.insert(sdAnnotation)
                                        try? modelContext.save()
                                        self.activeHighlightToEdit = sdAnnotation
                                    },
                                    pdfID: pdf.id,
                                    initialScrollFraction: initialScrollFraction,
                                    onScrollFractionChanged: { fraction in
                                        chapterScrollFraction = fraction
                                        saveProgress()
                                    },
                                    webViewRef: $webViewReference,
                                    onFootnoteTapped: { text in
                                        activeFootnoteText = text
                                    }
                                )
                                .id("book_curl_\(prefs.pageTurnStyle.rawValue)_\(vm.currentChapterIndex)")
                            } else {
                                // Scroll mode: EPUBWebView continuous vertical scroll
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

                                        let sdAnnotation = SDAnnotation(from: highlight)
                                        modelContext.insert(sdAnnotation)
                                        try? modelContext.save()
                                        self.activeHighlightToEdit = sdAnnotation
                                    },
                                    onPageLoaded: { webView in
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
                                    onLeftTap: { if isMangaMode { pageForward() } else { pageBackward() } },
                                    onRightTap: { if isMangaMode { pageBackward() } else { pageForward() } },
                                    onNextChapter: {
                                        let lastIdx = vm.chapterHtmlFiles.count - 1
                                        if vm.currentChapterIndex >= lastIdx {
                                            attemptBookSeriesContinuation()
                                        } else {
                                            scrollToLastPageOnLoad = false
                                            initialScrollFraction = 0.0
                                            chapterPage = 0
                                            vm.loadChapter(index: min(lastIdx, vm.currentChapterIndex + 1))
                                        }
                                    },
                                    onPrevChapter: {
                                        scrollToLastPageOnLoad = true
                                        initialScrollFraction = 1.0
                                        chapterPage = 99999
                                        vm.loadChapter(index: max(0, vm.currentChapterIndex - 1))
                                    }
                                )
                                .ignoresSafeArea()
                                .id("epub_chapter_\(vm.currentChapterIndex)")
                            }
                        }
                        .readingFilter(prefs.readingFilter)
                        
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
                                            UIScreen.main.brightness -= delta * 0.001
                                        }
                                        .onEnded { _ in lastBrightnessDragValue = 0 }
                                )
                            Spacer()
                        }
                    }
                }
            
            ReaderChrome(
                title: pdf.name,
                pageText: {
                    let label = vm.tocItems[safe: vm.currentChapterIndex]?.label.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let displayLabel = !label.isEmpty ? label : "Section \(vm.currentChapterIndex + 1)"
                    return "Page \(chapterPage + 1) of \(max(1, chapterTotalPages))  •  \(displayLabel)"
                }(),
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
                onSearchToggle: { showTOC = true },
                currentProgress: currentProgressBinding,
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
                sessionStartTime: sessionStartTime
            )

            if !chromeVisible {
                KindleProgressFooterView(
                    currentPage: vm.currentChapterIndex + 1,
                    totalPages: max(1, vm.chapterHtmlFiles.count),
                    chapterPage: chapterPage,
                    chapterTotalPages: max(1, chapterTotalPages),
                    chapterTitle: vm.tocItems[safe: vm.currentChapterIndex]?.label,
                    isBookSection: true,
                    estimatedMinutesLeft: ReaderProgressTracker.shared.progress(for: pdf.id)?.estimatedMinutesRemaining
                )
                .transition(.opacity)
            }
            
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

            ReadingJumpToastOverlay()
        }
        .sheet(isPresented: $showReadingStatsHUD) {
            ReadingStatsHUDView(
                pdfID: pdf.id,
                bookTitle: pdf.name,
                totalPages: max(1, vm.chapterHtmlFiles.count),
                currentPageIndex: vm.currentChapterIndex
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
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
            if sessionStartTime == nil {
                sessionStartTime = Date()
            }
        }
        .onDisappear {
            saveProgress()
        }
        .overlay { if prefs.showReadingRuler { ReadingRulerOverlay() } }
        .onChange(of: sleepTimer.didFire) { _, fired in
            if fired { onDismiss() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .readerJumpToPage)) { notification in
            if let pageIndex = notification.userInfo?["pageIndex"] as? Int, pageIndex >= 0, pageIndex < vm.chapterHtmlFiles.count {
                let fromChapter = vm.currentChapterIndex
                if abs(pageIndex - fromChapter) > 0 {
                    ReadingJumpTracker.shared.recordJump(fromPage: fromChapter, toPage: pageIndex) {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            vm.loadChapter(index: fromChapter)
                        }
                    }
                }
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
                    let targetIdx = chapterNum - 1
                    let fromChapter = vm.currentChapterIndex
                    if abs(targetIdx - fromChapter) > 0 {
                        ReadingJumpTracker.shared.recordJump(fromPage: fromChapter, toPage: targetIdx) {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                vm.loadChapter(index: fromChapter)
                            }
                        }
                    }
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        vm.loadChapter(index: targetIdx)
                    }
                }
            }
        } message: {
            Text("Enter a chapter number between 1 and \(vm.chapterHtmlFiles.count).")
        }
        .onKeyPress(.leftArrow) {
            if isMangaMode { pageForward() } else { pageBackward() }
            return .handled
        }
        .onKeyPress(.rightArrow) {
            if isMangaMode { pageBackward() } else { pageForward() }
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
                    scrollToLastPageOnLoad = false
                    initialScrollFraction = 0.0
                    chapterPage = 0
                    vm.loadChapter(index: min(lastIdx, vm.currentChapterIndex + 1))
                }
            } else {
                let rect = CGRect(x: min(targetOffset, maxOffset), y: 0, width: width, height: max(scroll.bounds.height, 1))
                scroll.scrollRectToVisible(rect, animated: true)
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
                    scrollToLastPageOnLoad = false
                    initialScrollFraction = 0.0
                    chapterPage = 0
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
                    initialScrollFraction = 1.0
                    chapterPage = 99999
                    vm.loadChapter(index: vm.currentChapterIndex - 1)
                }
            } else {
                let targetOffset = max(0, currentOffset - width)
                let rect = CGRect(x: targetOffset, y: 0, width: width, height: max(scroll.bounds.height, 1))
                scroll.scrollRectToVisible(rect, animated: true)
            }
        } else {
            let height = max(webView.bounds.height, 1)
            let currentOffset = scroll.contentOffset.y

            if currentOffset <= 4 {
                if vm.currentChapterIndex > 0 {
                    scrollToLastPageOnLoad = true
                    initialScrollFraction = 1.0
                    chapterPage = 99999
                    vm.loadChapter(index: vm.currentChapterIndex - 1)
                }
            } else {
                let targetOffset = currentOffset - height * 0.9
                scroll.setContentOffset(CGPoint(x: 0, y: max(0, targetOffset)), animated: true)
            }
        }
    }

    private func saveProgress() {
        guard chapterPage < 99900 else { return }
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
            HStack(spacing: 16) {
                Button(action: onEditNote) {
                    Label("Note", systemImage: "square.and.pencil")
                        .font(.subheadline)
                        .foregroundColor(.primary)
                }
                
                Button(action: {
                    if let text = annotation.selectedText, !text.isEmpty {
                        DictionaryLookupService.shared.lookupAndSave(
                            term: text,
                            contextSentence: text,
                            bookTitle: annotation.readwiseBookTitle ?? "EPUB Book"
                        )
                    }
                }) {
                    Label("Look Up", systemImage: "book.fill")
                        .font(.subheadline)
                        .foregroundColor(.orange)
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

struct AmbientReaderBackground: View {
    let theme: EBookTheme
    
    var body: some View {
        ZStack {
            theme.background
                .ignoresSafeArea()
            
            // Warm reading lamp radial gradient
            RadialGradient(
                colors: [
                    Color.white.opacity(theme.isDark ? 0.03 : 0.45),
                    Color.black.opacity(theme.isDark ? 0.40 : 0.08)
                ],
                center: .center,
                startRadius: 20,
                endRadius: 700
            )
            .ignoresSafeArea()
            
            // Subtle parchment paper grain overlay (if not OLED)
            if theme != .oled {
                GeometryReader { _ in
                    Canvas { context, size in
                        // Overlay soft grid noise to simulate paper fiber
                        var rng = ParchmentPaperSeededRandom(seed: 42)
                        let dotCount = Int((size.width * size.height) * 0.0015)
                        context.opacity = theme.isDark ? 0.03 : 0.012
                        context.blendMode = .multiply
                        
                        for _ in 0..<dotCount {
                            let x = CGFloat(rng.nextUniform()) * size.width
                            let y = CGFloat(rng.nextUniform()) * size.height
                            let r = CGFloat(rng.nextUniform() * 0.8 + 0.4)
                            let rect = CGRect(x: x, y: y, width: r, height: r)
                            context.fill(Path(ellipseIn: rect), with: .color(Color.black))
                        }
                    }
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
            }
        }
    }
}

/// A simple seeded pseudo-random number generator for deterministic paper texture generation
struct ParchmentPaperSeededRandom {
    private var state: UInt64
    
    init(seed: UInt64) {
        self.state = seed
    }
    
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
    
    mutating func nextUniform() -> Double {
        let val = next()
        return Double(val) / Double(UInt64.max)
    }
}

struct BookSpineCreaseOverlay: View {
    var body: some View {
        HStack {
            Spacer()
            // The fold shadow
            LinearGradient(
                colors: [
                    Color.black.opacity(0.16),
                    Color.black.opacity(0.04),
                    Color.clear
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: 14)
            
            LinearGradient(
                colors: [
                    Color.clear,
                    Color.black.opacity(0.04),
                    Color.black.opacity(0.16)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: 14)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}






