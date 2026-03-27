import SwiftUI
import WebKit
import ZIPFoundation

// MARK: - EBookReaderView
struct EBookReaderView: View {
    let fileURL: URL
        let title: String
    var onExit: (() -> Void)? = nil
    
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var prefs = EBookPreferences.shared
    @Environment(\.colorScheme) var colorScheme
    @State private var showingSettingsPanel = false
    
    // Preferences — shared across all books


    
        // Per-book progress key: fingerprinted by filename
    private var progressKey: String { "ebook_progress_\(fileURL.lastPathComponent.hashValue)" }
    private var pageKey: String { "ebook_page_\(fileURL.lastPathComponent.hashValue)" }

    
    // State
    @State private var metadata: EBookMetadata?
    @State private var currentIndex: Int = 0
    @State private var isLoading = true
    @State private var showChapterList = false
    @State private var showHUD = true
    @State private var errorMessage: String?
    @State private var unzipDir: URL?
    
    // Page state matching current chapter
    @State private var chapterPage: Int = 0
    @State private var chapterTotalPages: Int = 1
    

    private var totalChapters: Int { metadata?.spineItems.count ?? 1 }
    private var progressFraction: Double {
        guard totalChapters > 1 else { return 0 }
        return Double(currentIndex) / Double(totalChapters - 1)
    }
    
