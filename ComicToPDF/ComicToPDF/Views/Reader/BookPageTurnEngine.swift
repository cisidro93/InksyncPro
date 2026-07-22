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
        
        if let currentVC = uiViewController.viewControllers?.first as? PageContentViewController {
            let spreadsChanged: Bool
            if isTwoUp {
                let currentSpreads = currentVC.spreads
                let newSpreads = computeSpreads()
                spreadsChanged = currentSpreads != newSpreads
            } else {
                spreadsChanged = false
            }
            
            if currentVC.index != targetControllerIndex || currentVC.isTwoUp != isTwoUp || currentVC.activeFilterPreset != activeFilterPreset || spreadsChanged {
                let vc = context.coordinator.makeViewController(for: targetControllerIndex)
                let isForward = targetControllerIndex >= currentVC.index
                let direction: UIPageViewController.NavigationDirection
                if isMangaRTL {
                    direction = isForward ? .reverse : .forward
                } else {
                    direction = isForward ? .forward : .reverse
                }
                uiViewController.setViewControllers([vc], direction: direction, animated: false, completion: nil)
            }
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
            slidePager
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
            isMangaRTL: readingMode == .mangaRTL,
            activeFilterPreset: activeFilterPreset,
            onChromeTap: onChromeTap,
            onFlipPastEnd: onFlipPastEnd
        )
    }

    // ── Flat Slide (TabView / PageTabViewStyle) ────────────────────────
    private var slidePager: some View {
        return TabView(selection: $currentIndex) {
            ForEach(0..<totalPages, id: \.self) { idx in
                ComicPageView(
                    index: idx,
                    cache: cache
                )
                .applyFilterPreset(activeFilterPreset)
                .tag(idx)
                .onTapGesture { onChromeTap() }
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .ignoresSafeArea()
    }

    // ── Fade Crossfade ─────────────────────────────────────────────────
    @ViewBuilder
    private var fadePager: some View {
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
                    if val.translation.width < -30 {
                        // Swiping finger leftward -> Next page
                        if currentIndex < totalPages - 1 {
                            withAnimation(.easeInOut(duration: 0.28)) { currentIndex += 1 }
                        } else {
                            onFlipPastEnd?()
                        }
                    } else if val.translation.width > 30 {
                        // Swiping finger rightward -> Previous page
                        if currentIndex > 0 {
                            withAnimation(.easeInOut(duration: 0.28)) { currentIndex -= 1 }
                        }
                    }
                }
        )
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
        PageCurlReader(
            currentIndex: $currentIndex,
            totalPages: cache.pageCount,
            cache: cache,
            isTwoUp: true,
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
