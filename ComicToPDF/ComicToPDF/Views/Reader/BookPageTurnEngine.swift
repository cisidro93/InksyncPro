import SwiftUI
import UIKit

// ============================================================
// MARK: - Native Page Curl Transition (UIPageViewController)
// ============================================================
struct PageCurlReader: UIViewControllerRepresentable {
    @Binding var currentIndex: Int
    let totalPages: Int
    let cache: ComicImageCache
    let isTwoUp: Bool
    let isMangaRTL: Bool
    let activeFilterPreset: ReadingFilterPreset
    var transitionStyle: UIPageViewController.TransitionStyle = .pageCurl
    var onChromeTap: () -> Void
    var onFlipPastEnd: (() -> Void)?

    private func isPageLandscape(_ idx: Int, landscapeArray: [Bool]) -> Bool {
        if idx >= 0 && idx < landscapeArray.count && landscapeArray[idx] {
            return true
        }
        if let size = cache.peekImageSize(at: idx), size.width > size.height * 1.1 {
            return true
        }
        return false
    }

    func computeSpreads() -> [[Int]] {
        var allSpreads: [[Int]] = []
        let landscapeArray = cache.isLandscapeArray
        let linkCover = EBookPreferences.shared.linkCoverAsSpread

        if linkCover {
            var i = 0
            while i < totalPages {
                let isL = isPageLandscape(i, landscapeArray: landscapeArray)
                if isL {
                    allSpreads.append([i])
                    i += 1
                } else if i + 1 < totalPages {
                    let nextIsL = isPageLandscape(i + 1, landscapeArray: landscapeArray)
                    if nextIsL {
                        allSpreads.append([i])
                        i += 1
                    } else {
                        allSpreads.append([i, i + 1])
                        i += 2
                    }
                } else {
                    allSpreads.append([i])
                    i += 1
                }
            }
        } else {
            // Page 0: Standalone Cover
            allSpreads.append([0])
            
            // Page 1: Standalone Page 1 (Right in Western, Left in Manga)
            if totalPages > 1 {
                allSpreads.append([1])
            }
            
            // Natural (2+3, 4+5) facing spread pairing
            var i = 2
            while i < totalPages {
                let isL = isPageLandscape(i, landscapeArray: landscapeArray)
                if isL {
                    allSpreads.append([i])
                    i += 1
                } else {
                    if i + 1 < totalPages {
                        let nextIsL = isPageLandscape(i + 1, landscapeArray: landscapeArray)
                        if nextIsL {
                            allSpreads.append([i])
                            i += 1
                        } else {
                            allSpreads.append([i, i + 1])
                            i += 2
                        }
                    } else {
                        allSpreads.append([i])
                        i += 1
                    }
                }
            }
        }
        return allSpreads
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pageViewController = UIPageViewController(
            transitionStyle: transitionStyle,
            navigationOrientation: .horizontal,
            options: nil
        )
        pageViewController.dataSource = context.coordinator
        pageViewController.delegate = context.coordinator

        for gesture in pageViewController.gestureRecognizers {
            if gesture is UITapGestureRecognizer {
                gesture.isEnabled = false
            }
        }

        let view = pageViewController.view!
        
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.cancelsTouchesInView = false
        view.addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleSingleTap(_:)))
        singleTap.numberOfTapsRequired = 1
        singleTap.require(toFail: doubleTap)
        view.addGestureRecognizer(singleTap)

        context.coordinator.pageViewController = pageViewController
        
        let targetIndex = currentIndex
        let targetControllerIndex: Int
        if isTwoUp {
            let spreads = computeSpreads()
            targetControllerIndex = spreads.firstIndex(where: { $0.contains(targetIndex) }) ?? 0
        } else {
            targetControllerIndex = targetIndex
        }
        let initialVC = context.coordinator.makeViewController(for: targetControllerIndex)
        pageViewController.setViewControllers([initialVC], direction: .forward, animated: false)
        
        return pageViewController
    }

    func updateUIViewController(_ uiViewController: UIPageViewController, context: Context) {
        context.coordinator.parent = self
        
        // Prevent interrupting interactive swipe gestures
        if context.coordinator.isTransitioning {
            return
        }
        
        let targetIndex = currentIndex
        let targetControllerIndex: Int
        if isTwoUp {
            let spreads = computeSpreads()
            targetControllerIndex = spreads.firstIndex(where: { $0.contains(targetIndex) }) ?? 0
        } else {
            targetControllerIndex = targetIndex
        }
        
        if let currentVC = uiViewController.viewControllers?.first as? PageContentViewController {
            let isDisplayed: Bool
            if isTwoUp {
                let spreads = computeSpreads()
                let currentSpread = currentVC.index < spreads.count ? spreads[currentVC.index] : []
                isDisplayed = currentSpread.contains(targetIndex)
            } else {
                isDisplayed = currentVC.index == targetIndex
            }
            
            // Check if spreads changed due to orientation/cache update
            let newSpreads = computeSpreads()
            let spreadsChanged = currentVC.spreads != newSpreads
            
            // Clear gesture completion marker if set
            if context.coordinator.lastCompletedControllerIndex != nil {
                let lastCompleted = context.coordinator.lastCompletedControllerIndex
                context.coordinator.lastCompletedControllerIndex = nil
                if lastCompleted == targetControllerIndex && !spreadsChanged {
                    return // ✅ Gesture completed this exact page turn -- DO NOT TOUCH setViewControllers!
                }
            }
            
            if isDisplayed && currentVC.isTwoUp == isTwoUp && currentVC.activeFilterPreset == activeFilterPreset && !spreadsChanged {
                return // ✅ Target page is ALREADY displayed on screen -- DO NOT TOUCH setViewControllers!
            }
            
            let vc = context.coordinator.makeViewController(for: targetControllerIndex)
            let isForward = targetControllerIndex >= currentVC.index
            let direction: UIPageViewController.NavigationDirection
            if isMangaRTL {
                direction = isForward ? .reverse : .forward
            } else {
                direction = isForward ? .forward : .reverse
            }
            uiViewController.setViewControllers([vc], direction: direction, animated: false, completion: nil)
        } else {
            let vc = context.coordinator.makeViewController(for: targetControllerIndex)
            uiViewController.setViewControllers([vc], direction: .forward, animated: false, completion: nil)
        }
    }
}

