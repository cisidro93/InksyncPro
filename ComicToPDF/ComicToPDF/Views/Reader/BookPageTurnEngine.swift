import SwiftUI

// ============================================================
// MARK: - Book Page Turn Transition (Magazine-spread feel)
// ============================================================
/// A custom page-flip transition that mirrors how a physical book opens.
/// - Right side of screen taps → page turns forward (curl from right)
/// - Left side of screen taps → page turns back (curl from left)
struct BookFlipGesture: View {
    @Binding var currentIndex: Int
    let totalPages: Int
    let content: (Int) -> AnyView
    let isMangaRTL: Bool
    var onChromeTap: () -> Void

    @State private var dragOffset: CGFloat = 0
    @State private var isAnimating = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                content(max(0, currentIndex - 1))
                    .frame(width: geo.size.width, height: geo.size.height)

                content(currentIndex)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .rotation3DEffect(
                        .degrees(isAnimating ? 0 : Double(dragOffset / geo.size.width) * -20),
                        axis: (x: 0, y: 1, z: 0),
                        anchor: dragOffset > 0 ? .leading : .trailing,
                        perspective: 0.4
                    )
                    .offset(x: dragOffset * 0.08) // subtle parallax
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

                        if goNext && currentIndex < totalPages - 1 {
                            flipForward()
                        } else if goPrev && currentIndex > 0 {
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
        guard !isAnimating, currentIndex < totalPages - 1 else { return }
        HapticEngine.light()
        withAnimation(.interactiveSpring(response: 0.32, dampingFraction: 0.82)) {
            dragOffset = isMangaRTL ? 80 : -80
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            currentIndex += 1
            dragOffset = isMangaRTL ? -30 : 30
            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) { dragOffset = 0 }
        }
    }

    private func flipBack() {
        guard !isAnimating, currentIndex > 0 else { return }
        HapticEngine.light()
        withAnimation(.interactiveSpring(response: 0.32, dampingFraction: 0.82)) {
            dragOffset = isMangaRTL ? -80 : 80
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            currentIndex -= 1
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
            totalPages: totalPages,
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
            onChromeTap: onChromeTap
        )
    }
}

// ============================================================
// MARK: - Two-Up Spread Pager (Landscape / Dual Page)
// ============================================================
/// Shows two pages side-by-side that flip together as a spread.
/// Page 0 is shown alone (cover), then pairs: 1+2, 3+4, etc.
struct TwoUpBookPager: View {
    @Binding var currentIndex: Int
    let cache: ComicImageCache
    let activeFilterPreset: ReadingFilterPreset
    var onChromeTap: () -> Void

    // The "spread index" maps to the left-page index of a pair:
    // spread 0 → page 0 (cover alone)
    // spread 1 → pages 1+2
    // spread 2 → pages 3+4  etc.
    private var spreadCount: Int {
        if cache.pageCount <= 1 { return cache.pageCount }
        return 1 + Int(ceil(Double(cache.pageCount - 1) / 2.0))
    }

    private func leftPageIndex(for spreadIdx: Int) -> Int {
        spreadIdx == 0 ? 0 : (spreadIdx - 1) * 2 + 1
    }

    private func rightPageIndex(for spreadIdx: Int) -> Int? {
        let right = leftPageIndex(for: spreadIdx) + 1
        return right < cache.pageCount ? right : nil
    }

    // Translate absolute page index to spread index
    private var currentSpreadIndex: Int {
        if currentIndex == 0 { return 0 }
        return ((currentIndex - 1) / 2) + 1
    }

    @State private var displaySpread: Int = 0

    var body: some View {
        BookFlipGesture(
            currentIndex: $displaySpread,
            totalPages: spreadCount,
            content: { spreadIdx in
                AnyView(
                    spreadView(for: spreadIdx)
                )
            },
            isMangaRTL: false,
            onChromeTap: onChromeTap
        )
        .onAppear { displaySpread = currentSpreadIndex }
        .onChange(of: displaySpread) {
            // Map spread back to absolute page for the scrubber
            currentIndex = leftPageIndex(for: displaySpread)
        }
        .onChange(of: currentIndex) {
            // External scrubber moved; sync spread index
            let target = currentSpreadIndex
            if displaySpread != target { displaySpread = target }
        }
    }

    @ViewBuilder
    private func spreadView(for spreadIdx: Int) -> some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                // Left page (always present)
                pageSlot(leftPageIndex(for: spreadIdx))
                    .frame(width: rightPageIndex(for: spreadIdx) != nil ? geo.size.width / 2 : geo.size.width)

                // Right page (only for non-cover spreads)
                if let rightIdx = rightPageIndex(for: spreadIdx) {
                    pageSlot(rightIdx)
                        .frame(width: geo.size.width / 2)
                }
            }
            .id("spread_\(spreadIdx)_\(cache.cacheUpdatedTick)")
        }
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
                ProgressView().progressViewStyle(CircularProgressViewStyle(tint: .white.opacity(0.5)))
            }
        }
    }
}
