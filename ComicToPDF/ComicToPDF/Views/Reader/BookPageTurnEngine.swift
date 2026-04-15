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
// MARK: - Dynamic Two-Up Spread Pager
// ============================================================
/// Shows two pages side-by-side that flip together as a physical spread.
/// Dynamically respects actual image dimensions so landscape pages 
/// consume the entire frame instead of being squeezed into 50% width.
struct TwoUpBookPager: View {
    @Binding var currentIndex: Int // The absolute index of the LEFT page of current spread
    let cache: ComicImageCache
    let activeFilterPreset: ReadingFilterPreset
    var onChromeTap: () -> Void

    // MARK: - Layout Logic
    /// Fast check if the page at index is narrow enough to safely be half a spread.
    /// If image isn't loaded yet, defaults to portrait to avoid layout shifting until load.
    private func isPortrait(_ index: Int) -> Bool {
        guard let img = cache.getImage(at: index) else { return true }
        // Aspect ratio (width / height)
        let aspect = img.size.width / max(1, img.size.height)
        return aspect <= 1.15 // Standard single pages are ~0.6-0.8. Genuine landscape spreads are >1.2
    }
    
    // MARK: - Step Calculations
    private func spreadStepForward(from index: Int) -> Int {
        return isPortrait(index) ? 2 : 1
    }
    
    private func spreadStepBackward(from index: Int) -> Int {
        guard index > 0 else { return 0 }
        // Inspect the page immediately preceding us
        let prevIndex = index - 1
        return isPortrait(prevIndex) ? 2 : 1
    }

    private func canFlipForward() -> Bool {
        return currentIndex + spreadStepForward(from: currentIndex) < cache.pageCount
    }

    private func canFlipBack() -> Bool {
        return currentIndex > 0
    }

    private func flipForward() {
        let step = spreadStepForward(from: currentIndex)
        currentIndex = min(currentIndex + step, cache.pageCount - 1)
    }

    private func flipBack() {
        let step = spreadStepBackward(from: currentIndex)
        currentIndex = max(0, currentIndex - step)
    }

    var body: some View {
        BookFlipGesture(
            currentIndex: $currentIndex,
            content: { idx in
                AnyView(spreadView(forLeftIndex: idx))
            },
            isMangaRTL: false,
            onChromeTap: onChromeTap,
            canFlipForward: canFlipForward,
            canFlipBack: canFlipBack,
            onFlipForward: flipForward,
            onFlipBack: flipBack
        )
    }

    @ViewBuilder
    private func spreadView(forLeftIndex leftIdx: Int) -> some View {
        GeometryReader { geo in
            if isPortrait(leftIdx) {
                // Double Page Spread
                HStack(spacing: 0) {
                    // Left Slot
                    pageSlot(leftIdx)
                        .frame(width: geo.size.width / 2)

                    // Right Slot
                    if leftIdx + 1 < cache.pageCount {
                        pageSlot(leftIdx + 1)
                            .frame(width: geo.size.width / 2)
                    } else {
                        Color.black.frame(width: geo.size.width / 2) // End padding
                    }
                }
            } else {
                // Wide Landscape Page (Full Bleed)
                pageSlot(leftIdx)
                    .frame(width: geo.size.width)
            }
        }
        .id("spread_\(leftIdx)_\(cache.cacheUpdatedTick)")
    }

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