extension PageCurlReader {
    @MainActor
    class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: PageCurlReader
        weak var pageViewController: UIPageViewController?
        var isTransitioning: Bool = false
        var lastCompletedControllerIndex: Int? = nil

        init(_ parent: PageCurlReader) {
            self.parent = parent
            super.init()
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleZoomStateChanged(_:)),
                name: .readerZoomStateChanged,
                object: nil
            )
        }
        
        deinit {
            NotificationCenter.default.removeObserver(self)
        }
        
        func makeViewController(for index: Int) -> PageContentViewController {
            PageContentViewController(
                index: index,
                parent: self.parent
            )
        }
        
        // MARK: - UIPageViewControllerDataSource
        
        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerBefore viewController: UIViewController
        ) -> UIViewController? {
            guard let current = viewController as? PageContentViewController else { return nil }
            let prevIndex = current.index - 1
            guard prevIndex >= 0 else { return nil }
            return makeViewController(for: prevIndex)
        }
        
        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerAfter viewController: UIViewController
        ) -> UIViewController? {
            guard let current = viewController as? PageContentViewController else { return nil }
            let spreads = parent.computeSpreads()
            let maxIndex = parent.isTwoUp ? spreads.count - 1 : parent.totalPages - 1
            let nextIndex = current.index + 1
            guard nextIndex <= maxIndex else { return nil }
            return makeViewController(for: nextIndex)
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
            guard let currentVC = pageViewController.viewControllers?.first as? PageContentViewController else {
                return
            }
            
            let newControllerIndex = currentVC.index
            lastCompletedControllerIndex = newControllerIndex
            
            if completed {
                if self.parent.isTwoUp {
                    let spreads = self.parent.computeSpreads()
                    if newControllerIndex < spreads.count {
                        let newPageIndex = spreads[newControllerIndex].first ?? 0
                        if self.parent.currentIndex != newPageIndex {
                            self.parent.currentIndex = newPageIndex
                        }
                    }
                } else {
                    if self.parent.currentIndex != newControllerIndex {
                        self.parent.currentIndex = newControllerIndex
                    }
                }
            } else {
                // 🔴 CRITICAL SNAP-BACK GUARD: User cancelled swipe!
                let actualIndex: Int
                if self.parent.isTwoUp {
                    let spreads = self.parent.computeSpreads()
                    actualIndex = (newControllerIndex < spreads.count) ? (spreads[newControllerIndex].first ?? 0) : 0
                } else {
                    actualIndex = newControllerIndex
                }
                if self.parent.currentIndex != actualIndex {
                    self.parent.currentIndex = actualIndex
                }
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
            // Cooperative gesture helper
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
                if parent.isMangaRTL {
                    turnForward(pvc)
                } else {
                    turnBackward(pvc)
                }
            } else if location.x > width * zones.rightEdge {
                if parent.isMangaRTL {
                    turnBackward(pvc)
                } else {
                    turnForward(pvc)
                }
            } else {
                parent.onChromeTap()
            }
        }
        
        private func turnForward(_ pvc: UIPageViewController) {
            guard !isTransitioning else { return }
            let maxCount = parent.isTwoUp ? parent.computeSpreads().count : parent.totalPages
            let currentControllerIndex: Int
            if parent.isTwoUp {
                let spreads = parent.computeSpreads()
                currentControllerIndex = spreads.firstIndex(where: { $0.contains(parent.currentIndex) }) ?? 0
            } else {
                currentControllerIndex = parent.currentIndex
            }
            
            let targetIndex = currentControllerIndex + 1
            if targetIndex < maxCount {
                let vc = makeViewController(for: targetIndex)
                HapticEngine.light()
                let direction: UIPageViewController.NavigationDirection = parent.isMangaRTL ? .reverse : .forward
                isTransitioning = true // 🔴 Lock transitions during tap page flip
                pvc.setViewControllers([vc], direction: direction, animated: true) { [weak self] completed in
                    self?.isTransitioning = false // 🔓 Unlock transition
                    if completed {
                        DispatchQueue.main.async {
                            self?.updateParentIndex(to: targetIndex)
                        }
                    }
                }
            } else {
                parent.onFlipPastEnd?()
            }
        }
        
        private func turnBackward(_ pvc: UIPageViewController) {
            guard !isTransitioning else { return }
            let currentControllerIndex: Int
            if parent.isTwoUp {
                let spreads = parent.computeSpreads()
                currentControllerIndex = spreads.firstIndex(where: { $0.contains(parent.currentIndex) }) ?? 0
            } else {
                currentControllerIndex = parent.currentIndex
            }
            
            let targetIndex = currentControllerIndex - 1
            if targetIndex >= 0 {
                let vc = makeViewController(for: targetIndex)
                HapticEngine.light()
                let direction: UIPageViewController.NavigationDirection = parent.isMangaRTL ? .forward : .reverse
                isTransitioning = true // 🔴 Lock transitions during tap page flip
                pvc.setViewControllers([vc], direction: direction, animated: true) { [weak self] completed in
                    self?.isTransitioning = false // 🔓 Unlock transition
                    if completed {
                        DispatchQueue.main.async {
                            self?.updateParentIndex(to: targetIndex)
                        }
                    }
                }
            }
        }
        
        private func updateParentIndex(to controllerIndex: Int) {
            if parent.isTwoUp {
                let spreads = parent.computeSpreads()
                if controllerIndex < spreads.count {
                    let newPageIndex = spreads[controllerIndex].first ?? 0
                    parent.currentIndex = newPageIndex
                }
            } else {
                parent.currentIndex = controllerIndex
            }
        }
        
        @objc func handleZoomStateChanged(_ notification: Notification) {
            guard let isZoomed = notification.userInfo?["isZoomed"] as? Bool else { return }
            guard let pvc = self.pageViewController else { return }
            for gesture in pvc.gestureRecognizers {
                if gesture is UIPanGestureRecognizer {
                    gesture.isEnabled = !isZoomed
                }
            }
        }
    }
}

