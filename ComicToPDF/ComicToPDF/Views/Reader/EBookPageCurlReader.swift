import SwiftUI
import WebKit

// ============================================================
// MARK: - EBookPageCurlReader
// Native UIPageViewController(.pageCurl) for EPUB chapters.
// Uses a primary WKWebView for chapter layout & interaction,
// and pre-rendered column snapshots for 100% instant 3D curling
// with zero blank pages, zero text sliding, and zero loading lag.
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
        pvc.isDoubleSided = true
        pvc.dataSource = context.coordinator
        pvc.delegate = context.coordinator

        // Disable UIPageViewController's built-in single-tap (it conflicts with zone taps)
        for gesture in pvc.gestureRecognizers {
            if gesture is UITapGestureRecognizer {
                gesture.isEnabled = false
            }
        }

        let view = pvc.view!

        // Double tap
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

        let initialSpread = context.coordinator.spreadViewControllers(for: initialPage)
        pvc.setViewControllers(initialSpread, direction: .forward, animated: false)

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

        // If typography / theme preferences changed, update live styles in WKWebView
        if oldParent.prefs.fontSize != self.prefs.fontSize ||
           oldParent.prefs.fontFamily != self.prefs.fontFamily ||
           oldParent.prefs.activeTheme.id != self.prefs.activeTheme.id ||
           oldParent.prefs.lineHeight != self.prefs.lineHeight ||
           oldParent.prefs.letterSpacing != self.prefs.letterSpacing ||
           oldParent.prefs.wordSpacing != self.prefs.wordSpacing ||
           oldParent.prefs.textAlign != self.prefs.textAlign ||
           oldParent.prefs.textMargin != self.prefs.textMargin ||
           oldParent.prefs.paragraphSpacing != self.prefs.paragraphSpacing ||
           oldParent.prefs.paragraphIndent != self.prefs.paragraphIndent ||
           oldParent.prefs.hyphenation != self.prefs.hyphenation {
            context.coordinator.updateLiveStyles()
        }

        let targetIndex = currentPage

        // Clear gesture completion marker if set
        if context.coordinator.lastCompletedControllerIndex != nil {
            let lastCompleted = context.coordinator.lastCompletedControllerIndex
            context.coordinator.lastCompletedControllerIndex = nil
            if lastCompleted == targetIndex {
                return // Gesture completed this exact page turn — do NOT re-trigger setViewControllers!
            }
        }

        if let currentVC = uiViewController.viewControllers?.first as? EBookPageContentViewController {
            if currentVC.pageIndex == targetIndex && context.coordinator.currentPageIndex == targetIndex {
                return // Target page is ALREADY displayed on screen — do NOT touch setViewControllers!
            }

            context.coordinator.currentPageIndex = targetIndex
            context.coordinator.primaryWebView?.evaluateJavaScript("if(window.goToInksyncPage) window.goToInksyncPage(\(targetIndex));")

            let vcs = context.coordinator.spreadViewControllers(for: targetIndex)
            let isForward = targetIndex >= currentVC.pageIndex
            let direction: UIPageViewController.NavigationDirection = isForward ? .forward : .reverse
            uiViewController.setViewControllers(vcs, direction: direction, animated: false) { _ in
                if let targetVC = vcs.first as? EBookPageContentViewController {
                    targetVC.mountPrimaryWebView(context.coordinator.primaryWebView)
                }
            }
        }
    }

    static func dismantleUIView(_ uiViewController: UIPageViewController, coordinator: Coordinator) {
        coordinator.cleanup()
    }
}

extension EBookPageCurlReader {
    // ============================================================
    // MARK: - Coordinator
    // ============================================================
    @MainActor
    class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate, WKNavigationDelegate, WKScriptMessageHandler, UIGestureRecognizerDelegate {
        var parent: EBookPageCurlReader
        weak var pageViewController: UIPageViewController?
        var isTransitioning: Bool = false
        var lastCompletedControllerIndex: Int? = nil

