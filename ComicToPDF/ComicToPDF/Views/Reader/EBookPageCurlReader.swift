import SwiftUI
import WebKit

// ============================================================
// MARK: - EBookPageCurlReader
// Native UIPageViewController(.pageCurl) for EPUB chapters.
// Each "page" is a WKWebView rendering a single CSS column
// with scrolling disabled — UIKit handles the curl animation.
// ============================================================
struct EBookPageCurlReader: UIViewControllerRepresentable {
    let spineItem: EBookMetadata.SpineItem
    let unzipDir: URL?
    @ObservedObject var prefs: EBookPreferences
    let colorScheme: ColorScheme

    @Binding var currentPage: Int
    var initialPage: Int
    @Binding var totalPages: Int

    var onNext: () -> Void
    var onPrev: () -> Void
    var onCenterTap: () -> Void
    var onHighlightCreated: ((String) -> Void)? = nil
    var pdfID: UUID? = nil
    var initialScrollFraction: Double = 0.0
    var onScrollFractionChanged: ((Double) -> Void)? = nil
    @Binding var webViewRef: WKWebView?
    var onFootnoteTapped: ((String) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pvc = UIPageViewController(
            transitionStyle: .pageCurl,
            navigationOrientation: .horizontal,
            options: nil
        )
        pvc.isDoubleSided = false
        pvc.dataSource = context.coordinator
        pvc.delegate = context.coordinator

        // Disable UIPageViewController's built-in single-tap (it conflicts with zone taps)
        for gesture in pvc.gestureRecognizers {
            if gesture is UITapGestureRecognizer {
                gesture.isEnabled = false
            }
        }

        let view = pvc.view!

        // Double tap (reserved for future use / cooperative gesture)
        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        doubleTap.cancelsTouchesInView = false
        view.addGestureRecognizer(doubleTap)

        // Single tap — handles left/center/right zones
        let singleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleSingleTap(_:))
        )
        singleTap.numberOfTapsRequired = 1
        singleTap.require(toFail: doubleTap)
        view.addGestureRecognizer(singleTap)

        context.coordinator.pageViewController = pvc

        // Start chapter load asynchronously
        context.coordinator.loadChapterAndPresent()

        return pvc
    }

    func updateUIViewController(_ uiViewController: UIPageViewController, context: Context) {
        let oldParent = context.coordinator.parent
        context.coordinator.parent = self

        // Guard against re-entrant updates during interactive curl gestures
        if context.coordinator.isTransitioning { return }

        // If spine item (chapter) changed, reload everything
        if oldParent.spineItem.href != self.spineItem.href {
            context.coordinator.loadChapterAndPresent()
            return
        }

        // If prefs changed (font size, theme, etc.), rebuild CSS and reload
        // This is handled by the coordinator's preference observation
    }

    // ============================================================
    // MARK: - Coordinator
    // ============================================================
    @MainActor
    class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: EBookPageCurlReader
        weak var pageViewController: UIPageViewController?
        var isTransitioning: Bool = false

        // Chapter state
        private var chapterHTML: String = ""
        private var chapterBaseURL: URL?
        private var styledCSS: String = ""
        private var computedTotalPages: Int = 1
        private var currentPageIndex: Int = 0
        private var hasLoadedInitialPage: Bool = false

        init(_ parent: EBookPageCurlReader) {
            self.parent = parent
            super.init()
        }

        // MARK: - Chapter Loading

        func loadChapterAndPresent() {
            hasLoadedInitialPage = false
            currentPageIndex = parent.initialPage

            Task { @MainActor in
                guard let dir = parent.unzipDir else { return }
                var contentURL = dir.appendingPathComponent(parent.spineItem.href)
                if !FileManager.default.fileExists(atPath: contentURL.path) {
                    if let decoded = parent.spineItem.href.removingPercentEncoding {
                        contentURL = dir.appendingPathComponent(decoded)
                    }
                }
                guard FileManager.default.fileExists(atPath: contentURL.path) else { return }

                self.chapterBaseURL = contentURL.deletingLastPathComponent()

                // Read raw HTML
                var rawHTML: String = ""
                var enc: String.Encoding = .utf8
                if let html = try? String(contentsOf: contentURL, usedEncoding: &enc) {
                    rawHTML = html
                } else if let data = try? Data(contentsOf: contentURL) {
                    rawHTML = String(data: data, encoding: .isoLatin1)
                           ?? String(data: data, encoding: .ascii)
                           ?? ""
                }

                // Clean via SwiftReadability
                let cleanArticle = SwiftReadability.parse(html: rawHTML)
                var html = cleanArticle.content

                // Wrap with viewport div
                html = EBookPageCurlReader.wrapHTMLBodyWithViewport(html)

                self.chapterHTML = html
                self.styledCSS = self.buildFullCSS()

                // Create the initial page VC — it will compute total pages on didFinish
                let vc = self.makePageViewController(for: self.currentPageIndex)
                self.pageViewController?.setViewControllers([vc], direction: .forward, animated: false)
            }
        }

        // MARK: - Page VC Factory

        func makePageViewController(for pageIndex: Int) -> EBookPageContentViewController {
            let vc = EBookPageContentViewController(
                pageIndex: pageIndex,
                chapterHTML: chapterHTML,
                css: styledCSS,
                baseURL: chapterBaseURL,
                coordinator: self
            )
            return vc
        }

        // MARK: - UIPageViewControllerDataSource

        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerBefore viewController: UIViewController
        ) -> UIViewController? {
            guard let contentVC = viewController as? EBookPageContentViewController else { return nil }
            let prevIndex = contentVC.pageIndex - 1
            if prevIndex < 0 {
                // At start of chapter — no more pages before this
                return nil
            }
            return makePageViewController(for: prevIndex)
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerAfter viewController: UIViewController
        ) -> UIViewController? {
            guard let contentVC = viewController as? EBookPageContentViewController else { return nil }
            let nextIndex = contentVC.pageIndex + 1
            if nextIndex >= computedTotalPages {
                // At end of chapter — no more pages after this
                return nil
            }
            return makePageViewController(for: nextIndex)
        }

        // MARK: - UIPageViewControllerDelegate

        func pageViewController(
            _ pageViewController: UIPageViewController,
            willTransitionTo pendingViewControllers: [UIViewController]
        ) {
            isTransitioning = true
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            didFinishAnimating finished: Bool,
            previousViewControllers: [UIViewController],
            transitionCompleted completed: Bool
        ) {
            isTransitioning = false
            guard let currentVC = pageViewController.viewControllers?.first as? EBookPageContentViewController else {
                return
            }

            let newPageIndex = currentVC.pageIndex
            if completed {
                currentPageIndex = newPageIndex
                parent.currentPage = newPageIndex
                reportScrollFraction()
            } else {
                // Snap-back guard: user cancelled the swipe gesture midway
                parent.currentPage = currentPageIndex
            }
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            spineLocationFor orientation: UIInterfaceOrientation
        ) -> UIPageViewController.SpineLocation {
            pageViewController.isDoubleSided = false
            return .min
        }

        // MARK: - Gesture Handlers

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            // Reserved for cooperative gesture handling
        }

        private var tapZoneStyle: TapZoneStyle {
            TapZoneStyle(rawValue: UserDefaults.standard.string(forKey: "tapZoneStyle") ?? "") ?? .classic
        }

        @objc func handleSingleTap(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view, let pvc = pageViewController else { return }
            let location = gesture.location(in: view)
            let width = view.bounds.width
            let zones = tapZoneStyle.zones

            if location.x < width * zones.leftEdge {
                turnBackward(pvc)
            } else if location.x > width * zones.rightEdge {
                turnForward(pvc)
            } else {
                parent.onCenterTap()
            }
        }

        private func turnForward(_ pvc: UIPageViewController) {
            guard !isTransitioning else { return }

            let nextIndex = currentPageIndex + 1
            if nextIndex < computedTotalPages {
                let vc = makePageViewController(for: nextIndex)
                HapticEngine.light()
                isTransitioning = true
                pvc.setViewControllers([vc], direction: .forward, animated: true) { [weak self] completed in
                    self?.isTransitioning = false
                    if completed {
                        DispatchQueue.main.async {
                            self?.currentPageIndex = nextIndex
                            self?.parent.currentPage = nextIndex
                            self?.reportScrollFraction()
                        }
                    }
                }
            } else {
                // Past last page of chapter → advance to next chapter
                parent.onNext()
            }
        }

        private func turnBackward(_ pvc: UIPageViewController) {
            guard !isTransitioning else { return }

            let prevIndex = currentPageIndex - 1
            if prevIndex >= 0 {
                let vc = makePageViewController(for: prevIndex)
                HapticEngine.light()
                isTransitioning = true
                pvc.setViewControllers([vc], direction: .reverse, animated: true) { [weak self] completed in
                    self?.isTransitioning = false
                    if completed {
                        DispatchQueue.main.async {
                            self?.currentPageIndex = prevIndex
                            self?.parent.currentPage = prevIndex
                            self?.reportScrollFraction()
                        }
                    }
                }
            } else {
                // Before first page of chapter → go to previous chapter
                parent.onPrev()
            }
        }

        // MARK: - Metrics

        func reportScrollFraction() {
            let fraction: Double
            if computedTotalPages > 1 {
                fraction = Double(currentPageIndex) / Double(computedTotalPages - 1)
            } else {
                fraction = 0
            }
            parent.onScrollFractionChanged?(fraction)
        }

        /// Called by `EBookPageContentViewController` when the WebView finishes loading
        /// and computes total page count from the CSS column layout.
        func didReceiveMetrics(totalPages: Int, fromPageIndex: Int) {
            let clamped = max(1, totalPages)
            if computedTotalPages != clamped {
                computedTotalPages = clamped
                parent.totalPages = clamped
            }

            // Handle initial page restoration (fractional scroll or saved page)
            if !hasLoadedInitialPage {
                hasLoadedInitialPage = true

                var targetPage = parent.initialPage
                // If we have a saved scroll fraction and the initial page is 0,
                // compute the target page from the fraction
                if targetPage == 0 && parent.initialScrollFraction > 0.01 && clamped > 1 {
                    targetPage = Int((parent.initialScrollFraction * Double(clamped - 1)).rounded())
                }

                // Handle "go to last page" sentinel (99999)
                if targetPage >= clamped {
                    targetPage = clamped - 1
                }

                if targetPage != fromPageIndex && targetPage > 0 {
                    let vc = makePageViewController(for: targetPage)
                    currentPageIndex = targetPage
                    parent.currentPage = targetPage
                    pageViewController?.setViewControllers([vc], direction: .forward, animated: false)
                } else {
                    currentPageIndex = fromPageIndex
                    parent.currentPage = fromPageIndex
                }
                reportScrollFraction()
            }
        }

        /// Called by `EBookPageContentViewController` when it creates a highlight
        func didCreateHighlight(_ text: String) {
            parent.onHighlightCreated?(text)
        }

        /// Called by `EBookPageContentViewController` when a footnote is tapped
        func didTapFootnote(_ text: String) {
            parent.onFootnoteTapped?(text)
        }

        /// Called by `EBookPageContentViewController` when the WKWebView is ready
        func didExposeWebView(_ webView: WKWebView) {
            parent.webViewRef = webView
        }

        // MARK: - CSS Construction

        func buildFullCSS() -> String {
            let prefs = parent.prefs
            let colorScheme = parent.colorScheme
            let size = UIScreen.main.bounds.size
            let cssContent = computeCSS(prefs: prefs, size: size)
            let pageScript = buildPageScript()

            return """
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no, viewport-fit=cover">
            <style id="__inksync_live__">
            \(cssContent)
            </style>
            <script>
            \(pageScript)
            </script>
            """
        }

        func computeCSS(prefs: EBookPreferences, size: CGSize) -> String {
            let bgColor = prefs.activeTheme.cssBackground
            let textColor = ColorContrastCalculator.getLegibleTextColor(textHex: prefs.activeTheme.cssText, bgHex: bgColor)
            let linkColor = prefs.activeTheme.cssLink
            let fontFamily = prefs.fontFamily
            let fontSize = Int(prefs.fontSize)
            let lineHeight = String(format: "%.2f", prefs.lineHeight)
            let letterSpacing = String(format: "%.4fem", prefs.letterSpacing)
            let wordSpacing = String(format: "%.4fem", prefs.wordSpacing)
            let textAlign = prefs.textAlign
            let margin = prefs.textMargin
            let paraSpace = prefs.paragraphSpacing
            let paraIndent = prefs.paragraphIndent
            let hyphenCSS = prefs.hyphenation ? "auto" : "manual"

            let renderWidth = size.width > 0 ? size.width : UIScreen.main.bounds.width
            let renderHeight = size.height > 0 ? size.height : UIScreen.main.bounds.height

            let isPad = UIDevice.current.userInterfaceIdiom == .pad
            let isLandscape = renderWidth > renderHeight
            let defaultColumns = isLandscape ? (prefs.autoLandscapeDualPage ? 2 : (isPad ? 2 : 1)) : 1
            let cols = prefs.columnCount == 0 ? defaultColumns : prefs.columnCount

            let m = max(20.0, margin)
            let gap = 2 * m
            let colWidth = max(100.0, (renderWidth / CGFloat(cols)) - gap)

            let pagedCSS = """
                column-width: \(colWidth)px !important;
                column-gap: \(gap)px !important;
                column-fill: auto !important;
                column-rule: none !important;
            """

            let paddingLeft = m
            let paddingRight = m

            return """
            @font-face { font-family: 'Literata'; src: local('Literata-Regular'); font-weight: normal; font-style: normal; }
            @font-face { font-family: 'Literata'; src: local('Literata-Bold'); font-weight: bold; font-style: normal; }
            @font-face { font-family: 'Literata'; src: local('Literata-Italic'); font-weight: normal; font-style: italic; }
            @font-face { font-family: 'Literata'; src: local('Literata-BoldItalic'); font-weight: bold; font-style: italic; }
            @font-face { font-family: 'Atkinson Hyperlegible'; src: local('AtkinsonHyperlegible-Regular'); font-weight: normal; font-style: normal; }
            @font-face { font-family: 'Atkinson Hyperlegible'; src: local('AtkinsonHyperlegible-Bold'); font-weight: bold; font-style: normal; }
            @font-face { font-family: 'Atkinson Hyperlegible'; src: local('AtkinsonHyperlegible-Italic'); font-weight: normal; font-style: italic; }
            @font-face { font-family: 'Atkinson Hyperlegible'; src: local('AtkinsonHyperlegible-BoldItalic'); font-weight: bold; font-style: italic; }
            @font-face { font-family: 'OpenDyslexic'; src: local('OpenDyslexic-Regular'); font-weight: normal; font-style: normal; }
            @font-face { font-family: 'OpenDyslexic'; src: local('OpenDyslexic-Bold'); font-weight: bold; font-style: normal; }
            @font-face { font-family: 'OpenDyslexic'; src: local('OpenDyslexic-Italic'); font-weight: normal; font-style: italic; }
            @font-face { font-family: 'OpenDyslexic'; src: local('OpenDyslexic-BoldItalic'); font-weight: bold; font-style: italic; }
            @font-face { font-family: 'Merriweather'; src: local('Merriweather-Regular'); font-weight: normal; font-style: normal; }
            @font-face { font-family: 'Merriweather'; src: local('Merriweather-Bold'); font-weight: bold; font-style: normal; }
            @font-face { font-family: 'Merriweather'; src: local('Merriweather-Italic'); font-weight: normal; font-style: italic; }
            @font-face { font-family: 'Merriweather'; src: local('Merriweather-BoldItalic'); font-weight: bold; font-style: italic; }
            @font-face { font-family: 'Source Serif 4'; src: local('SourceSerif4-Regular'); font-weight: normal; font-style: normal; }
            @font-face { font-family: 'Source Serif 4'; src: local('SourceSerif4-Regular'); font-weight: bold; font-style: normal; }
            @font-face { font-family: 'Source Serif 4'; src: local('SourceSerif4-Italic'); font-weight: normal; font-style: italic; }
            @font-face { font-family: 'Source Serif 4'; src: local('SourceSerif4-Italic'); font-weight: bold; font-style: italic; }
            *, *::before, *::after { box-sizing: border-box; -webkit-tap-highlight-color: transparent; scroll-behavior: auto !important; }
            html {
                margin: 0 !important; padding: 0 !important;
                width: 100% !important;
                height: 100% !important;
                column-width: auto !important;
                touch-action: none;
                scroll-behavior: auto !important;
                scroll-snap-type: none !important;
                background-color: \(bgColor) !important;
                overflow: hidden !important;
            }
            body {
                color: \(textColor) !important;
                font-family: \(fontFamily) !important;
                font-size: \(fontSize)px !important;
                line-height: \(lineHeight) !important;
                text-align: \(textAlign) !important;
                margin: 0 !important;
                width: 100% !important;
                height: 100% !important;
                overflow: hidden !important;
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
            }
            #inksync-viewport {
                margin: 0 !important;
                box-sizing: border-box !important;
                display: block !important;
                position: static !important;
                padding-top: 60px !important;
                padding-bottom: 60px !important;
                padding-left: \(paddingLeft)px !important;
                padding-right: \(paddingRight)px !important;
                width: auto !important;
                height: 100% !important;
                \(pagedCSS)
            }
            body, p, span, li, td, th, div, a { font-family: \(fontFamily) !important; }
            body, p, li, td, th, a { font-size: \(fontSize)px !important; }
            h1 { font-size: \(Double(fontSize) * 1.5)px !important; font-family: \(fontFamily) !important; }
            h2 { font-size: \(Double(fontSize) * 1.3)px !important; font-family: \(fontFamily) !important; }
            h3 { font-size: \(Double(fontSize) * 1.15)px !important; font-family: \(fontFamily) !important; }
            h4 { font-size: \(Double(fontSize) * 1.05)px !important; font-family: \(fontFamily) !important; }
            h5, h6 { font-size: \(Double(fontSize) * 1.0)px !important; font-family: \(fontFamily) !important; }
            body * { max-width: 100% !important; }
            #inksync-viewport, #inksync-viewport *:not(mark):not(.inksync-highlight):not(pre):not(code):not(table):not(tr):not(td):not(th) {
                background-color: transparent !important;
                background: transparent !important;
            }
            div, section, article, main, p, span, blockquote {
                max-height: none !important;
                overflow: visible !important;
            }
            div, section, article, main { height: auto !important; }
            div, section, article, main, p, blockquote {
                display: block !important;
                position: static !important;
                float: none !important;
            }
            div, section, article { column-count: auto !important; column-width: auto !important; }
            p { margin-bottom: \(paraSpace)em !important; text-indent: \(paraIndent)em !important; }
            p, div, span, li, td, th, h1, h2, h3, h4, h5, h6 { color: \(textColor) !important; line-height: \(lineHeight); }
            img, svg, .page, .chunk-container { display: block !important; margin-left: auto !important; margin-right: auto !important; }
            img { max-width: 100% !important; max-height: 100% !important; height: auto !important; border-radius: 4px; object-fit: contain !important; }
            img.gaiji, img[gaiji], img.inline-image { display: inline-block !important; vertical-align: middle !important; max-height: 1.2em !important; width: auto !important; margin: 0 0.1em !important; }
            pre, table, code { max-width: 100% !important; overflow-x: auto !important; word-wrap: break-word !important; white-space: pre-wrap !important; }
            a { color: \(linkColor) !important; }
            blockquote { border-left: 3px solid \(linkColor); margin-left: 0; padding-left: 16px; opacity: 0.85; }
            mark.inksync-highlight { background-color: #ffd700; color: inherit; border-radius: 2px; mix-blend-mode: multiply; -webkit-mix-blend-mode: multiply; padding: 0 1px; }
            \(fontSize > 28 ? """
            .dropcap, .drop-cap, span.first-letter {
                float: none !important; font-size: 1em !important; line-height: inherit !important;
                margin: 0 !important; font-weight: inherit !important;
            }
            """ : """
            .dropcap, .drop-cap, span.first-letter {
                float: left !important; font-size: 3.2em !important; line-height: 0.85em !important;
                margin-top: 0.1em !important; margin-right: 0.1em !important; margin-bottom: -0.1em !important;
                font-weight: bold !important;
            }
            """)
            """
        }

        func buildPageScript() -> String {
            """
            document.addEventListener('DOMContentLoaded', function() {
                document.querySelectorAll('[style]').forEach(function(el) {
                    el.style.removeProperty('background-color');
                    el.style.removeProperty('color');
                });
                var liveStyle = document.getElementById('__inksync_live__');
                if (liveStyle) { document.head.appendChild(liveStyle); }
                document.body.style.webkitUserSelect = 'text';
                document.body.style.userSelect = 'text';
            });

            var _targetPage = 0;
            var _totalPages = 1;

            function computeMetrics() {
                var sv = document.scrollingElement || document.documentElement;
                var pageStep = window.innerWidth;
                _totalPages = Math.max(1, Math.round(sv.scrollWidth / pageStep));
                return _totalPages;
            }

            function goToPage(page) {
                _targetPage = Math.max(0, Math.min(page, _totalPages - 1));
                var pageStep = window.innerWidth;
                var sv = document.scrollingElement || document.documentElement;
                sv.scrollLeft = _targetPage * pageStep;
            }
            window.goToInksyncPage = goToPage;

            window.onload = function() {
                setTimeout(function() {
                    computeMetrics();
                    goToPage(_targetPage);
                    window.webkit.messageHandlers.metrics.postMessage({ current: _targetPage, total: _totalPages });
                }, 80);
                setTimeout(function() {
                    computeMetrics();
                    window.webkit.messageHandlers.metrics.postMessage({ current: _targetPage, total: _totalPages });
                }, 400);
            };

            window.addEventListener('resize', function() {
                computeMetrics();
                goToPage(_targetPage);
            });

            // ── Highlight Engine ───────────────────────────────────────
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
                try { range.surroundContents(mark); } catch(e) {
                    var frag = range.extractContents(); mark.appendChild(frag); range.insertNode(mark);
                }
                sel.removeAllRanges();
                window.webkit.messageHandlers.highlight.postMessage(text);
            };

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

            window.updateInksyncHighlightColor = function(textToFind, colorHex) {
                var marks = document.querySelectorAll('mark.inksync-highlight');
                for (var i = 0; i < marks.length; i++) {
                    if (marks[i].textContent.trim() === textToFind.trim()) {
                        marks[i].style.backgroundColor = colorHex;
                        break;
                    }
                }
            };

            window.removeInksyncHighlight = function(textToFind) {
                var marks = document.querySelectorAll('mark.inksync-highlight');
                for (var i = 0; i < marks.length; i++) {
                    if (marks[i].textContent.trim() === textToFind.trim()) {
                        var parent = marks[i].parentNode;
                        while (marks[i].firstChild) { parent.insertBefore(marks[i].firstChild, marks[i]); }
                        parent.removeChild(marks[i]);
                        parent.normalize();
                        break;
                    }
                }
            };
            """
        }

        /// Builds the complete HTML document for a specific page index
        func buildPageHTML(for pageIndex: Int) -> String {
            var fullHTML = chapterHTML

            // Inject CSS + JS before </head>
            if let range = fullHTML.range(of: "</head>", options: .caseInsensitive) {
                fullHTML = fullHTML.replacingCharacters(in: range, with: styledCSS + "</head>")
            } else {
                fullHTML = styledCSS + fullHTML
            }

            // Inject page-targeting script just before </body>
            let pageTargetScript = """
            <script>
            _targetPage = \(pageIndex);
            </script>
            """
            if let range = fullHTML.range(of: "</body>", options: .caseInsensitive) {
                fullHTML = fullHTML.replacingCharacters(in: range, with: pageTargetScript + "</body>")
            } else {
                fullHTML += pageTargetScript
            }

            return fullHTML
        }

        /// Rebuilds CSS and reloads all visible pages (called when prefs change)
        func refreshCSS() {
            styledCSS = buildFullCSS()
            guard let pvc = pageViewController,
                  let currentVC = pvc.viewControllers?.first as? EBookPageContentViewController else { return }
            let vc = makePageViewController(for: currentVC.pageIndex)
            pvc.setViewControllers([vc], direction: .forward, animated: false)
        }
    }

    // MARK: - HTML Viewport Wrapper (identical to EBookWebReader)
    static func wrapHTMLBodyWithViewport(_ html: String) -> String {
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
}