@MainActor
class PageContentViewController: UIViewController {
    let index: Int
    let isTwoUp: Bool
    let activeFilterPreset: ReadingFilterPreset
    let content: AnyView
    let spreads: [[Int]]
    
    init(index: Int, parent: PageCurlReader) {
        self.index = index
        self.isTwoUp = parent.isTwoUp
        self.activeFilterPreset = parent.activeFilterPreset
        
        let spreads = parent.computeSpreads()
        self.spreads = spreads
        
        if parent.isTwoUp {
            let pages = index < spreads.count ? spreads[index] : [0]
            
            let spreadView = GeometryReader { geo in
                if pages.count == 1 {
                    let pageIdx = pages[0]
                    if pageIdx == 0 {
                        // Physical Front Cover: Positioned on natural book cover side
                        HStack(spacing: 0) {
                            if parent.isMangaRTL {
                                TwoUpPageCell(index: 0, cache: parent.cache, activeFilterPreset: parent.activeFilterPreset, alignment: .leading)
                                    .frame(width: geo.size.width / 2, height: geo.size.height)
                                Color.black.opacity(0.95)
                                    .frame(width: geo.size.width / 2, height: geo.size.height)
                            } else {
                                Color.black.opacity(0.95)
                                    .frame(width: geo.size.width / 2, height: geo.size.height)
                                TwoUpPageCell(index: 0, cache: parent.cache, activeFilterPreset: parent.activeFilterPreset, alignment: .leading)
                                    .frame(width: geo.size.width / 2, height: geo.size.height)
                            }
                        }
                    } else {
                        // Wide landscape splash art: spans 100% width across both pages of the spread!
                        TwoUpPageCell(index: pageIdx, cache: parent.cache, activeFilterPreset: parent.activeFilterPreset, alignment: .center)
                            .frame(width: geo.size.width, height: geo.size.height)
                    }
                } else if parent.isMangaRTL {
                    // Physical Manga Spreads (Right-to-Left): Page 2 (Left), Page 1 (Right)
                    ZStack {
                        HStack(spacing: 0) {
                            if pages.count == 2 {
                                TwoUpPageCell(index: pages[1], cache: parent.cache, activeFilterPreset: parent.activeFilterPreset, alignment: .trailing)
                                    .frame(width: geo.size.width / 2, height: geo.size.height)
                            } else {
                                Color.black.opacity(0.95)
                                    .frame(width: geo.size.width / 2, height: geo.size.height)
                            }
                            TwoUpPageCell(index: pages[0], cache: parent.cache, activeFilterPreset: parent.activeFilterPreset, alignment: .leading)
                                .frame(width: geo.size.width / 2, height: geo.size.height)
                        }
                    }
                } else {
                    // Physical Comic Spreads (Left-to-Right): Page 1 (Left), Page 2 (Right)
                    ZStack {
                        HStack(spacing: 0) {
                            TwoUpPageCell(index: pages[0], cache: parent.cache, activeFilterPreset: parent.activeFilterPreset, alignment: .trailing)
                                .frame(width: geo.size.width / 2, height: geo.size.height)
                            if pages.count == 2 {
                                TwoUpPageCell(index: pages[1], cache: parent.cache, activeFilterPreset: parent.activeFilterPreset, alignment: .leading)
                                    .frame(width: geo.size.width / 2, height: geo.size.height)
                            } else {
                                Color.black.opacity(0.95)
                                    .frame(width: geo.size.width / 2, height: geo.size.height)
                            }
                        }
                    }
                }
            }
            .id("spread_\(pages.first ?? 0)")
            .background(Color.black)
            .ignoresSafeArea()
            
            self.content = AnyView(spreadView)
        } else {
            let singleView = ComicPageView(index: index, cache: parent.cache)
                .applyFilterPreset(parent.activeFilterPreset)
                .background(Color.black)
                .ignoresSafeArea()
            self.content = AnyView(singleView)
        }
        
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        
        let hostingController = UIHostingController(rootView: content)
        hostingController.view.backgroundColor = .black
        addChild(hostingController)
        view.addSubview(hostingController.view)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        hostingController.didMove(toParent: self)
    }
}