    var body: some View {
        ZStack(alignment: .top) {
            // Background bleeds into status bar
            prefs.activeTheme.background(colorScheme: colorScheme).ignoresSafeArea()
            
            VStack(spacing: 0) {
                // ── Reading Progress Bar ──────────────────────────────────
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(prefs.activeTheme.foreground(colorScheme: colorScheme).opacity(0.08)).frame(height: 2)
                        Rectangle()
                            .fill(LinearGradient(colors: [Color(hex: "#7B5EA7"), Color(hex: "#B39DDB")],
                                                 startPoint: .leading, endPoint: .trailing))
                            .frame(width: geo.size.width * progressFraction, height: 2)
                            .animation(.spring(response: 0.4), value: progressFraction)
                    }
                }
                .frame(height: 2)
                
                // ── Main Reader ───────────────────────────────────────────
                Group {
                    if isLoading {
                        readerLoadingView
                    } else if let err = errorMessage {
                        readerErrorView(err)
                    } else if let meta = metadata, !meta.spineItems.isEmpty {
                                                                        EBookWebReader(
                            spineItem:  meta.spineItems[currentIndex],
                            unzipDir:   unzipDir,
                            prefs:      prefs,
                            colorScheme: colorScheme,
                            currentPage: $chapterPage,
                            initialPage: chapterPage,
                            totalPages: $chapterTotalPages,
                            onNext: nextChapter,
                            onPrev: prevChapter,
                            onCenterTap: { withAnimation(.easeInOut(duration: 0.2)) { showHUD.toggle() } }
                        )
                        .transition(.opacity)
                        .animation(.easeInOut(duration: 0.2), value: currentIndex)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            
            // ── HUD Overlays (tap-to-show UI) ─────────────────────────────
            if showChapterList { chapterDrawer }
        }
        .navigationBarHidden(true)
        .statusBarHidden(false)
        
        .overlay(alignment: .top) {
            if showHUD {
                topBar
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottom) {
            if showHUD {
                bottomBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
                .sheet(isPresented: $showingSettingsPanel) {
            EBookSettingsPanel()
                .presentationDetents([.medium, .large])
        }
        .task { await loadBook() }
        .onDisappear { cleanup(); saveProgress() }
    }
    
    // MARK: - Top Bar
    @ViewBuilder private var topBar: some View {
        HStack(spacing: 16) {
            Button { if let onExit = onExit { onExit() } else { dismiss() } } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(prefs.activeTheme.foreground(colorScheme: colorScheme))
                    .padding(10)
                    .background(prefs.activeTheme.foreground(colorScheme: colorScheme).opacity(0.08))
                    .clipShape(Circle())
            }
            
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline).lineLimit(1).foregroundStyle(prefs.activeTheme.foreground(colorScheme: colorScheme))
                if let chapter = metadata?.spineItems[safe: currentIndex] {
                    Text(chapter.label).font(.caption).foregroundStyle(prefs.activeTheme.foreground(colorScheme: colorScheme).opacity(0.55)).lineLimit(1)
                }
            }
            
            Spacer()
            
                        Button { showingSettingsPanel.toggle(); showChapterList = false } label: {
                Image(systemName: "textformat.size")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(prefs.activeTheme.foreground(colorScheme: colorScheme))
                    .padding(10)
                    .background(prefs.activeTheme.foreground(colorScheme: colorScheme).opacity(0.08))
                    .clipShape(Circle())
            }
            
            Button { withAnimation(.spring()) { showChapterList.toggle() } } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(prefs.activeTheme.foreground(colorScheme: colorScheme))
                    .padding(10)
                    .background(showChapterList ? prefs.activeTheme.foreground(colorScheme: colorScheme).opacity(0.15) : prefs.activeTheme.foreground(colorScheme: colorScheme).opacity(0.08))
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 50)
        .padding(.bottom, 12)
        .background(
            prefs.activeTheme.background(colorScheme: colorScheme).opacity(0.92)
                .background(.ultraThinMaterial.opacity(0.3))
                .ignoresSafeArea(edges: .top)
        )
    }
    
    // MARK: - Bottom Bar
    @ViewBuilder private var bottomBar: some View {
        HStack(spacing: 20) {
            Button { prevChapter() } label: {
                Image(systemName: "chevron.left.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(currentIndex == 0 ? prefs.activeTheme.foreground(colorScheme: colorScheme).opacity(0.2) : Color(hex: "#7B5EA7"))
            }
            .disabled(currentIndex == 0)
            
            VStack(spacing: 2) {
                Text("Page \(chapterPage + 1) of \(chapterTotalPages)")
                    .font(.caption.monospacedDigit().bold())
                    .foregroundStyle(prefs.activeTheme.foreground(colorScheme: colorScheme))
                if totalChapters > 1 {
                    Text("Chapter \(currentIndex + 1) / \(totalChapters)")
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(prefs.activeTheme.foreground(colorScheme: colorScheme).opacity(0.5))
                }
            }
            .frame(minWidth: 90)
            
            Button { nextChapter() } label: {
                Image(systemName: "chevron.right.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(currentIndex >= totalChapters - 1 ? prefs.activeTheme.foreground(colorScheme: colorScheme).opacity(0.2) : Color(hex: "#7B5EA7"))
            }
            .disabled(currentIndex >= totalChapters - 1)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 24)
        .background(
            prefs.activeTheme.background(colorScheme: colorScheme).opacity(0.92)
                .background(.ultraThinMaterial.opacity(0.3))
                .ignoresSafeArea(edges: .bottom)
        )
    }
    
    // MARK: - Chapter Drawer
    @ViewBuilder private var chapterDrawer: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 72) // clear under top bar
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array((metadata?.spineItems ?? []).enumerated()), id: \.offset) { idx, chapter in
                            Button {
                                withAnimation(.spring()) { currentIndex = idx; showChapterList = false }
                                saveProgress()
                            } label: {
                                HStack(spacing: 12) {
                                    if idx == currentIndex {
                                        RoundedRectangle(cornerRadius: 2)
                                            .fill(Color(hex: "#7B5EA7"))
                                            .frame(width: 3, height: 22)
                                    } else {
                                        Color.clear.frame(width: 3, height: 22)
                                    }
                                    Text(chapter.label)
                                        .font(.subheadline)
                                        .fontWeight(idx == currentIndex ? .semibold : .regular)
                                        .foregroundStyle(idx == currentIndex ? Color(hex: "#7B5EA7") : prefs.activeTheme.foreground(colorScheme: colorScheme))
                                    Spacer()
                                }
                                .padding(.horizontal, 16).padding(.vertical, 13)
                                .background(idx == currentIndex ? Color(hex: "#7B5EA7").opacity(0.08) : Color.clear)
                            }
                            .buttonStyle(.plain)
                            .id(idx)
                            Divider().opacity(0.3)
                        }
                    }
                }
                .sheet(isPresented: $showingSettingsPanel) {
            EBookSettingsPanel().presentationDetents([.medium, .large])
        }
        .onAppear { proxy.scrollTo(currentIndex, anchor: .center) }
            }
            .frame(maxWidth: 320)
            .background(prefs.activeTheme.background(colorScheme: colorScheme).opacity(0.97))
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.15), radius: 20, x: 0, y: 8)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.horizontal, 16)
            Spacer()
        }
        .transition(.asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal:   .move(edge: .trailing).combined(with: .opacity)
        ))
    }
    
    // MARK: - Loading & Error States
    private var readerLoadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(Color(hex: "#7B5EA7"))
                .scaleEffect(1.4)
            Text("Opening Book…")
                .font(.subheadline)
                .foregroundStyle(prefs.activeTheme.foreground(colorScheme: colorScheme).opacity(0.6))
        }
    }
    
    private func readerErrorView(_ msg: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.orange)
            Text("Couldn't Open Book").font(.headline).foregroundStyle(prefs.activeTheme.foreground(colorScheme: colorScheme))
            Text(msg).font(.subheadline).foregroundStyle(prefs.activeTheme.foreground(colorScheme: colorScheme).opacity(0.6))
                .multilineTextAlignment(.center).padding(.horizontal, 40)
        }
    }
    
    // MARK: - Navigation
        private func nextChapter() {
        guard currentIndex < totalChapters - 1 else { return }
        chapterPage = 0 // Start next chapter at page 0
        withAnimation(.easeInOut(duration: 0.18)) { currentIndex += 1 }
        saveProgress()
    }
    
    private func prevChapter() {
        guard currentIndex > 0 else { return }
        chapterPage = 99999 // Send a signal to JS to jump to the END of the previous chapter
        withAnimation(.easeInOut(duration: 0.18)) { currentIndex -= 1 }
        saveProgress()
    }
    
    // MARK: - Load & Cleanup
    private func loadBook() async {
        Logger.shared.log("EBookReader: opening \(fileURL.lastPathComponent)", category: "EBook")
        
        // Restore saved progress
                let saved = UserDefaults.standard.integer(forKey: progressKey)
        let savedPage = UserDefaults.standard.integer(forKey: pageKey)
        
        // Parse metadata (streaming OPF, no full unzip)
        let parsed = await EBookParser.shared.parse(epub: fileURL)
        
        // Unzip for content serving (WKWebView needs local file access)
        let tempID = UUID().uuidString
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("EBookReader_\(tempID)")
        
        do {
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            try FileManager.default.unzipItem(at: fileURL, to: dest)
        } catch {
            await MainActor.run {
                errorMessage = "Could not extract book: \(error.localizedDescription)"
                isLoading = false
            }
            Logger.shared.log("EBookReader: extraction failed — \(error.localizedDescription)", category: "EBook", type: .error)
            return
        }
        
        await MainActor.run {
            self.unzipDir = dest
            if let parsed = parsed, !parsed.spineItems.isEmpty {
                self.metadata = parsed
                // Restore saved chapter (clamp to valid range)
                let total = parsed.spineItems.count
                                self.currentIndex = min(saved, max(0, total - 1))
                if saved == self.currentIndex {
                    self.chapterPage = savedPage
                } else {
                    self.chapterPage = 0
                }
            } else {
                self.errorMessage = "This EPUB file seems to be corrupted or missing a valid reading spine."
            }
            self.isLoading = false
        }
    }
    
        private func saveProgress() {
        UserDefaults.standard.set(currentIndex, forKey: progressKey)
        UserDefaults.standard.set(chapterPage, forKey: pageKey)
    }
    
    private func cleanup() {
        if let dir = unzipDir {
            try? FileManager.default.removeItem(at: dir)
        }
    }
}

