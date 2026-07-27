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
    var onChromeTap: () -> Void
    var onFlipPastEnd: (() -> Void)?

    func computeSpreads() -> [[Int]] {
        var allSpreads: [[Int]] = []
        let landscapeArray = cache.isLandscapeArray

        guard landscapeArray.count == totalPages else {
            if totalPages > 1 {
                allSpreads.append([0])
                var i = 1
                while i < totalPages {
                    if i + 1 < totalPages {
                        allSpreads.append([i, i + 1])
                        i += 2
                    } else {
                        allSpreads.append([i])
                        i += 1
                    }
                }
            } else {
                allSpreads.append([0])
            }
            return allSpreads
        }

        allSpreads.append([0])
        var i = 1
        while i < totalPages {
            let isL = landscapeArray[i]
            if isL {
                allSpreads.append([i])
                i += 1
            } else {
                if i + 1 < totalPages {
                    let nextIsL = landscapeArray[i + 1]
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
        return allSpreads
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pageViewController = UIPageViewController(
            transitionStyle: .pageCurl,
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
        
        // Clear gesture completion marker if set
        if context.coordinator.lastCompletedControllerIndex != nil {
            context.coordinator.lastCompletedControllerIndex = nil
        }
        
        if let currentVC = uiViewController.viewControllers?.first as? PageContentViewController {
            let spreadsChanged: Bool
            if isTwoUp {
                let currentSpreads = currentVC.spreads
                let newSpreads = computeSpreads()
                spreadsChanged = currentSpreads != newSpreads
            } else {
                spreadsChanged = false
            }
            
            let isDisplayed: Bool
            if isTwoUp {
                let currentSpreadPages = currentVC.spreads.first(where: { $0.contains(currentVC.index) }) ?? [currentVC.index]
                isDisplayed = currentSpreadPages.contains(targetIndex)
            } else {
                isDisplayed = (currentVC.index == targetControllerIndex)
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
            guard let contentVC = viewController as? PageContentViewController else { return nil }
            let currentIndex = contentVC.index
            let targetIndex: Int = parent.isMangaRTL ? (currentIndex + 1) : (currentIndex - 1)
            
            let maxCount = parent.isTwoUp ? parent.computeSpreads().count : parent.totalPages
            guard targetIndex >= 0 && targetIndex < maxCount else { return nil }
            return makeViewController(for: targetIndex)
        }
        
        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerAfter viewController: UIViewController
        ) -> UIViewController? {
            guard let contentVC = viewController as? PageContentViewController else { return nil }
            let currentIndex = contentVC.index
            let targetIndex: Int = parent.isMangaRTL ? (currentIndex - 1) : (currentIndex + 1)
            
            let maxCount = parent.isTwoUp ? parent.computeSpreads().count : parent.totalPages
            guard targetIndex >= 0 && targetIndex < maxCount else { return nil }
            return makeViewController(for: targetIndex)
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
            guard completed,
                  let currentVC = pageViewController.viewControllers?.first as? PageContentViewController else {
                return
            }
            
            let newControllerIndex = currentVC.index
            lastCompletedControllerIndex = newControllerIndex
            
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
                pvc.setViewControllers([vc], direction: direction, animated: true) { [weak self] completed in
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
                pvc.setViewControllers([vc], direction: direction, animated: true) { [weak self] completed in
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
                    TwoUpPageCell(index: pages[0], cache: parent.cache, activeFilterPreset: parent.activeFilterPreset, alignment: .center)
                        .frame(width: geo.size.width, height: geo.size.height)
                } else if parent.isMangaRTL {
                    HStack(spacing: 0) {
                        if pages.count == 2 {
                            TwoUpPageCell(index: pages[1], cache: parent.cache, activeFilterPreset: parent.activeFilterPreset, alignment: .trailing)
                                .frame(width: geo.size.width / 2, height: geo.size.height)
                        } else {
                            Color.black
                                .frame(width: geo.size.width / 2, height: geo.size.height)
                        }
                        TwoUpPageCell(index: pages[0], cache: parent.cache, activeFilterPreset: parent.activeFilterPreset, alignment: .leading)
                            .frame(width: geo.size.width / 2, height: geo.size.height)
                    }
                } else {
                    HStack(spacing: 0) {
                        TwoUpPageCell(index: pages[0], cache: parent.cache, activeFilterPreset: parent.activeFilterPreset, alignment: .trailing)
                            .frame(width: geo.size.width / 2, height: geo.size.height)
                        if pages.count == 2 {
                            TwoUpPageCell(index: pages[1], cache: parent.cache, activeFilterPreset: parent.activeFilterPreset, alignment: .leading)
                                .frame(width: geo.size.width / 2, height: geo.size.height)
                        } else {
                            Color.black
                                .frame(width: geo.size.width / 2, height: geo.size.height)
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
        switch readingMode {
        case .pageSlide:
            curlPager
        case .pageFade:
            fadePager
        default:
            curlPager
        }
    }

    // ── 3D Curl (UIPageViewController) ─────────────────────────
    private var curlPager: some View {
        PageCurlReader(
            currentIndex: $currentIndex,
            totalPages: totalPages,
            cache: cache,
            isTwoUp: false,
            isMangaRTL: isMangaRTL || readingMode == .mangaRTL,
            activeFilterPreset: activeFilterPreset,
            onChromeTap: onChromeTap,
            onFlipPastEnd: onFlipPastEnd
        )
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
            .id(currentIndex)
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
    var onChromeTap: () -> Void
    var onFlipPastEnd: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pageViewController = UIPageViewController(
            transitionStyle: .pageCurl,
            navigationOrientation: .horizontal,
            options: [.spineLocation: UIPageViewController.SpineLocation.mid.rawValue]
        )
        pageViewController.isDoubleSided = true
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
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func spreadViewControllers(for pageIndex: Int) -> [UIViewController] {
            let isCover = (pageIndex == 0)
            if isCover {
                let coverVC = SingleLeafViewController(pageIndex: 0, parent: parent)
                let blankVC = SingleLeafViewController(pageIndex: -1, parent: parent)
                return parent.isMangaRTL ? [coverVC, blankVC] : [blankVC, coverVC]
            } else {
                let leftIdx = (pageIndex % 2 == 0) ? (pageIndex - 1) : pageIndex
                let rightIdx = leftIdx + 1
                
                let leftVC = SingleLeafViewController(pageIndex: leftIdx, parent: parent)
                let rightVC = (rightIdx < parent.totalPages)
                    ? SingleLeafViewController(pageIndex: rightIdx, parent: parent)
                    : SingleLeafViewController(pageIndex: -1, parent: parent)
                
                return parent.isMangaRTL ? [rightVC, leftVC] : [leftVC, rightVC]
            }
        }

        // MARK: - UIPageViewControllerDataSource

        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerBefore viewController: UIViewController
        ) -> UIViewController? {
            guard let leafVC = viewController as? SingleLeafViewController else { return nil }
            let currentLeafIndex = leafVC.pageIndex
            let targetIndex: Int = parent.isMangaRTL ? (currentLeafIndex + 1) : (currentLeafIndex - 1)
            guard targetIndex >= -1 && targetIndex < parent.totalPages else { return nil }
            return SingleLeafViewController(pageIndex: targetIndex, parent: parent)
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerAfter viewController: UIViewController
        ) -> UIViewController? {
            guard let leafVC = viewController as? SingleLeafViewController else { return nil }
            let currentLeafIndex = leafVC.pageIndex
            let targetIndex: Int = parent.isMangaRTL ? (currentLeafIndex - 1) : (currentLeafIndex + 1)
            guard targetIndex >= -1 && targetIndex < parent.totalPages else { return nil }
            return SingleLeafViewController(pageIndex: targetIndex, parent: parent)
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
            guard completed,
                  let visibleVCs = pageViewController.viewControllers,
                  let firstLeaf = visibleVCs.first as? SingleLeafViewController else {
                return
            }
            let newIndex = firstLeaf.pageIndex < 0 ? 0 : firstLeaf.pageIndex
            lastCompletedIndex = newIndex
            if parent.currentIndex != newIndex {
                parent.currentIndex = newIndex
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
            let nextIndex = min(parent.totalPages - 1, parent.currentIndex + 2)
            if nextIndex != parent.currentIndex {
                let targetSpread = spreadViewControllers(for: nextIndex)
                HapticEngine.light()
                let direction: UIPageViewController.NavigationDirection = parent.isMangaRTL ? .reverse : .forward
                pvc.setViewControllers(targetSpread, direction: direction, animated: true) { [weak self] completed in
                    if completed {
                        DispatchQueue.main.async {
                            self?.parent.currentIndex = nextIndex
                        }
                    }
                }
            } else {
                parent.onFlipPastEnd?()
            }
        }

        private func turnBackward(_ pvc: UIPageViewController) {
            let prevIndex = max(0, parent.currentIndex - 2)
            if prevIndex != parent.currentIndex {
                let targetSpread = spreadViewControllers(for: prevIndex)
                HapticEngine.light()
                let direction: UIPageViewController.NavigationDirection = parent.isMangaRTL ? .forward : .reverse
                pvc.setViewControllers(targetSpread, direction: direction, animated: true) { [weak self] completed in
                    if completed {
                        DispatchQueue.main.async {
                            self?.parent.currentIndex = prevIndex
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

// MARK: - Single Leaf VC
@MainActor
class SingleLeafViewController: UIViewController {
    let pageIndex: Int
    let activeFilterPreset: ReadingFilterPreset
    
    init(pageIndex: Int, parent: SmartMidSpineCurlReader) {
        self.pageIndex = pageIndex
        self.activeFilterPreset = parent.activeFilterPreset
        super.init(nibName: nil, bundle: nil)
        
        view.backgroundColor = .black
        
        let leafContent: AnyView
        if pageIndex >= 0 && pageIndex < parent.totalPages {
            leafContent = AnyView(
                TwoUpPageCell(
                    index: pageIndex,
                    cache: parent.cache,
                    activeFilterPreset: parent.activeFilterPreset,
                    alignment: .center
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
            onChromeTap: onChromeTap,
            onFlipPastEnd: onFlipPastEnd
        )
    }
}

struct TwoUpPageCell: View {
    let index: Int
    let cache: ComicImageCache
    let activeFilterPreset: ReadingFilterPreset
    var alignment: Alignment = .center
    
    @State private var image: UIImage? = nil
    
    var body: some View {
        ZStack {
            Color.black
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .applyFilterPreset(activeFilterPreset)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
                    .transition(.opacity)
            } else {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white.opacity(0.5)))
                    .transition(.opacity)
            }
        }
        .id(index)
        .onAppear {
            image = cache.getImage(at: index)
        }
        .onReceive(NotificationCenter.default.publisher(for: .comicImageCacheImageLoaded)) { notification in
            guard let userInfo = notification.userInfo,
                  let loadedIndex = userInfo["index"] as? Int,
                  loadedIndex == index else { return }
            withAnimation(.easeIn(duration: 0.18)) {
                image = cache.getImage(at: index)
            }
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
