import SwiftUI

// ============================================================
// MARK: - Book Page Turn Transition (Magazine-spread feel)
// ============================================================
/// A custom page-flip transition that mirrors how a physical book opens.
/// - Right side of screen taps → page turns forward (curl from right)
/// - Left side of screen taps → page turns back (curl from left)
struct BookFlipGesture: View {
    @Binding var currentIndex: Int // The logical index (could be absolute page or spread index)
    let content: (Int) -> AnyView
    let isMangaRTL: Bool
    var onChromeTap: () -> Void
    
    // Extracted navigation logic so parent can dynamically determine step size
    var canFlipForward: () -> Bool
    var canFlipBack: () -> Bool
    var onFlipForward: () -> Void
    var onFlipBack: () -> Void

    @State private var dragOffset: CGFloat = 0
    @State private var isAnimating = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Background page
                content(max(0, currentIndex - 1))
                    .frame(width: geo.size.width, height: geo.size.height)
                    .zIndex(0)

                // The turning page
                content(currentIndex)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .rotation3DEffect(
                        .degrees(isAnimating ? 0 : Double(dragOffset / geo.size.width) * -20),
                        axis: (x: 0, y: 1, z: 0),
                        anchor: dragOffset > 0 ? .leading : .trailing,
                        perspective: 0.4
                    )
                    .offset(x: dragOffset * 0.08) // subtle parallax
                    .zIndex(1)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { val in
                        if !isAnimating { dragOffset = val.translation.width }
                    }
                    .onEnded { val in
                        let threshold = geo.size.width * 0.25
                        let swipeRight = val.translation.width > threshold  // prev page
                        let swipeLeft  = val.translation.width < -threshold // next page

                        let goNext = isMangaRTL ? swipeRight : swipeLeft
                        let goPrev = isMangaRTL ? swipeLeft  : swipeRight

                        if goNext && canFlipForward() {
                            flipForward()
                        } else if goPrev && canFlipBack() {
                            flipBack()
                        } else {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { dragOffset = 0 }
                        }
                    }
            )
            .onTapGesture { location in
                let third = geo.size.width / 3
                if location.x < third {
                    // Left tap
                    if isMangaRTL { flipForward() } else { flipBack() }
                } else if location.x > geo.size.width - third {
                    // Right tap
                    if isMangaRTL { flipBack() } else { flipForward() }
                } else {
                    onChromeTap()
                }
            }
        }
    }

    private func flipForward() {
        guard !isAnimating, canFlipForward() else { return }
        HapticEngine.light()
        withAnimation(.interactiveSpring(response: 0.32, dampingFraction: 0.82)) {
            dragOffset = isMangaRTL ? 80 : -80
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            onFlipForward()
            dragOffset = isMangaRTL ? -30 : 30
            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) { dragOffset = 0 }
        }
    }

    private func flipBack() {
        guard !isAnimating, canFlipBack() else { return }
        HapticEngine.light()
        withAnimation(.interactiveSpring(response: 0.32, dampingFraction: 0.82)) {
            dragOffset = isMangaRTL ? -80 : 80
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            onFlipBack()
            dragOffset = isMangaRTL ? 30 : -30
            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) { dragOffset = 0 }
        }
    }
}

// ============================================================
// MARK: - Single-Page Book Pager (replaces TabView for non-webtoon)
// ============================================================
/// Replaces the raw TabView PageTabViewStyle so pages feel like turning
/// a book rather than scrolling a carousel.
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
            canFlipBack: { currentIndex > 0 },
            onFlipForward: { currentIndex += 1 },
            onFlipBack: { currentIndex -= 1 }
        )
    }
}

