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

    @State private var dragOffset: CGFloat = 0
    /// Guards the full flip sequence — prevents double-advance from rapid taps.
    @State private var isAnimating = false
    /// Stored so new flips can cancel the previous in-flight animation Task.
    @State private var flipTask: Task<Void, Never>? = nil

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

                        if goNext && canFlipForward() {
                            flipForward(width: geo.size.width)
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
                let third = geo.size.width / 3
                if location.x < third {
                    if isMangaRTL { flipForward(width: geo.size.width) }
                    else          { flipBack(width: geo.size.width) }
                } else if location.x > geo.size.width - third {
                    if isMangaRTL { flipBack(width: geo.size.width) }
                    else          { flipForward(width: geo.size.width) }
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

    var body: some View {
        BookFlipGesture(
            currentIndex: $currentIndex,
            content: { idx in
                AnyView(
                    ComicPageView(
                        image: cache.getImage(at: idx),
                        forceRedrawTick: cache.cacheUpdatedTick
                    )
                    .applyFilterPreset(activeFilterPreset)
                )
            },
            isMangaRTL: readingMode == .mangaRTL,
            onChromeTap: onChromeTap,
            canFlipForward: { currentIndex < totalPages - 1 },
            canFlipBack:    { currentIndex > 0 },
            onFlipForward:  { currentIndex += 1 },
            onFlipBack:     { currentIndex -= 1 }
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

    @State private var spreadIdx: Int = 0

    private var totalSpreads: Int {
        max(1, Int(ceil(Double(cache.pageCount) / 2.0)))
    }

    private func leftPage(for sIdx: Int) -> Int { sIdx * 2 }

    private func isLandscapePage(_ absIdx: Int) -> Bool {
        guard let img = cache.getImage(at: absIdx) else { return false }
        return (img.size.width / max(1, img.size.height)) > 1.15
    }

    var body: some View {
        BookFlipGesture(
            currentIndex: $spreadIdx,
            content: { sIdx in
                AnyView(spreadView(leftPage: leftPage(for: sIdx)))
            },
            isMangaRTL: isMangaRTL,
            onChromeTap: onChromeTap,
            canFlipForward: { spreadIdx < totalSpreads - 1 },
            canFlipBack:    { spreadIdx > 0 },
            onFlipForward:  { spreadIdx += 1 },
            onFlipBack:     { spreadIdx -= 1 }
        )
        .onAppear { spreadIdx = currentIndex / 2 }
        .onChange(of: spreadIdx) { _, newVal in
            let page = leftPage(for: newVal)
            if currentIndex != page { currentIndex = page }
        }
        .onChange(of: currentIndex) { _, newVal in
            let target = newVal / 2
            if spreadIdx != target { spreadIdx = target }
        }
    }

    @ViewBuilder
    private func spreadView(leftPage leftIdx: Int) -> some View {
        GeometryReader { geo in
            if isLandscapePage(leftIdx) {
                // Native landscape — fills the full frame solo
                pageSlot(leftIdx)
                    .frame(width: geo.size.width, height: geo.size.height)
            } else if isMangaRTL {
                // Manga RTL: higher page number (right panel) on left of screen
                HStack(spacing: 0) {
                    if leftIdx + 1 < cache.pageCount {
                        pageSlot(leftIdx + 1)
                            .frame(width: geo.size.width / 2, height: geo.size.height)
                    } else {
                        Color.black
                            .frame(width: geo.size.width / 2, height: geo.size.height)
                    }
                    pageSlot(leftIdx)
                        .frame(width: geo.size.width / 2, height: geo.size.height)
                }
            } else {
                // Standard LTR two-page spread
                HStack(spacing: 0) {
                    pageSlot(leftIdx)
                        .frame(width: geo.size.width / 2, height: geo.size.height)
                    if leftIdx + 1 < cache.pageCount {
                        pageSlot(leftIdx + 1)
                            .frame(width: geo.size.width / 2, height: geo.size.height)
                    } else {
                        Color.black
                            .frame(width: geo.size.width / 2, height: geo.size.height)
                    }
                }
            }
        }
        .id("spread_\(leftIdx)")
        // Observe cache ticks WITHOUT rebuilding the full spread view:
        // opacity stays 1 always; this merely gives SwiftUI a value to watch
        // so that individual pageSlot views redraw in place.
        .animation(.easeIn(duration: 0.18), value: cache.cacheUpdatedTick)
    }

    @ViewBuilder
    private func pageSlot(_ index: Int) -> some View {
        // Use ZStack + opacity transition so the loaded image fades in over
        // the black placeholder — eliminates the hard white/black flash.
        ZStack {
            Color.black
            if let img = cache.getImage(at: index) {
                Image(uiImage: img)
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
        // cacheUpdatedTick is @Published on MainActor — safe to use as animation
        // trigger. Avoids calling cache.getImage() during SwiftUI's diffing phase
        // which can race with background prefetch mutations on NSCache.
        .animation(.easeIn(duration: 0.18), value: cache.cacheUpdatedTick)
    }
}
