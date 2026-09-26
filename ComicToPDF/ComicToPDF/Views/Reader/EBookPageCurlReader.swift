import SwiftUI
import WebKit
import PencilKit
import SwiftData
import Combine

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
    let prefs: EBookPreferences
    let colorScheme: ColorScheme
    @Binding var currentPage: Int
    var initialPage: Int
    @Binding var totalPages: Int
    var startAtEndOfChapter: Bool = false
    var spineIndex: Int = 0
    var isPencilMode: Bool = false

    var onNext: () -> Void
    var onPrev: () -> Void
    var onCenterTap: () -> Void
    var onPageTurn: (() -> Void)? = nil
    var isHUDShowing: Bool = false
    var onHighlightCreated: ((String) -> Void)? = nil
    var onHighlightCreatedWithMetadata: ((String, String, String) -> Void)? = nil
    var onHighlightTapped: ((String) -> Void)? = nil
    var onTextSelected: ((String) -> Void)? = nil
    var onSelectionDismissed: (() -> Void)? = nil
    var pdfID: UUID? = nil
    var initialScrollFraction: Double = 0.0
    var onScrollFractionChanged: ((Double) -> Void)? = nil
    @Binding var webViewRef: WKWebView?
    var onFootnoteTapped: ((String) -> Void)? = nil
    var targetAnchor: String? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let isInstant = (prefs.pageTurnStyle == .instant)
        let transitionStyle: UIPageViewController.TransitionStyle = isInstant ? .scroll : .pageCurl
        let pvc = InksyncPageViewController(
            transitionStyle: transitionStyle,
            navigationOrientation: .horizontal,
            options: nil
        )
        pvc.isDoubleSided = false
        pvc.dataSource = context.coordinator
        pvc.delegate = context.coordinator
        pvc.view.clipsToBounds = true
        pvc.view.layer.masksToBounds = true

        pvc.onLayoutSubviews = { [weak coordinator = context.coordinator] bounds in
            guard bounds.width > 1 && bounds.height > 1 else { return }
            coordinator?.handleContainerBoundsUpdated(bounds)
        }

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

        // ── 3-Finger Tap Redo shortcut (finger only) ──────────────────────────────
        let threeFingerTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleThreeFingerTap(_:)))
        threeFingerTap.numberOfTouchesRequired = 3
        threeFingerTap.numberOfTapsRequired = 1
        threeFingerTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        threeFingerTap.cancelsTouchesInView = false
        threeFingerTap.delegate = context.coordinator
        view.addGestureRecognizer(threeFingerTap)

        // ── 2-Finger Tap Undo shortcut (finger only) ──────────────────────────────
        let twoFingerTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTwoFingerTap(_:)))
        twoFingerTap.numberOfTouchesRequired = 2
        twoFingerTap.numberOfTapsRequired = 1
        twoFingerTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        twoFingerTap.cancelsTouchesInView = false
        twoFingerTap.delegate = context.coordinator
        view.addGestureRecognizer(twoFingerTap)

        // ── Apple Pencil Pro & Apple Pencil 2 native interaction (iPad only) ──
        if UIDevice.current.userInterfaceIdiom == .pad {
            let pencilInteraction = UIPencilInteraction()
            pencilInteraction.delegate = context.coordinator
            view.addInteraction(pencilInteraction)
        }

        // Single tap — handles left/center/right zones — fires instantly (< 5ms) on touch-up
        let singleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleSingleTap(_:))
        )
        singleTap.numberOfTapsRequired = 1
        singleTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        singleTap.cancelsTouchesInView = false
        singleTap.delegate = context.coordinator
        singleTap.require(toFail: twoFingerTap)
        singleTap.require(toFail: threeFingerTap)
        view.addGestureRecognizer(singleTap)

        // Pinch to Zoom / Scale Text (Kindle-style interactive text scaling)
        let pinch = UIPinchGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePinch(_:))
        )
        pinch.cancelsTouchesInView = false
        pinch.delegate = context.coordinator
        view.addGestureRecognizer(pinch)

        context.coordinator.pageViewController = pvc
        context.coordinator.mountPrimaryWebViewOnRoot()

        DispatchQueue.main.async {
            self.webViewRef = context.coordinator.primaryWebView
        }

        let initialVCs = context.coordinator.spreadViewControllers(for: initialPage)
        context.coordinator.safeSetViewControllers(initialVCs, direction: .forward, animated: false)

        // Start chapter load asynchronously
        context.coordinator.loadChapterAndPresent()

        return pvc
    }

    func updateUIViewController(_ uiViewController: UIPageViewController, context: Context) {
        let oldParent = context.coordinator.parent
        context.coordinator.parent = self
        context.coordinator.updatePencilInteractivity(isPencilMode: self.isPencilMode)

        if self.webViewRef == nil && context.coordinator.primaryWebView != nil {
            DispatchQueue.main.async {
                self.webViewRef = context.coordinator.primaryWebView
            }
        }

        // If spine item (chapter) changed, reset transitioning lock and reload in-place
        let chapterChanged = oldParent.spineItem.href != self.spineItem.href || oldParent.spineItem.id != self.spineItem.id || oldParent.spineIndex != self.spineIndex
        if chapterChanged {
            context.coordinator.isTransitioning = false
            context.coordinator.computedTotalPages = 1
            if self.startAtEndOfChapter || self.initialScrollFraction >= 0.99 {
                context.coordinator.needsJumpToEnd = true
            }
            context.coordinator.loadChapterAndPresent()
            return
        }

        // Guard against re-entrant updates during interactive curl gestures
        if context.coordinator.isTransitioning { return }

        // If typography / theme preferences changed, update live styles in WKWebView
        if oldParent.prefs.fontSize != self.prefs.fontSize ||
           oldParent.prefs.fontFamily != self.prefs.fontFamily ||
           oldParent.prefs.activeTheme.id != self.prefs.activeTheme.id ||
           oldParent.prefs.customThemeBg != self.prefs.customThemeBg ||
           oldParent.prefs.customThemeText != self.prefs.customThemeText ||
           oldParent.prefs.readingFilter != self.prefs.readingFilter ||
           oldParent.prefs.lineHeight != self.prefs.lineHeight ||
           oldParent.prefs.letterSpacing != self.prefs.letterSpacing ||
           oldParent.prefs.wordSpacing != self.prefs.wordSpacing ||
           oldParent.prefs.textAlign != self.prefs.textAlign ||
           oldParent.prefs.textMargin != self.prefs.textMargin ||
           oldParent.prefs.paragraphSpacing != self.prefs.paragraphSpacing ||
           oldParent.prefs.paragraphIndent != self.prefs.paragraphIndent ||
           oldParent.prefs.hyphenation != self.prefs.hyphenation ||
           oldParent.prefs.isBoldTextEnabled != self.prefs.isBoldTextEnabled ||
           oldParent.prefs.columnCount != self.prefs.columnCount ||
           oldParent.prefs.autoLandscapeDualPage != self.prefs.autoLandscapeDualPage ||
           oldParent.prefs.fullBleedSpreads != self.prefs.fullBleedSpreads {
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

        if let currentVCs = uiViewController.viewControllers as? [EBookPageContentViewController] {
            let displayedIndices = currentVCs.map { $0.pageIndex }
            if displayedIndices.contains(targetIndex) {
                // Ensure primaryWebView is framed to valid bounds and mounted to root on initial layout
                if uiViewController.view.bounds.width > 1 && uiViewController.view.bounds.height > 1 {
                    context.coordinator.mountPrimaryWebViewOnRoot()
                }
                return // Target page is ALREADY displayed on screen — do NOT touch setViewControllers!
            }

            let currentVC = currentVCs.first
            context.coordinator.currentPageIndex = targetIndex
            context.coordinator.primaryWebView?.evaluateJavaScript("if(window.goToInksyncPage) window.goToInksyncPage(\(targetIndex));")

            let vcs = context.coordinator.spreadViewControllers(for: targetIndex)
            let isForward = targetIndex >= (currentVC?.pageIndex ?? 0)
            let direction: UIPageViewController.NavigationDirection = isForward ? .forward : .reverse
            context.coordinator.safeSetViewControllers(vcs, direction: direction, animated: false) { _ in
                context.coordinator.mountPrimaryWebViewOnRoot()
                context.coordinator.takePageSnapshot(for: targetIndex)
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
    class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate, WKNavigationDelegate, WKScriptMessageHandler, UIGestureRecognizerDelegate, PKCanvasViewDelegate, UIPencilInteractionDelegate {
        var parent: EBookPageCurlReader
        weak var pageViewController: UIPageViewController?
        var isTransitioning: Bool = false {
            didSet {
                if isTransitioning {
                    // Watchdog: auto-release transitioning lock after 450ms in case a UIKit gesture or animation drops its completion
                    transitionWatchdogTask?.cancel()
                    transitionWatchdogTask = Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: 450_000_000)
                        guard !Task.isCancelled else { return }
                        self?.isTransitioning = false
                    }
                } else {
                    transitionWatchdogTask?.cancel()
                    transitionWatchdogTask = nil
                }
            }
        }
        private var transitionWatchdogTask: Task<Void, Never>? = nil
        var lastCompletedControllerIndex: Int? = nil

        // Chapter & Primary WebEngine state
        private var chapterHTML: String = ""
        private var chapterBaseURL: URL?
        private var styledCSS: String = ""
        var computedTotalPages: Int = 1
        var currentPageIndex: Int = 0
        var needsJumpToEnd: Bool = false
        private var hasLoadedInitialPage: Bool = false

        // Primary master WKWebView — used for text layout, metrics & live interactions
        private(set) var primaryWebView: WKWebView?
        // Apple Pencil Inking Overlay Engine
        private(set) var pencilCanvas: PassthroughPKCanvasView?
        private var inkingCancellables = Set<AnyCancellable>()
        private var debounceSaveDrawingTask: Task<Void, Never>? = nil
        // Pre-rendered column snapshots — used for instant, zero-lag 3D page curling
        private var pageSnapshots: [Int: UIImage] = [:]
        // Background pre-cache WKWebView for silent offscreen snapshot generation
        private var backgroundPrecacheWebView: WKWebView?
        private var precacheTask: Task<Void, Never>?
        // Tokens for block-based NotificationCenter observers to prevent memory leaks
        nonisolated(unsafe) private var observerTokens: [NSObjectProtocol] = []

        init(_ parent: EBookPageCurlReader) {
            self.parent = parent
            super.init()
            setupPrimaryWebView()

            // Initialize Apple Pencil inking canvas overlay
            let canvas = PassthroughPKCanvasView()
            canvas.overrideUserInterfaceStyle = .light
            canvas.backgroundColor = .clear
            canvas.isOpaque = false
            canvas.bounces = false
            canvas.isScrollEnabled = false
            canvas.delegate = self
            canvas.tool = InksyncInkingState.shared.makePKTool()
            self.pencilCanvas = canvas
            self.updatePencilInteractivity(isPencilMode: parent.isPencilMode)

            InksyncInkingState.shared.$activePreset
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    self?.pencilCanvas?.tool = InksyncInkingState.shared.makePKTool()
                }
                .store(in: &inkingCancellables)

            InksyncInkingState.shared.$activeToolMode
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    guard let self = self else { return }
                    self.pencilCanvas?.tool = InksyncInkingState.shared.makePKTool()
                    self.updatePencilInteractivity(isPencilMode: self.parent.isPencilMode)
                }
                .store(in: &inkingCancellables)

            InksyncInkingState.shared.$eraserType
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    self?.pencilCanvas?.tool = InksyncInkingState.shared.makePKTool()
                }
                .store(in: &inkingCancellables)

            let undoToken = NotificationCenter.default.addObserver(
                forName: NSNotification.Name("EPUBReaderUndoDrawing"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.pencilCanvas?.undoManager?.undo()
                }
            }
            observerTokens.append(undoToken)

            let redoToken = NotificationCenter.default.addObserver(
                forName: NSNotification.Name("EPUBReaderRedoDrawing"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.pencilCanvas?.undoManager?.redo()
                }
            }
            observerTokens.append(redoToken)

            let clearToken = NotificationCenter.default.addObserver(
                forName: NSNotification.Name("EPUBReaderClearDrawing"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.clearCurrentPageDrawing()
                }
            }
            observerTokens.append(clearToken)

            let forwardToken = NotificationCenter.default.addObserver(
                forName: NSNotification.Name("EBookTurnPageForward"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self = self, let pvc = self.pageViewController else { return }
                    self.turnForward(pvc)
                }
            }
            observerTokens.append(forwardToken)

            let backwardToken = NotificationCenter.default.addObserver(
                forName: NSNotification.Name("EBookTurnPageBackward"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self = self, let pvc = self.pageViewController else { return }
                    self.turnBackward(pvc)
                }
            }
            observerTokens.append(backwardToken)

            // Memory & Battery Protection: Purge distant/offscreen page snapshots on system memory warning
            let memoryToken = NotificationCenter.default.addObserver(
                forName: UIApplication.didReceiveMemoryWarningNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self = self else { return }
                    self.purgeDistantSnapshots(keepCurrent: true)
                }
            }
            observerTokens.append(memoryToken)

            // Backgrounding Protection: Discard all off-screen textures when app enters background
            let bgToken = NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self = self else { return }
                    self.purgeDistantSnapshots(keepCurrent: true)
                }
            }
            observerTokens.append(bgToken)
        }

        /// Prunes snapshot cache to a strict sliding window of (centerIndex ± maxSnapshotDistance)
        /// Preventing retina GPU texture memory leaks and battery drain (KOReader/SumatraPDF model).
        private let maxSnapshotDistance = ReaderCacheLimits.epubSnapshotDistance

        func pruneSnapshotCache(around centerIndex: Int) {
            let minKeep = centerIndex - maxSnapshotDistance
            let maxKeep = centerIndex + maxSnapshotDistance
            pageSnapshots = pageSnapshots.filter { key, _ in
                key >= minKeep && key <= maxKeep
            }
        }

        func purgeDistantSnapshots(keepCurrent: Bool = true) {
            if keepCurrent {
                let current = currentPageIndex
                pageSnapshots = pageSnapshots.filter { key, _ in
                    abs(key - current) <= 1
                }
            } else {
                pageSnapshots.removeAll()
            }
        }

        deinit {
            for token in observerTokens {
                NotificationCenter.default.removeObserver(token)
            }
        }

        var isUserSelectingText: Bool = false
        // Tracks whether the most recent touch began as a drag (text-selection intent).
        // Set by JS touchstart/touchend movement tracking and reset by handleSingleTap.
        var isTouchDragActive: Bool = false
        weak var selectionGuard: UILongPressGestureRecognizer?

        var containerBounds: CGRect {
            if let pvc = pageViewController, pvc.view.bounds.width > 1 && pvc.view.bounds.height > 1 {
                return pvc.view.bounds
            }
            return UIScreen.main.bounds
        }

        var containerSize: CGSize {
            containerBounds.size
        }

        // Typographic Measure Invariant (Oliver Reichenstein standard):
        // Dual-column spreads require at least 820pt of render width so each column maintains
        // a 380pt+ width (preserving 65-75 characters per line).
        // Typographic Measure Invariant (Oliver Reichenstein standard):
        // Dual-column spreads require at least 820pt of render width so each column maintains
        // a 380pt+ measure (preserving 65-75 characters per line).
        // If Split View narrows render width below 820pt, auto-mode gracefully falls back to a single column.
        static let minDualColumnRenderWidth: CGFloat = 820.0

        static func computeColumnCount(prefs: EBookPreferences, size: CGSize) -> Int {
            let renderWidth = size.width > 0 ? size.width : UIScreen.main.bounds.width
            let renderHeight = size.height > 0 ? size.height : UIScreen.main.bounds.height
            let isLandscape = renderWidth > renderHeight

            // Strict Invariant (Apple Books & Kindle Parity):
            // In Portrait, ALWAYS single page mode (1 column) regardless of device or settings.
            guard isLandscape else {
                return 1
            }

            if renderWidth < minDualColumnRenderWidth && prefs.columnCount == 0 {
                return 1
            }

            return prefs.effectiveColumnCount(for: size)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            if gestureRecognizer is UIPinchGestureRecognizer || otherGestureRecognizer is UIPinchGestureRecognizer {
                return true
            }
            if let tap = gestureRecognizer as? UITapGestureRecognizer, tap.numberOfTouchesRequired >= 2 {
                return true
            }
            if let otherTap = otherGestureRecognizer as? UITapGestureRecognizer, otherTap.numberOfTouchesRequired >= 2 {
                return true
            }
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
            // Block page curl pan if user is actively dragging a selection
            if isTouchDragActive {
                if gestureRecognizer is UIPanGestureRecognizer {
                    return false
                }
            }
            // Strict split-screen isolation: pan gestures must stay within reader bounds
            if let pan = gestureRecognizer as? UIPanGestureRecognizer, let targetView = pan.view {
                let loc = pan.location(in: targetView)
                if !targetView.bounds.contains(loc) {
                    return false
                }
            }
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let view = gestureRecognizer.view else { return false }
            let location = touch.location(in: view)
            guard view.bounds.contains(location) else { return false }

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
            for token in observerTokens {
                NotificationCenter.default.removeObserver(token)
            }
            observerTokens.removeAll()
            NotificationCenter.default.removeObserver(self)

            debounceSaveDrawingTask?.cancel()
            debounceSaveDrawingTask = nil
            precacheTask?.cancel()
            precacheTask = nil
            backgroundPrecacheWebView?.stopLoading()
            backgroundPrecacheWebView?.removeFromSuperview()
            backgroundPrecacheWebView = nil
            saveCurrentDrawing()
            inkingCancellables.removeAll()
            pencilCanvas?.removeFromSuperview()
            pencilCanvas = nil

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
            let handlerProxy = WeakScriptMessageHandler(delegate: self)
            controller.add(handlerProxy, name: "metrics")
            controller.add(handlerProxy, name: "highlight")
            controller.add(handlerProxy, name: "onHighlightTapped")
            controller.add(handlerProxy, name: "onTextSelected")
            controller.add(handlerProxy, name: "onSelectionDismissed")
            controller.add(handlerProxy, name: "footnote")
            controller.add(handlerProxy, name: "scrollFraction")

            let initialFrame = pageViewController?.view.bounds ?? CGRect(x: 0, y: 0, width: 768, height: 1024)
            let wv = HighlightableWebView(frame: initialFrame, configuration: config)
            wv.clipsToBounds = true
            wv.layer.masksToBounds = true
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
            wv.scrollView.pinchGestureRecognizer?.isEnabled = false

            self.primaryWebView = wv
            self.parent.webViewRef = wv
            DispatchQueue.main.async { [weak self] in
                self?.parent.webViewRef = wv
            }
        }

        // MARK: - Chapter Loading

        func loadChapterAndPresent() {
            hasLoadedInitialPage = false
            currentPageIndex = parent.initialPage
            pageSnapshots.removeAll()

            Task { @MainActor in
                guard let dir = parent.unzipDir else { return }
                var rawHref = parent.spineItem.href
                if let anchorIdx = rawHref.firstIndex(of: "#") {
                    rawHref = String(rawHref[..<anchorIdx])
                }
                var contentURL = dir.appendingPathComponent(rawHref).standardizedFileURL
                if !FileManager.default.fileExists(atPath: contentURL.path) {
                    if let decoded = rawHref.removingPercentEncoding {
                        contentURL = dir.appendingPathComponent(decoded).standardizedFileURL
                    }
                }
                guard FileManager.default.fileExists(atPath: contentURL.path) else {
                    Logger.shared.log("EBookPageCurlReader: Content file not found at \(contentURL.path) for href \(parent.spineItem.href)", category: "EBook", type: .error)
                    return
                }

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

                // Preserve native EPUB chapter markup directly to avoid stripping chapter styling & figures
                var html: String
                if rawHTML.contains("pdf-page-marker") || self.parent.spineItem.href.hasSuffix("reflow.html") {
                    html = rawHTML
                } else if rawHTML.range(of: "<body", options: .caseInsensitive) != nil {
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
                self.loadDrawingForCurrentPage()

                let goingBackward = self.parent.startAtEndOfChapter || self.parent.initialScrollFraction >= 0.99
                if goingBackward {
                    self.needsJumpToEnd = true
                }

                // Load HTML into primary master WKWebView directly in-memory
                let initialScriptPage = self.needsJumpToEnd ? 99999 : self.currentPageIndex
                let fullHTML = self.buildPageHTML(for: initialScriptPage)
                self.primaryWebView?.loadHTMLString(fullHTML, baseURL: self.chapterBaseURL)

                // Present initial page VC with direction matching navigation intent
                let vcs = self.spreadViewControllers(for: self.currentPageIndex)
                let direction: UIPageViewController.NavigationDirection = goingBackward ? .reverse : .forward
                self.safeSetViewControllers(vcs, direction: direction, animated: false)
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
                    let second = (currentPageIndex + 1 < computedTotalPages)
                        ? makePageViewController(for: currentPageIndex + 1)
                        : makeBlankPageViewController(for: currentPageIndex + 1)
                    safeVCs = [first, second]
                } else {
                    let first = makePageViewController(for: currentPageIndex)
                    let second = (currentPageIndex + 1 < computedTotalPages)
                        ? makePageViewController(for: currentPageIndex + 1)
                        : makeBlankPageViewController(for: currentPageIndex + 1)
                    safeVCs = [first, second]
                }
            }

            if let active = pvc.viewControllers, active.count == safeVCs.count {
                let matches = zip(active, safeVCs).allSatisfy { (act, target) in
                    if let actPage = act as? EBookPageContentViewController, let targetPage = target as? EBookPageContentViewController {
                        return actPage.pageIndex == targetPage.pageIndex
                    }
                    return act === target
                }
                if matches {
                    self.mountPrimaryWebViewOnRoot()
                    completion?(true)
                    return
                }
            }

            pvc.setViewControllers(safeVCs, direction: direction, animated: animated) { [weak self] finished in
                self?.mountPrimaryWebViewOnRoot()
                completion?(finished)
            }
        }


        var isDualPageMode: Bool {
            Coordinator.computeColumnCount(prefs: parent.prefs, size: containerSize) > 1
        }

        func spreadViewControllers(for pageIndex: Int) -> [UIViewController] {
            let effectiveIndex = (pageIndex == 99999 || pageIndex >= computedTotalPages)
                ? max(0, computedTotalPages - 1)
                : max(0, pageIndex)

            if isDualPageMode {
                let leftIndex: Int
                let rightIndex: Int
                if parent.prefs.linkCoverAsSpread {
                    leftIndex = effectiveIndex % 2 == 0 ? effectiveIndex : effectiveIndex - 1
                    rightIndex = leftIndex + 1
                } else {
                    if effectiveIndex <= 0 {
                        // Cover page: In unlinked mode, show blank on left, cover on right
                        let leftVC = makeBlankPageViewController(for: -1)
                        let rightVC = makePageViewController(for: 0)
                        return [leftVC, rightVC]
                    } else {
                        let offset = effectiveIndex - 1
                        leftIndex = 1 + (offset / 2) * 2
                        rightIndex = leftIndex + 1
                    }
                }
                let leftVC = makePageViewController(for: leftIndex)
                let rightVC = rightIndex < computedTotalPages
                    ? makePageViewController(for: rightIndex)
                    : makeBlankPageViewController(for: rightIndex)
                return [leftVC, rightVC]
            } else {
                let vc = makePageViewController(for: effectiveIndex)
                return [vc]
            }
        }

        func makeBlankPageViewController(for pageIndex: Int) -> EBookPageContentViewController {
            return EBookPageContentViewController(
                pageIndex: pageIndex,
                snapshot: nil,
                coordinator: self
            )
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
            let prevIndex = contentVC.pageIndex - 1
            guard prevIndex >= 0 else { return nil }
            return makePageViewController(for: prevIndex)
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerAfter viewController: UIViewController
        ) -> UIViewController? {
            guard let contentVC = viewController as? EBookPageContentViewController else { return nil }
            let nextIndex = contentVC.pageIndex + 1
            guard nextIndex < computedTotalPages else { return nil }
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
            saveCurrentDrawingImmediate()
            pencilCanvas?.isHidden = true
            // Hide primary webview during interactive 3D page curl gesture so the
            // underlying curling snapshot view controller is 100% visible with zero visual occlusion.
            primaryWebView?.isHidden = true
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            didFinishAnimating finished: Bool,
            previousViewControllers: [UIViewController],
            transitionCompleted completed: Bool
        ) {
            guard let activeVCs = pageViewController.viewControllers as? [EBookPageContentViewController],
                  let currentVC = activeVCs.first else {
                isTransitioning = false
                return
            }

            let newPageIndex = currentVC.pageIndex

            if completed {
                hasLoadedInitialPage = true
                parent.onPageTurn?()
                lastCompletedControllerIndex = newPageIndex
                currentPageIndex = newPageIndex
                parent.currentPage = newPageIndex
                reportScrollFraction()
            } else {
                let actualIndex = currentVC.pageIndex
                lastCompletedControllerIndex = actualIndex
                if parent.currentPage != actualIndex {
                    parent.currentPage = actualIndex
                }
            }

            let targetPage = completed ? newPageIndex : currentPageIndex
            pruneSnapshotCache(around: targetPage)
            primaryWebView?.isHidden = true
            pencilCanvas?.isHidden = true
            mountPrimaryWebViewOnRoot(reveal: false)
            loadDrawingForCurrentPage()
            // Reveal the WebView only after the JS column-position commit completes,
            // preventing any momentary flash of the wrong column position.
            primaryWebView?.evaluateJavaScript("if(window.goToInksyncPage) window.goToInksyncPage(\(targetPage));") { [weak self, weak pageViewController] _, _ in
                DispatchQueue.main.async {
                    self?.isTransitioning = false
                    self?.primaryWebView?.isHidden = false
                    self?.pencilCanvas?.isHidden = false
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

            let config = WKSnapshotConfiguration()
            config.rect = wv.bounds
            config.afterScreenUpdates = false
            wv.takeSnapshot(with: config) { [weak self] image, _ in
                guard let image = image, let self = self else { return }
                self.pageSnapshots[current] = image
                self.pruneSnapshotCache(around: current)
            }
        }

        func handleContainerBoundsUpdated(_ bounds: CGRect) {
            guard bounds.width > 1 && bounds.height > 1 else { return }
            guard let wv = primaryWebView, let pvc = pageViewController else { return }

            let boundsChanged = (abs(wv.frame.width - bounds.width) > 0.5 || abs(wv.frame.height - bounds.height) > 0.5)
            if wv.frame != bounds {
                wv.frame = bounds
            }
            if let canvas = pencilCanvas, canvas.frame != bounds {
                canvas.frame = bounds
            }

            if !isTransitioning {
                pvc.view.bringSubviewToFront(wv)
                if let canvas = pencilCanvas {
                    pvc.view.bringSubviewToFront(canvas)
                    canvas.isHidden = false
                }
                wv.isHidden = false
            }

            if boundsChanged {
                updateLiveStyles()
                wv.evaluateJavaScript("if(window.computeMetrics) { computeMetrics(); applyPagePosition(false); }")
                let vcs = spreadViewControllers(for: currentPageIndex)
                safeSetViewControllers(vcs, direction: .forward, animated: false)
            }
        }

        func mountPrimaryWebViewOnRoot(reveal: Bool = true) {
            guard let pvc = pageViewController, let wv = primaryWebView else { return }
            let bgColor = UIColor(hex: parent.prefs.activeTheme.cssBackground) ?? .black
            pvc.view.backgroundColor = bgColor
            wv.backgroundColor = .clear
            wv.scrollView.backgroundColor = .clear

            let targetBounds = containerBounds
            wv.clipsToBounds = true
            wv.layer.masksToBounds = true
            wv.frame = targetBounds
            wv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            if wv.superview != pvc.view {
                wv.removeFromSuperview()
                pvc.view.addSubview(wv)
            }
            pvc.view.bringSubviewToFront(wv)
            if reveal {
                wv.isHidden = false
            }

            if let canvas = pencilCanvas {
                canvas.clipsToBounds = true
                canvas.layer.masksToBounds = true
                canvas.frame = targetBounds
                canvas.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                if canvas.superview != pvc.view {
                    canvas.removeFromSuperview()
                    pvc.view.addSubview(canvas)
                }
                pvc.view.bringSubviewToFront(canvas)
                if reveal {
                    canvas.isHidden = false
                }
            }
        }

        // MARK: - Apple Pencil Inking & Drawing Engine

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            debounceSaveDrawingTask?.cancel()
            debounceSaveDrawingTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled, let self = self else { return }
                self.saveCurrentDrawing()
            }
        }

        func saveCurrentDrawingImmediate() {
            debounceSaveDrawingTask?.cancel()
            debounceSaveDrawingTask = nil
            saveCurrentDrawing()
        }

        func saveCurrentDrawing() {
            guard let pdfID = parent.pdfID, let canvas = pencilCanvas else { return }
            let drawing = canvas.drawing
            let drawingData = drawing.dataRepresentation()
            let pageIdx = parent.spineIndex * 10_000 + currentPageIndex
            let ctx = InksyncProApp.sharedModelContainer.mainContext

            let descriptor = FetchDescriptor<SDAnnotation>(predicate: #Predicate {
                $0.pdfID == pdfID && $0.pageIndex == pageIdx && $0.kindRaw == "ink"
            })

            let existing = try? ctx.fetch(descriptor).first
            if drawing.bounds.isEmpty && existing == nil { return }

            if let annotation = existing {
                annotation.drawingData = drawingData
                annotation.modifiedAt = Date()
                Task { @MainActor in
                    try? InksyncProApp.sharedModelContainer.mainContext.save()
                }
                var storeDto = annotation.toDTO()
                storeDto.drawingData = drawingData
                AnnotationStore.shared.update(storeDto)
            } else {
                var dto = Annotation(
                    id: UUID(),
                    pdfID: pdfID,
                    pageIndex: pageIdx,
                    chapterTitle: parent.spineItem.label,
                    kind: .ink,
                    createdAt: Date(),
                    modifiedAt: Date()
                )
                dto.drawingData = drawingData
                AnnotationStore.shared.add(dto)
            }
        }

        func loadDrawingForCurrentPage() {
            guard let pdfID = parent.pdfID, let canvas = pencilCanvas else { return }
            let pageIdx = parent.spineIndex * 10_000 + currentPageIndex
            let ctx = InksyncProApp.sharedModelContainer.mainContext
            let descriptor = FetchDescriptor<SDAnnotation>(predicate: #Predicate {
                $0.pdfID == pdfID && $0.pageIndex == pageIdx && $0.kindRaw == "ink"
            })

            if let existing = try? ctx.fetch(descriptor).first,
               let data = existing.drawingData,
               let drawing = try? PKDrawing(data: data) {
                canvas.drawing = drawing
            } else if let storeAnn = AnnotationStore.shared.annotations(for: pdfID).first(where: {
                $0.pageIndex == pageIdx && $0.kind == .ink
            }), let data = storeAnn.drawingData, let drawing = try? PKDrawing(data: data) {
                canvas.drawing = drawing
            } else {
                canvas.drawing = PKDrawing()
            }
        }

        func clearCurrentPageDrawing() {
            pencilCanvas?.drawing = PKDrawing()
            saveCurrentDrawing()
        }

        func updatePencilInteractivity(isPencilMode: Bool) {
            guard let canvas = pencilCanvas else { return }
            let prefs = EBookPreferences.shared
            let isPad = UIDevice.current.userInterfaceIdiom == .pad
            let currentMode = InksyncInkingState.shared.activeToolMode
            let isEraser = currentMode == .eraser
            let isPenDrawingTool = currentMode == .write || isEraser
            let isColoring = InksyncInkingState.shared.isColoringModeActive
            let autoPenActive = isPad && prefs.applePencilAutoDraw && prefs.applePencilDefaultTool == "pen"
            let isExplicitDrawingMode = (isPencilMode && isPenDrawingTool) || isColoring
            let shouldBeActive = isExplicitDrawingMode || autoPenActive
            let pencilOnlySetting = AppSettingsManager.shared.conversionSettings.pencilOnlyDrawing

            canvas.overrideUserInterfaceStyle = .light
            canvas.isMarkupActive = shouldBeActive
            
            // Finger drawing policy:
            // In normal reading mode (!isExplicitDrawingMode), finger drawing MUST NEVER be allowed!
            // When in explicit drawing mode: allow finger only if not isPad, or pencilOnlySetting is off, or eraser.
            let allowFinger: Bool
            if isExplicitDrawingMode {
                allowFinger = !isPad || !pencilOnlySetting || isEraser
            } else {
                // In normal reading mode with auto-pencil active: STRICTLY Apple Pencil only!
                allowFinger = false
            }

            canvas.allowFingerDrawing = allowFinger
            canvas.drawingPolicy = allowFinger ? .anyInput : .pencilOnly
            canvas.isUserInteractionEnabled = shouldBeActive
            canvas.drawingGestureRecognizer.cancelsTouchesInView = false
            canvas.isScrollEnabled = false
            canvas.bounces = false
            canvas.panGestureRecognizer.isEnabled = allowFinger
            primaryWebView?.evaluateJavaScript("window.__inksync_is_pencil_mode = \(isPencilMode);", completionHandler: nil)
        }


        func pageViewController(
            _ pageViewController: UIPageViewController,
            spineLocationFor orientation: UIInterfaceOrientation
        ) -> UIPageViewController.SpineLocation {
            isTransitioning = true
            defer { isTransitioning = false }

            let isLandscape = orientation.isLandscape
            let dual = isLandscape && isDualPageMode

            if dual {
                let leftIndex = currentPageIndex % 2 == 0 ? currentPageIndex : currentPageIndex - 1
                let rightIndex = leftIndex + 1
                let leftVC = makePageViewController(for: leftIndex)
                let rightVC = rightIndex < computedTotalPages
                    ? makePageViewController(for: rightIndex)
                    : makeBlankPageViewController(for: rightIndex)
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
            if parent.isPencilMode { return }
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

        @MainActor @objc func handleTwoFingerTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended else { return }
            if pencilCanvas?.undoManager?.canUndo == true {
                pencilCanvas?.undoManager?.undo()
                HapticEngine.medium()
                NotificationCenter.default.post(name: NSNotification.Name("InksyncPro.ShowToast"), object: nil, userInfo: ["message": "Undo"])
            } else {
                HapticEngine.light()
                NotificationCenter.default.post(name: NSNotification.Name("InksyncPro.ShowToast"), object: nil, userInfo: ["message": "Nothing to Undo"])
            }
        }

        @MainActor @objc func handleThreeFingerTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended else { return }
            if pencilCanvas?.undoManager?.canRedo == true {
                pencilCanvas?.undoManager?.redo()
                HapticEngine.medium()
                NotificationCenter.default.post(name: NSNotification.Name("InksyncPro.ShowToast"), object: nil, userInfo: ["message": "Redo"])
            } else {
                HapticEngine.light()
                NotificationCenter.default.post(name: NSNotification.Name("InksyncPro.ShowToast"), object: nil, userInfo: ["message": "Nothing to Redo"])
            }
        }

        // MARK: - UIPencilInteractionDelegate (iPad Apple Pencil 2 & Pencil Pro)
        @MainActor func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
            InksyncInkingState.shared.toggleEraser()
            HapticEngine.selection()
            NotificationCenter.default.post(
                name: NSNotification.Name("InksyncPro.ShowToast"),
                object: nil,
                userInfo: ["message": InksyncInkingState.shared.activeToolMode == .eraser ? "Eraser" : "Pen"]
            )
        }

        @available(iOS 17.5, *)
        @MainActor func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
            guard squeeze.phase == .ended else { return }
            HapticEngine.selection()
            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                InksyncInkingState.shared.isDockMinimized.toggle()
            }
        }


        @objc func handleSingleTap(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view, let pvc = pageViewController else { return }
            isTouchDragActive = false

            if isUserSelectingText {
                isUserSelectingText = false
                primaryWebView?.evaluateJavaScript("window.getSelection().removeAllRanges();")
                parent.onSelectionDismissed?()
                return
            }

            // If the reader HUD overlay is currently showing:
            // Edge taps turn pages while keeping HUD active; center tap dismisses HUD.
            if parent.isHUDShowing {
                let tapLocation = gesture.location(in: view)
                let viewWidth = view.bounds.width
                let zones = tapZoneStyle.zones
                if tapLocation.x < viewWidth * zones.leftEdge || tapLocation.x > viewWidth * zones.rightEdge {
                    performTapZoneAction(location: tapLocation, width: viewWidth, pvc: pvc)
                    return
                }
                parent.onCenterTap()
                return
            }

            let tapLocation = gesture.location(in: view)
            let viewWidth = view.bounds.width
            let zones = tapZoneStyle.zones

            // Instantaneous edge turn: left or right page turn zones fire with zero asynchronous latency
            if tapLocation.x < viewWidth * zones.leftEdge || tapLocation.x > viewWidth * zones.rightEdge {
                performTapZoneAction(location: tapLocation, width: viewWidth, pvc: pvc)
                return
            }

            guard let wv = primaryWebView else {
                performTapZoneAction(location: tapLocation, width: viewWidth, pvc: pvc)
                return
            }

            let ptInWV = gesture.location(in: wv)
            let checkJS = """
            (function() {
                var sel = window.getSelection();
                if (sel && !sel.isCollapsed && sel.toString().trim().length > 0) return "selection";
                var el = document.elementFromPoint(\(ptInWV.x), \(ptInWV.y));
                if (!el) return "page";
                var mark = el.closest ? el.closest('mark.inksync-highlight') : (el.classList && el.classList.contains('inksync-highlight') ? el : null);
                if (mark) {
                    var id = mark.getAttribute('data-id') || '';
                    var text = mark.textContent.trim();
                    return JSON.stringify({ type: "highlight", id: id, text: text });
                }
                var link = el.closest ? el.closest('a[href]') : null;
                if (link) {
                    var href = link.getAttribute('href') || '';
                    if (href.trim().length > 0 && !href.startsWith('#')) return "link";
                }
                if (el.closest('.footnote') || el.getAttribute('epub:type') === 'noteref' || el.getAttribute('epub:type') === 'footnote') return "footnote";
                return "page";
            })();
            """

            wv.evaluateJavaScript(checkJS) { [weak self, weak pvc] result, _ in
                guard let self = self, let pvc = pvc else { return }
                let res = result as? String ?? "page"
                if res == "selection" {
                    wv.evaluateJavaScript("window.getSelection().removeAllRanges();")
                    self.isUserSelectingText = false
                    return
                }
                if res.contains("\"highlight\"") || res == "highlight" {
                    if self.parent.isPencilMode {
                        if let data = res.data(using: .utf8),
                           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
                            let id = obj["id"] ?? ""
                            let text = obj["text"] ?? ""
                            let target = !id.isEmpty ? id : text
                            if !target.isEmpty {
                                self.parent.onHighlightTapped?(target)
                                HapticEngine.selection()
                                return
                            }
                        }
                        return
                    }
                    // In Pure Reading Mode (!isPencilMode): highlights never hijack navigation!
                    // Fall through to performTapZoneAction!
                } else if res == "link" || res == "footnote" {
                    // Touched a link or interactive element; allow native action to proceed
                    return
                }

                self.performTapZoneAction(location: tapLocation, width: viewWidth, pvc: pvc)
            }
        }

        private func performTapZoneAction(location: CGPoint, width: CGFloat, pvc: UIPageViewController) {
            let zones = tapZoneStyle.zones
            let isManga = parent.prefs.pdfRTL || UserDefaults.standard.bool(forKey: "isMangaMode")
            if location.x < width * zones.leftEdge {
                if isManga {
                    turnForward(pvc)
                } else {
                    turnBackward(pvc)
                }
            } else if location.x > width * zones.rightEdge {
                if isManga {
                    turnBackward(pvc)
                } else {
                    turnForward(pvc)
                }
            } else {
                parent.onCenterTap()
            }
        }

        private func turnForward(_ pvc: UIPageViewController) {
            guard !isTransitioning else { return }

            let isDual = isDualPageMode
            let step = isDual ? 2 : 1

            parent.onPageTurn?()
            let nextIndex = currentPageIndex + step
            if nextIndex < computedTotalPages {
                hasLoadedInitialPage = true
                HapticEngine.light()
                let animate = (parent.prefs.pageTurnStyle != .instant)
                lastCompletedControllerIndex = nextIndex
                currentPageIndex = nextIndex
                parent.currentPage = nextIndex
                reportScrollFraction()
                
                // Smooth 120Hz CSS hardware-accelerated slide within the active chapter
                primaryWebView?.evaluateJavaScript("if(window.goToInksyncPage) window.goToInksyncPage(\(nextIndex), \(animate ? "true" : "false"));")
                
                // Keep UIPageViewController underlying view controllers synchronized without tearing down the webview
                let vcs = spreadViewControllers(for: nextIndex)
                safeSetViewControllers(vcs, direction: .forward, animated: false)
                precacheAdjacentSnapshots()
            } else {
                parent.onNext()
            }
        }

        private func turnBackward(_ pvc: UIPageViewController) {
            guard !isTransitioning else { return }

            let isDual = isDualPageMode
            let step = isDual ? 2 : 1

            parent.onPageTurn?()
            let prevIndex = currentPageIndex - step
            if prevIndex >= 0 {
                hasLoadedInitialPage = true
                HapticEngine.light()
                let animate = (parent.prefs.pageTurnStyle != .instant)
                lastCompletedControllerIndex = prevIndex
                currentPageIndex = prevIndex
                parent.currentPage = prevIndex
                reportScrollFraction()
                
                // Smooth 120Hz CSS hardware-accelerated slide within the active chapter
                primaryWebView?.evaluateJavaScript("if(window.goToInksyncPage) window.goToInksyncPage(\(prevIndex), \(animate ? "true" : "false"));")
                
                // Keep UIPageViewController underlying view controllers synchronized without tearing down the webview
                let vcs = spreadViewControllers(for: prevIndex)
                safeSetViewControllers(vcs, direction: .reverse, animated: false)
                precacheAdjacentSnapshots()
            } else {
                parent.onPrev()
            }
        }

        // MARK: - WKNavigationDelegate & Metrics

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            self.parent.webViewRef = webView
            DispatchQueue.main.async { [weak self] in
                self?.parent.webViewRef = webView
            }
            webView.evaluateJavaScript("window.__inksync_is_pencil_mode = \(self.parent.isPencilMode);", completionHandler: nil)
            restoreHighlights(in: webView)
            // Note: Snapshot is deferred to didReceiveMetrics once DOM fonts and layout metrics settle.
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
                let currentFileName = (parent.spineItem.href as NSString).lastPathComponent
                let isSameChapter = fileName.isEmpty || fileName == currentFileName || url.path.isEmpty || url.path == "/"

                if !isSameChapter {
                    // Navigate to a different chapter via EBookReaderView
                    NotificationCenter.default.post(
                        name: NSNotification.Name("Reader_JumpToChapterHref"),
                        object: nil,
                        userInfo: ["href": fileName, "fragment": fragment]
                    )
                    decisionHandler(.cancel)
                    return
                }

                // In-chapter link or footnote
                if !fragment.isEmpty {
                    let js = """
                    (function() {
                        var fragment = "\(fragment)";
                        var el = document.getElementById(fragment) || document.getElementsByName(fragment)[0];
                        if (el) {
                            var tag = el.tagName.toLowerCase();
                            var isFN = el.classList.contains('footnote') || el.getAttribute('epub:type') === 'noteref' || el.getAttribute('epub:type') === 'footnote' || el.getAttribute('rel') === 'footnote' || el.id.toLowerCase().indexOf('fn') === 0 || el.id.toLowerCase().indexOf('note') === 0;
                            if (isFN) {
                                var text = el.innerText || el.textContent;
                                if (text && text.trim().length > 0 && text.trim().length < 1200) {
                                    window.webkit.messageHandlers.footnote.postMessage({ "id": fragment, "text": text.trim() });
                                    return;
                                }
                            }
                            // Calculate column page of anchor element
                            var rect = el.getBoundingClientRect();
                            var vp = document.getElementById('inksync-viewport') || document.body;
                            var vpRect = vp ? vp.getBoundingClientRect() : { left: 0 };
                            var currentShift = (typeof _currentShift !== 'undefined') ? _currentShift : 0;
                            var absLeft = (rect.left - vpRect.left) + currentShift;
                            var pageStep = (typeof getPageStep === 'function') ? getPageStep() : (window.innerWidth || 1);
                            var colWidth = _isMultiCol ? (pageStep / 2) : pageStep;
                            if (colWidth > 0) {
                                var targetPage = Math.max(0, Math.min(Math.floor(absLeft / colWidth), _totalPages - 1));
                                if (typeof goToPage === 'function') {
                                    goToPage(targetPage, false);
                                } else if (window.goToInksyncPage) {
                                    window.goToInksyncPage(targetPage, false);
                                }
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

            if !hasLoadedInitialPage || needsJumpToEnd || parent.startAtEndOfChapter {
                hasLoadedInitialPage = true

                var targetPage = clampedCurrent
                if needsJumpToEnd || parent.startAtEndOfChapter || parent.initialScrollFraction >= 0.99 {
                    targetPage = max(0, clampedTotal - 1)
                    needsJumpToEnd = false
                    parent.startAtEndOfChapter = false
                } else if parent.initialPage == 0 && parent.initialScrollFraction > 0.01 && clampedTotal > 1 {
                    targetPage = Int((parent.initialScrollFraction * Double(clampedTotal - 1)).rounded())
                } else if parent.initialPage >= 99999 {
                    targetPage = max(0, clampedTotal - 1)
                } else if parent.initialPage > 0 && parent.initialPage < clampedTotal {
                    targetPage = parent.initialPage
                } else if currentPageIndex > 0 && currentPageIndex < clampedTotal {
                    targetPage = currentPageIndex
                }

                if let anchor = parent.targetAnchor, !anchor.isEmpty {
                    targetPage = clampedCurrent
                }

                currentPageIndex = targetPage
                parent.currentPage = targetPage
                primaryWebView?.evaluateJavaScript("if(window.goToInksyncPage) window.goToInksyncPage(\(targetPage), false);")
                let vcs = spreadViewControllers(for: targetPage)
                safeSetViewControllers(vcs, direction: .forward, animated: false)
                reportScrollFraction()
            } else {
                if clampedCurrent != currentPageIndex {
                    currentPageIndex = clampedCurrent
                    parent.currentPage = clampedCurrent
                    let vcs = spreadViewControllers(for: clampedCurrent)
                    safeSetViewControllers(vcs, direction: .forward, animated: false)
                }
                reportScrollFraction()
            }

            mountPrimaryWebViewOnRoot()

            // Pre-render column snapshots for current chapter
            generateAllColumnSnapshots()
            if clampedTotal > 1 {
                startBackgroundSnapshotPrecaching(totalPages: clampedTotal)
            }
        }

        func updateLiveStyles() {
            guard let wv = primaryWebView else { return }
            let frac = computedTotalPages > 1 ? Double(currentPageIndex) / Double(computedTotalPages - 1) : 0.0
            let size = containerSize
            let newCSS = computeCSS(prefs: parent.prefs, size: size)
            let safeCSS = newCSS
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "`", with: "\\`")
                .replacingOccurrences(of: "\n", with: " ")
            let isDark = parent.prefs.activeTheme.isDark
            let themeBg = parent.prefs.activeTheme.cssBackground
            let themeText = parent.prefs.activeTheme.cssText
            let isMultiCol = isDualPageMode
            let js = """
            (function() {
                var currentFrac = \(frac);
                _isMultiCol = \(isMultiCol ? "true" : "false");
                var el = document.getElementById('__inksync_live__');
                if (el) { el.innerHTML = `\(safeCSS)`; }
                if (window.updateAllInksyncHighlights) {
                    window.updateAllInksyncHighlights(\(isDark ? "true" : "false"), '\(themeBg)', '\(themeText)');
                }
                if (window.computeMetrics) {
                    var newTotal = computeMetrics();
                    if (newTotal > 1 && currentFrac > 0.0) {
                        _targetPage = Math.max(0, Math.min(Math.round(currentFrac * (newTotal - 1)), newTotal - 1));
                    }
                    applyPagePosition();
                    try {
                        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.metrics) {
                            window.webkit.messageHandlers.metrics.postMessage({ current: _targetPage, total: newTotal });
                        }
                    } catch(e) {}
                }
            })();
            """
            wv.evaluateJavaScript(js)
            if let pvc = pageViewController, let view = pvc.view {
                view.backgroundColor = UIColor(hex: parent.prefs.activeTheme.cssBackground) ?? .black
            }
            pageSnapshots.removeAll()
            takePageSnapshot(for: currentPageIndex)
        }

        private func generateAllColumnSnapshots() {
            takePageSnapshot(for: currentPageIndex)
        }

        private func startBackgroundSnapshotPrecaching(totalPages: Int) {
            precacheTask?.cancel()
            backgroundPrecacheWebView?.stopLoading()
            backgroundPrecacheWebView?.removeFromSuperview()
            backgroundPrecacheWebView = nil

            guard totalPages > 1, let pvc = pageViewController, let pv = pvc.view else { return }
            let frame = primaryWebView?.bounds ?? pv.bounds
            guard frame.width > 1, frame.height > 1 else { return }

            let config = WKWebViewConfiguration()
            config.suppressesIncrementalRendering = false
            let bgWV = WKWebView(frame: frame, configuration: config)
            bgWV.clipsToBounds = true
            bgWV.layer.masksToBounds = true
            bgWV.isOpaque = false
            bgWV.backgroundColor = .clear
            bgWV.scrollView.isScrollEnabled = false
            bgWV.alpha = 1.0 // Full opacity guarantees sharp, legible snapshots
            pv.insertSubview(bgWV, at: 0) // Occluded behind root page view controllers
            self.backgroundPrecacheWebView = bgWV

            let fullHTML = self.buildPageHTML(for: 0)
            bgWV.loadHTMLString(fullHTML, baseURL: self.chapterBaseURL)

            precacheTask = Task { @MainActor [weak self, weak bgWV] in
                // Verify DOM readiness before snapshotting
                var ready = false
                for _ in 0..<6 {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    guard let bgWV = bgWV, !Task.isCancelled else { return }
                    if let state = try? await bgWV.evaluateJavaScript("document.readyState") as? String,
                       state == "complete" || state == "interactive" {
                        ready = true
                        break
                    }
                }
                guard ready, let self = self, let bgWV = bgWV, !Task.isCancelled else { return }

                // Wait for custom fonts to rasterize and ensure CSS columns layout stabilizes
                let fontsScript = """
                new Promise(function(resolve) {
                    var settled = false;
                    var finish = function() {
                        if (!settled) {
                            settled = true;
                            if (window.computeMetrics) { computeMetrics(); }
                            if (window.applyPagePosition) { applyPagePosition(false); }
                            resolve(true);
                        }
                    };
                    var timer = setTimeout(finish, 2000);
                    if (document.fonts && document.fonts.ready) {
                        document.fonts.ready.then(function() {
                            clearTimeout(timer);
                            finish();
                        }).catch(function() {
                            clearTimeout(timer);
                            finish();
                        });
                    } else {
                        clearTimeout(timer);
                        finish();
                    }
                });
                """
                let _ = try? await bgWV.evaluateJavaScript(fontsScript)
                try? await Task.sleep(nanoseconds: 60_000_000)
                guard !Task.isCancelled, !self.isTransitioning else { return }

                let isDual = self.isDualPageMode
                let step = isDual ? 2 : 1
                let current = self.currentPageIndex

                var pagesToCache: [Int] = []
                for delta in [step, -step, 2 * step, -2 * step, 3 * step, -3 * step, 4 * step] {
                    let p = current + delta
                    if p >= 0 && p < totalPages && !pagesToCache.contains(p) {
                        pagesToCache.append(p)
                    }
                }
                for p in stride(from: 0, to: min(totalPages, 24), by: step) {
                    if !pagesToCache.contains(p) {
                        pagesToCache.append(p)
                    }
                }

                for targetPage in pagesToCache {
                    guard !Task.isCancelled, !self.isTransitioning else { break }
                    let leftIdx = isDual ? (targetPage % 2 == 0 ? targetPage : targetPage - 1) : targetPage
                    let rightIdx = leftIdx + 1

                    if self.pageSnapshots[leftIdx] == nil || (isDual && rightIdx < totalPages && self.pageSnapshots[rightIdx] == nil) {
                        await withCheckedContinuation { continuation in
                            bgWV.evaluateJavaScript("if(window.goToInksyncPage) window.goToInksyncPage(\(targetPage), false);") { _, _ in
                                continuation.resume()
                            }
                        }

                        try? await Task.sleep(nanoseconds: 60_000_000)
                        guard !Task.isCancelled, !self.isTransitioning else { break }

                        let snapshotConfig = WKSnapshotConfiguration()
                        snapshotConfig.rect = bgWV.bounds
                        snapshotConfig.afterScreenUpdates = true

                        await withCheckedContinuation { continuation in
                            bgWV.takeSnapshot(with: snapshotConfig) { [weak self] image, _ in
                                guard let image = image, let self = self else {
                                    continuation.resume()
                                    return
                                }
                                if isDual, let cgImg = image.cgImage {
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
                                        self.pageSnapshots[leftIdx] = leftImg
                                        self.pageSnapshots[rightIdx] = rightImg
                                    } else {
                                        self.pageSnapshots[leftIdx] = image
                                    }
                                } else {
                                    self.pageSnapshots[leftIdx] = image
                                }
                                continuation.resume()
                            }
                        }
                    }
                }

                bgWV.removeFromSuperview()
                if self.backgroundPrecacheWebView === bgWV {
                    self.backgroundPrecacheWebView = nil
                }
            }
        }

        fileprivate func takePageSnapshot(for pageIndex: Int) {
            guard let wv = primaryWebView, wv.bounds.width > 1, wv.bounds.height > 1 else { return }
            let config = WKSnapshotConfiguration()
            config.rect = wv.bounds
            config.afterScreenUpdates = true
            wv.takeSnapshot(with: config) { [weak self] image, _ in
                guard let self = self, let img = image else { return }
                if self.isDualPageMode, let cgImg = img.cgImage {
                    let scale = img.scale
                    let width = CGFloat(cgImg.width)
                    let height = CGFloat(cgImg.height)
                    let halfWidth = width / 2.0

                    let leftRect = CGRect(x: 0, y: 0, width: halfWidth, height: height)
                    let rightRect = CGRect(x: halfWidth, y: 0, width: halfWidth, height: height)

                    let leftIdx = pageIndex % 2 == 0 ? pageIndex : pageIndex - 1
                    let rightIdx = leftIdx + 1

                    if let leftCg = cgImg.cropping(to: leftRect),
                       let rightCg = cgImg.cropping(to: rightRect) {
                        let leftImg = UIImage(cgImage: leftCg, scale: scale, orientation: img.imageOrientation)
                        let rightImg = UIImage(cgImage: rightCg, scale: scale, orientation: img.imageOrientation)
                        self.pageSnapshots[leftIdx] = leftImg
                        self.pageSnapshots[rightIdx] = rightImg
                        if let vcs = self.pageViewController?.viewControllers as? [EBookPageContentViewController] {
                            for vc in vcs {
                                if vc.pageIndex == leftIdx { vc.updateSnapshot(leftImg) }
                                else if vc.pageIndex == rightIdx { vc.updateSnapshot(rightImg) }
                            }
                        }
                        return
                    }
                }

                self.pageSnapshots[pageIndex] = img
                if let vcs = self.pageViewController?.viewControllers as? [EBookPageContentViewController] {
                    for vc in vcs where vc.pageIndex == pageIndex {
                        vc.updateSnapshot(img)
                    }
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
            let colorHex = parent.prefs.defaultHighlightColor.rawValue
            let newID = UUID().uuidString
            let js = """
            (function() {
                var sel = window.getSelection();
                var range = null;
                if (sel && !sel.isCollapsed && sel.rangeCount > 0) {
                    range = sel.getRangeAt(0);
                } else if (window.__lastSelectedRange) {
                    range = window.__lastSelectedRange;
                }
                var text = (sel && !sel.isCollapsed) ? sel.toString().trim() : (range && range.toString ? range.toString().trim() : "");
                if (!text && window.__lastSelectedText) text = window.__lastSelectedText.trim();
                if (!text || text.length === 0) return "";
                if (window.applyInksyncHighlight) {
                    window.applyInksyncHighlight('\(newID)', '\(colorHex)', '', 'highlight');
                }
                return JSON.stringify({ id: '\(newID)', text: text, color: '\(colorHex)' });
            })();
            """
            wv.evaluateJavaScript(js) { [weak self] result, _ in
                guard let self = self else { return }
                var textToReport = ""
                var highlightID = newID
                var usedColor = colorHex

                if let str = result as? String, !str.isEmpty {
                    if let data = str.data(using: .utf8),
                       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
                        highlightID = obj["id"] ?? newID
                        textToReport = obj["text"] ?? ""
                        usedColor = obj["color"] ?? colorHex
                    } else {
                        textToReport = str
                    }
                }

                if !textToReport.isEmpty {
                    if let onWithMeta = self.parent.onHighlightCreatedWithMetadata {
                        onWithMeta(highlightID, textToReport, usedColor)
                    } else {
                        self.parent.onHighlightCreated?(textToReport)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                        guard let self = self else { return }
                        self.takePageSnapshot(for: self.currentPageIndex)
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
                    if ann.pageIndex == parent.spineIndex {
                        return true
                    }
                    if let title = ann.chapterTitle?.lowercased(), !title.isEmpty {
                        return (!spineLabel.isEmpty && title == spineLabel) || (!spineHref.isEmpty && title == spineHref)
                    }
                    return false
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
            let size = containerSize
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
            let isDarkTheme = prefs.activeTheme.isDark
            let defaultBlendMode = isDarkTheme ? "normal" : "multiply"
            let defaultHighlightBg = isDarkTheme ? "rgba(255, 214, 10, 0.52)" : "rgba(255, 214, 10, 0.45)"
            let hyphenCSS = prefs.hyphenation ? "auto" : "manual"

            let renderWidth = size.width > 0 ? size.width : containerSize.width
            let renderHeight = size.height > 0 ? size.height : containerSize.height

            let cols = Coordinator.computeColumnCount(prefs: prefs, size: CGSize(width: renderWidth, height: renderHeight))
            let isPhone = UIDevice.current.userInterfaceIdiom == .phone

            let m = isPhone ? max(12.0, min(margin, 16.0)) : max(20.0, margin)
            let gap = 2 * m
            let colWidth = max(100.0, (renderWidth / CGFloat(cols)) - gap)

            let pagedCSS = """
                column-width: \(colWidth)px !important;
                -webkit-column-width: \(colWidth)px !important;
                column-gap: \(gap)px !important;
                -webkit-column-gap: \(gap)px !important;
                column-fill: auto !important;
                -webkit-column-fill: auto !important;
                column-rule: none !important;
                -webkit-column-rule: none !important;
            """

            let windowScene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            let safeArea = windowScene?.windows.first?.safeAreaInsets ?? .zero
            let safeTop = max(safeArea.top, isPhone ? 0.0 : 24.0)
            let safeBottom = max(safeArea.bottom, isPhone ? 0.0 : 20.0)
            // iPhone optimization (Apple Books parity): safeArea.top already clears the Dynamic Island/notch;
            // provide 8pt breathing room. Reclaims 45-50pt of vertical space for 2-3 extra lines of book text.
            let paddingTop = isPhone ? (safeArea.top + 8.0) : (safeTop + max(16.0, prefs.textMarginTop))
            // Progress footer is a 26pt floating pill in the home indicator area; 20pt above safeArea.bottom clears it cleanly.
            let paddingBottom = isPhone ? (safeArea.bottom + 20.0) : (safeBottom + max(48.0, prefs.textMarginBottom + 20.0))

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
                background-color: \(defaultHighlightBg);
                color: inherit !important;
                border-radius: 3px !important;
                padding: 1px 2px !important;
                margin: 0 !important;
                box-decoration-break: clone !important;
                -webkit-box-decoration-break: clone !important;
                cursor: pointer !important;
                mix-blend-mode: \(defaultBlendMode) !important;
                \(isDarkTheme ? "border-bottom: 2px solid rgba(255, 214, 10, 0.9) !important; text-shadow: 0 1px 2px rgba(0, 0, 0, 0.85) !important;" : "border-bottom: none !important; text-shadow: none !important;")
                transition: opacity 0.15s ease, filter 0.15s ease, background-color 0.2s ease !important;
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
            html {
                margin: 0 !important; padding: 0 !important;
                width: 100vw !important;
                height: 100vh !important;
                overflow: hidden !important;
                background-color: \(bgColor) !important;
                -webkit-text-size-adjust: 100%;
            }
            html::-webkit-scrollbar, body::-webkit-scrollbar {
                display: none !important;
                width: 0 !important;
                height: 0 !important;
            }
            html, body {
                scrollbar-width: none !important;
                -ms-overflow-style: none !important;
            }
            body {
                color: \(textColor) !important;
                font-family: \(fontFamily) !important;
                font-size: \(fontSize)px !important;
                line-height: \(lineHeight) !important;
                text-align: \(textAlign) !important;
                margin: 0 !important;
                padding: 0 !important;
                width: 100vw !important;
                height: 100vh !important;
                overflow: hidden !important;
                background-color: transparent !important;
                word-wrap: break-word;
                -webkit-text-size-adjust: 100%;
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
                position: relative !important;
                top: 0 !important; left: 0 !important;
                padding-top: \(paddingTop)px !important;
                padding-bottom: \(paddingBottom)px !important;
                padding-left: \(m)px !important;
                padding-right: \(m)px !important;
                width: 100vw !important;
                max-width: 100vw !important;
                height: 100vh !important;
                max-height: 100vh !important;
                overflow: visible !important;
                -webkit-user-select: text !important;
                user-select: text !important;
                \(pagedCSS)
                will-change: transform;
            }
            #inksync-viewport > * {
                max-width: 100% !important;
                box-sizing: border-box !important;
            }
            div, section, article, main, p, span, blockquote {
                max-height: none !important;
                overflow: visible !important;
            }
            div, section, article, main {
                height: auto !important;
                column-count: auto !important;
                -webkit-column-count: auto !important;
                column-width: auto !important;
                -webkit-column-width: auto !important;
            }
            p, blockquote {
                orphans: 2 !important;
                widows: 2 !important;
                margin-bottom: \(paraSpace)em !important;
                text-indent: \(paraIndent)em !important;
            }
            img, svg, figure, video {
                max-width: 100% !important;
                max-height: calc(100vh - \(paddingTop + paddingBottom + 20)px) !important;
                height: auto !important;
                object-fit: contain !important;
                break-inside: avoid !important;
                page-break-inside: avoid !important;
                display: block !important;
                margin: 1em auto !important;
            }
            img.gaiji, img[gaiji], img.inline-image {
                display: inline-block !important;
                vertical-align: middle !important;
                max-height: 1.2em !important;
                width: auto !important;
                margin: 0 0.1em !important;
            }
            pre, table, code {
                max-width: 100% !important;
                overflow-x: auto !important;
                word-wrap: break-word !important;
                white-space: pre-wrap !important;
            }
            h1, h2, h3, h4, h5, h6 {
                break-after: avoid !important;
                page-break-after: avoid !important;
                break-inside: avoid !important;
                page-break-inside: avoid !important;
                line-height: 1.25 !important;
                color: \(textColor) !important;
            }
            body, p, span, li, td, th, div, a { font-family: \(fontFamily) !important; }
            body, p, li, td, th, a { font-size: \(fontSize)px !important; }
            h1 { font-size: \(Double(fontSize) * 1.5)px !important; }
            h2 { font-size: \(Double(fontSize) * 1.3)px !important; }
            h3 { font-size: \(Double(fontSize) * 1.15)px !important; }
            h4 { font-size: \(Double(fontSize) * 1.05)px !important; }
            h5, h6 { font-size: \(Double(fontSize) * 1.0)px !important; }
            #inksync-viewport, #inksync-viewport *:not(mark):not(.inksync-highlight):not(pre):not(code):not(table):not(tr):not(td):not(th) {
                background-color: transparent !important;
                background: transparent !important;
            }
            p, div, span, li, td, th, h1, h2, h3, h4, h5, h6 {
                color: \(textColor) !important;
                line-height: \(lineHeight);
                \(prefs.isBoldTextEnabled ? "font-weight: 600 !important;" : "")
            }
            a { color: \(linkColor) !important; }
            blockquote { border-left: 3px solid \(linkColor); margin-left: 0; padding-left: 16px; opacity: 0.85; }
            \(fontSize > 28 ? """
            .dropcap, .drop-cap, span.first-letter {
                float: none !important; font-size: 1em !important; line-height: inherit !important;
                margin: 0 !important; font-weight: inherit !important;
            }
            """ : """
            .dropcap, .drop-cap, span.first-letter {
                float: left !important; font-size: 3.0em !important; line-height: 0.85em !important;
                margin-top: 0.1em !important; margin-right: 0.12em !important; margin-bottom: -0.1em !important;
                font-weight: bold !important;
            }
            """)
            """
        }

        func buildPageScript(initialPage: Int = 0) -> String {
            let isMultiCol = isDualPageMode
            let isDarkTheme = parent.prefs.activeTheme.isDark

            return """
            var _targetPage = \(initialPage >= 99999 ? 99999 : max(0, initialPage));
            var _targetAnchor = "\(parent.targetAnchor ?? "")";
            var _totalPages = 1;
            var _isMultiCol = \(isMultiCol ? "true" : "false");
            var _isDarkTheme = \(isDarkTheme ? "true" : "false");
            var _currentShift = 0;

            function getPageStep() {
                var w = window.innerWidth || (document.documentElement ? document.documentElement.clientWidth : 0);
                return w > 0 ? w : 1;
            }

            function applyPagePosition(animated) {
                var pageStep = getPageStep();
                if (pageStep <= 0) return;
                if (_targetPage >= 99999) return;
                var spreadIndex = _isMultiCol ? Math.floor(_targetPage / 2) : _targetPage;
                var shift = spreadIndex * pageStep;
                _currentShift = shift;

                var vp = document.getElementById('inksync-viewport') || document.body;
                if (vp) {
                    if (animated === true) {
                        vp.style.transition = 'transform 0.22s cubic-bezier(0.25, 1, 0.5, 1)';
                        vp.style.webkitTransition = '-webkit-transform 0.22s cubic-bezier(0.25, 1, 0.5, 1)';
                    } else {
                        vp.style.transition = 'none';
                        vp.style.webkitTransition = 'none';
                    }
                    vp.style.transform = 'translate3d(-' + shift + 'px, 0, 0)';
                    vp.style.webkitTransform = 'translate3d(-' + shift + 'px, 0, 0)';
                }
            }

            applyPagePosition(false);

            document.addEventListener('DOMContentLoaded', function() {
                applyPagePosition(false);
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
                var vp = document.getElementById('inksync-viewport') || document.body;

                var maxRight = 0;
                try {
                    var range = document.createRange();
                    range.selectNodeContents(vp);
                    var rects = range.getClientRects();
                    for (var i = 0; i < rects.length; i++) {
                        var r = rects[i].right + _currentShift;
                        if (r > maxRight) { maxRight = r; }
                    }
                } catch(e) {}

                try {
                    var children = vp.children;
                    for (var j = 0; j < children.length; j++) {
                        var cr = children[j].getBoundingClientRect();
                        var crRight = cr.right + _currentShift;
                        if (crRight > maxRight) { maxRight = crRight; }
                    }
                } catch(e) {}

                try {
                    var media = vp.querySelectorAll('img, svg, table, pre, figure');
                    for (var k = 0; k < media.length; k++) {
                        var mr = media[k].getBoundingClientRect();
                        var mrRight = mr.right + _currentShift;
                        if (mrRight > maxRight) { maxRight = mrRight; }
                    }
                } catch(e) {}

                var scrollW = Math.max(maxRight, vp ? vp.scrollWidth : 0, document.body.scrollWidth || 0, document.documentElement.scrollWidth || 0);

                var totalSpreads = Math.max(1, Math.ceil((scrollW - 10) / pageStep));
                _totalPages = _isMultiCol ? (totalSpreads * 2) : totalSpreads;
                if (_targetAnchor && _targetAnchor.length > 0) {
                    var anchorEl = document.getElementById(_targetAnchor) || document.getElementsByName(_targetAnchor)[0];
                    if (anchorEl) {
                        var aRect = anchorEl.getBoundingClientRect();
                        var absLeft = (aRect.left - (vp ? vp.getBoundingClientRect().left : 0)) + _currentShift;
                        var colWidth = _isMultiCol ? (pageStep / 2) : pageStep;
                        if (colWidth > 0) {
                            _targetPage = Math.max(0, Math.min(Math.floor(absLeft / colWidth), _totalPages - 1));
                        }
                    }
                    _targetAnchor = "";
                } else if (_targetPage >= 99999) {
                    _targetPage = Math.max(0, _totalPages - 1);
                }
                applyPagePosition(false);
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.metrics) {
                    window.webkit.messageHandlers.metrics.postMessage({ current: _targetPage, total: _totalPages });
                }
                return _totalPages;
            }

            function goToPage(page, animated) {
                if (typeof page === 'number' && !isNaN(page)) {
                    if (_totalPages > 1 && page < _totalPages) {
                        _targetPage = Math.max(0, page);
                    } else {
                        _targetPage = Math.max(0, page);
                        _totalPages = Math.max(_totalPages, _targetPage + 1);
                    }
                }
                applyPagePosition(animated);
                try {
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.metrics) {
                        window.webkit.messageHandlers.metrics.postMessage({ current: _targetPage, total: _totalPages });
                    }
                } catch(e) {}
            }
            window.goToInksyncPage = goToPage;

            window.onload = function() {
                computeMetrics();
                applyPagePosition();
                try {
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.metrics) {
                        window.webkit.messageHandlers.metrics.postMessage({ current: _targetPage, total: _totalPages });
                    }
                } catch(e) {}
            };

            if (document.fonts && document.fonts.ready) {
                document.fonts.ready.then(function() {
                    computeMetrics();
                    applyPagePosition();
                    try {
                        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.metrics) {
                            window.webkit.messageHandlers.metrics.postMessage({ current: _targetPage, total: _totalPages });
                        }
                    } catch(e) {}
                });
            }

            var __resizeTimeout = null;
            window.addEventListener('resize', function() {
                if (__resizeTimeout) clearTimeout(__resizeTimeout);
                __resizeTimeout = setTimeout(function() {
                    computeMetrics();
                    applyPagePosition(false);
                    try {
                        window.webkit.messageHandlers.metrics.postMessage({ current: _targetPage, total: _totalPages });
                    } catch(e) {}
                }, 40);
            });

            document.addEventListener('selectionchange', function() {
                var sel = window.getSelection();
                if (!sel || sel.isCollapsed || sel.rangeCount === 0) {
                    if (window.__selectionDismissTimeout) {
                        clearTimeout(window.__selectionDismissTimeout);
                    }
                    window.__selectionDismissTimeout = setTimeout(function() {
                        var currentSel = window.getSelection();
                        if (!currentSel || currentSel.isCollapsed || currentSel.rangeCount === 0) {
                            window.__lastSelectedRange = null;
                            window.__lastSelectedText = "";
                            try { window.webkit.messageHandlers.onSelectionDismissed.postMessage({}); } catch(e) {}
                        }
                    }, 120);
                    return;
                }
                if (window.__selectionDismissTimeout) {
                    clearTimeout(window.__selectionDismissTimeout);
                    window.__selectionDismissTimeout = null;
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

            // Passive selection observer for SwiftUI context HUD

            document.addEventListener('click', function(e) {
                if (!window.__inksync_is_pencil_mode) return;
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

            function hexToRgba(hex, alpha) {
                if (!hex) return 'rgba(255, 214, 10, ' + alpha + ')';
                if (hex.indexOf('rgba') === 0 || hex.indexOf('hsla') === 0) return hex;
                var c = hex.replace('#', '');
                if (c.length === 3) {
                    c = c[0] + c[0] + c[1] + c[1] + c[2] + c[2];
                }
                if (c.length >= 6) {
                    var r = parseInt(c.substring(0, 2), 16) || 0;
                    var g = parseInt(c.substring(2, 4), 16) || 0;
                    var b = parseInt(c.substring(4, 6), 16) || 0;
                    return 'rgba(' + r + ',' + g + ',' + b + ',' + alpha + ')';
                }
                return hex;
            }

            function styleHighlightMark(mark, colorHex, style, symbol) {
                if (style) mark.setAttribute('data-style', style);
                if (colorHex) mark.setAttribute('data-color', colorHex);
                if (symbol) mark.setAttribute('data-symbol', symbol);
                
                var col = colorHex || '#FFD600';
                var st = style || 'highlight';
                var bgAlpha = _isDarkTheme ? 0.52 : 0.40;
                var highlightBg = hexToRgba(col, bgAlpha);
                
                if (st === 'underline') {
                    mark.style.setProperty('background-color', 'transparent', 'important');
                    mark.style.setProperty('text-decoration', 'underline', 'important');
                    mark.style.setProperty('text-decoration-color', col, 'important');
                    mark.style.setProperty('text-underline-offset', '3px', 'important');
                    mark.style.setProperty('mix-blend-mode', 'normal', 'important');
                    mark.style.setProperty('border-bottom', 'none', 'important');
                    mark.style.setProperty('text-shadow', 'none', 'important');
                } else if (st === 'strikeout') {
                    mark.style.setProperty('background-color', 'transparent', 'important');
                    mark.style.setProperty('text-decoration', 'line-through', 'important');
                    mark.style.setProperty('text-decoration-color', col, 'important');
                    mark.style.setProperty('mix-blend-mode', 'normal', 'important');
                    mark.style.setProperty('border-bottom', 'none', 'important');
                    mark.style.setProperty('text-shadow', 'none', 'important');
                } else {
                    mark.style.setProperty('background-color', highlightBg, 'important');
                    mark.style.setProperty('text-decoration', 'none', 'important');
                    if (_isDarkTheme) {
                        mark.style.setProperty('mix-blend-mode', 'normal', 'important');
                        mark.style.setProperty('border-bottom', '2px solid ' + col, 'important');
                        mark.style.setProperty('text-shadow', '0 1px 2px rgba(0,0,0,0.85)', 'important');
                    } else {
                        mark.style.setProperty('mix-blend-mode', 'multiply', 'important');
                        mark.style.setProperty('border-bottom', 'none', 'important');
                        mark.style.setProperty('text-shadow', 'none', 'important');
                    }
                }
                mark.style.setProperty('color', 'inherit', 'important');
                mark.style.setProperty('border-radius', '3px', 'important');
                mark.style.setProperty('padding', '1px 2px', 'important');
                mark.style.setProperty('-webkit-box-decoration-break', 'clone', 'important');
                mark.style.setProperty('box-decoration-break', 'clone', 'important');
            }

            window.createHighlightElement = function(id, colorHex, symbol, style) {
                var mark = document.createElement('mark');
                mark.className = 'inksync-highlight';
                if (id) mark.setAttribute('data-id', id);
                styleHighlightMark(mark, colorHex, style, symbol);
                return mark;
            };

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
                
                var mark = window.createHighlightElement(id, colorHex, symbol, style);
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
                                var subMark = window.createHighlightElement(id, colorHex, symbol, style);
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
                return text;
            };

            window.adjustInksyncSelection = function(delta, isStart) {
                var sel = window.getSelection();
                var range = (sel && sel.rangeCount > 0 && !sel.isCollapsed) ? sel.getRangeAt(0) : window.__lastSelectedRange;
                if (!range) return "";
                try {
                    if (isStart) {
                        if (delta < 0) {
                            if (range.startOffset > 0) {
                                range.setStart(range.startContainer, Math.max(0, range.startOffset - 1));
                            } else if (range.startContainer.previousSibling && range.startContainer.previousSibling.nodeType === Node.TEXT_NODE) {
                                var prev = range.startContainer.previousSibling;
                                range.setStart(prev, Math.max(0, prev.nodeValue.length - 1));
                            }
                        } else {
                            var maxStart = (range.startContainer === range.endContainer) ? range.endOffset - 1 : (range.startContainer.nodeValue ? range.startContainer.nodeValue.length : 0);
                            if (range.startOffset < maxStart) {
                                range.setStart(range.startContainer, range.startOffset + 1);
                            }
                        }
                    } else {
                        if (delta > 0) {
                            var endLen = range.endContainer.nodeValue ? range.endContainer.nodeValue.length : 0;
                            if (range.endOffset < endLen) {
                                range.setEnd(range.endContainer, range.endOffset + 1);
                            } else if (range.endContainer.nextSibling && range.endContainer.nextSibling.nodeType === Node.TEXT_NODE) {
                                var next = range.endContainer.nextSibling;
                                range.setEnd(next, Math.min(next.nodeValue.length, 1));
                            }
                        } else {
                            var minEnd = (range.startContainer === range.endContainer) ? range.startOffset + 1 : 1;
                            if (range.endOffset > minEnd) {
                                range.setEnd(range.endContainer, range.endOffset - 1);
                            }
                        }
                    }
                    if (sel) {
                        sel.removeAllRanges();
                        sel.addRange(range);
                    }
                    window.__lastSelectedRange = range.cloneRange();
                    var newText = range.toString().trim();
                    window.__lastSelectedText = newText;
                    return newText;
                } catch(e) {
                    return range.toString().trim();
                }
            };

            window.updateInksyncHighlightColor = function(idOrText, newColorHex) {
                if (!idOrText) return;
                var targetMarks = [];
                var idMark = document.querySelector('mark.inksync-highlight[data-id="' + idOrText + '"]');
                if (idMark) {
                    targetMarks.push(idMark);
                } else {
                    var marks = document.querySelectorAll('mark.inksync-highlight');
                    var trimmedTarget = idOrText.trim();
                    for (var i = 0; i < marks.length; i++) {
                        if (marks[i].textContent.trim() === trimmedTarget) {
                            targetMarks.push(marks[i]);
                        }
                    }
                    if (targetMarks.length === 0 && trimmedTarget.length >= 6) {
                        for (var i = 0; i < marks.length; i++) {
                            if (marks[i].textContent.indexOf(trimmedTarget) !== -1 || trimmedTarget.indexOf(marks[i].textContent.trim()) !== -1) {
                                targetMarks.push(marks[i]);
                            }
                        }
                    }
                }
                for (var j = 0; j < targetMarks.length; j++) {
                    var m = targetMarks[j];
                    var st = m.getAttribute('data-style') || 'highlight';
                    var sym = m.getAttribute('data-symbol');
                    styleHighlightMark(m, newColorHex, st, sym);
                }
            };

            window.updateAllInksyncHighlights = function(isDark, themeBg, themeText) {
                _isDarkTheme = (isDark === true || isDark === 'true');
                var marks = document.querySelectorAll('mark.inksync-highlight');
                for (var i = 0; i < marks.length; i++) {
                    var m = marks[i];
                    var col = m.getAttribute('data-color') || '#FFD600';
                    var st = m.getAttribute('data-style') || 'highlight';
                    var sym = m.getAttribute('data-symbol');
                    styleHighlightMark(m, col, st, sym);
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
                    var trimmedTarget = idOrText.trim();
                    for (var i = 0; i < marks.length; i++) {
                        if (marks[i].textContent.trim() === trimmedTarget) {
                            targetMarks.push(marks[i]);
                        }
                    }
                    if (targetMarks.length === 0 && trimmedTarget.length >= 6) {
                        for (var i = 0; i < marks.length; i++) {
                            if (marks[i].textContent.indexOf(trimmedTarget) !== -1 || trimmedTarget.indexOf(marks[i].textContent.trim()) !== -1) {
                                targetMarks.push(marks[i]);
                            }
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
                var target = textToFind.trim();
                if (!target) return;
                
                var normTarget = target.replace(/[—–]/g, '-').replace(/\\s+/g, ' ');
                var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null, false);
                var node;
                var nodeOffsets = [];
                var fullDocText = '';
                
                while ((node = walker.nextNode())) {
                    if (node.parentElement && node.parentElement.closest && node.parentElement.closest('mark.inksync-highlight')) {
                        continue;
                    }
                    var val = node.nodeValue;
                    var sIdx = val.indexOf(textToFind);
                    if (sIdx === -1 && val.indexOf(target) !== -1) {
                        sIdx = val.indexOf(target);
                    }
                    if (sIdx !== -1) {
                        try {
                            var r = document.createRange();
                            r.setStart(node, sIdx);
                            r.setEnd(node, sIdx + target.length);
                            var m = window.createHighlightElement(id, colorHex, symbol, style);
                            r.surroundContents(m);
                            return;
                        } catch(e) {}
                    }
                    nodeOffsets.push({ node: node, start: fullDocText.length, length: val.length });
                    fullDocText += val;
                }
                
                var normDoc = fullDocText.replace(/[—–]/g, '-').replace(/\\s+/g, ' ');
                var matchIdx = normDoc.indexOf(normTarget);
                if (matchIdx === -1) matchIdx = fullDocText.indexOf(target);
                if (matchIdx === -1 && normTarget.length > 30) {
                    matchIdx = normDoc.indexOf(normTarget.substring(0, 30));
                }
                if (matchIdx !== -1) {
                    var matchLen = Math.min(normTarget.length, fullDocText.length - matchIdx);
                    var matchEnd = matchIdx + matchLen;
                    var startN = null, startO = 0;
                    var endN = null, endO = 0;
                    for (var k = 0; k < nodeOffsets.length; k++) {
                        var no = nodeOffsets[k];
                        if (!startN && matchIdx >= no.start && matchIdx < no.start + no.length) {
                            startN = no.node;
                            startO = matchIdx - no.start;
                        }
                        if (matchEnd > no.start && matchEnd <= no.start + no.length) {
                            endN = no.node;
                            endO = matchEnd - no.start;
                            break;
                        }
                    }
                    if (startN && !endN && nodeOffsets.length > 0) {
                        endN = nodeOffsets[nodeOffsets.length - 1].node;
                        endO = endN.nodeValue.length;
                    }
                    if (startN && endN) {
                        try {
                            var mr = document.createRange();
                            mr.setStart(startN, Math.min(startO, startN.nodeValue.length));
                            mr.setEnd(endN, Math.min(endO, endN.nodeValue.length));
                            var wrap = window.createHighlightElement(id, colorHex, symbol, style);
                            try {
                                mr.surroundContents(wrap);
                            } catch(err) {
                                var tw = document.createTreeWalker(mr.commonAncestorContainer, NodeFilter.SHOW_TEXT, null, false);
                                var tn;
                                while ((tn = tw.nextNode())) {
                                    if (mr.intersectsNode(tn)) {
                                        var so = (tn === mr.startContainer) ? mr.startOffset : 0;
                                        var eo = (tn === mr.endContainer) ? mr.endOffset : tn.nodeValue.length;
                                        if (so < eo) {
                                            var sr = document.createRange();
                                            sr.setStart(tn, so);
                                            sr.setEnd(tn, eo);
                                            var sm = window.createHighlightElement(id, colorHex, symbol, style);
                                            try { sr.surroundContents(sm); } catch(x) {}
                                        }
                                    }
                                }
                            }
                        } catch(ex) {}
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
        if html.contains("id=\"inksync-viewport\"") || html.contains("id='inksync-viewport'") {
            return html
        }
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
// MARK: - InksyncPageViewController
// Specialized UIPageViewController subclass providing layout observation
// to guarantee primary WKWebView frames & Z-order stay aligned with container bounds.
// ============================================================
@MainActor
final class InksyncPageViewController: UIPageViewController {
    var onLayoutSubviews: ((CGRect) -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.clipsToBounds = true
        view.layer.masksToBounds = true
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        view.clipsToBounds = true
        view.layer.masksToBounds = true
        onLayoutSubviews?(view.bounds)
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
        let bgColor = UIColor(hex: EBookPreferences.shared.activeTheme.cssBackground) ?? .black
        self.view.backgroundColor = bgColor
        self.imageView?.backgroundColor = bgColor
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let prefs = EBookPreferences.shared
        let bgColor = UIColor(hex: prefs.activeTheme.cssBackground) ?? .black
        view.backgroundColor = bgColor
        view.clipsToBounds = true
        view.layer.masksToBounds = true

        // Setup snapshot image view (0ms instant page rendering for 3D curl)
        let iv = UIImageView(frame: view.bounds)
        // scaleToFill maps snapshot pixels 1:1 to view bounds — avoids shrinking/expanding text during 3D page curl.
        iv.contentMode = .scaleToFill
        iv.clipsToBounds = true
        iv.layer.masksToBounds = true
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

// ============================================================
// MARK: - WeakScriptMessageHandler
// Weak proxy to prevent circular retain cycles between WKUserContentController
// and Coordinator (Paul Hudson / Apple WebKit leak prevention pattern).
// ============================================================
final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var delegate: WKScriptMessageHandler?

    init(delegate: WKScriptMessageHandler) {
        self.delegate = delegate
        super.init()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        delegate?.userContentController(userContentController, didReceive: message)
    }
}

