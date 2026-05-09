import SwiftUI

// ============================================================================
// PPLReaderView — Pro Spread Reader Engine
// ============================================================================
// Dual-page mode renders TWO pages side by side as a single spread unit.
// The buffer engine (PageBufferManager) preloads the previous and next spread
// pairs so every page turn is zero-latency.
//
// Spread parity rules (industry standard, matching Panels / Chunky / ComicFlow):
//  - Page 0 (cover) is always displayed solo.
//  - Any image whose width > 1.2× its height is a physical spread → solo.
//  - All other pages pair as (odd, even): 1+2, 3+4, 5+6 etc.
//  - Manga (RTL): right slot shows the current page, left slot shows the next.
//  - Page turn advances by 2 (or 1 if the next page is a spread or end of book).
//
// The `currentPageIndex` binding always tracks the LEAD (first-in-reading-order)
// index of the current spread. The scrubber, progress tracker, and bookmark
// engine all read from this binding so they remain accurate.
// ============================================================================

struct PPLReaderView: View {
    let pages: [URL]
    @Binding var currentPageIndex: Int
    var pdfID: UUID?
    var isMangaMode: Bool
    var isDoublePageOverride: Bool = false
    var onCenterTap: () -> Void

    @ObservedObject private var bufferManager = PageBufferManager.shared

    // High-frequency gesture state
    @State private var scale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var dragOffset: CGSize = .zero

    @AppStorage("isDoublePageMode") private var isDoublePageStored = false
    @AppStorage("autoSplitPortraitSpreads") private var autoSplitPortraitSpreads = true

    // Spread Splitting (portrait mode for wide spreads)
    @State private var splitHalf: Int = 0  // 0 = first reading half, 1 = second

    // Guided Reading
    @State private var isGuidedReadingActive: Bool = false
    @State private var guidedPanelIndex: Int = 0
    @State private var guidedPanels: [NormalizedRect] = []

    // Effective dual-page flag: respects stored toggle AND landscape override
    private var effectiveDoublePage: Bool { isDoublePageOverride || isDoublePageStored }

    // MARK: - Body