// ============================================================
// MARK: - Single-Page Book Pager
// ============================================================
struct BookPager: View {
    @Binding var currentIndex: Int
    let totalPages: Int
    let cache: ComicImageCache
    let readingMode: ComicReadingMode
    let activeFilterPreset: ReadingFilterPreset
    let isMangaRTL: Bool
    var onChromeTap: () -> Void
    var onFlipPastEnd: (() -> Void)? = nil

    var body: some View {
        curlPager
    }

    // ── Slide (UIPageViewController .scroll) ───────────────────────────
    private var slidePager: some View {
        PageCurlReader(
            currentIndex: $currentIndex,
            totalPages: totalPages,
            cache: cache,
            isTwoUp: false,
            isMangaRTL: isMangaRTL || readingMode == .mangaRTL,
            activeFilterPreset: activeFilterPreset,
            transitionStyle: .scroll,
            onChromeTap: onChromeTap,
            onFlipPastEnd: onFlipPastEnd
        )
        .id("comic_slide_\(readingMode.rawValue)")
    }

    // ── 3D Curl (UIPageViewController .pageCurl) ─────────────────────────
    private var curlPager: some View {
        PageCurlReader(
            currentIndex: $currentIndex,
            totalPages: totalPages,
            cache: cache,
            isTwoUp: false,
            isMangaRTL: isMangaRTL || readingMode == .mangaRTL,
            activeFilterPreset: activeFilterPreset,
            transitionStyle: .pageCurl,
            onChromeTap: onChromeTap,
            onFlipPastEnd: onFlipPastEnd
        )
        .id("comic_curl_\(readingMode.rawValue)")
    }

    // ── Fade Crossfade ─────────────────────────────────────────────────
    @ViewBuilder
    private var fadePager: some View {
        let isRTL = isMangaRTL || readingMode == .mangaRTL
        ZStack {
            ComicPageView(
                index: currentIndex,
                cache: cache
            )
            .applyFilterPreset(activeFilterPreset)
            .id("comic_fade_\(currentIndex)")
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.28), value: currentIndex)
        }
        .contentShape(Rectangle())
        .onTapGesture { onChromeTap() }
        .gesture(
            DragGesture(minimumDistance: 30)
                .onEnded { val in
                    let isNextSwipe = isRTL ? (val.translation.width > 30) : (val.translation.width < -30)
                    let isPrevSwipe = isRTL ? (val.translation.width < -30) : (val.translation.width > 30)
                    if isNextSwipe {
                        if currentIndex < totalPages - 1 {
                            withAnimation(.easeInOut(duration: 0.28)) { currentIndex += 1 }
                        } else {
                            onFlipPastEnd?()
                        }
                    } else if isPrevSwipe {
                        if currentIndex > 0 {
                            withAnimation(.easeInOut(duration: 0.28)) { currentIndex -= 1 }
                        }
                    }
                }
        )
    }
}

