import SwiftUI

// ============================================================
// MARK: - Book Page Turn Transition (Magazine-spread feel)
// ============================================================
/// A custom page-flip transition that mirrors how a physical book opens.
/// - Right side of screen taps → page turns forward (curl from right)
/// - Left side of screen taps → page turns back (curl from left)
struct BookFlipGesture: View {
    @Binding var currentIndex: Int
    let content: (Int) -> AnyView
    let isMangaRTL: Bool
    var onChromeTap: () -> Void

    var canFlipForward: () -> Bool
    var canFlipBack: () -> Bool
    var onFlipForward: () -> Void
    var onFlipBack: () -> Void
    var onFlipPastEnd: (() -> Void)? = nil

    @State private var dragOffset: CGFloat = 0
    /// Guards the full flip sequence — prevents double-advance from rapid taps.
    @State private var isAnimating = false
    /// Stored so new flips can cancel the previous in-flight animation Task.
    @State private var flipTask: Task<Void, Never>? = nil

    @Environment(\.horizontalSizeClass) private var hSizeClass

    private func tapZoneWidth(totalWidth: CGFloat) -> CGFloat {
        hSizeClass == .regular ? totalWidth * 0.15 : totalWidth / 3.0
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // ── Background: previous spread (renders beneath the curl) ──
                content(max(0, currentIndex - 1))
                    .frame(width: geo.size.width, height: geo.size.height)
                    .zIndex(0)

                // ── The page curling away ──
                let normalizedDrag = geo.size.width > 0 ? dragOffset / geo.size.width : 0
                let rotation = Double(normalizedDrag) * -70.0

                content(currentIndex)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .rotation3DEffect(
                        .degrees(isAnimating ? 0 : rotation),
                        axis: (x: 0, y: 1, z: 0),
                        anchor: dragOffset > 0 ? .leading : .trailing,
                        perspective: 0.35
                    )
                    .offset(x: dragOffset * 0.06)
                    // Shadow darkens the leading/trailing edge during curl
                    .overlay(
                        LinearGradient(
                            colors: [
                                Color.black.opacity(
                                    max(0, min(0.5, abs(normalizedDrag) * 0.9))
                                ),
                                Color.clear
                            ],
                            startPoint: dragOffset < 0 ? .trailing : .leading,
                            endPoint:   dragOffset < 0 ? .leading  : .trailing
                        )
                        .allowsHitTesting(false)
                    )
                    .zIndex(1)

                // ── Instant Tap Zones Overlay ──
                let zoneW = tapZoneWidth(totalWidth: geo.size.width)
                HStack(spacing: 0) {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard !isAnimating else { return }
                            if isMangaRTL {
                                if canFlipForward() { flipForward(width: geo.size.width) } else { onFlipPastEnd?() }
                            } else {
                                if canFlipBack() { flipBack(width: geo.size.width) }
                            }
                        }
                        .frame(width: zoneW)
                    
                    Spacer()
                    
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard !isAnimating else { return }
                            if isMangaRTL {
                                if canFlipBack() { flipBack(width: geo.size.width) }
                            } else {
                                if canFlipForward() { flipForward(width: geo.size.width) } else { onFlipPastEnd?() }
                            }
                        }
                        .frame(width: zoneW)
                }
                .zIndex(2)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { val in
                        if !isAnimating { dragOffset = val.translation.width }
                    }
                    .onEnded { val in
                        let threshold = geo.size.width * 0.22
                        let swipeRight = val.translation.width >  threshold
                        let swipeLeft  = val.translation.width < -threshold

                        let goNext = isMangaRTL ? swipeRight : swipeLeft
                        let goPrev = isMangaRTL ? swipeLeft  : swipeRight

                        if goNext {
                            if canFlipForward() {
                                flipForward(width: geo.size.width)
                            } else {
                                onFlipPastEnd?()
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { dragOffset = 0 }
                            }
                        } else if goPrev && canFlipBack() {
                            flipBack(width: geo.size.width)
                        } else {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                dragOffset = 0
                            }
                        }
                    }
            )
            .onTapGesture { location in
                guard !isAnimating else { return }
                let zoneW = tapZoneWidth(totalWidth: geo.size.width)
                if location.x < zoneW {
                    if isMangaRTL { 
                        if canFlipForward() { flipForward(width: geo.size.width) } else { onFlipPastEnd?() }
                    } else { 
                        if canFlipBack() { flipBack(width: geo.size.width) } 
                    }
                } else if location.x > geo.size.width - zoneW {
                    if isMangaRTL { 
                        if canFlipBack() { flipBack(width: geo.size.width) } 
                    } else { 
                        if canFlipForward() { flipForward(width: geo.size.width) } else { onFlipPastEnd?() }
                    }
                } else {
                    onChromeTap()
                }
            }
        }
        .onDisappear {
            // Cancel any in-flight animation when the view is torn down
            // (e.g. orientation changes switching between pageTwoUp and pageHorizontal).
            flipTask?.cancel()
            flipTask = nil
            isAnimating = false
        }
    }

    // MARK: - Flip Forward
    private func flipForward(width: CGFloat) {
        guard !isAnimating, canFlipForward() else { return }
        isAnimating = true
        HapticEngine.light()
        // Cancel any lingering previous task before starting fresh
        flipTask?.cancel()

        // Phase 1 — peel the page offscreen
        let exitOffset: CGFloat = isMangaRTL ? width * 0.6 : -width * 0.6
        withAnimation(.interactiveSpring(response: 0.28, dampingFraction: 0.78)) {
            dragOffset = exitOffset
        }

        flipTask = Task { @MainActor in
            // Phase 2 — swap content while curl is offscreen
            try? await Task.sleep(nanoseconds: 160_000_000)
            guard !Task.isCancelled else { isAnimating = false; return }
            onFlipForward()

            // Phase 3 — bounce snap back to reveal new page
            dragOffset = isMangaRTL ? -28 : 28
            withAnimation(.spring(response: 0.22, dampingFraction: 0.88)) { dragOffset = 0 }

            // Phase 4 — unlock gate after settle
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            isAnimating = false
        }
    }

    // MARK: - Flip Back
    private func flipBack(width: CGFloat) {
        guard !isAnimating, canFlipBack() else { return }
        isAnimating = true
        HapticEngine.light()
        flipTask?.cancel()

        let exitOffset: CGFloat = isMangaRTL ? -width * 0.6 : width * 0.6
        withAnimation(.interactiveSpring(response: 0.28, dampingFraction: 0.78)) {
            dragOffset = exitOffset
        }

        flipTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 160_000_000)
            guard !Task.isCancelled else { isAnimating = false; return }
            onFlipBack()

            dragOffset = isMangaRTL ? 28 : -28
            withAnimation(.spring(response: 0.22, dampingFraction: 0.88)) { dragOffset = 0 }

            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            isAnimating = false
        }
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

    // ── 3D Curl (default, original behaviour) ─────────────────────────
    private var curlPager: some View {
        BookFlipGesture(
            currentIndex: $currentIndex,
            content: { idx in
                AnyView(
                    ComicPageView(
                        index: idx,
                        cache: cache
                    )
                    .applyFilterPreset(activeFilterPreset)
                )
            },
            isMangaRTL: readingMode == .mangaRTL,
            onChromeTap: onChromeTap,
            canFlipForward: { currentIndex < totalPages - 1 },
            canFlipBack:    { currentIndex > 0 },
            onFlipForward:  { currentIndex += 1 },
            onFlipBack:     { currentIndex -= 1 },
            onFlipPastEnd:  onFlipPastEnd
        )
    }

    // ── Flat Slide (TabView / PageTabViewStyle) ────────────────────────
    private var slidePager: some View {
        TabView(selection: $currentIndex) {
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
            .id(currentIndex) // forces view replacement on change → triggers transition
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.28), value: currentIndex)
        }
        .contentShape(Rectangle())
        .onTapGesture { onChromeTap() }
        .gesture(
            DragGesture(minimumDistance: 30)
                .onEnded { val in
                    if val.translation.width < -30 {
                        if currentIndex < totalPages - 1 {
                            withAnimation(.easeInOut(duration: 0.28)) { currentIndex += 1 }
                        } else {
                            onFlipPastEnd?()
                        }
                    } else if val.translation.width > 30, currentIndex > 0 {
                        withAnimation(.easeInOut(duration: 0.28)) { currentIndex -= 1 }
                    }
                }
        )
    }
}

