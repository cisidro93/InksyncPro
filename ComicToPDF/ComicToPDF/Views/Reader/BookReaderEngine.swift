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
    @ObservedObject var prefs: EBookPreferences
    var onHighlightCreated: ((String, String) -> Void)?
    var onPageLoaded: ((WKWebView) -> Void)?
    /// Fired when user taps the center third of the page (toggles chrome)
    var onCenterTap: (() -> Void)? = nil
    /// Fired when user taps the left third of the page (turns page back)
    var onLeftTap: (() -> Void)? = nil
    /// Fired when user taps the right third of the page (turns page forward)
    var onRightTap: (() -> Void)? = nil
    /// Fired when a forward swipe reaches the end of the last column
    var onNextChapter: (() -> Void)? = nil
    /// Fired when a backward swipe is at the first column
    var onPrevChapter: (() -> Void)? = nil

    class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: EPUBWebView
        /// Stable hash of the combined (content + prefs) state — prevents update loops.
        var lastContentHash: Int = 0
        /// Hash of the raw HTML only — used to distinguish content changes from prefs-only changes.
        var lastContentOnlyHash: Int = 0

        init(_ parent: EPUBWebView) { self.parent = parent }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "highlightHandler", let dict = message.body as? [String: String] {
                if let text = dict["text"], let html = dict["html"] {
                    parent.onHighlightCreated?(text, html)
                }
            } else if message.name == "nav", let body = message.body as? String {
                switch body {
                case "center": parent.onCenterTap?()
                case "left":   parent.onLeftTap?()
                case "right":  parent.onRightTap?()
                case "next":   parent.onNextChapter?()
                case "prev":   parent.onPrevChapter?()
                default: break
                }
            }
        }

        // Intercept navigation for Footnotes, External links, and Chapters
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated {
                if let url = navigationAction.request.url {
                    if url.scheme == "http" || url.scheme == "https" {
                        UIApplication.shared.open(url)
                    } else if let fragment = url.fragment {
                        // Internal anchor (e.g., footnote)
                        let js = """
                        var el = document.getElementById('\(fragment)') || document.getElementsByName('\(fragment)')[0];
                        if (el) {
                            var targetOffset = el.getBoundingClientRect().left + window.pageXOffset;
                            var pageIndex = Math.floor(targetOffset / window.innerWidth);
                            window.scrollTo({ left: pageIndex * window.innerWidth, behavior: 'smooth' });
                        }
                        """
                        webView.evaluateJavaScript(js, completionHandler: nil)
                    }
                }
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.onPageLoaded?(webView)
        }

        /// Recover from Jetsam Out-Of-Memory (OOM) WebKit process crashes.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            Logger.shared.log("WebKit process terminated (OOM Jetsam crash). Reloading EPUB chapter.", category: "EPUBWebView", type: .error)
            webView.reload()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    func makeUIView(context: Context) -> WKWebView {
        let webpagePrefs = WKWebpagePreferences()
        webpagePrefs.allowsContentJavaScript = true
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences = webpagePrefs

        // Use WeakProxy — WKUserContentController strongly retains handlers by default.
        let proxy = WeakScriptMessageProxy(context.coordinator)
        config.userContentController.add(proxy, name: "highlightHandler")
        // `nav` bridge: center/left/right tap, next/prev chapter boundary swipes
        config.userContentController.add(proxy, name: "nav")

        // CSS + JS Injection (runs once after each page load, not on every SwiftUI update)
        let userScript = WKUserScript(
            source: """
            var meta = document.createElement('meta');
            meta.name = 'viewport';
            meta.content = 'width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no, viewport-fit=cover';
            var head = document.getElementsByTagName('head')[0];
            head.appendChild(meta);

            // Wrap body content in a container for margins while keeping columns full-width
            if (!document.getElementById('inksync-container')) {
                var container = document.createElement('div');
                container.id = 'inksync-container';
                container.className = 'content-container';
                while(document.body.firstChild) {
                    container.appendChild(document.body.firstChild);
                }
                document.body.appendChild(container);
            }

            // Highlight Engine JS
            // Uses DOM Range + <mark> element wrapping.
            window.applyInksyncHighlight = function(colorHex) {
                var sel = window.getSelection();
                if (!sel || sel.rangeCount === 0 || sel.isCollapsed) return;

                var text = sel.toString().trim();
                if (!text) return;
                var range = sel.getRangeAt(0);
                var mark = document.createElement('mark');
                mark.className = 'inksync-highlight';
                mark.style.backgroundColor = colorHex || '#ffd700';
                mark.style.color = 'inherit';
                mark.style.borderRadius = '2px';
                mark.style.mixBlendMode = 'multiply';
                try {
                    range.surroundContents(mark);
                } catch(e) {
                    var frag = range.extractContents();
                    mark.appendChild(frag);
                    range.insertNode(mark);
                }
                sel.removeAllRanges();

                window.webkit.messageHandlers.highlightHandler.postMessage({
                    "text": text,
                    "html": "N/A"
                });
            };

            // Restore a previously saved highlight on chapter reload.
            window.restoreInksyncHighlight = function(textToFind, colorHex) {
                if (!textToFind) return;
                var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null, false);
                var node;
                while ((node = walker.nextNode())) {
                    var idx = node.nodeValue.indexOf(textToFind);
                    if (idx !== -1) {
                        try {
                            var range = document.createRange();
                            range.setStart(node, idx);
                            range.setEnd(node, idx + textToFind.length);
                            var mark = document.createElement('mark');
                            mark.className = 'inksync-highlight';
                            mark.style.backgroundColor = colorHex || '#ffd700';
                            mark.style.color = 'inherit';
                            mark.style.borderRadius = '2px';
                            range.surroundContents(mark);
                        } catch(e) {}
                        break;
                    }
                }
            };

            // ── Auto Scroll ──────────────────────────────────────────────────
            var scrollTimer = null;
            window.startInksyncAutoScroll = function(speed) {
                if (scrollTimer) clearInterval(scrollTimer);
                scrollTimer = setInterval(function() {
                    window.scrollBy(0, speed);
                }, 16);
            };
            window.stopInksyncAutoScroll = function() {
                if (scrollTimer) {
                    clearInterval(scrollTimer);
                    scrollTimer = null;
                }
            };

            // ── Navigation (swipe + tap) bridge ──────────────────────────────
            var _sx = 0, _sy = 0;
            document.addEventListener('touchstart', function(e) {
                _sx = e.changedTouches[0].clientX;
                _sy = e.changedTouches[0].clientY;
            }, {passive: true});
            document.addEventListener('touchend', function(e) {
                var dx = e.changedTouches[0].clientX - _sx;
                var dy = e.changedTouches[0].clientY - _sy;
                if (Math.abs(dx) < 8 && Math.abs(dy) < 8) {
                    // Tap: determine zone (30% left / 40% center / 30% right)
                    var x = e.changedTouches[0].clientX;
                    var w = window.innerWidth;
                    if (x < w * 0.30) {
                        window.webkit.messageHandlers.nav.postMessage('left');
                    } else if (x > w * 0.70) {
                        window.webkit.messageHandlers.nav.postMessage('right');
                    } else {
                        window.webkit.messageHandlers.nav.postMessage('center');
                    }
                } else if (Math.abs(dx) > 40 && Math.abs(dx) > Math.abs(dy)) {
                    // Horizontal swipe
                    if (dx < 0) {
                        var sv = document.scrollingElement || document.documentElement;
                        var atEnd = (sv.scrollLeft + window.innerWidth) >= sv.scrollWidth - 4;
                        if (atEnd) window.webkit.messageHandlers.nav.postMessage('next');
                    } else {
                        var sv2 = document.scrollingElement || document.documentElement;
                        if (sv2.scrollLeft <= 4) window.webkit.messageHandlers.nav.postMessage('prev');
                    }
                }
            }, {passive: true});
            """,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(userScript)

        let webView = HighlightableWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isPagingEnabled = prefs.paginationMode == EBookPaginationMode.paged.rawValue
        webView.scrollView.showsHorizontalScrollIndicator = false
        webView.scrollView.showsVerticalScrollIndicator = prefs.paginationMode == EBookPaginationMode.continuous.rawValue
        webView.scrollView.bounces = true
        webView.scrollView.alwaysBounceVertical = prefs.paginationMode == EBookPaginationMode.continuous.rawValue
        webView.scrollView.contentInsetAdjustmentBehavior = .never

        webView.onHighlightRequested = {
            webView.evaluateJavaScript("window.applyInksyncHighlight('#ffd700');")
        }

        return webView
    }

    /// Remove message handlers so UCC releases the WeakProxy and WKWebView can be deallocated.
    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "highlightHandler")
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "nav")
        uiView.navigationDelegate = nil
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let contentHash = htmlContent.hashValue
        let prefsState = "\(prefs.themeRaw)_\(prefs.fontSize)_\(prefs.fontFamily)_\(prefs.lineHeight)_\(prefs.letterSpacing)_\(prefs.wordSpacing)_\(prefs.textAlign)_\(prefs.paginationMode)_\(prefs.columnCount)_\(prefs.textMargin)_\(prefs.hyphenation)_\(prefs.autoScroll)_\(prefs.autoScrollSpeed)"
        let newHash = contentHash ^ prefsState.hashValue
        
        guard context.coordinator.lastContentHash != newHash else { return }
        
        // True when the chapter HTML itself changed (not just prefs)
        let contentChanged = contentHash != context.coordinator.lastContentOnlyHash
        context.coordinator.lastContentHash = newHash
        context.coordinator.lastContentOnlyHash = contentHash

        if contentChanged {
            // Swift-side HTML preprocessing: pre-inject CSS into head directly
            var html = htmlContent
            let css = buildReaderCSS(prefs: prefs)
            if let range = html.range(of: "</head>", options: .caseInsensitive) {
                html = html.replacingCharacters(in: range, with: css + "</head>")
            } else {
                html = css + html
            }
            webView.loadHTMLString(html, baseURL: baseUrl)
        } else {
            // Prefs-only change — inject updated CSS directly into the live DOM.
            injectLiveCSS(into: webView)
        }

        // Always sync native appearance
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isPagingEnabled = prefs.paginationMode == EBookPaginationMode.paged.rawValue
        webView.scrollView.showsVerticalScrollIndicator = prefs.paginationMode == EBookPaginationMode.continuous.rawValue
        webView.scrollView.alwaysBounceVertical = prefs.paginationMode == EBookPaginationMode.continuous.rawValue

        // Apply auto-scroll logic
        if prefs.autoScroll && prefs.paginationMode == EBookPaginationMode.continuous.rawValue {
            let speed = prefs.autoScrollSpeed * 1.5
            webView.evaluateJavaScript("window.startInksyncAutoScroll(\(speed));", completionHandler: nil)
        } else {
            webView.evaluateJavaScript("window.stopInksyncAutoScroll();", completionHandler: nil)
        }
    }

    /// Builds the full CSS + JS block as a pure string.
    private func buildReaderCSS(prefs: EBookPreferences) -> String {
        let isPaged = prefs.paginationMode == EBookPaginationMode.paged.rawValue

        let bgColor       = prefs.activeTheme.cssBackground
        let textColor     = prefs.activeTheme.cssText
        let linkColor     = prefs.activeTheme.cssLink
        let fontFamily    = prefs.fontFamily
        let fontSize      = Int(prefs.fontSize)
        let lineHeight    = String(format: "%.2f", prefs.lineHeight)
        let letterSpacing = String(format: "%.4fem", prefs.letterSpacing)
        let wordSpacing   = String(format: "%.4fem", prefs.wordSpacing)
        let hyphenCSS     = prefs.hyphenation ? "auto" : "manual"
        let textAlign     = prefs.textAlign
        let margin        = prefs.textMargin
        let paraSpace     = prefs.paragraphSpacing
        let paraIndent    = prefs.paragraphIndent

        let overflowCSS = isPaged
            ? "overflow: hidden !important;"
            : "overflow-x: hidden !important; overflow-y: auto !important;"
        let widthCSS = isPaged ? "" : "width: 100vw !important; overflow-x: hidden !important;"
        
        let deviceIsPad = UIDevice.current.userInterfaceIdiom == .pad
        let defaultColumns = deviceIsPad ? 2 : 1
        let cols = prefs.columnCount == 0 ? defaultColumns : prefs.columnCount
        
        let gap = cols == 2 ? 16 : Int(margin * 2)
        
        let pagedCSS = isPaged ? """
            column-count: \(cols) !important;
            column-gap: \(gap)px !important;
            column-fill: auto !important;
            column-rule: 1px solid rgba(128, 128, 128, 0.15) !important;
        """ : ""

        let maxSpreadWidthCSS = (isPaged && cols == 2) ? """
            max-width: calc(1.42 * (100vh - 120px) + \(gap)px) !important;
            margin-left: auto !important;
            margin-right: auto !important;
        """ : ""

        let paddingLeft = (isPaged && cols == 2) ? 0 : margin
        let paddingRight = (isPaged && cols == 2) ? 0 : margin

        return """
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no, viewport-fit=cover">
        <style id="__inksync_live__">
        @import url('https://fonts.googleapis.com/css2?family=Literata:ital,opsz,wght@0,7..72,200..900;1,7..72,200..900&family=Merriweather:ital,wght@0,300;0,400;0,700;0,900;1,300;1,400;1,700;1,900&family=Source+Serif+4:ital,opsz,wght@0,8..60,200..900;1,8..60,200..900&family=Atkinson+Hyperlegible:ital,wght@0,400;0,700;1,400;1,700&display=swap');
        @import url('https://cdn.jsdelivr.net/npm/open-dyslexic@1.0.3/open-dyslexic.css');
        *, *::before, *::after { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
        html {
            margin: 0 !important; padding: 0 !important;
            height: 100vh !important; width: 100vw !important;
            \(overflowCSS)
            background-color: \(bgColor) !important;
        }
        body {
            color: \(textColor) !important;
            font-family: \(fontFamily);
            font-size: \(fontSize)px;
            line-height: \(lineHeight);
            text-align: \(textAlign) !important;
            \(pagedCSS)
            \(maxSpreadWidthCSS)
            margin: 0 !important;
            height: 100vh !important;
            \(widthCSS)
            padding-top: 60px !important;
            padding-bottom: 60px !important;
            padding-left: \(paddingLeft)px !important;
            padding-right: \(paddingRight)px !important;
            box-sizing: border-box !important;
            word-wrap: break-word;
            -webkit-text-size-adjust: none;
            letter-spacing: \(letterSpacing) !important;
            word-spacing: \(wordSpacing) !important;
            -webkit-hyphens: \(hyphenCSS) !important;
            hyphens: \(hyphenCSS) !important;
        }
        p { margin-bottom: \(paraSpace)em !important; text-indent: \(paraIndent)em !important; }
        p, div, span, li, td, th, h1, h2, h3, h4, h5, h6 { color: \(textColor) !important; line-height: \(lineHeight); }
        img, svg, .page, .chunk-container { display: block !important; margin-left: auto !important; margin-right: auto !important; }
        img { max-width: 100%; height: auto; border-radius: 4px; object-fit: contain; max-height: calc(100vh - 120px); }
        a { color: \(linkColor) !important; }
        blockquote { border-left: 3px solid \(linkColor); margin-left: 0; padding-left: 16px; opacity: 0.85; }
        mark.inksync-highlight { background-color: #ffd700; color: inherit; border-radius: 2px; mix-blend-mode: multiply; -webkit-mix-blend-mode: multiply; padding: 0 1px; }
        </style>
        """
    }

    /// Injects a live CSS update into the existing WebView DOM — no reload required.
    private func injectLiveCSS(into webView: WKWebView) {
        let isPaged = prefs.paginationMode == EBookPaginationMode.paged.rawValue
        
        let bg            = prefs.activeTheme.cssBackground
        let fg            = prefs.activeTheme.cssText
        let link          = prefs.activeTheme.cssLink
        let ff            = prefs.fontFamily
        let fs            = Int(prefs.fontSize)
        let lh            = String(format: "%.2f", prefs.lineHeight)
        let ls            = String(format: "%.4fem", prefs.letterSpacing)
        let ws            = String(format: "%.4fem", prefs.wordSpacing)
        let hyph          = prefs.hyphenation ? "auto" : "manual"
        let align         = prefs.textAlign
        let margin        = prefs.textMargin
        
        let deviceIsPad = UIDevice.current.userInterfaceIdiom == .pad
        let defaultColumns = deviceIsPad ? 2 : 1
        let cols = prefs.columnCount == 0 ? defaultColumns : prefs.columnCount
        
        let gap = cols == 2 ? 16 : Int(margin * 2)
        
        let pagedCSS = isPaged ? """
            column-count: \(cols) !important;
            column-gap: \(gap)px !important;
            column-fill: auto !important;
            column-rule: 1px solid rgba(128, 128, 128, 0.15) !important;
        """ : ""

        let maxSpreadWidthCSS = (isPaged && cols == 2) ? """
            max-width: calc(1.42 * (100vh - 120px) + \(gap)px) !important;
            margin-left: auto !important;
            margin-right: auto !important;
        """ : ""

        let paddingLeft = (isPaged && cols == 2) ? 0 : margin
        let paddingRight = (isPaged && cols == 2) ? 0 : margin

        let css = """
        @import url('https://fonts.googleapis.com/css2?family=Literata:ital,opsz,wght@0,7..72,200..900;1,7..72,200..900&family=Merriweather:ital,wght@0,300;0,400;0,700;0,900;1,300;1,400;1,700;1,900&family=Source+Serif+4:ital,opsz,wght@0,8..60,200..900;1,8..60,200..900&family=Atkinson+Hyperlegible:ital,wght@0,400;0,700;1,400;1,700&display=swap');
        @import url('https://cdn.jsdelivr.net/npm/open-dyslexic@1.0.3/open-dyslexic.css');
        body {
            font-family: \(ff) !important;
            font-size: \(fs)px !important;
            line-height: \(lh) !important;
            background-color: \(bg) !important;
            color: \(fg) !important;
            letter-spacing: \(ls) !important;
            word-spacing: \(ws) !important;
            text-align: \(align) !important;
            -webkit-hyphens: \(hyph) !important;
            hyphens: \(hyph) !important;
            \(pagedCSS)
            \(maxSpreadWidthCSS)
            padding-left: \(paddingLeft)px !important;
            padding-right: \(paddingRight)px !important;
        }
        body, p, div, span, li, td, th, h1, h2, h3, h4, h5, h6 { color: \(fg) !important; }
        a { color: \(link) !important; }
        html { background-color: \(bg) !important; }
        """

        let js = """
        (function() {
            var el = document.getElementById('__inksync_live__');
            if (!el) { el = document.createElement('style'); el.id = '__inksync_live__'; document.head.appendChild(el); }
            el.textContent = \("`\(css.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "`", with: "\\`"))`");
        })();
        """
        webView.evaluateJavaScript(js)
    }
}