// ============================================================
// MARK: - Smart Mid-Spine 3D Physical Page Curl Engine
// ============================================================
struct SmartMidSpineCurlReader: UIViewControllerRepresentable {
    @Binding var currentIndex: Int
    let totalPages: Int
    let cache: ComicImageCache
    let isMangaRTL: Bool
    let activeFilterPreset: ReadingFilterPreset
    var transitionStyle: UIPageViewController.TransitionStyle = .pageCurl
    var onChromeTap: () -> Void
    var onFlipPastEnd: (() -> Void)? = nil

    func computeSpreads() -> [[Int]] {
        var allSpreads: [[Int]] = []
        let landscapeArray = cache.isLandscapeArray
        let pageCount = cache.pageCount
        let linkCover = EBookPreferences.shared.linkCoverAsSpread

        let isPageL: (Int) -> Bool = { idx in
            if idx >= 0 && idx < landscapeArray.count && landscapeArray[idx] { return true }
            if let size = cache.peekImageSize(at: idx), size.width > size.height * 1.1 { return true }
            return false
        }

        if linkCover {
            var i = 0
            while i < pageCount {
                if isPageL(i) {
                    allSpreads.append([i])
                    i += 1
                } else if i + 1 < pageCount {
                    if isPageL(i + 1) {
                        allSpreads.append([i])
                        i += 1
                    } else {
                        allSpreads.append([i, i + 1])
                        i += 2
                    }
                } else {
                    allSpreads.append([i])
                    i += 1
                }
            }
        } else {
            // Page 0: Standalone Cover
            allSpreads.append([0])
            
            // Page 1: Standalone Page 1
            if pageCount > 1 {
                allSpreads.append([1])
            }
            
            // Natural (2+3, 4+5) facing spread pairing
            var i = 2
            while i < pageCount {
                if isPageL(i) {
                    allSpreads.append([i])
                    i += 1
                } else {
                    if i + 1 < pageCount {
                        if isPageL(i + 1) {
                            allSpreads.append([i])
                            i += 1
                        } else {
                            allSpreads.append([i, i + 1])
                            i += 2
                        }
                    } else {
                        allSpreads.append([i])
                        i += 1
                    }
                }
            }
        }
        return allSpreads
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let isSlide = (transitionStyle == .scroll)
        let options: [UIPageViewController.OptionsKey: Any]? = isSlide ? nil : [.spineLocation: UIPageViewController.SpineLocation.mid.rawValue]
        let pageViewController = UIPageViewController(
            transitionStyle: transitionStyle,
            navigationOrientation: .horizontal,
            options: options
        )
        pageViewController.isDoubleSided = !isSlide
        pageViewController.dataSource = context.coordinator
        pageViewController.delegate = context.coordinator

        for gesture in pageViewController.gestureRecognizers {
            if gesture is UITapGestureRecognizer {
                gesture.isEnabled = false
            }
        }

        let view = pageViewController.view!
        
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.cancelsTouchesInView = false
        view.addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleSingleTap(_:)))
        singleTap.numberOfTapsRequired = 1
        singleTap.require(toFail: doubleTap)
        view.addGestureRecognizer(singleTap)

        context.coordinator.pageViewController = pageViewController
        
        let initialSpread = context.coordinator.spreadViewControllers(for: currentIndex)
        pageViewController.setViewControllers(initialSpread, direction: .forward, animated: false)
        return pageViewController
    }

    func updateUIViewController(_ uiViewController: UIPageViewController, context: Context) {
        context.coordinator.parent = self
        
        if context.coordinator.isTransitioning {
            return
        }
        
        if context.coordinator.lastCompletedIndex != nil {
            context.coordinator.lastCompletedIndex = nil
        }
        
        if let currentVCs = uiViewController.viewControllers as? [SingleLeafViewController] {
            let displayedIndices = currentVCs.map { $0.pageIndex }
            let filterPresets = currentVCs.map { $0.activeFilterPreset }
            let allPresetMatch = filterPresets.allSatisfy { $0 == activeFilterPreset }
            
            let spreadMatches = displayedIndices.contains(currentIndex) || (currentIndex == 0 && displayedIndices.contains(-1))
            if spreadMatches && allPresetMatch {
                return // ✅ Target spread is ALREADY displayed on screen -- DO NOT TOUCH setViewControllers!
            }
        }
        
        let targetSpread = context.coordinator.spreadViewControllers(for: currentIndex)
        uiViewController.setViewControllers(targetSpread, direction: .forward, animated: false)
    }
}

extension SmartMidSpineCurlReader {
    @MainActor
    class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: SmartMidSpineCurlReader
        weak var pageViewController: UIPageViewController?
        var isTransitioning: Bool = false
        var lastCompletedIndex: Int? = nil