// ============================================================
// MARK: - Two-Up Spread Pager
// ============================================================
/// Shows two portrait pages side-by-side that flip as a complete spread.
/// Manga mode (isMangaRTL) renders right page first for authentic RTL layout.
///   spreadIdx 0  →  pages 0 + 1
///   spreadIdx 1  →  pages 2 + 3  …
struct TwoUpBookPager: View {
    @Binding var currentIndex: Int
    let cache: ComicImageCache
    let activeFilterPreset: ReadingFilterPreset
    let isMangaRTL: Bool
    var onChromeTap: () -> Void
    var onFlipPastEnd: (() -> Void)? = nil

    @State private var spreadIdx: Int = 0
    @State private var forceUpdateTick: Int = 0

    private var spreads: [[Int]] {
        _ = forceUpdateTick
        var allSpreads: [[Int]] = []
        guard cache.pageCount > 0 else { return [[0]] }
        
        if cache.pageCount > 1 {
            allSpreads.append([0]) // Page 0 is the cover, keep it solo
            var i = 1
            while i < cache.pageCount {
                if i + 1 < cache.pageCount {
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
        return allSpreads.isEmpty ? [[0]] : allSpreads
    }

    private var totalSpreads: Int {
        spreads.count
    }

    private func isLandscapePage(_ absIdx: Int) -> Bool {
        guard let size = cache.peekImageSize(at: absIdx) else { return false }
        return (size.width / max(1, size.height)) > 1.15
    }
    
    private func updateSpreadIdx(from targetPageIndex: Int) {
        let currentSpreads = spreads
        if let idx = currentSpreads.firstIndex(where: { $0.contains(targetPageIndex) }) {
            if spreadIdx != idx { spreadIdx = idx }
        }
    }

    var body: some View {
        BookFlipGesture(
            currentIndex: $spreadIdx,
            content: { sIdx in
                AnyView(spreadView(sIdx: sIdx))
            },
            isMangaRTL: isMangaRTL,
            onChromeTap: onChromeTap,
            canFlipForward: { spreadIdx < totalSpreads - 1 },
            canFlipBack:    { spreadIdx > 0 },
            onFlipForward:  { spreadIdx += 1 },
            onFlipBack:     { spreadIdx -= 1 },
            onFlipPastEnd:  onFlipPastEnd
        )
        .onAppear { updateSpreadIdx(from: currentIndex) }
        .onChange(of: spreadIdx) { _, newVal in
            let currentSpreads = spreads
            if newVal < currentSpreads.count {
                let page = currentSpreads[newVal].first ?? 0
                if currentIndex != page { currentIndex = page }
            }
        }
        .onChange(of: currentIndex) { _, newVal in
            updateSpreadIdx(from: newVal)
        }
        .onReceive(NotificationCenter.default.publisher(for: .comicImageCacheImageLoaded)) { _ in
            forceUpdateTick += 1
            updateSpreadIdx(from: currentIndex)
        }
    }

    @ViewBuilder
    private func spreadView(sIdx: Int) -> some View {
        let currentSpreads = spreads
        let pages = sIdx < currentSpreads.count ? currentSpreads[sIdx] : [0]
        
        GeometryReader { geo in
            if pages.count == 1 && isLandscapePage(pages[0]) {
                // Native landscape — fills the full frame solo
                TwoUpPageCell(index: pages[0], cache: cache, activeFilterPreset: activeFilterPreset)
                    .frame(width: geo.size.width, height: geo.size.height)
            } else if isMangaRTL {
                // Manga RTL: higher page number (right panel) on left of screen
                HStack(spacing: 0) {
                    if pages.count == 2 {
                        TwoUpPageCell(index: pages[1], cache: cache, activeFilterPreset: activeFilterPreset)
                            .frame(width: geo.size.width / 2, height: geo.size.height)
                    } else {
                        Color.black
                            .frame(width: geo.size.width / 2, height: geo.size.height)
                    }
                    TwoUpPageCell(index: pages[0], cache: cache, activeFilterPreset: activeFilterPreset)
                        .frame(width: geo.size.width / 2, height: geo.size.height)
                }
            } else {
                // Standard LTR two-page spread
                HStack(spacing: 0) {
                    TwoUpPageCell(index: pages[0], cache: cache, activeFilterPreset: activeFilterPreset)
                        .frame(width: geo.size.width / 2, height: geo.size.height)
                    if pages.count == 2 {
                        TwoUpPageCell(index: pages[1], cache: cache, activeFilterPreset: activeFilterPreset)
                            .frame(width: geo.size.width / 2, height: geo.size.height)
                    } else {
                        Color.black
                            .frame(width: geo.size.width / 2, height: geo.size.height)
                    }
                }
            }
        }
        .id("spread_\(pages.first ?? 0)")
    }
}

struct TwoUpPageCell: View {
    let index: Int
    let cache: ComicImageCache
    let activeFilterPreset: ReadingFilterPreset
    
    @State private var image: UIImage? = nil
    
    var body: some View {
        ZStack {
            Color.black
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .applyFilterPreset(activeFilterPreset)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
            } else {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white.opacity(0.5)))
                    .transition(.opacity)
            }
        }
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
