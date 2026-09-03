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
    var onHighlightTapped: ((String) -> Void)? = nil
    var onTextSelected: ((String) -> Void)? = nil
    var onSelectionDismissed: (() -> Void)? = nil
    var pdfID: UUID? = nil
    var initialScrollFraction: Double = 0.0
    var onScrollFractionChanged: ((Double) -> Void)? = nil
    @Binding var webViewRef: WKWebView?
    var onFootnoteTapped: ((String) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let isInstant = (prefs.pageTurnStyle == .instant)
        let transitionStyle: UIPageViewController.TransitionStyle = isInstant ? .scroll : .pageCurl
        let pvc = UIPageViewController(
            transitionStyle: transitionStyle,
            navigationOrientation: .horizontal,
            options: nil
        )
        pvc.isDoubleSided = false
        pvc.dataSource = context.coordinator
        pvc.delegate = context.coordinator

        let view = pvc.view!
        view.backgroundColor = UIColor(hex: prefs.activeTheme.cssBackground) ?? .black

        // Long-press selection guard (250ms) to disambiguate text selection from page taps & curls
        let selectionGuard = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleSelectionGuard(_:))
        )
        selectionGuard.minimumPressDuration = 0.25
        selectionGuard.cancelsTouchesInView = false
        selectionGuard.delegate = context.coordinator
        view.addGestureRecognizer(selectionGuard)
        context.coordinator.selectionGuard = selectionGuard

        // Disable UIPageViewController's built-in single-tap (it conflicts with zone taps)
        for gesture in pvc.gestureRecognizers {
            if gesture is UITapGestureRecognizer {
                gesture.isEnabled = false
            } else if let pan = gesture as? UIPanGestureRecognizer {
                pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
                pan.delegate = context.coordinator
                pan.require(toFail: selectionGuard)
            }
        }

        // Double tap — restricted to direct finger touches
        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        doubleTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        doubleTap.cancelsTouchesInView = false
        view.addGestureRecognizer(doubleTap)

        // Single tap — handles left/center/right zones — guarded by selectionGuard & doubleTap
        let singleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleSingleTap(_:))
        )
        singleTap.numberOfTapsRequired = 1
        singleTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        singleTap.cancelsTouchesInView = false
        singleTap.delegate = context.coordinator
        singleTap.require(toFail: doubleTap)
        singleTap.require(toFail: selectionGuard)
        view.addGestureRecognizer(singleTap)

        // Pinch to Zoom / Scale Text (Kindle-style interactive text scaling)
        let pinch = UIPinchGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePinch(_:))
        )
        pinch.cancelsTouchesInView = false
        view.addGestureRecognizer(pinch)

        context.coordinator.pageViewController = pvc
        context.coordinator.mountPrimaryWebViewOnRoot()

        let initialVCs = context.coordinator.spreadViewControllers(for: initialPage)
        context.coordinator.safeSetViewControllers(initialVCs, direction: .forward, animated: false)

        // Start chapter load asynchronously
        context.coordinator.loadChapterAndPresent()

        return pvc
    }

    func updateUIViewController(_ uiViewController: UIPageViewController, context: Context) {
        let oldParent = context.coordinator.parent
        context.coordinator.parent = self

        // If spine item (chapter) changed, reset transitioning lock and reload everything
        if oldParent.spineItem.href != self.spineItem.href {
            context.coordinator.isTransitioning = false
            context.coordinator.loadChapterAndPresent()
            return
        }

        // Guard against re-entrant updates during interactive curl gestures
        if context.coordinator.isTransitioning { return }

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
            
            NotificationCenter.default.addObserver(forName: NSNotification.Name("EBookTurnPageForward"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self = self, let pvc = self.pageViewController else { return }
                    self.turnForward(pvc)
                }
            }
            NotificationCenter.default.addObserver(forName: NSNotification.Name("EBookTurnPageBackward"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self = self, let pvc = self.pageViewController else { return }
                    self.turnBackward(pvc)
                }
            }
        }

        var isUserSelectingText: Bool = false
        // Tracks whether the most recent touch began as a drag (text-selection intent).
        // Set by JS touchstart/touchend movement tracking and reset by handleSingleTap.
        var isTouchDragActive: Bool = false
        weak var selectionGuard: UILongPressGestureRecognizer?

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            // UIPageViewController's pan gesture should NEVER recognize simultaneously with
            // WebKit selection, handle adjustment, loupe, or text editing gestures.
            if gestureRecognizer is UIPanGestureRecognizer || otherGestureRecognizer is UIPanGestureRecognizer {
                let otherName = NSStringFromClass(type(of: otherGestureRecognizer))
                if otherName.contains("Selection") || otherName.contains("Range") || otherName.contains("Text") || otherName.contains("Loupe") {
                    return false
                }
            }
            return true
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            // Block our tap or page curl pan if user is actively selecting text or dragging a selection
            if isUserSelectingText || isTouchDragActive {
                if gestureRecognizer is UITapGestureRecognizer || gestureRecognizer is UIPanGestureRecognizer {
                    return false
                }
            }
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            // Walk the entire responder hierarchy of the touch to reject text selection handles/loupe
            var v: UIView? = touch.view
            while let current = v {
                let name = NSStringFromClass(type(of: current))
                if name.contains("Selection") || name.contains("RangeView") || name.contains("Handle") || name.contains("Loupe") || name.contains("TextRange") || name.contains("Grabber") {
                    return false
                }
                v = current.superview
            }
            if isUserSelectingText && gestureRecognizer is UIPanGestureRecognizer {
                return false
            }
            return true
        }

        func cleanup() {
            NotificationCenter.default.removeObserver(self, name: NSNotification.Name("EBookTurnPageForward"), object: nil)
            NotificationCenter.default.removeObserver(self, name: NSNotification.Name("EBookTurnPageBackward"), object: nil)
            guard let wv = primaryWebView else { return }
            wv.configuration.userContentController.removeScriptMessageHandler(forName: "metrics")
            wv.configuration.userContentController.removeScriptMessageHandler(forName: "highlight")
            wv.configuration.userContentController.removeScriptMessageHandler(forName: "onHighlightTapped")
            wv.configuration.userContentController.removeScriptMessageHandler(forName: "onTextSelected")
            wv.configuration.userContentController.removeScriptMessageHandler(forName: "onSelectionDismissed")
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
            controller.add(self, name: "onHighlightTapped")
            controller.add(self, name: "onTextSelected")
            controller.add(self, name: "onSelectionDismissed")
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

                // Clean via SwiftReadability (bypassed for synthesized reflow HTML)
                var html: String
                if rawHTML.contains("pdf-page-marker") || self.parent.spineItem.href.hasSuffix("reflow.html") {
                    html = rawHTML
                } else {
                    let cleanArticle = SwiftReadability.parse(html: rawHTML)
                    html = cleanArticle.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    if html.isEmpty || html.count < 20 {
                        html = rawHTML
                    }
                }

                // Wrap with viewport div
                html = EBookPageCurlReader.wrapHTMLBodyWithViewport(html)

                self.chapterHTML = html
                self.styledCSS = self.buildFullCSS()

                // Mount primaryWebView on root so WebKit processes layout, metrics and JS immediately
                self.mountPrimaryWebViewOnRoot()

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

            let reqCount: Int = (pvc.spineLocation == .mid) ? 2 : 1

            let safeVCs: [UIViewController]
            if reqCount == 1 {
                if let first = vcs.first {
                    safeVCs = [first]
                } else {
                    safeVCs = [makePageViewController(for: currentPageIndex)]
                }
            } else {
                if vcs.count >= 2 {
                    safeVCs = Array(vcs.prefix(2))
                } else if let first = vcs.first {
                    let second = makePageViewController(for: min(currentPageIndex + 1, max(0, computedTotalPages - 1)))
                    safeVCs = [first, second]
                } else {
                    let first = makePageViewController(for: currentPageIndex)
                    let second = makePageViewController(for: min(currentPageIndex + 1, max(0, computedTotalPages - 1)))
                    safeVCs = [first, second]
                }
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
                let leftIndex: Int
                let rightIndex: Int
                if parent.prefs.linkCoverAsSpread {
                    leftIndex = pageIndex % 2 == 0 ? pageIndex : pageIndex - 1
                    rightIndex = leftIndex + 1
                    let leftVC = makePageViewController(for: leftIndex)
                    let rightVC = makePageViewController(for: min(rightIndex, max(0, computedTotalPages - 1)))
                    return [leftVC, rightVC]
                } else {
                    if pageIndex == 0 {
                        return [makePageViewController(for: 0)]
                    } else if pageIndex == 1 {
                        return [makePageViewController(for: 1)]
                    } else {
                        let offset = pageIndex - 2
                        leftIndex = 2 + (offset / 2) * 2
                        rightIndex = leftIndex + 1
                        let leftVC = makePageViewController(for: leftIndex)
                        let rightVC = makePageViewController(for: min(rightIndex, max(0, computedTotalPages - 1)))
                        return [leftVC, rightVC]
                    }
                }
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
            let snapshot = pageSnapshots[clampedIndex]
            let hit = snapshot != nil
            ReaderEngineDiagnosticLogger.logPrecache(hit: hit, pageIndex: clampedIndex, cachedPagesCount: pageSnapshots.count)
            
            let vc = EBookPageContentViewController(
                pageIndex: clampedIndex,
                snapshot: snapshot,
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

        func captureSnapshot(for vcs: [UIViewController]) {
            guard let wv = primaryWebView else { return }
            let snapshotFrame = wv.bounds
            guard snapshotFrame.width > 1, snapshotFrame.height > 1 else { return }
            let config = WKSnapshotConfiguration()
            config.rect = snapshotFrame
            config.afterScreenUpdates = false
            wv.takeSnapshot(with: config) { [weak self] image, _ in
                guard let image = image, let self = self else { return }
                if self.isDualPageMode && vcs.count == 2,
                   let cgImg = image.cgImage {
                    let scale = image.scale
                    let width = CGFloat(cgImg.width)
                    let height = CGFloat(cgImg.height)
                    let halfWidth = width / 2.0

                    let leftRect = CGRect(x: 0, y: 0, width: halfWidth, height: height)
                    let rightRect = CGRect(x: halfWidth, y: 0, width: halfWidth, height: height)

                    if let leftCg = cgImg.cropping(to: leftRect),
                       let rightCg = cgImg.cropping(to: rightRect) {
                        let leftImg = UIImage(cgImage: leftCg, scale: scale, orientation: image.imageOrientation)
                        let rightImg = UIImage(cgImage: rightCg, scale: scale, orientation: image.imageOrientation)

                        if let leftVC = vcs[0] as? EBookPageContentViewController {
                            leftVC.updateSnapshot(leftImg)
                        }
                        if let rightVC = vcs[1] as? EBookPageContentViewController {
                            rightVC.updateSnapshot(rightImg)
                        }
                        return
                    }
                }

                if let singleVC = vcs.first as? EBookPageContentViewController {
                    singleVC.updateSnapshot(image)
                }
            }
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            willTransitionTo pendingViewControllers: [UIViewController]
        ) {
            isTransitioning = true
            let bgColor = UIColor(hex: parent.prefs.activeTheme.cssBackground) ?? .black
            pageViewController.view.backgroundColor = bgColor
            if let vcs = pageViewController.viewControllers {
                captureSnapshot(for: vcs)
            }
            captureSnapshot(for: pendingViewControllers)
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
            mountPrimaryWebViewOnRoot()
            // Reveal the WebView only after the JS column-position commit completes,
            // preventing any momentary flash of the wrong column position.
            primaryWebView?.evaluateJavaScript("if(window.goToInksyncPage) window.goToInksyncPage(\(targetPage));") { [weak self, weak pageViewController] _, _ in
                DispatchQueue.main.async {
                    self?.primaryWebView?.isHidden = false
                    if let activeVCs = pageViewController?.viewControllers {
                        self?.captureSnapshot(for: activeVCs)
                    }
                    self?.precacheAdjacentSnapshots()
                }
            }
        }

        func precacheAdjacentSnapshots() {
            guard let wv = primaryWebView, !isTransitioning else { return }
            let current = currentPageIndex
            let step = isDualPageMode ? 2 : 1
            let nextIdx = current + step

            guard nextIdx < computedTotalPages else { return }

            let config = WKSnapshotConfiguration()
            config.rect = wv.bounds
            config.afterScreenUpdates = false
            wv.takeSnapshot(with: config) { [weak self] image, _ in
                guard let image = image, let self = self else { return }
                self.pageSnapshots[nextIdx] = image
            }
        }

        func mountPrimaryWebViewOnRoot() {
            guard let pvc = pageViewController, let wv = primaryWebView else { return }
            let bgColor = UIColor(hex: parent.prefs.activeTheme.cssBackground) ?? .black
            pvc.view.backgroundColor = bgColor
            wv.backgroundColor = .clear
            wv.scrollView.backgroundColor = .clear
            wv.isHidden = false
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

        private var initialPinchFontSize: Double = 0
        private var lastLiveStyleUpdate: Date = Date()

        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            switch gesture.state {
            case .began:
                initialPinchFontSize = parent.prefs.fontSize
            case .changed:
                guard initialPinchFontSize > 0 else { return }
                let scale = Double(gesture.scale)
                let newSize = initialPinchFontSize * scale
                let clamped = max(12.0, min(44.0, round(newSize)))
                if clamped != parent.prefs.fontSize {
                    parent.prefs.fontSize = clamped
                    HapticEngine.selection()
                    NotificationCenter.default.post(
                        name: NSNotification.Name("InksyncPro.fontSizePinchChanged"),
                        object: nil,
                        userInfo: ["fontSize": clamped]
                    )
                    if Date().timeIntervalSince(lastLiveStyleUpdate) > 0.08 {
                        lastLiveStyleUpdate = Date()
                        updateLiveStyles()
                    }
                }
            case .ended, .cancelled:
                initialPinchFontSize = 0
                updateLiveStyles()
            default:
                break
            }
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            // Double-tap resets font size to default 18pt if changed, or triggers chrome
            if parent.prefs.fontSize != 18.0 {
                parent.prefs.fontSize = 18.0
                HapticEngine.selection()
                NotificationCenter.default.post(
                    name: NSNotification.Name("InksyncPro.fontSizePinchChanged"),
                    object: nil,
                    userInfo: ["fontSize": 18.0]
                )
                updateLiveStyles()
            }
        }

        private var tapZoneStyle: TapZoneStyle {
            // Read from shared prefs so live setting changes in EBookSettingsPanel
            // are immediately reflected without requiring a reader dismiss/reopen.
            parent.prefs.tapZoneStyle
        }

        /// Selection guard gesture — fires when touch is stationary > 80ms (text selection intent).
        /// Resets automatically when the gesture ends. The tap zone recognizer requires this to fail.
        @objc func handleSelectionGuard(_ gesture: UILongPressGestureRecognizer) {
            switch gesture.state {
            case .began:
                // The touch lingered — this is likely a text selection attempt, not a page tap
                isTouchDragActive = true
            case .ended, .cancelled, .failed:
                isTouchDragActive = false
            default:
                break
            }
        }

        @objc func handleSingleTap(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view, let pvc = pageViewController else { return }
            isTouchDragActive = false

            if isUserSelectingText {
                isUserSelectingText = false
                primaryWebView?.evaluateJavaScript("window.getSelection().removeAllRanges();")
                return
            }

            guard let wv = primaryWebView else {
                performTapZoneAction(location: gesture.location(in: view), width: view.bounds.width, pvc: pvc)
                return
            }

            let ptInWV = gesture.location(in: wv)
            let checkJS = """
            (function() {
                var sel = window.getSelection();
                if (sel && !sel.isCollapsed && sel.toString().trim().length > 0) return "selection";
                if (window.__selectionDragActive) return "drag";
                var el = document.elementFromPoint(\(ptInWV.x), \(ptInWV.y));
                if (!el) return "page";
                if (el.closest('mark.inksync-highlight') || el.classList.contains('inksync-highlight')) return "highlight";
                if (el.closest('a') || el.tagName === 'A') return "link";
                if (el.closest('.footnote') || el.getAttribute('epub:type') === 'noteref' || el.getAttribute('epub:type') === 'footnote') return "footnote";
                return "page";
            })();
            """

            wv.evaluateJavaScript(checkJS) { [weak self, weak view, weak pvc] result, _ in
                guard let self = self, let view = view, let pvc = pvc else { return }
                let res = result as? String ?? "page"
                if res == "selection" {
                    wv.evaluateJavaScript("window.getSelection().removeAllRanges();")
                    self.isUserSelectingText = false
                    return
                }
                if res == "highlight" || res == "drag" || res == "link" || res == "footnote" {
                    // Touched a highlight or interactive element; suppress page turn!
                    return
                }

                let location = gesture.location(in: view)
                self.performTapZoneAction(location: location, width: view.bounds.width, pvc: pvc)
            }
        }

        private func performTapZoneAction(location: CGPoint, width: CGFloat, pvc: UIPageViewController) {
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
                if let vcs = pvc.viewControllers {
                    captureSnapshot(for: vcs)
                }
                let vcs = spreadViewControllers(for: nextIndex)
                HapticEngine.light()
                isTransitioning = true
                primaryWebView?.removeFromSuperview()
                primaryWebView?.evaluateJavaScript("if(window.goToInksyncPage) window.goToInksyncPage(\(nextIndex));")
                safeSetViewControllers(vcs, direction: .forward, animated: true) { [weak self, weak pvc] completed in
                    self?.isTransitioning = false
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        let targetIndex = completed ? nextIndex : self.currentPageIndex
                        self.lastCompletedControllerIndex = targetIndex
                        self.currentPageIndex = targetIndex
                        self.parent.currentPage = targetIndex
                        self.reportScrollFraction()
                        self.primaryWebView?.evaluateJavaScript("if(window.goToInksyncPage) window.goToInksyncPage(\(targetIndex));")
                        self.mountPrimaryWebViewOnRoot()
                        if let activeVCs = pvc?.viewControllers {
                            self.captureSnapshot(for: activeVCs)
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
                if let vcs = pvc.viewControllers {
                    captureSnapshot(for: vcs)
                }
                let vcs = spreadViewControllers(for: prevIndex)
                HapticEngine.light()
                isTransitioning = true
                primaryWebView?.removeFromSuperview()
                primaryWebView?.evaluateJavaScript("if(window.goToInksyncPage) window.goToInksyncPage(\(prevIndex));")
                safeSetViewControllers(vcs, direction: .reverse, animated: true) { [weak self, weak pvc] completed in
                    self?.isTransitioning = false
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        let targetIndex = completed ? prevIndex : self.currentPageIndex
                        self.lastCompletedControllerIndex = targetIndex
                        self.currentPageIndex = targetIndex
                        self.parent.currentPage = targetIndex
                        self.reportScrollFraction()
                        self.primaryWebView?.evaluateJavaScript("if(window.goToInksyncPage) window.goToInksyncPage(\(targetIndex));")
                        self.mountPrimaryWebViewOnRoot()
                        if let activeVCs = pvc?.viewControllers {
                            self.captureSnapshot(for: activeVCs)
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

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
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

            if navigationAction.navigationType == .linkActivated || !fragment.isEmpty {
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
                            var isFN = el.classList.contains('footnote') || el.getAttribute('epub:type') === 'noteref' || el.getAttribute('epub:type') === 'footnote' || el.getAttribute('rel') === 'footnote' || el.id.toLowerCase().indexOf('fn') === 0 || el.id.toLowerCase().indexOf('note') === 0;
                            if (isFN) {
                                var text = el.innerText || el.textContent;
                                if (text && text.trim().length > 0 && text.trim().length < 1200) {
                                    window.webkit.messageHandlers.footnote.postMessage({ "id": '\(fragment)', "text": text.trim() });
                                    return;
                                }
                            }
                            // Calculate column page of anchor element
                            var rect = el.getBoundingClientRect();
                            var vp = document.getElementById('inksync-viewport') || document.body;
                            var vpRect = vp ? vp.getBoundingClientRect() : { left: 0 };
                            var offsetLeft = (rect.left - vpRect.left);
                            var pageStep = getPageStep();
                            var colWidth = _isMultiCol ? (pageStep / 2) : pageStep;
                            if (colWidth > 0) {
                                var targetPage = Math.max(0, Math.min(Math.floor(offsetLeft / colWidth), _totalPages - 1));
                                goToPage(targetPage);
                                window.webkit.messageHandlers.metrics.postMessage({ current: _targetPage, total: _totalPages });
                            }
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
                takePageSnapshot(for: currentPageIndex)
            } else if message.name == "onHighlightTapped" {
                if let dict = message.body as? [String: String], let text = dict["text"] {
                    let identifier = dict["id"]?.isEmpty == false ? dict["id"]! : text
                    parent.onHighlightTapped?(identifier)
                } else if let text = message.body as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    parent.onHighlightTapped?(text)
                }
            } else if message.name == "onTextSelected", let text = message.body as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.isUserSelectingText = true
                parent.onTextSelected?(text)
            } else if message.name == "onSelectionDismissed" {
                self.isUserSelectingText = false
                parent.onSelectionDismissed?()
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
                safeSetViewControllers(vcs, direction: .forward, animated: false)
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
            let frac = computedTotalPages > 1 ? Double(currentPageIndex) / Double(computedTotalPages - 1) : 0.0
            let size = UIScreen.main.bounds.size
            let newCSS = computeCSS(prefs: parent.prefs, size: size)
            let safeCSS = newCSS
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "`", with: "\\`")
                .replacingOccurrences(of: "\n", with: " ")
            let js = """
            (function() {
                var currentFrac = \(frac);
                var el = document.getElementById('__inksync_live__');
                if (el) { el.innerHTML = `\(safeCSS)`; }
                if (window.computeMetrics) {
                    var newTotal = computeMetrics();
                    if (newTotal > 1 && currentFrac > 0.0) {
                        _targetPage = Math.max(0, Math.min(Math.round(currentFrac * (newTotal - 1)), newTotal - 1));
                    }
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
            let js = """
            (function() {
                var sel = window.getSelection();
                if (!sel || sel.isCollapsed || sel.rangeCount === 0) return "";
                var text = sel.toString();
                if (!text || text.trim().length === 0) return "";
                if (window.applyInksyncHighlight) {
                    window.applyInksyncHighlight('', '#FFD600', '');
                } else {
                    try {
                        var range = sel.getRangeAt(0);
                        var mark = document.createElement('mark');
                        mark.className = 'inksync-highlight';
                        mark.style.setProperty('background-color', '#FFD600', 'important');
                        mark.style.color = 'inherit';
                        mark.style.borderRadius = '3px';
                        range.surroundContents(mark);
                        sel.removeAllRanges();
                    } catch(e) {}
                }
                return text;
            })();
            """
            wv.evaluateJavaScript(js) { [weak self] result, _ in
                if let text = result as? String, !text.isEmpty {
                    self?.parent.onHighlightCreated?(text)
                    if let cur = self?.currentPageIndex {
                        self?.takePageSnapshot(for: cur)
                    }
                }
            }
        }

        private func restoreHighlights(in webView: WKWebView) {
            guard let pdfID = parent.pdfID else { return }
            let spineLabel = parent.spineItem.label.lowercased()
            let spineHref = parent.spineItem.href.lowercased()
            let annotations = AnnotationStore.shared.annotations(for: pdfID)
                .filter { ann in
                    guard ann.kind == .highlight || ann.kind == .underline || ann.kind == .strikeOut else { return false }
                    if let title = ann.chapterTitle?.lowercased(), !title.isEmpty {
                        if !spineLabel.isEmpty && (title.contains(spineLabel) || spineLabel.contains(title)) { return true }
                        if !spineHref.isEmpty && (title.contains(spineHref) || spineHref.contains(title)) { return true }
                    }
                    return true
                }
            for ann in annotations {
                guard let text = ann.selectedText, let color = ann.colorHex else { continue }
                let idStr = ann.id.uuidString
                let safeText = text
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "`", with: "\\`")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                    .replacingOccurrences(of: "\n", with: " ")
                let safeSymbol = (ann.marginaliaSymbolRaw ?? "").replacingOccurrences(of: "'", with: "\\'")
                let styleStr = ann.kind == .underline ? "underline" : (ann.kind == .strikeOut ? "strikeout" : "highlight")
                let js = "window.restoreInksyncHighlight('\(idStr)', `\(safeText)`, '\(color)', '\(safeSymbol)', '\(styleStr)');"
                webView.evaluateJavaScript(js)
            }
        }

        // MARK: - CSS & JS Construction

        func buildFullCSS() -> String {
            let prefs = parent.prefs
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
            let isPhone = UIDevice.current.userInterfaceIdiom == .phone
            let isLandscape = renderWidth > renderHeight
            let defaultColumns = isLandscape ? (prefs.autoLandscapeDualPage ? 2 : (isPad ? 2 : 1)) : 1
            let cols = (isPhone && !isLandscape) ? 1 : (prefs.columnCount == 0 ? defaultColumns : prefs.columnCount)

            let m = isPhone ? max(12.0, min(margin, 16.0)) : max(20.0, margin)
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
            ::selection {
                background-color: rgba(255, 214, 10, 0.5) !important;
                color: inherit !important;
            }
            ::-moz-selection {
                background-color: rgba(255, 214, 10, 0.5) !important;
                color: inherit !important;
            }
            mark.inksync-highlight, .inksync-highlight {
                background-color: rgba(255, 214, 10, 0.45);
                color: inherit !important;
                border-radius: 3px !important;
                padding: 1px 2px !important;
                margin: 0 !important;
                box-decoration-break: clone !important;
                -webkit-box-decoration-break: clone !important;
                cursor: pointer !important;
                mix-blend-mode: multiply;
                transition: opacity 0.15s ease, filter 0.15s ease !important;
            }
            mark.inksync-highlight:active {
                filter: brightness(0.88) !important;
                opacity: 0.85 !important;
            }
            mark.inksync-highlight[data-symbol]:after {
                content: " [" attr(data-symbol) "]";
                font-size: 0.75em !important;
                font-weight: bold !important;
                color: #ff9800 !important;
                opacity: 0.9 !important;
                vertical-align: super !important;
            }
            html, body {
                margin: 0 !important; padding: 0 !important;
                width: 100% !important;
                height: 100% !important;
                column-width: auto !important;
                touch-action: pan-y pinch-zoom;
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
                -webkit-user-select: text !important;
                user-select: text !important;
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
                width: 100% !important;
                height: 100% !important;
                max-width: 100% !important;
                overflow: visible !important;
                -webkit-user-select: text !important;
                user-select: text !important;
                \(pagedCSS)
                /* No CSS transition — column jumps are instantaneous; animation belongs to UIPageViewController curl. */
            }
            #inksync-viewport *, body * {
                max-width: 100% !important;
                box-sizing: border-box !important;
                word-break: break-word !important;
                overflow-wrap: break-word !important;
                -webkit-user-select: text !important;
                user-select: text !important;
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
            p, div, span, li, td, th, h1, h2, h3, h4, h5, h6 { color: \(textColor) !important; line-height: \(lineHeight); \(prefs.isBoldTextEnabled ? "font-weight: 600 !important;" : "") }
            img, svg, .page, .chunk-container { display: block !important; margin-left: auto !important; margin-right: auto !important; }
            img { max-width: 100% !important; max-height: 100% !important; height: auto !important; border-radius: 4px; object-fit: contain !important; }
            img.gaiji, img[gaiji], img.inline-image { display: inline-block !important; vertical-align: middle !important; max-height: 1.2em !important; width: auto !important; margin: 0 0.1em !important; }
            pre, table, code { max-width: 100% !important; overflow-x: auto !important; word-wrap: break-word !important; white-space: pre-wrap !important; }
            a { color: \(linkColor) !important; }
            blockquote { border-left: 3px solid \(linkColor); margin-left: 0; padding-left: 16px; opacity: 0.85; }
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
                if (_targetPage >= 99999) return; // Wait for computeMetrics to resolve true total pages!
                var spreadIndex = _isMultiCol ? Math.floor(_targetPage / 2) : _targetPage;
                var shift = spreadIndex * pageStep;

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
                var colWidth = _isMultiCol ? (pageStep / 2) : pageStep;
                var total = Math.floor((scrollW + 5) / colWidth);
                var remainder = (scrollW + 5) % colWidth;
                if (remainder > 35) {
                    total += 1;
                }
                _totalPages = Math.max(1, total);
                if (_targetPage >= 99999 || _targetPage >= _totalPages) {
                    _targetPage = Math.max(0, _totalPages - 1);
                }
                applyPagePosition();
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

            document.addEventListener('selectionchange', function() {
                var sel = window.getSelection();
                if (!sel || sel.isCollapsed || sel.rangeCount === 0) {
                    if (window.__lastSelectedText) {
                        window.__lastSelectedText = "";
                        try { window.webkit.messageHandlers.onSelectionDismissed.postMessage({}); } catch(e) {}
                    }
                    return;
                }
                var text = sel.toString().trim();
                if (text.length > 0) {
                    window.__lastSelectedRange = sel.getRangeAt(0).cloneRange();
                    if (text !== window.__lastSelectedText) {
                        window.__lastSelectedText = text;
                        try {
                            window.webkit.messageHandlers.onTextSelected.postMessage(text);
                        } catch(e) {}
                    }
                }
            });

            // ✅ Fix: Track touch movement so the native tap-zone guard can detect
            // text-selection drags before the UITapGestureRecognizer fires.
            (function() {
                var __touchStartX = 0, __touchStartY = 0;
                document.addEventListener('touchstart', function(e) {
                    var t = e.touches[0];
                    if (t) { __touchStartX = t.clientX; __touchStartY = t.clientY; }
                    window.__selectionDragActive = false;
                }, { passive: true });
                document.addEventListener('touchmove', function(e) {
                    var t = e.touches[0];
                    if (t) {
                        var dx = t.clientX - __touchStartX;
                        var dy = t.clientY - __touchStartY;
                        if (Math.sqrt(dx*dx + dy*dy) > 5) {
                            window.__selectionDragActive = true;
                        }
                    }
                }, { passive: true });
                document.addEventListener('touchend', function() {
                    // Keep flag alive for 200ms so Swift tap handler can read it without edge turn conflicts
                    setTimeout(function() { window.__selectionDragActive = false; }, 200);
                }, { passive: true });
            })();

            document.addEventListener('click', function(e) {
                var mark = e.target.closest ? e.target.closest('mark.inksync-highlight') : null;
                if (mark) {
                    var id = mark.getAttribute('data-id') || '';
                    var text = mark.textContent.trim();
                    if (id || text) {
                        try {
                            window.webkit.messageHandlers.onHighlightTapped.postMessage({ id: id, text: text });
                        } catch(err) {
                            try { window.webkit.messageHandlers.onHighlightTapped.postMessage(text); } catch(x) {}
                        }
                    }
                }
            }, true);

            window.applyInksyncHighlight = function(id, colorHex, symbol, style) {
                if (typeof id === 'string' && id.indexOf('#') === 0) {
                    style = symbol;
                    symbol = colorHex;
                    colorHex = id;
                    id = '';
                }
                var sel = window.getSelection();
                var range = null;
                if (sel && sel.rangeCount > 0 && !sel.isCollapsed) {
                    range = sel.getRangeAt(0);
                } else if (window.__lastSelectedRange) {
                    range = window.__lastSelectedRange;
                }
                if (!range) return "";
                var text = (sel && !sel.isCollapsed) ? sel.toString().trim() : (range.toString ? range.toString().trim() : "");
                if (!text && window.__lastSelectedText) text = window.__lastSelectedText;
                if (!text) return "";
                var mark = document.createElement('mark');
                mark.className = 'inksync-highlight';
                if (id) mark.setAttribute('data-id', id);
                if (style) mark.setAttribute('data-style', style);
                if (style === 'underline') {
                    mark.style.setProperty('background-color', 'transparent', 'important');
                    mark.style.setProperty('text-decoration', 'underline', 'important');
                    mark.style.setProperty('text-decoration-color', colorHex || '#FF9100', 'important');
                    mark.style.setProperty('text-underline-offset', '3px', 'important');
                } else if (style === 'strikeout') {
                    mark.style.setProperty('background-color', 'transparent', 'important');
                    mark.style.setProperty('text-decoration', 'line-through', 'important');
                    mark.style.setProperty('text-decoration-color', colorHex || '#FF4081', 'important');
                } else {
                    mark.style.setProperty('background-color', colorHex || '#FFD600', 'important');
                    mark.style.mixBlendMode = 'multiply';
                }
                mark.style.color = 'inherit';
                mark.style.borderRadius = '3px';
                if (symbol) {
                    mark.setAttribute('data-symbol', symbol);
                }
                try {
                    range.surroundContents(mark);
                } catch(e) {
                    try {
                        var frag = range.extractContents();
                        mark.appendChild(frag);
                        range.insertNode(mark);
                    } catch(err) {
                        var walker = document.createTreeWalker(range.commonAncestorContainer, NodeFilter.SHOW_TEXT, null, false);
                        var textNode;
                        while ((textNode = walker.nextNode())) {
                            if (range.intersectsNode(textNode)) {
                                var subMark = document.createElement('mark');
                                subMark.className = 'inksync-highlight';
                                if (id) subMark.setAttribute('data-id', id);
                                if (style) subMark.setAttribute('data-style', style);
                                if (style === 'underline') {
                                    subMark.style.setProperty('background-color', 'transparent', 'important');
                                    subMark.style.setProperty('text-decoration', 'underline', 'important');
                                    subMark.style.setProperty('text-decoration-color', colorHex || '#FF9100', 'important');
                                    subMark.style.setProperty('text-underline-offset', '3px', 'important');
                                } else if (style === 'strikeout') {
                                    subMark.style.setProperty('background-color', 'transparent', 'important');
                                    subMark.style.setProperty('text-decoration', 'line-through', 'important');
                                    subMark.style.setProperty('text-decoration-color', colorHex || '#FF4081', 'important');
                                } else {
                                    subMark.style.setProperty('background-color', colorHex || '#FFD600', 'important');
                                    subMark.style.mixBlendMode = 'multiply';
                                }
                                if (symbol) subMark.setAttribute('data-symbol', symbol);
                                var startOffset = (textNode === range.startContainer) ? range.startOffset : 0;
                                var endOffset = (textNode === range.endContainer) ? range.endOffset : textNode.nodeValue.length;
                                var subRange = document.createRange();
                                subRange.setStart(textNode, startOffset);
                                subRange.setEnd(textNode, endOffset);
                                try { subRange.surroundContents(subMark); } catch(x) {}
                            }
                        }
                    }
                }
                if (sel) sel.removeAllRanges();
                window.__lastSelectedText = "";
                window.__lastSelectedRange = null;
                try { window.webkit.messageHandlers.highlight.postMessage(text); } catch(e) {}
                return text;
            };

            window.updateInksyncHighlightColor = function(idOrText, newColorHex) {
                if (!idOrText) return;
                var targetMarks = [];
                var idMark = document.querySelector('mark.inksync-highlight[data-id="' + idOrText + '"]');
                if (idMark) {
                    targetMarks.push(idMark);
                } else {
                    var marks = document.querySelectorAll('mark.inksync-highlight');
                    for (var i = 0; i < marks.length; i++) {
                        if (marks[i].textContent.indexOf(idOrText) !== -1 || idOrText.indexOf(marks[i].textContent) !== -1) {
                            targetMarks.push(marks[i]);
                        }
                    }
                }
                for (var j = 0; j < targetMarks.length; j++) {
                    targetMarks[j].style.backgroundColor = newColorHex;
                }
            };

            window.removeInksyncHighlight = function(idOrText) {
                if (!idOrText) return;
                var targetMarks = [];
                var idMark = document.querySelector('mark.inksync-highlight[data-id="' + idOrText + '"]');
                if (idMark) {
                    targetMarks.push(idMark);
                } else {
                    var marks = document.querySelectorAll('mark.inksync-highlight');
                    for (var i = 0; i < marks.length; i++) {
                        if (marks[i].textContent.indexOf(idOrText) !== -1 || idOrText.indexOf(marks[i].textContent) !== -1) {
                            targetMarks.push(marks[i]);
                        }
                    }
                }
                for (var j = 0; j < targetMarks.length; j++) {
                    var mark = targetMarks[j];
                    var parent = mark.parentNode;
                    if (parent) {
                        while (mark.firstChild) {
                            parent.insertBefore(mark.firstChild, mark);
                        }
                        parent.removeChild(mark);
                        parent.normalize();
                    }
                }
            };

            window.restoreInksyncHighlight = function(id, textToFind, colorHex, symbol, style) {
                if (!textToFind) return;
                var trimmed = textToFind.trim();
                var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null, false);
                var node;
                while ((node = walker.nextNode())) {
                    if (node.parentElement && node.parentElement.closest && node.parentElement.closest('mark.inksync-highlight')) {
                        continue;
                    }
                    var val = node.nodeValue;
                    var idx = val.indexOf(textToFind);
                    var matchLen = textToFind.length;
                    if (idx === -1 && trimmed !== textToFind) {
                        idx = val.indexOf(trimmed);
                        matchLen = trimmed.length;
                    }
                    if (idx !== -1) {
                        try {
                            var range = document.createRange();
                            range.setStart(node, idx);
                            range.setEnd(node, idx + matchLen);
                            var mark = document.createElement('mark');
                            mark.className = 'inksync-highlight';
                            if (id) mark.setAttribute('data-id', id);
                            if (style) mark.setAttribute('data-style', style);
                            if (style === 'underline') {
                                mark.style.setProperty('background-color', 'transparent', 'important');
                                mark.style.setProperty('text-decoration', 'underline', 'important');
                                mark.style.setProperty('text-decoration-color', colorHex || '#FF9100', 'important');
                                mark.style.setProperty('text-underline-offset', '3px', 'important');
                            } else if (style === 'strikeout') {
                                mark.style.setProperty('background-color', 'transparent', 'important');
                                mark.style.setProperty('text-decoration', 'line-through', 'important');
                                mark.style.setProperty('text-decoration-color', colorHex || '#FF4081', 'important');
                            } else {
                                mark.style.setProperty('background-color', colorHex || '#FFD600', 'important');
                                mark.style.mixBlendMode = 'multiply';
                            }
                            mark.style.color = 'inherit';
                            mark.style.borderRadius = '3px';
                            if (symbol) {
                                mark.setAttribute('data-symbol', symbol);
                            }
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
        // scaleToFill maps snapshot pixels 1:1 to view bounds — avoids shrinking/expanding text during 3D page curl.
        iv.contentMode = .scaleToFill
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
