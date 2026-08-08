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
        // Set theme background immediately to prevent white bleed on initial load
        // and before the primary WKWebView mounts its first content frame.
        view.backgroundColor = UIColor(hex: prefs.activeTheme.cssBackground) ?? .black

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

        let initialVCs = context.coordinator.spreadViewControllers(for: initialPage)
        context.coordinator.safeSetViewControllers(initialVCs, direction: .forward, animated: false)

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
            context.coordinator.safeSetViewControllers(vcs, direction: direction, animated: false) { _ in
                context.coordinator.mountPrimaryWebViewOnRoot()
            }
        }
    }



    /// Called by SwiftUI when the EPUB curl reader is removed from the hierarchy.
    /// MUST use UIViewControllerRepresentable's dismantleUIViewController — dismantleUIView
    /// is for UIViewRepresentable and is never called here.
    static func dismantleUIViewController(_ uiViewController: UIPageViewController, coordinator: Coordinator) {
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

                // Clean via SwiftReadability with rawHTML fallback safeguard
                let cleanArticle = SwiftReadability.parse(html: rawHTML)
                var html = cleanArticle.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if html.isEmpty || html.count < 20 {
                    html = rawHTML
                }

                // Wrap with viewport div
                html = EBookPageCurlReader.wrapHTMLBodyWithViewport(html)

                self.chapterHTML = html
                self.styledCSS = self.buildFullCSS()

                // Load HTML into primary master WKWebView directly in-memory
                let fullHTML = self.buildPageHTML(for: self.currentPageIndex)
                self.primaryWebView?.loadHTMLString(fullHTML, baseURL: self.chapterBaseURL)

                // Present initial page VC
                let vcs = self.spreadViewControllers(for: self.currentPageIndex)
                self.safeSetViewControllers(vcs, direction: .forward, animated: false)
            }
        }

        func safeSetViewControllers(
            _ vcs: [UIViewController],
            direction: UIPageViewController.NavigationDirection,
            animated: Bool,
            completion: ((Bool) -> Void)? = nil
        ) {
            guard let pvc = pageViewController else { return }

            let reqCount: Int
            switch pvc.spineLocation {
            case .mid:
                reqCount = 2
            case .min:
                reqCount = 1
            case .none:
                reqCount = isDualPageMode ? 2 : 1
            @unknown default:
                reqCount = 1
            }

            let safeVCs: [UIViewController]
            if reqCount == 1 && vcs.count > 1 {
                safeVCs = Array(vcs.prefix(1))
            } else if reqCount == 2 && vcs.count == 1, let first = vcs.first {
                let second = makePageViewController(for: min(currentPageIndex + 1, max(0, computedTotalPages - 1)))
                safeVCs = [first, second]
            } else {
                safeVCs = vcs
            }


            pvc.setViewControllers(safeVCs, direction: direction, animated: animated, completion: completion)
        }


        var isDualPageMode: Bool {
            let isLandscape = UIScreen.main.bounds.width > UIScreen.main.bounds.height
            let isPad = UIDevice.current.userInterfaceIdiom == .pad
            let cols = parent.prefs.columnCount == 0 ? (isLandscape ? (parent.prefs.autoLandscapeDualPage ? 2 : (isPad ? 2 : 1)) : 1) : parent.prefs.columnCount
            return cols > 1
        }

        func spreadViewControllers(for pageIndex: Int) -> [UIViewController] {
            if isDualPageMode {
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
            let step = isDualPageMode ? 2 : 1
            let prevIndex = contentVC.pageIndex - step
            if prevIndex < 0 { return nil }
            return makePageViewController(for: prevIndex)
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerAfter viewController: UIViewController
        ) -> UIViewController? {
            guard let contentVC = viewController as? EBookPageContentViewController else { return nil }
            let step = isDualPageMode ? 2 : 1
            let nextIndex = contentVC.pageIndex + step
            if nextIndex >= computedTotalPages { return nil }
            return makePageViewController(for: nextIndex)
        }


        // MARK: - UIPageViewControllerDelegate

        func captureSnapshot(for vc: EBookPageContentViewController) {
            // Snapshot must be taken while the WebView is still in the view hierarchy and has valid bounds.
            // takeSnapshot is async — capture frame reference before any removeFromSuperview call.
            guard let wv = primaryWebView else { return }
            let snapshotFrame = wv.bounds
            guard snapshotFrame.width > 1, snapshotFrame.height > 1 else { return }
            let config = WKSnapshotConfiguration()
            config.rect = snapshotFrame
            config.afterScreenUpdates = false
            wv.takeSnapshot(with: config) { [weak vc] image, _ in
                guard let image = image, let vc = vc else { return }
                vc.updateSnapshot(image)
            }
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            willTransitionTo pendingViewControllers: [UIViewController]
        ) {
            isTransitioning = true
            let bgColor = UIColor(hex: parent.prefs.activeTheme.cssBackground) ?? .black
            pageViewController.view.backgroundColor = bgColor
            if let currentVC = pageViewController.viewControllers?.first as? EBookPageContentViewController {
                captureSnapshot(for: currentVC)
            }
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
                parent.currentPage = currentPageIndex
            }

            let targetPage = completed ? newPageIndex : currentPageIndex
            primaryWebView?.isHidden = true
            primaryWebView?.evaluateJavaScript("if(window.goToInksyncPage) window.goToInksyncPage(\(targetPage));")
            mountPrimaryWebViewOnRoot()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self, weak currentVC] in
                self?.primaryWebView?.isHidden = false
                if let currentVC = currentVC {
                    self?.captureSnapshot(for: currentVC)
                }
            }
        }

        func mountPrimaryWebViewOnRoot() {
            guard let pvc = pageViewController, let wv = primaryWebView else { return }
            let bgColor = UIColor(hex: parent.prefs.activeTheme.cssBackground) ?? .black
            pvc.view.backgroundColor = bgColor
            wv.backgroundColor = .clear
            wv.scrollView.backgroundColor = .clear
            if wv.superview == pvc.view { return }
            wv.removeFromSuperview()
            wv.frame = pvc.view.bounds
            wv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            pvc.view.addSubview(wv)
        }


        func pageViewController(
            _ pageViewController: UIPageViewController,
            spineLocationFor orientation: UIInterfaceOrientation
        ) -> UIPageViewController.SpineLocation {
            isTransitioning = true
            defer { isTransitioning = false }

            let isLandscape = orientation.isLandscape
            let isPad = UIDevice.current.userInterfaceIdiom == .pad
            let cols = parent.prefs.columnCount == 0
                ? (isLandscape ? (parent.prefs.autoLandscapeDualPage ? 2 : (isPad ? 2 : 1)) : 1)
                : parent.prefs.columnCount
            let dual = cols > 1

            if dual {
                let leftIndex = currentPageIndex % 2 == 0 ? currentPageIndex : currentPageIndex - 1
                let rightIndex = leftIndex + 1
                let leftVC = makePageViewController(for: leftIndex)
                let rightVC = makePageViewController(for: min(rightIndex, max(0, computedTotalPages - 1)))
                pageViewController.isDoubleSided = true
                pageViewController.setViewControllers([leftVC, rightVC], direction: .forward, animated: false)
                return .mid
            } else {
                let vc = makePageViewController(for: currentPageIndex)
                pageViewController.isDoubleSided = false
                pageViewController.setViewControllers([vc], direction: .forward, animated: false)
                return .min
            }
        }




        // MARK: - Gesture Handlers

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {}

        private var tapZoneStyle: TapZoneStyle {
            // Read from shared prefs so live setting changes in EBookSettingsPanel
            // are immediately reflected without requiring a reader dismiss/reopen.
            parent.prefs.tapZoneStyle
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
                if let currentVC = pvc.viewControllers?.first as? EBookPageContentViewController {
                    captureSnapshot(for: currentVC)
                }
                let vcs = spreadViewControllers(for: nextIndex)
                HapticEngine.light()
                isTransitioning = true
                primaryWebView?.removeFromSuperview()
                primaryWebView?.evaluateJavaScript("if(window.goToInksyncPage) window.goToInksyncPage(\(nextIndex));")
                safeSetViewControllers(vcs, direction: .forward, animated: true) { [weak self] completed in
                    self?.isTransitioning = false
                    if completed {
                        DispatchQueue.main.async {
                            self?.lastCompletedControllerIndex = nextIndex
                            self?.currentPageIndex = nextIndex
                            self?.parent.currentPage = nextIndex
                            self?.reportScrollFraction()
                            self?.primaryWebView?.evaluateJavaScript("if(window.goToInksyncPage) window.goToInksyncPage(\(nextIndex));")
                            self?.mountPrimaryWebViewOnRoot()
                            if let activeVC = pvc.viewControllers?.first as? EBookPageContentViewController {
                                self?.captureSnapshot(for: activeVC)
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
                if let currentVC = pvc.viewControllers?.first as? EBookPageContentViewController {
                    captureSnapshot(for: currentVC)
                }
                let vcs = spreadViewControllers(for: prevIndex)
                HapticEngine.light()
                isTransitioning = true
                primaryWebView?.removeFromSuperview()
                primaryWebView?.evaluateJavaScript("if(window.goToInksyncPage) window.goToInksyncPage(\(prevIndex));")
                safeSetViewControllers(vcs, direction: .reverse, animated: true) { [weak self] completed in

                    self?.isTransitioning = false
                    if completed {
                        DispatchQueue.main.async {
                            self?.lastCompletedControllerIndex = prevIndex
                            self?.currentPageIndex = prevIndex
                            self?.parent.currentPage = prevIndex
                            self?.reportScrollFraction()
                            self?.primaryWebView?.evaluateJavaScript("if(window.goToInksyncPage) window.goToInksyncPage(\(prevIndex));")
                            self?.mountPrimaryWebViewOnRoot()
                            if let activeVC = pvc.viewControllers?.first as? EBookPageContentViewController {
                                self?.captureSnapshot(for: activeVC)
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

            let fileName = url.lastPathComponent
            let fragment = url.fragment ?? ""

            if navigationAction.navigationType == .linkActivated || !fileName.isEmpty {
                // Post navigation event to EBookReaderView
                NotificationCenter.default.post(
                    name: NSNotification.Name("Reader_JumpToChapterHref"),
                    object: nil,
                    userInfo: ["href": fileName, "fragment": fragment]
                )

                // Check if fragment targets a footnote vs a section heading anchor
                if !fragment.isEmpty {
                    let js = """
                    (function() {
                        var el = document.getElementById('\(fragment)') || document.getElementsByName('\(fragment)')[0];
                        if (el) {
                            var tag = el.tagName.toLowerCase();
                            var isFN = el.classList.contains('footnote') || el.getAttribute('epub:type') === 'noteref' || el.getAttribute('rel') === 'footnote' || el.id.toLowerCase().indexOf('fn') === 0;
                            if (isFN) {
                                var text = el.innerText || el.textContent;
                                if (text && text.trim().length > 0 && text.trim().length < 1000) {
                                    window.webkit.messageHandlers.footnote.postMessage({ "id": '\(fragment)', "text": text.trim() });
                                    return;
                                }
                            }
                            el.scrollIntoView({ behavior: 'smooth', block: 'start' });
                        }
                    })();
                    """
                    webView.evaluateJavaScript(js, completionHandler: nil)
                }

                decisionHandler(.cancel)
                return
            }

            decisionHandler(.allow)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "metrics", let body = message.body as? [String: Int] {
                let total = body["total"] ?? 1
                let current = body["current"] ?? 0
                didReceiveMetrics(current: current, totalPages: total, fromPageIndex: currentPageIndex)
            } else if message.name == "highlight", let text = message.body as? String, !text.isEmpty {
                parent.onHighlightCreated?(text)
            } else if message.name == "footnote", let body = message.body as? [String: String], let text = body["text"] {
                parent.onFootnoteTapped?(text)
            }
        }

        func didReceiveMetrics(current: Int, totalPages: Int, fromPageIndex: Int) {
            let clampedTotal = max(1, totalPages)
            let clampedCurrent = max(0, min(current, clampedTotal - 1))

            if computedTotalPages != clampedTotal {
                computedTotalPages = clampedTotal
                parent.totalPages = clampedTotal
            }

            if !hasLoadedInitialPage {
                hasLoadedInitialPage = true

                var targetPage = clampedCurrent
                if parent.initialPage == 0 && parent.initialScrollFraction > 0.01 && clampedTotal > 1 {
                    targetPage = Int((parent.initialScrollFraction * Double(clampedTotal - 1)).rounded())
                } else if parent.initialPage >= 99999 {
                    targetPage = clampedTotal - 1
                } else if parent.initialPage > 0 && parent.initialPage < clampedTotal {
                    targetPage = parent.initialPage
                }

                currentPageIndex = targetPage
                parent.currentPage = targetPage
                primaryWebView?.evaluateJavaScript("if(window.goToInksyncPage) window.goToInksyncPage(\(targetPage));")
                let vcs = spreadViewControllers(for: targetPage)
                pageViewController?.setViewControllers(vcs, direction: .forward, animated: false)
                reportScrollFraction()
            } else {
                currentPageIndex = clampedCurrent
                if parent.currentPage != clampedCurrent {
                    parent.currentPage = clampedCurrent
                }
            }

            mountPrimaryWebViewOnRoot()

            
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
            guard let wv = primaryWebView, wv.bounds.width > 1, wv.bounds.height > 1 else { return }
            let activePage = currentPageIndex
            let config = WKSnapshotConfiguration()
            config.rect = wv.bounds
            config.afterScreenUpdates = true
            wv.takeSnapshot(with: config) { [weak self] image, _ in
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
            let pageScript = buildPageScript(initialPage: parent.initialPage)

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

        func buildPageScript(initialPage: Int = 0) -> String {
            let isLandscape = UIScreen.main.bounds.width > UIScreen.main.bounds.height
            let isPad = UIDevice.current.userInterfaceIdiom == .pad
            let cols = parent.prefs.columnCount == 0 ? (isLandscape ? (parent.prefs.autoLandscapeDualPage ? 2 : (isPad ? 2 : 1)) : 1) : parent.prefs.columnCount
            let isMultiCol = cols > 1

            return """
            var _targetPage = \(initialPage >= 99999 ? 99999 : max(0, initialPage));
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

                var vp = document.getElementById('inksync-viewport') || document.body;
                if (vp) {
                    vp.style.transform = 'translateX(-' + shift + 'px)';
                    vp.style.webkitTransform = 'translateX(-' + shift + 'px)';
                }
            }

            applyPagePosition();

            document.addEventListener('DOMContentLoaded', function() {
                applyPagePosition();
                document.querySelectorAll('*').forEach(function(el) {
                    if (el.tagName !== 'MARK' && !el.classList.contains('inksync-highlight')) {
                        el.style.removeProperty('background-color');
                        el.style.removeProperty('background');
                    }
                });
                var liveStyle = document.getElementById('__inksync_live__');
                if (liveStyle) { document.head.appendChild(liveStyle); }
                document.body.style.webkitUserSelect = 'text';
                document.body.style.userSelect = 'text';
            });

            function computeMetrics() {
                var pageStep = getPageStep();
                if (pageStep <= 0) return 1;
                var vp = document.getElementById('inksync-viewport');
                var sv = document.scrollingElement || document.documentElement;
                var scrollW = vp ? vp.scrollWidth : Math.max(sv.scrollWidth, document.body.scrollWidth);
                var total = Math.floor((scrollW + 5) / pageStep);
                var remainder = (scrollW + 5) % pageStep;
                if (remainder > 35) {
                    total += 1;
                }
                _totalPages = Math.max(1, total);
                if (_targetPage >= 99999 || _targetPage >= _totalPages) {
                    _targetPage = Math.max(0, _totalPages - 1);
                }
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

            if (document.fonts && document.fonts.ready) {
                document.fonts.ready.then(function() {
                    computeMetrics();
                    applyPagePosition();
                    window.webkit.messageHandlers.metrics.postMessage({ current: _targetPage, total: _totalPages });
                });
            }

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
            if let closeBodyRange = result.range(of: "</body>", options: [.caseInsensitive, .backwards]) {
                result.insert(contentsOf: "</div>", at: closeBodyRange.lowerBound)
            } else {
                result += "</div>"
            }
        } else if let bodyIndex = result.range(of: "<body>", options: .caseInsensitive)?.upperBound {
            result.insert(contentsOf: "<div id=\"inksync-viewport\">", at: bodyIndex)
            if let closeBodyRange = result.range(of: "</body>", options: [.caseInsensitive, .backwards]) {
                result.insert(contentsOf: "</div>", at: closeBodyRange.lowerBound)
            } else {
                result += "</div>"
            }
        } else {
            result = "<body><div id=\"inksync-viewport\">" + result + "</div></body>"
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

    func updateSnapshot(_ image: UIImage) {
        self.snapshot = image
        self.imageView?.image = image
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let prefs = EBookPreferences.shared
        let bgColor = UIColor(hex: prefs.activeTheme.cssBackground) ?? .black
        view.backgroundColor = bgColor

        // Setup snapshot image view (0ms instant page rendering for 3D curl)
        let iv = UIImageView(frame: view.bounds)
        // scaleAspectFit preserves page aspect ratio — avoids distorting text during 3D curl.
        // The parent view already fills the screen, so the image fills edge-to-edge cleanly.
        iv.contentMode = .scaleAspectFit
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

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if let wv = coordinator?.primaryWebView, wv.superview == view {
            wv.frame = view.bounds
        }
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