        init(_ parent: SmartMidSpineCurlReader) {
            self.parent = parent
            super.init()
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleZoomStateChanged(_:)),
                name: .readerZoomStateChanged,
                object: nil
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleOrientationsScanned(_:)),
                name: NSNotification.Name("ComicImageCache.OrientationsScanned"),
                object: nil
            )
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        @objc func handleOrientationsScanned(_ notification: Notification) {
            DispatchQueue.main.async { [weak self] in
                guard let self = self, let pvc = self.pageViewController else { return }
                let currentSpread = self.spreadViewControllers(for: self.parent.currentIndex)
                pvc.setViewControllers(currentSpread, direction: .forward, animated: false)
            }
        }

        func spreadViewControllers(for pageIndex: Int) -> [UIViewController] {
            let spreads = parent.computeSpreads()
            let targetSpread = spreads.first(where: { $0.contains(pageIndex) }) ?? [max(0, pageIndex)]
            
            if targetSpread == [0] {
                let coverVC = SingleLeafViewController(pageIndex: 0, parent: parent, alignment: parent.isMangaRTL ? .leading : .trailing)
                let blankVC = SingleLeafViewController(pageIndex: -1, parent: parent)
                return parent.isMangaRTL ? [coverVC, blankVC] : [blankVC, coverVC]
            } else if targetSpread.count == 1 {
                let singleIdx = targetSpread[0]
                let isL: Bool = {
                    if singleIdx >= 0 && singleIdx < parent.cache.isLandscapeArray.count && parent.cache.isLandscapeArray[singleIdx] { return true }
                    if let size = parent.cache.peekImageSize(at: singleIdx), size.width > size.height * 1.1 { return true }
                    return false
                }()
                if isL {
                    let leftVC = SingleLeafViewController(pageIndex: singleIdx, parent: parent, alignment: .trailing, cropHalf: parent.isMangaRTL ? .right : .left)
                    let rightVC = SingleLeafViewController(pageIndex: singleIdx, parent: parent, alignment: .leading, cropHalf: parent.isMangaRTL ? .left : .right)
                    return parent.isMangaRTL ? [rightVC, leftVC] : [leftVC, rightVC]
                } else {
                    let pageVC = SingleLeafViewController(pageIndex: singleIdx, parent: parent, alignment: parent.isMangaRTL ? .leading : .trailing)
                    let blankVC = SingleLeafViewController(pageIndex: -1, parent: parent)
                    return parent.isMangaRTL ? [pageVC, blankVC] : [blankVC, pageVC]
                }
            } else {
                let leftIdx = targetSpread[0]
                let rightIdx = targetSpread[1]
                let leftVC = SingleLeafViewController(pageIndex: leftIdx, parent: parent, alignment: parent.isMangaRTL ? .leading : .trailing)
                let rightVC = SingleLeafViewController(pageIndex: rightIdx, parent: parent, alignment: parent.isMangaRTL ? .trailing : .leading)
                return parent.isMangaRTL ? [rightVC, leftVC] : [leftVC, rightVC]
            }
        }

        // MARK: - UIPageViewControllerDataSource

        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerBefore viewController: UIViewController
        ) -> UIViewController? {
            guard let leafVC = viewController as? SingleLeafViewController else { return nil }
            let spreads = parent.computeSpreads()
            guard let currentSpreadIdx = spreads.firstIndex(where: { $0.contains(leafVC.pageIndex) }) else { return nil }
            let targetSpreadIdx = parent.isMangaRTL ? (currentSpreadIdx + 1) : (currentSpreadIdx - 1)
            guard targetSpreadIdx >= 0 && targetSpreadIdx < spreads.count else { return nil }
            let targetPages = spreads[targetSpreadIdx]
            let targetPage = targetPages.first ?? -1
            
            let isL: Bool = {
                if targetPage >= 0 && targetPage < parent.cache.isLandscapeArray.count && parent.cache.isLandscapeArray[targetPage] { return true }
                if let size = parent.cache.peekImageSize(at: targetPage), size.width > size.height * 1.1 { return true }
                return false
            }()
            let cropHalf: CropHalf = isL ? (parent.isMangaRTL ? .left : .right) : .none
            return SingleLeafViewController(pageIndex: targetPage, parent: parent, alignment: parent.isMangaRTL ? .leading : .trailing, cropHalf: cropHalf)
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerAfter viewController: UIViewController
        ) -> UIViewController? {
            guard let leafVC = viewController as? SingleLeafViewController else { return nil }
            let spreads = parent.computeSpreads()
            guard let currentSpreadIdx = spreads.firstIndex(where: { $0.contains(leafVC.pageIndex) }) else { return nil }
            let targetSpreadIdx = parent.isMangaRTL ? (currentSpreadIdx - 1) : (currentSpreadIdx + 1)
            guard targetSpreadIdx >= 0 && targetSpreadIdx < spreads.count else { return nil }
            let targetPages = spreads[targetSpreadIdx]
            let targetPage = targetPages.first ?? -1
            
            let isL: Bool = {
                if targetPage >= 0 && targetPage < parent.cache.isLandscapeArray.count && parent.cache.isLandscapeArray[targetPage] { return true }
                if let size = parent.cache.peekImageSize(at: targetPage), size.width > size.height * 1.1 { return true }
                return false
            }()
            let cropHalf: CropHalf = isL ? (parent.isMangaRTL ? .right : .left) : .none
            return SingleLeafViewController(pageIndex: targetPage, parent: parent, alignment: parent.isMangaRTL ? .trailing : .leading, cropHalf: cropHalf)
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
            guard let visibleVCs = pageViewController.viewControllers,
                  let firstLeaf = visibleVCs.first as? SingleLeafViewController else {
                return
            }
            let visibleIndices = visibleVCs.compactMap { ($0 as? SingleLeafViewController)?.pageIndex }.filter { $0 >= 0 }
            let actualIndex = visibleIndices.first ?? (firstLeaf.pageIndex < 0 ? 0 : firstLeaf.pageIndex)
            lastCompletedIndex = actualIndex
            
            if completed {
                if parent.currentIndex != actualIndex {
                    parent.currentIndex = actualIndex
                }
            } else {
                // 🔴 CRITICAL SNAP-BACK GUARD: User cancelled drag gesture midway!
                // Restore parent.currentIndex to match the page currently visible
                if parent.currentIndex != actualIndex {
                    parent.currentIndex = actualIndex
                }
            }
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            spineLocationFor orientation: UIInterfaceOrientation
        ) -> UIPageViewController.SpineLocation {
            pageViewController.isDoubleSided = true
            return .mid
        }

        // MARK: - Gesture Handlers

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            // Cooperative gesture helper
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
                if parent.isMangaRTL { turnForward(pvc) } else { turnBackward(pvc) }
            } else if location.x > width * zones.rightEdge {
                if parent.isMangaRTL { turnBackward(pvc) } else { turnForward(pvc) }
            } else {
                parent.onChromeTap()
            }
        }

        private func turnForward(_ pvc: UIPageViewController) {
            guard !isTransitioning else { return }
            let spreads = parent.computeSpreads()
            if let currentSpreadIdx = spreads.firstIndex(where: { $0.contains(parent.currentIndex) }) {
                let nextSpreadIdx = currentSpreadIdx + 1
                if nextSpreadIdx < spreads.count {
                    let nextIndex = spreads[nextSpreadIdx].first ?? parent.currentIndex
                    let targetSpread = spreadViewControllers(for: nextIndex)
                    HapticEngine.light()
                    let direction: UIPageViewController.NavigationDirection = parent.isMangaRTL ? .reverse : .forward
                    isTransitioning = true // 🔴 Lock transitions during tap page flip
                    pvc.setViewControllers(targetSpread, direction: direction, animated: true) { [weak self] completed in
                        self?.isTransitioning = false // 🔓 Unlock transition
                        if completed {
                            DispatchQueue.main.async {
                                self?.parent.currentIndex = nextIndex
                            }
                        }
                    }
                    return
                }
            }
            parent.onFlipPastEnd?()
        }

        private func turnBackward(_ pvc: UIPageViewController) {
            guard !isTransitioning else { return }
            let spreads = parent.computeSpreads()
            if let currentSpreadIdx = spreads.firstIndex(where: { $0.contains(parent.currentIndex) }) {
                let prevSpreadIdx = currentSpreadIdx - 1
                if prevSpreadIdx >= 0 {
                    let prevIndex = spreads[prevSpreadIdx].first ?? parent.currentIndex
                    let targetSpread = spreadViewControllers(for: prevIndex)
                    HapticEngine.light()
                    let direction: UIPageViewController.NavigationDirection = parent.isMangaRTL ? .forward : .reverse
                    isTransitioning = true // 🔴 Lock transitions during tap page flip
                    pvc.setViewControllers(targetSpread, direction: direction, animated: true) { [weak self] completed in
                        self?.isTransitioning = false // 🔓 Unlock transition
                        if completed {
                            DispatchQueue.main.async {
                                self?.parent.currentIndex = prevIndex
                            }
                        }
                    }
                }
            }
        }

        @objc func handleZoomStateChanged(_ notification: Notification) {
            guard let isZoomed = notification.userInfo?["isZoomed"] as? Bool else { return }
            guard let pvc = self.pageViewController else { return }
            for gesture in pvc.gestureRecognizers {
                if gesture is UIPanGestureRecognizer {
                    gesture.isEnabled = !isZoomed
                }
            }
        }
    }
}