    var body: some View {
        GeometryReader { geo in
            let isLandscape = geo.size.width > geo.size.height
            let showingDual = effectiveDoublePage && isLandscape

            ZStack {
                Color.black.ignoresSafeArea()

                if bufferManager.isLoading && bufferManager.currentImage == nil {
                    ProgressView("Buffering…")
                        .scaleEffect(1.2)
                        .foregroundStyle(.white)
                } else {
                    if showingDual {
                        dualSpreadView(geo: geo)
                    } else {
                        singlePageView(geo: geo)
                    }
                }
            }
            .onAppear {
                setupBuffer(geo: geo, dual: effectiveDoublePage && geo.size.width > geo.size.height)
            }
            .onChange(of: currentPageIndex) { _, newIndex in
                let isDual = effectiveDoublePage && geo.size.width > geo.size.height
                if isDual {
                    let lead = PageBufferManager.canonicalLeadIndex(for: newIndex, isMangaMode: isMangaMode)
                    bufferManager.renderDual(leadIndex: lead, pages: pages, isMangaMode: isMangaMode)
                } else {
                    bufferManager.render(pageIndex: newIndex, bounds: geo.size)
                }
            }
            .onChange(of: geo.size) { _, newSize in
                guard newSize.width > 0, newSize.height > 0 else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    scale = 1.0; offset = .zero; dragOffset = .zero
                }
                bufferManager.isPPLEnabled = false
                bufferManager.updateViewport(rect: .full)
                let isDual = effectiveDoublePage && newSize.width > newSize.height
                if isDual {
                    let lead = PageBufferManager.canonicalLeadIndex(for: currentPageIndex, isMangaMode: isMangaMode)
                    bufferManager.renderDual(leadIndex: lead, pages: pages, isMangaMode: isMangaMode)
                } else {
                    bufferManager.render(pageIndex: currentPageIndex, bounds: newSize)
                }
            }
            .onChange(of: isDoublePageStored) { _, _ in
                setupBuffer(geo: geo, dual: effectiveDoublePage && geo.size.width > geo.size.height)
            }
        }
    }

    // MARK: - Dual Spread View

    @ViewBuilder
    private func dualSpreadView(geo: GeometryProxy) -> some View {
        let spread = bufferManager.currentSpread
        let leftImg  = spread?.leftImage
        let rightImg = spread?.rightImage

        // Determine if either slot is a physical spread (wide image) → force solo
        let leftIsSpread  = leftImg.map  { isWideSpread($0) } ?? false
        let rightIsSpread = rightImg.map { isWideSpread($0) } ?? false

        // If this page is itself a wide spread OR it's page 0 (cover), render solo
        let leadIndex = spread?.leadIndex ?? currentPageIndex
        let isCover   = leadIndex == 0
        let forceSolo = isCover || leftIsSpread || rightIsSpread

        Group {
            if forceSolo {
                // Solo mode even in dual-page mode for cover / wide spreads
                singlePageCanvas(image: leftImg ?? rightImg, geo: geo)
            } else {
                HStack(spacing: 0) {
                    // Left slot (blank if nil)
                    if let left = leftImg {
                        MetalCanvasView(image: left, lockedRect: .full, isPPLEnabled: false)
                    } else {
                        Color.black // gutter for first/last page
                    }

                    // Right slot (blank if nil)
                    if let right = rightImg {
                        MetalCanvasView(image: right, lockedRect: .full, isPPLEnabled: false)
                    } else {
                        Color.black
                    }
                }
                .scaleEffect(scale)
                .offset(x: offset.width + dragOffset.width, y: offset.height + dragOffset.height)
            }
        }
        .gesture(zoomGesture(geo: geo))
        .simultaneousGesture(panAndSwipeGesture(geo: geo))
        .onTapGesture(count: 2) { loc in handleDoubleTap(at: loc, geo: geo) }
        .onTapGesture { loc in handleSingleTap(at: loc, geo: geo) }
    }

    // MARK: - Single Page View

    @ViewBuilder
    private func singlePageView(geo: GeometryProxy) -> some View {
        let imgWidth  = CGFloat(bufferManager.currentImage?.width  ?? 0)
        let imgHeight = CGFloat(bufferManager.currentImage?.height ?? 1)
        let isSpread  = imgWidth > imgHeight * 1.2
        let isPortrait = geo.size.height > geo.size.width

        Group {
            if isPortrait && isSpread && autoSplitPortraitSpreads, let img = bufferManager.currentImage {
                // Portrait spread-split mode
                let rightHalf = NormalizedRect(x: 500, y: 0, width: 500, height: 1000)
                let leftHalf  = NormalizedRect(x: 0,   y: 0, width: 500, height: 1000)
                let rect: NormalizedRect = isMangaMode
                    ? (splitHalf == 0 ? rightHalf : leftHalf)
                    : (splitHalf == 0 ? leftHalf  : rightHalf)
                MetalCanvasView(image: img, lockedRect: rect, isPPLEnabled: true)
            } else {
                MetalCanvasView(
                    image: bufferManager.currentImage,
                    lockedRect: bufferManager.lockedRect,
                    isPPLEnabled: bufferManager.isPPLEnabled
                )
            }
        }
        .scaleEffect(scale)
        .offset(x: offset.width + dragOffset.width, y: offset.height + dragOffset.height)
        .gesture(zoomGesture(geo: geo))
        .simultaneousGesture(panAndSwipeGesture(geo: geo))
        .onTapGesture(count: 2) { loc in handleDoubleTap(at: loc, geo: geo) }
        .onTapGesture { loc in handleSingleTap(at: loc, geo: geo) }
    }

    // MARK: - Solo Canvas (for covers/spreads in dual mode)

    @ViewBuilder
    private func singlePageCanvas(image: CGImage?, geo: GeometryProxy) -> some View {
        MetalCanvasView(
            image: image,
            lockedRect: bufferManager.lockedRect,
            isPPLEnabled: bufferManager.isPPLEnabled
        )
        .scaleEffect(scale)
        .offset(x: offset.width + dragOffset.width, y: offset.height + dragOffset.height)
    }

    // MARK: - Gestures

    private func zoomGesture(geo: GeometryProxy) -> some Gesture {
        MagnificationGesture()
            .onChanged { val in
                scale = min(max(val, 1.0), 5.0)
            }
            .onEnded { _ in
                updatePPL(in: geo.size)
            }
    }

    private func panAndSwipeGesture(geo: GeometryProxy) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { val in
                if scale > 1.0 {
                    dragOffset = val.translation
                }
            }
            .onEnded { val in
                if scale > 1.0 {
                    offset.width  += val.translation.width
                    offset.height += val.translation.height
                    dragOffset = .zero
                    updatePPL(in: geo.size)
                } else {
                    // Swipe page turn — uses the full horizontal velocity for zero-latency feel
                    let dx = val.translation.width
                    let dy = val.translation.height
                    // Only fire on predominantly horizontal swipes
                    guard abs(dx) > abs(dy), abs(dx) > 50 else { return }
                    if dx < 0 {
                        isMangaMode ? prevPage(geo: geo.size) : nextPage(geo: geo.size)
                    } else {
                        isMangaMode ? nextPage(geo: geo.size) : prevPage(geo: geo.size)
                    }
                }
            }
    }

    private func handleDoubleTap(at location: CGPoint, geo: GeometryProxy) {
        guard scale == 1.0 else {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                scale = 1.0; offset = .zero
                updatePPL(in: geo.size)
            }
            return
        }

        if isGuidedReadingActive {
            isGuidedReadingActive = false
            updatePPL(in: geo.size)
            return
        }

        refreshGuidedPanels()
        if !guidedPanels.isEmpty {
            isGuidedReadingActive = true
            guidedPanelIndex = 0
            withAnimation(.easeInOut(duration: 0.25)) {
                bufferManager.lockedRect  = guidedPanels[0]
                bufferManager.isPPLEnabled = true
            }
            Haptics.shared.playImpact(style: .medium)
            return
        }

        // Smart zoom toward tap point
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            scale = 2.0
            let tapX = location.x - (geo.size.width  / 2)
            let tapY = location.y - (geo.size.height / 2)
            offset = CGSize(width: -tapX * scale, height: -tapY * scale)
            updatePPL(in: geo.size)
        }
    }

    private func handleSingleTap(at location: CGPoint, geo: GeometryProxy) {
        guard scale <= 1.0 || isGuidedReadingActive else { return }
        let w = geo.size.width

        if isGuidedReadingActive {
            if location.x < w * 0.3 {
                isMangaMode ? nextGuidedPanel(geo: geo.size) : prevGuidedPanel(geo: geo.size)
            } else if location.x > w * 0.7 {
                isMangaMode ? prevGuidedPanel(geo: geo.size) : nextGuidedPanel(geo: geo.size)
            } else {
                onCenterTap()
            }
        } else {
            if location.x < w * 0.3 {
                isMangaMode ? nextPage(geo: geo.size) : prevPage(geo: geo.size)
            } else if location.x > w * 0.7 {
                isMangaMode ? prevPage(geo: geo.size) : nextPage(geo: geo.size)
            } else {
                onCenterTap()
            }
        }
    }

    // MARK: - Navigation

    private func nextPage(geo: CGSize) {
        let isLandscape = geo.width > geo.height
        let showingDual = effectiveDoublePage && isLandscape

        if !showingDual {
            // Single page mode — portrait spread split handling
            let imgW = CGFloat(bufferManager.currentImage?.width  ?? 0)
            let imgH = CGFloat(bufferManager.currentImage?.height ?? 1)
            let isSpread = imgW > imgH * 1.2
            let isPortrait = geo.height > geo.width
            if isPortrait && isSpread && autoSplitPortraitSpreads {
                if splitHalf == 0 { splitHalf = 1; return }
                else { splitHalf = 0 }
            }
            advanceSinglePage(forward: true)
            return
        }

        // Dual page mode: advance by the correct hop
        let spread = bufferManager.currentSpread
        let leadIndex = spread?.leadIndex ?? currentPageIndex
        let isCover   = leadIndex == 0
        let leftIsSpread  = (spread?.leftImage).map  { isWideSpread($0) } ?? false
        let rightIsSpread = (spread?.rightImage).map { isWideSpread($0) } ?? false

        let hopCount: Int
        if isCover || leftIsSpread || rightIsSpread {
            hopCount = 1
        } else {
            // Standard dual: advance by 2, but clamp so we don't skip the last page
            let nextLead = leadIndex + 2
            hopCount = nextLead < pages.count ? 2 : 1
        }

        let nextIndex = leadIndex + hopCount
        if nextIndex < pages.count {
            Haptics.shared.playImpact(style: .light)
            currentPageIndex = nextIndex
        } else if leadIndex < pages.count - 1 {
            Haptics.shared.playImpact(style: .light)
            currentPageIndex = pages.count - 1
        } else {
            NotificationCenter.default.post(name: NSNotification.Name("Reader_EndOfBookReached"), object: nil)
        }
    }

    private func prevPage(geo: CGSize) {
        let isLandscape = geo.width > geo.height
        let showingDual = effectiveDoublePage && isLandscape

        if !showingDual {
            let imgW = CGFloat(bufferManager.currentImage?.width  ?? 0)
            let imgH = CGFloat(bufferManager.currentImage?.height ?? 1)
            let isSpread = imgW > imgH * 1.2
            let isPortrait = geo.height > geo.width
            if isPortrait && isSpread && autoSplitPortraitSpreads {
                if splitHalf == 1 { splitHalf = 0; return }
                else { splitHalf = 1 }
            }
            advanceSinglePage(forward: false)
            return
        }

        let spread = bufferManager.currentSpread
        let leadIndex = spread?.leadIndex ?? currentPageIndex
        guard leadIndex > 0 else { return }

        // What was the lead of the previous spread?
        let prevLead = max(0, leadIndex - 2)
        // Check if the previous spread would be a wide spread
        let prevLeftIdx = isMangaMode ? prevLead + 1 : prevLead
        let prevLeftURL = prevLeftIdx < pages.count ? pages[prevLeftIdx] : nil
        // We check prevImage from buffer for instant response
        let prevIsSpread = (bufferManager.prevImage).map { isWideSpread($0) } ?? false
        let hopCount = prevIsSpread ? 1 : (prevLead == 0 ? leadIndex : 2)

        Haptics.shared.playImpact(style: .light)
        currentPageIndex = max(0, leadIndex - hopCount)
        _ = prevLeftURL // suppress unused warning
    }

    private func advanceSinglePage(forward: Bool) {
        if forward {
            if currentPageIndex < pages.count - 1 {
                Haptics.shared.playImpact(style: .light)
                currentPageIndex += 1
            } else {
                NotificationCenter.default.post(name: NSNotification.Name("Reader_EndOfBookReached"), object: nil)
            }
        } else {
            if currentPageIndex > 0 {
                Haptics.shared.playImpact(style: .light)
                currentPageIndex -= 1
            }
        }
    }

    // MARK: - Buffer Setup

    private func setupBuffer(geo: GeometryProxy, dual: Bool) {
        if dual {
            let lead = PageBufferManager.canonicalLeadIndex(for: currentPageIndex, isMangaMode: isMangaMode)
            bufferManager.renderDual(leadIndex: lead, pages: pages, isMangaMode: isMangaMode)
        } else {
            bufferManager.setup(pages: pages)
            bufferManager.render(pageIndex: currentPageIndex, bounds: geo.size)
        }
    }

    // MARK: - PPL Math

    private func updatePPL(in size: CGSize) {
        if scale <= 1.0 {
            bufferManager.isPPLEnabled = false
            bufferManager.updateViewport(rect: .full)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { offset = .zero }
            return
        }

        bufferManager.isPPLEnabled = true
        let visibleW = size.width  / scale
        let visibleH = size.height / scale
        let x = ((size.width  - visibleW) / 2.0) - (offset.width  / scale)
        let y = ((size.height - visibleH) / 2.0) - (offset.height / scale)
        let rawRect = CGRect(x: x, y: y, width: visibleW, height: visibleH)
        bufferManager.updateViewport(rect: CoordinateConverter.normalize(rect: rawRect, in: size))
    }

    // MARK: - Spread Detection

    private func isWideSpread(_ img: CGImage) -> Bool {
        CGFloat(img.width) > CGFloat(img.height) * 1.2
    }

    // MARK: - Guided Reading Engine

    private func refreshGuidedPanels() {
        guard let pdfID = pdfID else { return }
        let model = PageModelStore.shared.getPageModel(for: pdfID, pageIndex: currentPageIndex)
        guidedPanels = model.panels.sorted { a, b in
            if abs(a.origin.y - b.origin.y) > 50 { return a.origin.y < b.origin.y }
            return isMangaMode ? (a.origin.x > b.origin.x) : (a.origin.x < b.origin.x)
        }
    }

    private func nextGuidedPanel(geo: CGSize) {
        if guidedPanelIndex + 1 < guidedPanels.count {
            guidedPanelIndex += 1
            withAnimation(.easeInOut(duration: 0.25)) {
                bufferManager.lockedRect = guidedPanels[guidedPanelIndex]
            }
        } else {
            nextPage(geo: geo)
            if isGuidedReadingActive {
                refreshGuidedPanels()
                guidedPanelIndex = 0
                if guidedPanels.isEmpty {
                    isGuidedReadingActive = false
                    updatePPL(in: geo)
                } else {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        bufferManager.lockedRect = guidedPanels[0]
                    }
                }
            }
        }
    }

    private func prevGuidedPanel(geo: CGSize) {
        if guidedPanelIndex > 0 {
            guidedPanelIndex -= 1
            withAnimation(.easeInOut(duration: 0.25)) {
                bufferManager.lockedRect = guidedPanels[guidedPanelIndex]
            }
        } else {
            prevPage(geo: geo)
            if isGuidedReadingActive {
                refreshGuidedPanels()
                if guidedPanels.isEmpty {
                    isGuidedReadingActive = false
                    updatePPL(in: geo)
                } else {
                    guidedPanelIndex = guidedPanels.count - 1
                    withAnimation(.easeInOut(duration: 0.25)) {
                        bufferManager.lockedRect = guidedPanels[guidedPanelIndex]
                    }
                }
            }
        }
    }
}