// ============================================================
// MARK: - Two-Up Spread Pager (Always-pairs book model)
// ============================================================
/// Shows two pages side-by-side that flip together as a physical book.
/// Internally tracks a SPREAD index (0, 1, 2 …) so BookFlipGesture's
/// background layer — content(spreadIdx-1) — always shows the correct
/// previous full spread, never an intermediate half-page.
///   spreadIdx 0  →  pages 0 + 1
///   spreadIdx 1  →  pages 2 + 3
///   spreadIdx 2  →  pages 4 + 5  …
/// Landscape source images (aspect > 1.15) fill the full frame alone.
struct TwoUpBookPager: View {
    @Binding var currentIndex: Int  // Absolute page index (exposed to scrubber/progress)
    let cache: ComicImageCache
    let activeFilterPreset: ReadingFilterPreset
    var onChromeTap: () -> Void

    // Internal spread cursor — BookFlipGesture steps this by ±1 per flip.
    // Because each unit = one complete spread, content(spreadIdx-1) is always
    // the previous full spread, never an intermediate page.
    @State private var spreadIdx: Int = 0

    // MARK: - Spread Geometry

    private var totalSpreads: Int {
        max(1, Int(ceil(Double(cache.pageCount) / 2.0)))
    }

    /// Left page absolute index for a given spread slot.
    private func leftPage(for sIdx: Int) -> Int {
        sIdx * 2
    }

    /// True when the page at `absIdx` is portrait-ratio (normal half-width slot).
    private func isPortrait(_ absIdx: Int) -> Bool {
        guard let img = cache.getImage(at: absIdx) else { return true }
        return (img.size.width / max(1, img.size.height)) <= 1.15
    }

    // MARK: - Body

    var body: some View {
        BookFlipGesture(
            // Pass SPREAD index so content(spreadIdx-1) = previous FULL spread
            currentIndex: $spreadIdx,
            content: { sIdx in
                let lp = leftPage(for: sIdx)
                return AnyView(spreadView(leftPage: lp))
            },
            isMangaRTL: false,
            onChromeTap: onChromeTap,
            canFlipForward: { spreadIdx < totalSpreads - 1 },
            canFlipBack:    { spreadIdx > 0 },
            onFlipForward:  { spreadIdx += 1 },
            onFlipBack:     { spreadIdx -= 1 }
        )
        // Sync on open / resume
        .onAppear { spreadIdx = currentIndex / 2 }
        // Push absolute index to scrubber when spread changes
        .onChange(of: spreadIdx) { _, newVal in
            let page = leftPage(for: newVal)
            if currentIndex != page { currentIndex = page }
        }
        // Pull from scrubber when user drags it
        .onChange(of: currentIndex) { _, newVal in
            let target = newVal / 2
            if spreadIdx != target { spreadIdx = target }
        }
    }

    // MARK: - Spread View

    @ViewBuilder
    private func spreadView(leftPage leftIdx: Int) -> some View {
        GeometryReader { geo in
            if !isPortrait(leftIdx) {
                // Native landscape page — fills the whole frame alone
                pageSlot(leftIdx)
                    .frame(width: geo.size.width, height: geo.size.height)
            } else {
                // Standard two-page portrait spread
                HStack(spacing: 0) {
                    pageSlot(leftIdx)
                        .frame(width: geo.size.width / 2, height: geo.size.height)

                    if leftIdx + 1 < cache.pageCount {
                        pageSlot(leftIdx + 1)
                            .frame(width: geo.size.width / 2, height: geo.size.height)
                    } else {
                        // Last page: black right filler so layout is stable
                        Color.black
                            .frame(width: geo.size.width / 2, height: geo.size.height)
                    }
                }
            }
        }
        // Re-render when cache delivers new images
        .id("spread_\(leftIdx)_\(cache.cacheUpdatedTick)")
    }

    // MARK: - Page Slot

    @ViewBuilder
    private func pageSlot(_ index: Int) -> some View {
        if let img = cache.getImage(at: index) {
            Image(uiImage: img)
                .resizable()
                .applyFilterPreset(activeFilterPreset)
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ZStack {
                Color.black
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white.opacity(0.5)))
            }
        }
    }
}