enum CropHalf {
    case none
    case left
    case right
}

// MARK: - Single Leaf VC
@MainActor
class SingleLeafViewController: UIViewController {
    let pageIndex: Int
    let activeFilterPreset: ReadingFilterPreset
    let alignment: Alignment
    let cropHalf: CropHalf
    
    init(pageIndex: Int, parent: SmartMidSpineCurlReader, alignment: Alignment = .center, cropHalf: CropHalf = .none) {
        self.pageIndex = pageIndex
        self.activeFilterPreset = parent.activeFilterPreset
        self.alignment = alignment
        self.cropHalf = cropHalf
        super.init(nibName: nil, bundle: nil)
        
        view.backgroundColor = .black
        
        let leafContent: AnyView
        if pageIndex >= 0 && pageIndex < parent.totalPages {
            leafContent = AnyView(
                TwoUpPageCell(
                    index: pageIndex,
                    cache: parent.cache,
                    activeFilterPreset: parent.activeFilterPreset,
                    alignment: alignment,
                    cropHalf: cropHalf
                )
                .background(Color.black)
                .ignoresSafeArea()
            )
        } else {
            leafContent = AnyView(Color.black.ignoresSafeArea())
        }
        
        let hostingController = UIHostingController(rootView: leafContent)
        hostingController.view.backgroundColor = .black
        addChild(hostingController)
        view.addSubview(hostingController.view)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        hostingController.didMove(toParent: self)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

// ============================================================
// MARK: - Two-Up Spread Pager
// ============================================================
struct TwoUpBookPager: View {
    @Binding var currentIndex: Int
    let cache: ComicImageCache
    let activeFilterPreset: ReadingFilterPreset
    var readingMode: ComicReadingMode = .pageHorizontal
    let isMangaRTL: Bool
    var onChromeTap: () -> Void
    var onFlipPastEnd: (() -> Void)? = nil

    var body: some View {
        SmartMidSpineCurlReader(
            currentIndex: $currentIndex,
            totalPages: cache.pageCount,
            cache: cache,
            isMangaRTL: isMangaRTL,
            activeFilterPreset: activeFilterPreset,
            transitionStyle: .pageCurl,
            onChromeTap: onChromeTap,
            onFlipPastEnd: onFlipPastEnd
        )
        .id("twoup_\(readingMode.rawValue)")
    }
}

struct TwoUpPageCell: View {
    let index: Int
    let cache: ComicImageCache
    let activeFilterPreset: ReadingFilterPreset
    var alignment: Alignment = .center
    var cropHalf: CropHalf = .none
    
    @State private var image: UIImage? = nil
    
    var body: some View {
        let currentImage = image ?? cache.getImage(at: index)
        
        ZStack {
            Color.black
            if let displayImg = currentImage {
                if cropHalf != .none {
                    GeometryReader { geo in
                        Image(uiImage: displayImg)
                            .resizable()
                            .applyFilterPreset(activeFilterPreset)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: geo.size.width * 2, height: geo.size.height, alignment: .center)
                            .offset(x: cropHalf == .left ? 0 : -geo.size.width)
                    }
                    .clipped()
                } else {
                    Image(uiImage: displayImg)
                        .resizable()
                        .applyFilterPreset(activeFilterPreset)
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
                        .clipped()
                }
            } else {
                Color.black
            }
        }
        .clipped()
        .id(index)
        .onAppear {
            if image == nil {
                image = cache.getImage(at: index)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .comicImageCacheImageLoaded)) { notification in
            guard let userInfo = notification.userInfo,
                  let loadedIndex = userInfo["index"] as? Int,
                  loadedIndex == index else { return }
            image = cache.getImage(at: index)
        }
    }
}

// MARK: - 3D Authentic Page Curl Effect for Reader Engines
struct PageCurl3DEffect: ViewModifier {
    let angle: Double
    let axisX: CGFloat
    let axisY: CGFloat
    let axisZ: CGFloat
    let anchor: UnitPoint