struct BookReaderEngine: View {
    let pdf: ConvertedPDF
    var onDismiss: () -> Void
    /// All books in the library — used to find the next volume in a series.
    var allBooks: [ConvertedPDF] = []
    
    @StateObject private var vm: BookReaderViewModel
    @State private var webViewReference: WKWebView?
    @State private var chromeVisible = false
    @State private var showAnnotations = false
    @State private var showTypographyHUD = false
    @State private var showTOC = false
    @State private var activeHighlightToEdit: SDAnnotation? = nil
    @ObservedObject private var prefs = EBookPreferences.shared
    @ObservedObject private var sleepTimer = SleepTimerManager.shared
    
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
    
    var body: some View {
        ZStack {
            Color(prefs.activeTheme.background).edgesIgnoringSafeArea(.all)
            
            if vm.isLoading {
                ProgressView("Unpacking EPUB...")
                    .foregroundColor(prefs.activeTheme.foreground(colorScheme: .light))
            } else {
                if !vm.chapterHtmlFiles.isEmpty {
                    let currentChapterURL = vm.chapterHtmlFiles[vm.currentChapterIndex]
                    EPUBWebView(htmlContent: $vm.currentChapterHTML, baseUrl: .constant(currentChapterURL), prefs: EBookPreferences.shared, onHighlightCreated: { selectedText, _ in

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
                        vm.loadChapter(index: max(0, vm.currentChapterIndex - 1))
                    })
                    .edgesIgnoringSafeArea(.horizontal)
                    
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
                pageText: vm.tocItems.indices.contains(vm.currentChapterIndex) ? vm.tocItems[vm.currentChapterIndex].label : "Ch. \(vm.currentChapterIndex + 1) / \(max(1, vm.chapterHtmlFiles.count))",
                isVisible: $chromeVisible,
                onBack: onDismiss,
                onBookmark: {
                    let bookmark = Annotation(pdfID: pdf.id, pageIndex: vm.currentChapterIndex, chapterTitle: "Chapter \(vm.currentChapterIndex + 1)", kind: .bookmark, createdAt: Date(), modifiedAt: Date())
                    AnnotationStore.shared.add(bookmark)
                },
                onSettingsToggle: {
                    withAnimation { showTypographyHUD = true }
                },
                onTOCToggle: { showTOC = true },
                onAnnotationsToggle: { showAnnotations = true },
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
                hasCopyAction: true,
                onCopyToggle: {
                    webViewReference?.evaluateJavaScript("document.body.innerText") { result, _ in
                        if let text = result as? String, !text.isEmpty {
                            UIPasteboard.general.string = text
                            showToastMessage("Chapter copied to clipboard")
                            Haptics.shared.playImpact(style: .light)
                        }
                    }
                }
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
            }
            // Apply per-book theme + typography profiles
            prefs.applyBookTheme(bookID: pdf.id.uuidString)
            prefs.applyBookTypography(bookID: pdf.id.uuidString)
            isReaderFocused = true
        }
        .onDisappear {
            ReaderProgressTracker.shared.update(ReadingProgress(
                pdfID: pdf.id, lastOpenedAt: Date(), currentPageIndex: vm.currentChapterIndex,
                currentChapterIndex: vm.currentChapterIndex, currentChapterOffset: 0.0,
                totalPagesRead: 1, completionFraction: Double(vm.currentChapterIndex + 1) / Double(max(1, vm.chapterHtmlFiles.count)),
                readingSessionDates: [Date()], estimatedMinutesRemaining: nil
            ))
        }
        .overlay { if prefs.showReadingRuler { ReadingRulerOverlay() } }
        .onChange(of: sleepTimer.didFire) { _, fired in
            if fired { onDismiss() }
        }
        .sheet(isPresented: $showAnnotations) {
            StudyNotebookView(bookID: pdf.id.uuidString, bookTitle: pdf.name, fileURL: pdf.url)
        }
        .sheet(item: $activeHighlightToEdit) { annotation in
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
            let width = webView.bounds.width
            let currentOffset = scroll.contentOffset.x
            let targetOffset = currentOffset + width
            let maxOffset = scroll.contentSize.width - width
            
            if targetOffset >= scroll.contentSize.width - 4 {
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
            let height = webView.bounds.height
            let currentOffset = scroll.contentOffset.y
            let targetOffset = currentOffset + height * 0.9
            let maxOffset = scroll.contentSize.height - height
            
            if targetOffset >= scroll.contentSize.height - 4 {
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
            let width = webView.bounds.width
            let currentOffset = scroll.contentOffset.x
            let targetOffset = currentOffset - width
            
            if targetOffset <= 4 {
                if vm.currentChapterIndex > 0 {
                    vm.loadChapter(index: vm.currentChapterIndex - 1)
                }
            } else {
                scroll.setContentOffset(CGPoint(x: max(0, targetOffset), y: 0), animated: true)
            }
        } else {
            let height = webView.bounds.height
            let currentOffset = scroll.contentOffset.y
            let targetOffset = currentOffset - height * 0.9
            
            if targetOffset <= 4 {
                if vm.currentChapterIndex > 0 {
                    vm.loadChapter(index: vm.currentChapterIndex - 1)
                }
            } else {
                scroll.setContentOffset(CGPoint(x: 0, y: max(0, targetOffset)), animated: true)
            }
        }
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