// ============================================================
// MARK: - EBookPageContentViewController
// A single "page" in the UIPageViewController.
// Contains a WKWebView that renders the full chapter HTML
// scrolled to a specific column offset with all scrolling disabled.
// ============================================================
@MainActor
class EBookPageContentViewController: UIViewController, WKNavigationDelegate, WKScriptMessageHandler {
    let pageIndex: Int
    private let chapterHTML: String
    private let css: String
    private let baseURL: URL?
    private weak var coordinator: EBookPageCurlReader.Coordinator?
    private var webView: WKWebView?
    private var hasReportedMetrics: Bool = false

    init(
        pageIndex: Int,
        chapterHTML: String,
        css: String,
        baseURL: URL?,
        coordinator: EBookPageCurlReader.Coordinator
    ) {
        self.pageIndex = pageIndex
        self.chapterHTML = chapterHTML
        self.css = css
        self.baseURL = baseURL
        self.coordinator = coordinator
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let prefs = EBookPreferences.shared
        let bgColor = UIColor(hex: prefs.activeTheme.cssBackground) ?? .black
        view.backgroundColor = bgColor

        // Configure WKWebView
        let configuration = WKWebViewConfiguration()
        let controller = configuration.userContentController
        controller.add(self, name: "metrics")
        controller.add(self, name: "highlight")
        controller.add(self, name: "footnote")
        controller.add(self, name: "scrollFraction")

        let wv = HighlightableWebView(frame: view.bounds, configuration: configuration)
        wv.onHighlightRequested = { [weak self] in
            self?.handleHighlightRequest()
        }
        wv.navigationDelegate = self
        wv.isOpaque = false
        wv.backgroundColor = .clear
        wv.scrollView.backgroundColor = .clear

        // CRITICAL: Disable all scrolling — UIPageViewController handles page turns
        wv.scrollView.isScrollEnabled = false
        wv.scrollView.isPagingEnabled = false
        wv.scrollView.bounces = false
        wv.scrollView.alwaysBounceHorizontal = false
        wv.scrollView.alwaysBounceVertical = false
        wv.scrollView.showsHorizontalScrollIndicator = false
        wv.scrollView.showsVerticalScrollIndicator = false
        wv.scrollView.contentInsetAdjustmentBehavior = .never
        wv.scrollView.contentInset = .zero

        wv.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(wv)
        NSLayoutConstraint.activate([
            wv.topAnchor.constraint(equalTo: view.topAnchor),
            wv.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            wv.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            wv.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        self.webView = wv

        // Build full HTML with page-targeting script
        guard let coordinator = coordinator else { return }
        let fullHTML = coordinator.buildPageHTML(for: pageIndex)

        // Load the HTML
        if let base = baseURL {
            let tempName = "__inksync_curl_\(abs(fullHTML.hashValue)).html"
            let fileURL = base.appendingPathComponent(tempName)
            do {
                try fullHTML.write(to: fileURL, atomically: true, encoding: .utf8)
                wv.loadFileURL(fileURL, allowingReadAccessTo: base.deletingLastPathComponent())
            } catch {
                wv.loadHTMLString(fullHTML, baseURL: base)
            }
        } else {
            wv.loadHTMLString(fullHTML, baseURL: nil)
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Expose this WebView for search (window.find)
        coordinator?.didExposeWebView(webView)

        // Restore saved highlights
        restoreHighlights(in: webView)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        if url.scheme == "http" || url.scheme == "https" {
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
            return
        }

        if let fragment = url.fragment {
            // Try footnote extraction
            let js = """
            (function() {
                var el = document.getElementById('\(fragment)') || document.getElementsByName('\(fragment)')[0];
                if (el) {
                    var text = el.innerText || el.textContent;
                    if (text && text.trim().length > 0 && text.trim().length < 1000) {
                        window.webkit.messageHandlers.footnote.postMessage({ "id": '\(fragment)', "text": text.trim() });
                    }
                }
            })();
            """
            webView.evaluateJavaScript(js, completionHandler: nil)
            decisionHandler(.cancel)
            return
        }

        decisionHandler(.allow)
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "metrics", let body = message.body as? [String: Int] {
            let total = body["total"] ?? 1
            if !hasReportedMetrics {
                hasReportedMetrics = true
                coordinator?.didReceiveMetrics(totalPages: total, fromPageIndex: pageIndex)
            }
        } else if message.name == "highlight", let text = message.body as? String, !text.isEmpty {
            coordinator?.didCreateHighlight(text)
        } else if message.name == "footnote", let body = message.body as? [String: String], let text = body["text"] {
            coordinator?.didTapFootnote(text)
        }
    }

    // MARK: - Highlight Support

    private func handleHighlightRequest() {
        guard let wv = webView else { return }
        wv.evaluateJavaScript("window.getSelection().toString()") { [weak self] result, _ in
            if let text = result as? String, !text.isEmpty {
                self?.coordinator?.didCreateHighlight(text)
            }
        }
    }

    private func restoreHighlights(in webView: WKWebView) {
        guard let pdfID = coordinator?.parent.pdfID else { return }
        let annotations = AnnotationStore.shared.annotations(for: pdfID)
            .filter { $0.kind == .highlight && $0.chapterTitle == coordinator?.parent.spineItem.label }
        for ann in annotations {
            guard let text = ann.selectedText, let color = ann.colorHex else { continue }
            let safeText = text
                .replacingOccurrences(of: "`", with: "\\`")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: " ")
            let js = "window.restoreInksyncHighlight(`\(safeText)`, '\(color)');"
            webView.evaluateJavaScript(js)
        }
    }

    // MARK: - Cleanup

    deinit {
        // Remove message handlers to prevent retain cycles
        webView?.configuration.userContentController.removeAllScriptMessageHandlers()
        webView?.navigationDelegate = nil
    }
}