        // Chapter & Primary WebEngine state
        private var chapterHTML: String = ""
        private var chapterBaseURL: URL?
        private var styledCSS: String = ""
        private var computedTotalPages: Int = 1
        var currentPageIndex: Int = 0
        private var hasLoadedInitialPage: Bool = false

        // Primary master WKWebView — used for text layout, metrics & live interactions
        private(set) var primaryWebView: WKWebView?
        // Pre-rendered column snapshots — used for instant, zero-lag 3D page curling
        private var pageSnapshots: [Int: UIImage] = [:]

        init(_ parent: EBookPageCurlReader) {
            self.parent = parent
            super.init()
            setupPrimaryWebView()
        }

        nonisolated func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            return true
        }

        func cleanup() {
            guard let wv = primaryWebView else { return }
            wv.configuration.userContentController.removeScriptMessageHandler(forName: "metrics")
            wv.configuration.userContentController.removeScriptMessageHandler(forName: "highlight")
            wv.configuration.userContentController.removeScriptMessageHandler(forName: "footnote")
            wv.configuration.userContentController.removeScriptMessageHandler(forName: "scrollFraction")
            wv.navigationDelegate = nil
            wv.scrollView.delegate = nil
            wv.stopLoading()
            wv.removeFromSuperview()
            primaryWebView = nil
            pageSnapshots.removeAll()
        }