    init(angle: Double, axis: (x: CGFloat, y: CGFloat, z: CGFloat), anchor: UnitPoint) {
        self.angle = angle
        self.axisX = axis.x
        self.axisY = axis.y
        self.axisZ = axis.z
        self.anchor = anchor
    }

    func body(content: Content) -> some View {
        let progress = abs(angle) / 90.0
        let isTrailingAnchor = (anchor == .trailing || anchor == .topTrailing || anchor == .bottomTrailing)
        let curlOffset = isTrailingAnchor ? -progress * 20.0 : progress * 20.0
        
        content
            .rotation3DEffect(
                .degrees(angle),
                axis: (x: axisX, y: axisY, z: axisZ),
                anchor: anchor,
                anchorZ: 0,
                perspective: 0.35
            )
            .offset(x: curlOffset)
            .overlay(
                LinearGradient(
                    colors: [
                        Color.black.opacity(0.40 * progress),
                        Color.black.opacity(0.12 * progress),
                        Color.clear
                    ],
                    startPoint: isTrailingAnchor ? .trailing : .leading,
                    endPoint: isTrailingAnchor ? .leading : .trailing
                )
                .allowsHitTesting(false)
            )
            .shadow(color: .black.opacity(0.4 * progress), radius: 10, x: isTrailingAnchor ? -6 : 6, y: 2)
    }
}