// MARK: - EBookWebReader (single reused WKWebView)
struct EBookWebReader: UIViewRepresentable {
    let spineItem:  EBookMetadata.SpineItem
    let unzipDir:   URL?
    @ObservedObject var prefs: EBookPreferences
        let colorScheme: ColorScheme
    @Binding var currentPage: Int
    var initialPage: Int
    @Binding var totalPages: Int
    var onNext: () -> Void
    var onPrev: () -> Void
    var onCenterTap: () -> Void
    
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "nav")
        config.userContentController.add(context.coordinator, name: "metrics")
        
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.isOpaque = false
        wv.backgroundColor = .clear
        wv.scrollView.backgroundColor = .clear
        wv.scrollView.contentInsetAdjustmentBehavior = .always
        wv.navigationDelegate = context.coordinator
        return wv
    }
    
    func updateUIView(_ wv: WKWebView, context: Context) {
        guard let dir = unzipDir else { return }
        
        var contentURL = dir.appendingPathComponent(spineItem.href)
        if !FileManager.default.fileExists(atPath: contentURL.path) {
            if let decoded = spineItem.href.removingPercentEncoding {
                contentURL = dir.appendingPathComponent(decoded)
            }
        }
        guard FileManager.default.fileExists(atPath: contentURL.path) else { return }
        
        // Only reload if the chapter changed
                // Re-render trigger on ANY pref change
        let currentStateHash = "\(prefs.themeRaw)_\(prefs.fontSize)_\(prefs.fontFamily)_\(prefs.lineHeight)_\(prefs.textMargin)_\(prefs.paragraphSpacing)_\(prefs.paragraphIndent)_\(prefs.paginationMode)_\(prefs.textAlign)"
        
        if context.coordinator.lastLoadedHref == spineItem.href && context.coordinator.lastTheme == currentStateHash { return }
        context.coordinator.lastLoadedHref = spineItem.href
        context.coordinator.lastTheme = currentStateHash
        
        // Read HTML
        var rawHTML: String?
        var usedEncoding: String.Encoding = .utf8
        if let html = try? String(contentsOf: contentURL, usedEncoding: &usedEncoding) {
            rawHTML = html
        } else if let data = try? Data(contentsOf: contentURL) {
            if let latin = String(data: data, encoding: .isoLatin1) { rawHTML = latin }
            else if let ascii = String(data: data, encoding: .ascii) { rawHTML = ascii }
        }
        
        if var html = rawHTML {
            // Strip any legacy charset declarations to prevent WKWebView from mangling our UTF-8 file
            let pattern = "<meta[^>]*charset[^>]*>"
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                html = regex.stringByReplacingMatches(in: html, range: NSRange(html.startIndex..., in: html), withTemplate: "")
            }
            
                        let styledHTML = injectReaderCSS(into: html, prefs: prefs, colorScheme: colorScheme, initialPage: initialPage)
            
            // Write to a temporary file in the same directory to grant WKWebView `allowingReadAccessTo` privileges for images and CSS.
            let injectedURL = contentURL.deletingPathExtension().appendingPathExtension("injected.html")
            try? styledHTML.write(to: injectedURL, atomically: true, encoding: .utf8)
            wv.loadFileURL(injectedURL, allowingReadAccessTo: dir)
        } else {
            wv.loadFileURL(contentURL, allowingReadAccessTo: dir)
        }
    }
        private func injectReaderCSS(into html: String, prefs: EBookPreferences, colorScheme: ColorScheme, initialPage: Int) -> String {
        let isPaged = prefs.paginationMode == EBookPaginationMode.paged.rawValue
        _ = isPaged ? """
            /* Paged */
            column-width: calc(100vw - \\(prefs.textMargin * 2)px) !important;
            column-gap: \\(prefs.textMargin * 2)px !important;
            column-fill: auto !important;
        """ : ""

        let css = """
                <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no, viewport-fit=cover">
        <style id="__inksync_reader__">
        *, *::before, *::after { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
                html {
            margin: 0 !important;
            padding: 0 !important;
            height: 100vh !important;
            width: 100vw !important;
            \\(isPaged ? "overflow: hidden !important;" : "overflow-x: hidden !important; overflow-y: auto !important;")
            background-color: \\(prefs.activeTheme.cssBackground(colorScheme: colorScheme)) !important;
        }
        body {
            color: \\(prefs.activeTheme.cssText(colorScheme: colorScheme)) !important;
            font-family: \\(prefs.fontFamily);
            font-size: \\(Int(prefs.fontSize))px;
            line-height: \\(String(format: "%.1f", prefs.lineHeight));
            text-align: \\(prefs.textAlign) !important;
            
            \\(pagedCSS)
            
            margin: 0 !important;
            height: 100vh !important;
            \\(isPaged ? "" : "width: 100vw !important; overflow-x: hidden !important;")
            padding-top: 60px !important;
            padding-bottom: 60px !important;
            padding-left: \\(prefs.textMargin)px !important;
            padding-right: \\(prefs.textMargin)px !important;
            box-sizing: border-box !important;
            word-wrap: break-word;
            -webkit-text-size-adjust: none;
            
            /* Premium Typography */
            -webkit-hyphens: auto !important;
            hyphens: auto !important;
        }
        p { margin-bottom: \\(prefs.paragraphSpacing)em !important; text-indent: \\(prefs.paragraphIndent)em !important; }
        p, div, span, li, td, th, h1, h2, h3, h4, h5, h6 { color: \\(prefs.activeTheme.cssText(colorScheme: colorScheme)) !important; line-height: 1.3; }
        img { max-width: 100%; height: auto; border-radius: 4px; object-fit: contain; max-height: calc(100vh - 120px); }
        a { color: \\(prefs.activeTheme.cssLink(colorScheme: colorScheme)) !important; }
        blockquote { border-left: 3px solid \\(prefs.activeTheme.cssLink(colorScheme: colorScheme)); margin-left: 0; padding-left: 16px; opacity: 0.85; }
        </style>
        <script>
        document.addEventListener('DOMContentLoaded', function() {
            document.querySelectorAll('[style]').forEach(function(el) {
                el.style.removeProperty('background-color');
                el.style.removeProperty('color');
            });
        });
        
                var _currentPage = \(initialPage);
        var _totalPages = 1;

        function updateMetrics() {
            // Document element scrollWidth reliably accounts for WebKit column flows
            _totalPages = Math.max(1, Math.ceil(document.documentElement.scrollWidth / window.innerWidth));
            window.webkit.messageHandlers.metrics.postMessage({ current: _currentPage, total: _totalPages });
        }

        function goToPage(page) {
            _currentPage = Math.max(0, Math.min(page, _totalPages - 1));
            window.scrollTo({ left: _currentPage * window.innerWidth, behavior: 'instant' });
            updateMetrics();
        }

        window.onload = function() { setTimeout(updateMetrics, 100); };
        window.addEventListener('resize', function() {
            updateMetrics();
            goToPage(_currentPage);
        });

        // Swipe & Tap engine
        var _sx = 0;
        document.addEventListener('touchstart', function(e) { _sx = e.changedTouches[0].clientX; }, {passive:true});
        document.addEventListener('touchend', function(e) {
            var dx = e.changedTouches[0].clientX - _sx;
            if (dx < -40) { // Swipe Left (Next)
                if (_currentPage < _totalPages - 1) goToPage(_currentPage + 1);
                else window.webkit.messageHandlers.nav.postMessage('next');
            } else if (dx > 40) { // Swipe Right (Prev)
                if (_currentPage > 0) goToPage(_currentPage - 1);
                else window.webkit.messageHandlers.nav.postMessage('prev');
            }
        }, {passive:true});

        document.addEventListener('click', function(e) {
            // Ignore clicks on links
            if (e.target.tagName.toLowerCase() === 'a') return;
            var x = e.clientX;
            var w = window.innerWidth;
            if (x < w * 0.35) { // Left 35%
                if (_currentPage > 0) goToPage(_currentPage - 1);
                else window.webkit.messageHandlers.nav.postMessage('prev');
            } else if (x > w * 0.65) { // Right 35%
                if (_currentPage < _totalPages - 1) goToPage(_currentPage + 1);
                else window.webkit.messageHandlers.nav.postMessage('next');
            } else {
                window.webkit.messageHandlers.nav.postMessage('center');
            }
        });

        // Keyboard Navigation (Bluetooth, Smart Keyboard, etc)
        document.addEventListener('keydown', function(e) {
            if (e.key === 'ArrowRight' || e.key === 'Space') {
                if (_currentPage < _totalPages - 1) goToPage(_currentPage + 1);
                else window.webkit.messageHandlers.nav.postMessage('next');
                e.preventDefault();
            } else if (e.key === 'ArrowLeft') {
                if (_currentPage > 0) goToPage(_currentPage - 1);
                else window.webkit.messageHandlers.nav.postMessage('prev');
                e.preventDefault();
            }
        });
        </script>
        """
        
        if let range = html.range(of: "</head>", options: .caseInsensitive) {
            return html.replacingCharacters(in: range, with: css + "</head>")
        }
        return css + html
    }
    
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: EBookWebReader
        var lastLoadedHref: String = ""
        var lastTheme: String = ""
        var lastFontSize: Double = 0
        
        init(_ parent: EBookWebReader) { self.parent = parent }
        
        func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "nav", let body = message.body as? String {
                DispatchQueue.main.async {
                    if body == "next" { self.parent.onNext() }
                    else if body == "prev" { self.parent.onPrev() }
                    else if body == "center" { self.parent.onCenterTap() }
                }
            } else if message.name == "metrics", let body = message.body as? [String: Int] {
                DispatchQueue.main.async {
                    self.parent.currentPage = body["current"] ?? 0
                    self.parent.totalPages = body["total"] ?? 1
                }
            }
        }
        
                // Intercept navigation for Footnotes, External links, and Chapters
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated {
                if let url = action.request.url {
                    if url.scheme == "http" || url.scheme == "https" {
                        UIApplication.shared.open(url)
                    } else if let fragment = url.fragment {
                        // Internal anchor (e.g., footnote)
                        let js = """
                        var el = document.getElementById('\(fragment)') || document.getElementsByName('\(fragment)')[0];
                        if (el) {
                            var targetPage = Math.floor(el.getBoundingClientRect().left / window.innerWidth) + _currentPage;
                            goToPage(Math.max(0, targetPage));
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
    }
}

// MARK: - Safe array subscript
extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}