        private func setupPrimaryWebView() {
            let config = WKWebViewConfiguration()
            let controller = config.userContentController
            controller.add(self, name: "metrics")
            controller.add(self, name: "highlight")
            controller.add(self, name: "footnote")
            controller.add(self, name: "scrollFraction")

            let wv = HighlightableWebView(frame: UIScreen.main.bounds, configuration: config)
            wv.onHighlightRequested = { [weak self] in
                self?.handleHighlightRequest()
            }
            wv.navigationDelegate = self
            wv.isOpaque = false
            wv.backgroundColor = .clear
            wv.scrollView.backgroundColor = .clear

            wv.scrollView.isScrollEnabled = false
            wv.scrollView.isPagingEnabled = false
            wv.scrollView.bounces = false
            wv.scrollView.alwaysBounceHorizontal = false
            wv.scrollView.alwaysBounceVertical = false
            wv.scrollView.showsHorizontalScrollIndicator = false
            wv.scrollView.showsVerticalScrollIndicator = false
            wv.scrollView.contentInsetAdjustmentBehavior = .never
            wv.scrollView.contentInset = .zero

            let webTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap(_:)))
            webTap.numberOfTapsRequired = 1
            webTap.cancelsTouchesInView = false
            webTap.delegate = self
            wv.addGestureRecognizer(webTap)

            self.primaryWebView = wv
            self.parent.webViewRef = wv
        }

        // MARK: - Chapter Loading

        func loadChapterAndPresent() {
            hasLoadedInitialPage = false
            currentPageIndex = parent.initialPage
            pageSnapshots.removeAll()

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

                // Load HTML into primary master WKWebView
                let fullHTML = self.buildPageHTML(for: self.currentPageIndex)
                if let base = self.chapterBaseURL {
                    let tempName = "__inksync_curl_\(abs(fullHTML.hashValue)).html"
                    let fileURL = base.appendingPathComponent(tempName)
                    do {
                        try fullHTML.write(to: fileURL, atomically: true, encoding: .utf8)
                        self.primaryWebView?.loadFileURL(fileURL, allowingReadAccessTo: base.deletingLastPathComponent())
                    } catch {
                        self.primaryWebView?.loadHTMLString(fullHTML, baseURL: base)
                    }
                } else {
                    self.primaryWebView?.loadHTMLString(fullHTML, baseURL: nil)
                }

                // Present initial page VC
                let vcs = self.spreadViewControllers(for: self.currentPageIndex)
                self.pageViewController?.setViewControllers(vcs, direction: .forward, animated: false)
            }
        }

        // MARK: - Page VC Factory

        func spreadViewControllers(for pageIndex: Int) -> [UIViewController] {
            let isLandscape = UIScreen.main.bounds.width > UIScreen.main.bounds.height
            let isPad = UIDevice.current.userInterfaceIdiom == .pad
            let cols = parent.prefs.columnCount == 0 ? (isLandscape ? (parent.prefs.autoLandscapeDualPage ? 2 : (isPad ? 2 : 1)) : 1) : parent.prefs.columnCount

            if cols > 1 {
                let leftIndex = pageIndex % 2 == 0 ? pageIndex : pageIndex - 1
                let rightIndex = leftIndex + 1
                let leftVC = makePageViewController(for: leftIndex)
                let rightVC = makePageViewController(for: min(rightIndex, max(0, computedTotalPages - 1)))
                return [leftVC, rightVC]
            } else {
                let vc = makePageViewController(for: pageIndex)
                return [vc]
            }
        }

        func makePageViewController(for pageIndex: Int) -> EBookPageContentViewController {
            let clampedIndex: Int
            if pageIndex >= computedTotalPages || pageIndex == 99999 {
                clampedIndex = max(0, computedTotalPages - 1)
            } else {
                clampedIndex = max(0, pageIndex)
            }
            let vc = EBookPageContentViewController(
                pageIndex: clampedIndex,
                snapshot: pageSnapshots[clampedIndex],
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
            if prevIndex < 0 { return nil }
            return makePageViewController(for: prevIndex)
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerAfter viewController: UIViewController
        ) -> UIViewController? {
            guard let contentVC = viewController as? EBookPageContentViewController else { return nil }
            let nextIndex = contentVC.pageIndex + 1
            if nextIndex >= computedTotalPages { return nil }
            return makePageViewController(for: nextIndex)
        }

        // MARK: - UIPageViewControllerDelegate

        func pageViewController(
            _ pageViewController: UIPageViewController,
            willTransitionTo pendingViewControllers: [UIViewController]
        ) {
            isTransitioning = true
            // Detach primary WebView during active 3D curl transition so snapshots curl cleanly
            primaryWebView?.removeFromSuperview()
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
                lastCompletedControllerIndex = newPageIndex
                currentPageIndex = newPageIndex
                parent.currentPage = newPageIndex
                reportScrollFraction()
            } else {
                // Snap-back guard: user cancelled swipe gesture midway
                parent.currentPage = currentPageIndex
            }

            // Sync page position to primary master WKWebView and mount on current active page VC
            let targetPage = completed ? newPageIndex : currentPageIndex
            primaryWebView?.evaluateJavaScript("if(window.goToInksyncPage) window.goToInksyncPage(\(targetPage));")
            currentVC.mountPrimaryWebView(primaryWebView)
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            spineLocationFor orientation: UIInterfaceOrientation
        ) -> UIPageViewController.SpineLocation {
            let isLandscape = UIScreen.main.bounds.width > UIScreen.main.bounds.height
            let isPad = UIDevice.current.userInterfaceIdiom == .pad
            let cols = parent.prefs.columnCount == 0 ? (isLandscape ? (parent.prefs.autoLandscapeDualPage ? 2 : (isPad ? 2 : 1)) : 1) : parent.prefs.columnCount

            if cols > 1 {
                pageViewController.isDoubleSided = true
                return .mid
            } else {
                pageViewController.isDoubleSided = false
                return .min
            }
        }

        // MARK: - Gesture Handlers

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {}

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

            let isLandscape = UIScreen.main.bounds.width > UIScreen.main.bounds.height
            let isPad = UIDevice.current.userInterfaceIdiom == .pad
            let cols = parent.prefs.columnCount == 0 ? (isLandscape ? (parent.prefs.autoLandscapeDualPage ? 2 : (isPad ? 2 : 1)) : 1) : parent.prefs.columnCount
            let step = cols > 1 ? 2 : 1

            let nextIndex = currentPageIndex + step
            if nextIndex < computedTotalPages {
                let vcs = spreadViewControllers(for: nextIndex)
                HapticEngine.light()
                isTransitioning = true
                primaryWebView?.removeFromSuperview()
                primaryWebView?.evaluateJavaScript("if(window.goToInksyncPage) window.goToInksyncPage(\(nextIndex));")
                pvc.setViewControllers(vcs, direction: .forward, animated: true) { [weak self] completed in
                    self?.isTransitioning = false
                    if completed {
                        DispatchQueue.main.async {
                            self?.lastCompletedControllerIndex = nextIndex
                            self?.currentPageIndex = nextIndex
                            self?.parent.currentPage = nextIndex
                            self?.reportScrollFraction()
                            self?.primaryWebView?.evaluateJavaScript("if(window.goToInksyncPage) window.goToInksyncPage(\(nextIndex));")
                            if let targetVC = vcs.first as? EBookPageContentViewController {
                                targetVC.mountPrimaryWebView(self?.primaryWebView)
                            }
                        }
                    }
                }
            } else {
                parent.onNext()
            }
        }

        private func turnBackward(_ pvc: UIPageViewController) {
            guard !isTransitioning else { return }

            let isLandscape = UIScreen.main.bounds.width > UIScreen.main.bounds.height
            let isPad = UIDevice.current.userInterfaceIdiom == .pad
            let cols = parent.prefs.columnCount == 0 ? (isLandscape ? (parent.prefs.autoLandscapeDualPage ? 2 : (isPad ? 2 : 1)) : 1) : parent.prefs.columnCount
            let step = cols > 1 ? 2 : 1

            let prevIndex = currentPageIndex - step
            if prevIndex >= 0 {
                let vcs = spreadViewControllers(for: prevIndex)
                HapticEngine.light()
                isTransitioning = true
                primaryWebView?.removeFromSuperview()
                primaryWebView?.evaluateJavaScript("if(window.goToInksyncPage) window.goToInksyncPage(\(prevIndex));")
                pvc.setViewControllers(vcs, direction: .reverse, animated: true) { [weak self] completed in
                    self?.isTransitioning = false
                    if completed {
                        DispatchQueue.main.async {
                            self?.lastCompletedControllerIndex = prevIndex
                            self?.currentPageIndex = prevIndex
                            self?.parent.currentPage = prevIndex
                            self?.reportScrollFraction()
                            self?.primaryWebView?.evaluateJavaScript("if(window.goToInksyncPage) window.goToInksyncPage(\(prevIndex));")
                            if let targetVC = vcs.first as? EBookPageContentViewController {
                                targetVC.mountPrimaryWebView(self?.primaryWebView)
                            }
                        }
                    }
                }
            } else {
                parent.onPrev()
            }
        }

        // MARK: - WKNavigationDelegate & Metrics

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.webViewRef = webView
            restoreHighlights(in: webView)
            
            // Take initial snapshot of active page once loaded
            takePageSnapshot(for: currentPageIndex)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            // Auto-reload chapter if WebKit content process terminates under low memory
            webView.reload()
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

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "metrics", let body = message.body as? [String: Int] {
                let total = body["total"] ?? 1
                didReceiveMetrics(totalPages: total, fromPageIndex: currentPageIndex)
            } else if message.name == "highlight", let text = message.body as? String, !text.isEmpty {
                parent.onHighlightCreated?(text)
            } else if message.name == "footnote", let body = message.body as? [String: String], let text = body["text"] {
                parent.onFootnoteTapped?(text)
            }
        }

        func didReceiveMetrics(totalPages: Int, fromPageIndex: Int) {
            let clamped = max(1, totalPages)
            if computedTotalPages != clamped {
                computedTotalPages = clamped
                parent.totalPages = clamped
            }

            if !hasLoadedInitialPage {
                hasLoadedInitialPage = true

                var targetPage = parent.initialPage
                if targetPage == 0 && parent.initialScrollFraction > 0.01 && clamped > 1 {
                    targetPage = Int((parent.initialScrollFraction * Double(clamped - 1)).rounded())
                }
                if targetPage >= clamped { targetPage = clamped - 1 }

                if targetPage != fromPageIndex && targetPage > 0 {
                    currentPageIndex = targetPage
                    parent.currentPage = targetPage
                    primaryWebView?.evaluateJavaScript("if(window.goToInksyncPage) window.goToInksyncPage(\(targetPage));")
                    let vc = makePageViewController(for: targetPage)
                    pageViewController?.setViewControllers([vc], direction: .forward, animated: false)
                }
                reportScrollFraction()
            }

            // Mount primary WebView on active VC once initial metrics arrive
            if let currentVC = pageViewController?.viewControllers?.first as? EBookPageContentViewController {
                currentVC.mountPrimaryWebView(primaryWebView)
            }
            
            // Pre-render column snapshots for current chapter
            generateAllColumnSnapshots()
        }

        func updateLiveStyles() {
            guard let wv = primaryWebView else { return }
            let size = UIScreen.main.bounds.size
            let newCSS = computeCSS(prefs: parent.prefs, size: size)
            let safeCSS = newCSS
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "`", with: "\\`")
                .replacingOccurrences(of: "\n", with: " ")
            let js = """
            (function() {
                var el = document.getElementById('__inksync_live__');
                if (el) { el.innerHTML = `\(safeCSS)`; }
                if (window.computeMetrics) {
                    var newTotal = computeMetrics();
                    applyPagePosition();
                    window.webkit.messageHandlers.metrics.postMessage({ current: _targetPage, total: newTotal });
                }
            })();
            """
            wv.evaluateJavaScript(js)
            pageSnapshots.removeAll()
            takePageSnapshot(for: currentPageIndex)
        }

        private func generateAllColumnSnapshots() {
            guard let wv = primaryWebView else { return }
            let activePage = currentPageIndex
            wv.takeSnapshot(with: nil) { [weak self] image, _ in
                if let img = image {
                    self?.pageSnapshots[activePage] = img
                }
            }
        }

        private func takePageSnapshot(for pageIndex: Int) {
            guard let wv = primaryWebView else { return }
            wv.takeSnapshot(with: nil) { [weak self] image, _ in
                if let img = image {
                    self?.pageSnapshots[pageIndex] = img
                }
            }
        }

        private func reportScrollFraction() {
            let fraction: Double
            if computedTotalPages > 1 {
                fraction = Double(currentPageIndex) / Double(computedTotalPages - 1)
            } else {
                fraction = 0
            }
            parent.onScrollFractionChanged?(fraction)
        }

        private func handleHighlightRequest() {
            guard let wv = primaryWebView else { return }
            wv.evaluateJavaScript("window.getSelection().toString()") { [weak self] result, _ in
                if let text = result as? String, !text.isEmpty {
                    self?.parent.onHighlightCreated?(text)
                }
            }
        }

        private func restoreHighlights(in webView: WKWebView) {
            guard let pdfID = parent.pdfID else { return }
            let annotations = AnnotationStore.shared.annotations(for: pdfID)
                .filter { $0.kind == .highlight && $0.chapterTitle == parent.spineItem.label }
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

        // MARK: - CSS & JS Construction

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
            *, *::before, *::after { 
                box-sizing: border-box; 
                -webkit-tap-highlight-color: transparent; 
                scroll-behavior: auto !important; 
                -webkit-overflow-scrolling: auto !important;
            }
            html, body {
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
                position: absolute !important;
                top: 0 !important; left: 0 !important;
                padding-top: 60px !important;
                padding-bottom: 60px !important;
                padding-left: \(paddingLeft)px !important;
                padding-right: \(paddingRight)px !important;
                height: 100% !important;
                \(pagedCSS)
                transition: transform 0.05s ease-out;
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
            let isLandscape = UIScreen.main.bounds.width > UIScreen.main.bounds.height
            let isPad = UIDevice.current.userInterfaceIdiom == .pad
            let cols = parent.prefs.columnCount == 0 ? (isLandscape ? (parent.prefs.autoLandscapeDualPage ? 2 : (isPad ? 2 : 1)) : 1) : parent.prefs.columnCount
            let isMultiCol = cols > 1

            return """
            var _targetPage = 0;
            var _totalPages = 1;
            var _isMultiCol = \(isMultiCol ? "true" : "false");

            function getPageStep() {
                var w = window.innerWidth;
                return w > 0 ? w : 1;
            }

            function applyPagePosition() {
                var pageStep = getPageStep();
                if (pageStep <= 0) return;
                var shift = _targetPage * pageStep;

                var sv = document.scrollingElement || document.documentElement || document.body;
                if (sv) {
                    sv.scrollLeft = shift;
                }
                window.scrollTo(shift, 0);

                var vp = document.getElementById('inksync-viewport') || document.body;
                if (vp) {
                    vp.style.transform = 'translateX(-' + shift + 'px)';
                    vp.style.webkitTransform = 'translateX(-' + shift + 'px)';
                }
            }

            applyPagePosition();

            document.addEventListener('DOMContentLoaded', function() {
                applyPagePosition();
                document.querySelectorAll('[style]').forEach(function(el) {
                    el.style.removeProperty('background-color');
                    el.style.removeProperty('color');
                });
                var liveStyle = document.getElementById('__inksync_live__');
                if (liveStyle) { document.head.appendChild(liveStyle); }
                document.body.style.webkitUserSelect = 'text';
                document.body.style.userSelect = 'text';
            });

            function computeMetrics() {
                var sv = document.scrollingElement || document.documentElement;
                var pageStep = getPageStep();
                if (pageStep <= 0) return 1;
                var scrollW = Math.max(sv.scrollWidth, document.body.scrollWidth);
                var total = Math.floor((scrollW + 5) / pageStep);
                var remainder = (scrollW + 5) % pageStep;
                if (remainder > 35) {
                    total += 1;
                }
                _totalPages = Math.max(1, total);
                return _totalPages;
            }

            function goToPage(page) {
                _targetPage = Math.max(0, Math.min(page, _totalPages - 1));
                applyPagePosition();
            }
            window.goToInksyncPage = goToPage;

            window.onload = function() {
                computeMetrics();
                applyPagePosition();
                window.webkit.messageHandlers.metrics.postMessage({ current: _targetPage, total: _totalPages });
            };

            window.addEventListener('resize', function() {
                computeMetrics();
                applyPagePosition();
            });

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
            """
        }

        func buildPageHTML(for pageIndex: Int) -> String {
            var fullHTML = chapterHTML
            let pageTargetScript = "<script>var _targetPage = \(pageIndex);</script>"
            if let range = fullHTML.range(of: "</head>", options: .caseInsensitive) {
                fullHTML = fullHTML.replacingCharacters(in: range, with: pageTargetScript + styledCSS + "</head>")
            } else {
                fullHTML = pageTargetScript + styledCSS + fullHTML
            }
            return fullHTML
        }
    }

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
// Leaf view controller rendered inside UIPageViewController.
// Uses a pre-rendered column snapshot during 3D page curl (0ms delay),
// and hosts the active master WKWebView when stationary for 100% interactivity.
// ============================================================
@MainActor
class EBookPageContentViewController: UIViewController {
    let pageIndex: Int
    private var snapshot: UIImage?
    private weak var coordinator: EBookPageCurlReader.Coordinator?
    private var imageView: UIImageView?
    private var hostedWebView: WKWebView?

    init(
        pageIndex: Int,
        snapshot: UIImage?,
        coordinator: EBookPageCurlReader.Coordinator
    ) {
        self.pageIndex = pageIndex
        self.snapshot = snapshot
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

        // Setup snapshot image view (0ms instant page rendering for 3D curl)
        let iv = UIImageView(frame: view.bounds)
        iv.contentMode = .scaleAspectFill
        iv.clipsToBounds = true
        iv.image = snapshot
        iv.backgroundColor = bgColor
        iv.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(iv)
        NSLayoutConstraint.activate([
            iv.topAnchor.constraint(equalTo: view.topAnchor),
            iv.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            iv.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            iv.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        self.imageView = iv
    }

    /// Mounts the primary master WKWebView onto this page VC when active
    func mountPrimaryWebView(_ webView: WKWebView?) {
        guard let wv = webView else { return }
        if wv.superview == view { return }

        wv.removeFromSuperview()
        wv.frame = view.bounds
        wv.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(wv)

        NSLayoutConstraint.activate([
            wv.topAnchor.constraint(equalTo: view.topAnchor),
            wv.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            wv.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            wv.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        self.hostedWebView = wv
    }
}
