import SwiftUI

// ============================================================================
// PPLReaderView — Pro Spread Reader Engine v2
// ============================================================================
// New in this version:
//   1. Live swipe page-peel preview (slide & flip3D styles)
//   2. Spread seam divider between left/right pages
//   3. Tap zone customization via TapZoneStyle
//   4. Zoom pan momentum (CADisplayLink-driven velocity decay)
//   5. Long-press context menu (Bookmark / Share)
//   6. Real decode-progress bar replaces spinner
// ============================================================================

struct PPLReaderView: View {
    let pages: [URL]
    @Binding var currentPageIndex: Int
    var pdfID: UUID?
    var isMangaMode: Bool
    var isDrawingMode: Bool = false // ✅ Added for GoodNotes Parity
    var startWithGuidedReading: Bool = false
    var onCenterTap: () -> Void

    @ObservedObject private var bufferManager = PageBufferManager.shared

    // ── Zoom / pan state ──────────────────────────────────────────────────────
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var dragOffset: CGSize = .zero
    @State private var momentumTask: Task<Void, Never>?

    // ── Live swipe peel state ─────────────────────────────────────────────────
    @State private var swipeDragX: CGFloat = 0
    @State private var isCommittingSwipe = false

    // ── Settings ──────────────────────────────────────────────────────────────
    @AppStorage("isDoublePageMode")       private var isDoublePageStored  = false
    @AppStorage("autoSplitPortraitSpreads") private var autoSplitPortraitSpreads = true
    @AppStorage("tapZoneStyle")           private var tapZoneStyleRaw     = TapZoneStyle.classic.rawValue
    @AppStorage("pageTurnStyle")          private var pageTurnStyleRaw    = PageTurnStyle.slide.rawValue
    @AppStorage("showSpreadSeam")         private var showSpreadSeam      = true
    @AppStorage("isAutoCropEnabled")      private var isAutoCropEnabled   = false
    @AppStorage("isZoomLockEnabled")      private var isZoomLockEnabled   = false

    private var tapZoneStyle:  TapZoneStyle  { TapZoneStyle(rawValue: tapZoneStyleRaw)   ?? .classic }
    private var pageTurnStyle: PageTurnStyle { PageTurnStyle(rawValue: pageTurnStyleRaw) ?? .slide   }

    // ── Spread splitting ──────────────────────────────────────────────────────
    @State private var splitHalf: Int = 0

    // ── Guided reading ────────────────────────────────────────────────────────
    @State private var isGuidedReadingActive = false
    @State private var guidedPanelIndex = 0
    @State private var guidedPanels: [NormalizedRect] = []
    @State private var hasInitializedGuidedReading = false

    // effectiveDoublePage: orientation-intelligence implementation.
    // Single source of truth is autoLandscapeDualPage — the reader automatically
    // uses dual-page in landscape and single-page in portrait.
    // isDoublePageStored (the old manual toggle) is intentionally excluded:
    // it caused a double-trigger race condition and also broke the intelligent
    // orientation-based behavior the user expects.
    private var effectiveDoublePage: Bool { autoLandscapeDualPage }


    // MARK: - Body

    var body: some View {
        GeometryReader { geo in
            let isLandscape  = geo.size.width > geo.size.height
            let showingDual  = effectiveDoublePage && isLandscape

            ZStack {
                Color.black.ignoresSafeArea()

                // Show loading indicator whenever there's no image to display.
                // CRITICAL: checking isLoading alone is NOT enough — setupDirectArchive
                // clears currentImage synchronously before the async ZIP scan sets isLoading.
                // During dual→single mode switches this gap causes singlePageView to render
                // with currentImage=nil → MetalCanvasView GPU texture crash.
                // Guard on currentImage == nil directly so the loading indicator covers
                // the full async gap regardless of isLoading state.
                if bufferManager.currentImage == nil {
                    loadingIndicator
                } else {
                    pageContent(geo: geo, showingDual: showingDual)
                        .contextMenu { contextMenuItems() }
                }
            }
            .onAppear       { setupBuffer(geo: geo, dual: showingDual) }
            .onChange(of: currentPageIndex) { _, newIndex in
                if !isZoomLockEnabled {
                    withAnimation(.easeOut(duration: 0.15)) {
                        scale = 1.0
                        lastScale = 1.0
                        offset = .zero
                        dragOffset = .zero
                    }
                    bufferManager.isPPLEnabled = false
                    bufferManager.updateViewport(rect: .full)
                } else if scale > 1.0 {
                    updatePPL(in: geo.size)
                }
                advanceBuffer(to: newIndex, geo: geo, dual: showingDual)
            }
            // onChange(of: geo.size) fires many times during the rotation animation with
            // intermediate sizes. We debounce by ignoring any size where either dimension
            // is zero, and we only commit a full buffer reset once the final stable size
            // has settled (detected by the guard in resetOnResize).
            .onChange(of: geo.size)         { _, size   in
                // Ignore intermediate near-zero sizes emitted during rotation animation
                guard size.width > 0, size.height > 0 else { return }
                resetOnResize(to: size, dual: effectiveDoublePage && size.width > size.height)
            }
            // When the user toggles "Auto Dual Page in Landscape" in settings,
            // reload the buffer immediately with the correct mode.
            .onChange(of: autoLandscapeDualPage) { _, _ in
                setupBuffer(geo: geo, dual: effectiveDoublePage && geo.size.width > geo.size.height)
            }
            .onChange(of: isAutoCropEnabled) { _, _ in setupBuffer(geo: geo, dual: showingDual) }
        }
    }

    // MARK: - Page Content with Live Peel

    @ViewBuilder
    private func pageContent(geo: GeometryProxy, showingDual: Bool) -> some View {
        let w = geo.size.width

        ZStack(alignment: .center) {
            // ── Back layer: adjacent spread peeking ──────────────────────────
            if pageTurnStyle != .instant {
                if swipeDragX > 8 {
                    adjacentSpread(isNext: false, showingDual: showingDual, geo: geo)
                        .offset(x: swipeDragX - w)
                        .allowsHitTesting(false)
                }
                if swipeDragX < -8 {
                    adjacentSpread(isNext: true, showingDual: showingDual, geo: geo)
                        .offset(x: swipeDragX + w)
                        .allowsHitTesting(false)
                }
            }

            // ── Front layer: current spread, sliding with finger ──────────────
            ZStack {
                currentContent(geo: geo, showingDual: showingDual)
                
                // ✅ Phase 4: In-Line Handwriting
                PageCanvasOverlay(pdfID: pdfID, pageIndex: currentPageIndex, isMarkupEnabled: isDrawingMode)
            }
            .offset(x: scale > 1.0 ? 0 : swipeDragX,
                    y: 0)
            .rotation3DEffect(
                flip3DAngle(geo: geo),
                axis: (x: 0, y: 1, z: 0),
                anchor: swipeDragX > 0 ? .leading : .trailing,
                perspective: 0.4
            )
            .scaleEffect(scale)
            .offset(x: offset.width + dragOffset.width,
                    y: offset.height + dragOffset.height)
        }
        // If drawing mode is on, we let PKCanvasView handle gestures and disable reader zoom/pan
        .gesture(isDrawingMode ? nil : zoomGesture(geo: geo))
        .simultaneousGesture(isDrawingMode ? nil : swipeAndPanGesture(geo: geo))
        .onTapGesture(count: 2) { loc in handleDoubleTap(at: loc, geo: geo) }
        .onTapGesture              { loc in handleSingleTap(at: loc, geo: geo) }
        .overlay(alignment: .bottom) {
            // Guided Reading panel progress indicator
            if isGuidedReadingActive && !guidedPanels.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "viewfinder")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.orange)
                    Text("Panel \(guidedPanelIndex + 1) / \(guidedPanels.count)")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("· Double-tap to exit")
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
                .padding(.bottom, 100)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: guidedPanelIndex)
            }
        }
    }

    // MARK: - Current Content

    @ViewBuilder
    private func currentContent(geo: GeometryProxy, showingDual: Bool) -> some View {
        if showingDual {
            dualSpreadView(geo: geo, spread: bufferManager.currentSpread)
        } else {
            singlePageView(geo: geo)
        }
    }

    // MARK: - Dual Spread View

    @ViewBuilder
    private func dualSpreadView(geo: GeometryProxy, spread: SpreadPair?) -> some View {
        let leftImg   = spread?.leftImage
        let rightImg  = spread?.rightImage
        let isCover   = (spread?.leadIndex ?? currentPageIndex) == 0
        let leftWide  = leftImg.map  { isWideSpread($0) } ?? false
        let rightWide = rightImg.map { isWideSpread($0) } ?? false
        let forceSolo = isCover || leftWide || rightWide

        if forceSolo {
            MetalCanvasView(image: leftImg ?? rightImg,
                            lockedRect: bufferManager.lockedRect,
                            isPPLEnabled: bufferManager.isPPLEnabled)
        } else {
            HStack(spacing: 0) {
                if let left = leftImg {
                    MetalCanvasView(image: left, lockedRect: .full, isPPLEnabled: false)
                } else {
                    Color.black
                }

                // ── Seam divider ─────────────────────────────────────────────
                if showSpreadSeam {
                    Rectangle()
                        .fill(Color(white: 0.08))
                        .frame(width: 1)
                }

                if let right = rightImg {
                    MetalCanvasView(image: right, lockedRect: .full, isPPLEnabled: false)
                } else {
                    Color.black
                }
            }
        }
    }

    // MARK: - Single Page View

    @ViewBuilder
    private func singlePageView(geo: GeometryProxy) -> some View {
        let imgW = CGFloat(bufferManager.currentImage?.width  ?? 0)
        let imgH = CGFloat(bufferManager.currentImage?.height ?? 1)
        let isSpread  = imgW > imgH * 1.2
        let isPortrait = geo.size.height > geo.size.width

        if isPortrait && isSpread && autoSplitPortraitSpreads, let img = bufferManager.currentImage {
            let rightHalf = NormalizedRect(x: 500, y: 0, width: 500, height: 1000)
            let leftHalf  = NormalizedRect(x: 0,   y: 0, width: 500, height: 1000)
            let rect = isMangaMode
                ? (splitHalf == 0 ? rightHalf : leftHalf)
                : (splitHalf == 0 ? leftHalf  : rightHalf)
            MetalCanvasView(image: img, lockedRect: rect, isPPLEnabled: true)
        } else {
            MetalCanvasView(image: bufferManager.currentImage,
                            lockedRect: bufferManager.lockedRect,
                            isPPLEnabled: bufferManager.isPPLEnabled)
        }
    }

    // MARK: - Adjacent Spread (peel preview layer)

    @ViewBuilder
    private func adjacentSpread(isNext: Bool, showingDual: Bool, geo: GeometryProxy) -> some View {
        if showingDual {
            let spread = isNext ? bufferManager.nextSpread : bufferManager.prevSpread
            dualSpreadView(geo: geo, spread: spread)
        } else {
            let img = isNext ? bufferManager.nextImage : bufferManager.prevImage
            MetalCanvasView(image: img, lockedRect: .full, isPPLEnabled: false)
        }
    }

    // MARK: - Loading Indicator (real progress)

    private var loadingIndicator: some View {
        VStack(spacing: 14) {
            ProgressView(value: bufferManager.decodeProgress)
                .progressViewStyle(.linear)
                .tint(.orange)
                .frame(width: 180)
                .animation(.easeInOut(duration: 0.2), value: bufferManager.decodeProgress)

            Text("Loading pages…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Gestures

    private func zoomGesture(geo: GeometryProxy) -> some Gesture {
        MagnificationGesture()
            .onChanged { val in
                let targetScale = lastScale * val
                scale = min(max(targetScale, 1.0), 5.0)
            }
            .onEnded { _ in
                lastScale = scale
                updatePPL(in: geo.size)
            }
    }

    private func swipeAndPanGesture(geo: GeometryProxy) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { val in
                momentumTask?.cancel()
                if scale > 1.0 {
                    dragOffset = val.translation
                } else {
                    let dx = val.translation.width
                    let dy = val.translation.height
                    guard abs(dx) > abs(dy) else { return }
                    // Rubber-band resistance at boundaries
                    let atStart = currentPageIndex == 0 && dx > 0
                    let atEnd   = currentPageIndex >= pages.count - 1 && dx < 0
                    let resist: CGFloat = (atStart || atEnd) ? 0.3 : 0.9
                    swipeDragX = dx * resist
                }
            }
            .onEnded { val in
                if scale > 1.0 {
                    commitPan(val: val, geo: geo)
                } else {
                    commitSwipe(val: val, geo: geo)
                }
            }
    }

    // MARK: - Swipe Commit / Snap

    private func commitSwipe(val: DragGesture.Value, geo: GeometryProxy) {
        let dx       = val.translation.width
        let velocity = val.velocity.width          // iOS 17+
        let w        = geo.size.width
        let threshold = w * 0.35
        let velThresh: CGFloat = 400

        let isLandscape = geo.size.width > geo.size.height
        let showingDual = effectiveDoublePage && isLandscape

        let goForward = dx < -threshold || velocity < -velThresh
        let goBack    = dx >  threshold || velocity >  velThresh

        let (triggerNext, triggerPrev) = isMangaMode
            ? (goBack, goForward)
            : (goForward, goBack)

        isCommittingSwipe = true

        if triggerNext && currentPageIndex < pages.count - 1 {
            let targetX: CGFloat = pageTurnStyle == .flip3D ? 0 : -w
            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                swipeDragX = targetX
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: pageTurnStyle == .flip3D ? 200_000_000 : 160_000_000)
                nextPage(geo: geo.size, showingDual: showingDual)
                swipeDragX = pageTurnStyle == .flip3D ? 0 : w * 0.15
                withAnimation(.spring(response: 0.22, dampingFraction: 0.9)) { swipeDragX = 0 }
                isCommittingSwipe = false
            }
        } else if triggerPrev && currentPageIndex > 0 {
            let targetX: CGFloat = pageTurnStyle == .flip3D ? 0 : w
            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                swipeDragX = targetX
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 160_000_000)
                prevPage(geo: geo.size, showingDual: showingDual)
                swipeDragX = -w * 0.15
                withAnimation(.spring(response: 0.22, dampingFraction: 0.9)) { swipeDragX = 0 }
                isCommittingSwipe = false
            }
        } else {
            // Snap back
            let atStart = triggerPrev && currentPageIndex == 0
            let atEnd = triggerNext && currentPageIndex == pages.count - 1
            if atStart || atEnd {
                Haptics.shared.playImpact(style: .rigid)
            }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { swipeDragX = 0 }
            isCommittingSwipe = false
        }
    }

    // MARK: - Pan Commit + Momentum

    private func commitPan(val: DragGesture.Value, geo: GeometryProxy) {
        offset.width  += val.translation.width
        offset.height += val.translation.height
        dragOffset = .zero
        updatePPL(in: geo.size)

        let vel = val.velocity
        guard abs(vel.width) > 30 || abs(vel.height) > 30 else { return }

        momentumTask = Task { @MainActor in
            var vx = vel.width  * 0.012
            var vy = vel.height * 0.012
            repeat {
                try? await Task.sleep(nanoseconds: 16_000_000) // ~60 fps
                guard !Task.isCancelled else { return }
                vx *= 0.90; vy *= 0.90
                offset.width  = max(-geo.size.width  * (scale - 1), min(geo.size.width  * (scale - 1), offset.width  + vx))
                offset.height = max(-geo.size.height * (scale - 1), min(geo.size.height * (scale - 1), offset.height + vy))
                updatePPL(in: geo.size)
            } while abs(vx) > 0.5 || abs(vy) > 0.5
        }
    }

    // MARK: - 3D Flip Angle

    private func flip3DAngle(geo: GeometryProxy) -> Angle {
        guard pageTurnStyle == .flip3D, scale <= 1.0 else { return .zero }
        let fraction = swipeDragX / max(geo.size.width, 1)
        return .degrees(Double(fraction) * -25)
    }

    // MARK: - Tap Handling

    private func handleDoubleTap(at location: CGPoint, geo: GeometryProxy) {
        if scale > 1.0 {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                scale = 1.0
                lastScale = 1.0
                offset = .zero
                updatePPL(in: geo.size)
            }
            return
        }
        if isGuidedReadingActive {
            isGuidedReadingActive = false; updatePPL(in: geo.size); return
        }
        refreshGuidedPanels()
        if !guidedPanels.isEmpty {
            isGuidedReadingActive = true; guidedPanelIndex = 0
            withAnimation(.easeInOut(duration: 0.25)) {
                bufferManager.lockedRect   = guidedPanels[0]
                bufferManager.isPPLEnabled = true
            }
            Haptics.shared.playImpact(style: .medium); return
        }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            scale = 2.0
            lastScale = 2.0
            offset = CGSize(width:  -(location.x - geo.size.width  / 2) * scale,
                            height: -(location.y - geo.size.height / 2) * scale)
            updatePPL(in: geo.size)
        }
    }

    private func handleSingleTap(at location: CGPoint, geo: GeometryProxy) {
        guard scale <= 1.0 || isZoomLockEnabled || isGuidedReadingActive else { return }
        let w = geo.size.width
        let isLandscape = geo.size.width > geo.size.height
        let showingDual = effectiveDoublePage && isLandscape
        let zones = tapZoneStyle.zones

        if isGuidedReadingActive {
            if location.x < w * zones.leftEdge {
                if isMangaMode { nextGuidedPanel(geo: geo.size) } else { prevGuidedPanel(geo: geo.size) }
            } else if location.x > w * zones.rightEdge {
                if isMangaMode { prevGuidedPanel(geo: geo.size) } else { nextGuidedPanel(geo: geo.size) }
            } else {
                onCenterTap()
            }
        } else {
            if location.x < w * zones.leftEdge {
                if isMangaMode { nextPage(geo: geo.size, showingDual: showingDual) } else { prevPage(geo: geo.size, showingDual: showingDual) }
            } else if location.x > w * zones.rightEdge {
                if isMangaMode { prevPage(geo: geo.size, showingDual: showingDual) } else { nextPage(geo: geo.size, showingDual: showingDual) }
            } else {
                onCenterTap()
            }
        }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func contextMenuItems() -> some View {
        Button {
            // Bookmark — fire notification; ReaderView owns the bookmark store
            NotificationCenter.default.post(
                name: NSNotification.Name("Reader_BookmarkCurrentPage"),
                object: nil,
                userInfo: ["pageIndex": currentPageIndex]
            )
        } label: { Label("Bookmark This Page", systemImage: "bookmark") }

        Button {
            NotificationCenter.default.post(
                name: NSNotification.Name("Reader_ShareCurrentPage"),
                object: nil,
                userInfo: ["pageIndex": currentPageIndex]
            )
        } label: { Label("Share This Page", systemImage: "square.and.arrow.up") }
    }

    // MARK: - Navigation

    private func nextPage(geo: CGSize, showingDual: Bool) {
        let isSpread     = bufferManager.currentImage.map { isWideSpread($0) } ?? false
        let nextIsSpread = bufferManager.nextImage.map   { isWideSpread($0) } ?? false
        let isPortrait   = geo.height > geo.width

        if isPortrait && isSpread && autoSplitPortraitSpreads {
            if splitHalf == 0 { splitHalf = 1; return } else { splitHalf = 0 }
        }

        // Always base hop arithmetic on the canonical lead in dual-page mode so we never sit on a
        // right-slot index and stall for a tap. This gives the natural
        // "every tap = one spread forward" feel the user expects.
        // In single-page mode, just use the current page index.
        let lead = showingDual
            ? PageBufferManager.canonicalLeadIndex(for: currentPageIndex, isMangaMode: isMangaMode)
            : currentPageIndex
        let isCover = showingDual && lead == 0

        // In dual-page mode hop by 2 (one full spread) unless the current or next
        // page is a wide physical spread — those always occupy a solo slot.
        let hop: Int = (showingDual && !isSpread && !nextIsSpread && !isCover) ? 2 : 1
        let next = lead + hop

        if next < pages.count {
            Haptics.shared.playImpact(style: .light)
            currentPageIndex = next
        } else if lead < pages.count - 1 {
            Haptics.shared.playImpact(style: .light)
            currentPageIndex = pages.count - 1
        } else {
            Haptics.shared.playImpact(style: .rigid)
            NotificationCenter.default.post(name: NSNotification.Name("Reader_EndOfBookReached"), object: nil)
        }
    }

    private func prevPage(geo: CGSize, showingDual: Bool) {
        let isSpread     = bufferManager.currentImage.map { isWideSpread($0) } ?? false
        let prevIsSpread = bufferManager.prevImage.map    { isWideSpread($0) } ?? false
        let isPortrait   = geo.height > geo.width

        if isPortrait && isSpread && autoSplitPortraitSpreads {
            if splitHalf == 1 { splitHalf = 0; return } else { splitHalf = 1 }
        }

        // Always base hop arithmetic on the canonical lead in dual-page mode — same reasoning as nextPage.
        let lead = showingDual
            ? PageBufferManager.canonicalLeadIndex(for: currentPageIndex, isMangaMode: isMangaMode)
            : currentPageIndex
        let isCover = showingDual && lead == 0
        guard lead > 0 else {
            Haptics.shared.playImpact(style: .rigid)
            return
        }

        // In dual-page mode hop back by 2 (one full spread), respecting wide pages.
        let hop: Int = (showingDual && !isSpread && !prevIsSpread && !isCover) ? 2 : 1
        Haptics.shared.playImpact(style: .light)
        currentPageIndex = max(0, lead - hop)
    }

    // MARK: - Buffer Setup

    private func setupBuffer(geo: GeometryProxy, dual: Bool) {
        let isLandscape = geo.size.width > geo.size.height
        let showingDual = dual && isLandscape

        if let firstPage = pages.first,
           let archiveURL = PageBufferManager.findArchiveURL(in: firstPage) {
            // setupDirectArchive is async — it fires the initial render() itself
            // after pageURLs is populated. Do NOT call render() here separately;
            // doing so would race with the empty pageURLs and produce a nil
            // currentImage crash in MetalCanvasView (single-page mode only).
            bufferManager.setupDirectArchive(
                url: archiveURL,
                initialPageIndex: currentPageIndex,
                bounds: geo.size,
                dual: showingDual,
                isMangaMode: isMangaMode
            )
        } else {
            bufferManager.setup(pages: pages)
            if showingDual {
                let lead = PageBufferManager.canonicalLeadIndex(
                    for: currentPageIndex, isMangaMode: isMangaMode)
                bufferManager.renderDual(
                    leadIndex: lead, pages: pages,
                    isMangaMode: isMangaMode, bounds: geo.size)
            } else {
                bufferManager.render(pageIndex: currentPageIndex, bounds: geo.size)
            }
        }

        if startWithGuidedReading && !hasInitializedGuidedReading {
            hasInitializedGuidedReading = true
            refreshGuidedPanels()
            if !guidedPanels.isEmpty {
                isGuidedReadingActive = true
                guidedPanelIndex = 0
                withAnimation(.easeInOut(duration: 0.25)) {
                    bufferManager.lockedRect   = guidedPanels[0]
                    bufferManager.isPPLEnabled = true
                }
            }
        }
    }

    private func advanceBuffer(to index: Int, geo: GeometryProxy, dual: Bool) {
        if dual {
            let lead = PageBufferManager.canonicalLeadIndex(for: index, isMangaMode: isMangaMode)
            bufferManager.renderDual(leadIndex: lead, pages: pages, isMangaMode: isMangaMode, bounds: geo.size)
        } else {
            bufferManager.render(pageIndex: index, bounds: geo.size)
        }
    }

    private func resetOnResize(to size: CGSize, dual: Bool) {
        guard size.width > 0, size.height > 0 else { return }
        // Cancel any in-flight momentum or swipe-commit task so stale geometry
        // can't mutate state after the screen has already rotated.
        momentumTask?.cancel()
        momentumTask = nil
        isCommittingSwipe = false
        withAnimation(.easeOut(duration: 0.15)) {
            scale = 1.0
            lastScale = 1.0
            offset = .zero
            dragOffset = .zero
            swipeDragX = 0
        }
        bufferManager.isPPLEnabled = false
        bufferManager.updateViewport(rect: .full)

        // ✅ Rotation crash fix: eagerly clear spread state BEFORE issuing the
        // new render. Without this, the old dual-page CGImages remain alive in
        // currentSpread while the new render sets currentImage = nil (isLoading=true).
        // SwiftUI then picks the singlePageView branch and passes currentImage=nil
        // to MetalCanvasView — crashing the GPU texture upload path.
        // Clearing spreads here makes the body show the loading indicator instead.
        if !dual {
            bufferManager.currentSpread = nil
            bufferManager.nextSpread = nil
            bufferManager.prevSpread = nil
        } else {
            bufferManager.currentImage = nil
            bufferManager.nextImage = nil
            bufferManager.prevImage = nil
        }

        if dual {
            let lead = PageBufferManager.canonicalLeadIndex(for: currentPageIndex, isMangaMode: isMangaMode)
            bufferManager.renderDual(leadIndex: lead, pages: pages, isMangaMode: isMangaMode, bounds: size)
        } else {
            bufferManager.render(pageIndex: currentPageIndex, bounds: size)
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
        let visW = size.width  / scale
        let visH = size.height / scale
        let x = ((size.width  - visW) / 2) - (offset.width  / scale)
        let y = ((size.height - visH) / 2) - (offset.height / scale)
        bufferManager.updateViewport(rect: CoordinateConverter.normalize(
            rect: CGRect(x: x, y: y, width: visW, height: visH), in: size))
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
            withAnimation(.easeInOut(duration: 0.25)) { bufferManager.lockedRect = guidedPanels[guidedPanelIndex] }
        } else {
            let isLandscape = geo.width > geo.height
            nextPage(geo: geo, showingDual: effectiveDoublePage && isLandscape)
            if isGuidedReadingActive {
                refreshGuidedPanels(); guidedPanelIndex = 0
                if guidedPanels.isEmpty { isGuidedReadingActive = false; updatePPL(in: geo) }
                else { withAnimation(.easeInOut(duration: 0.25)) { bufferManager.lockedRect = guidedPanels[0] } }
            }
        }
    }

    private func prevGuidedPanel(geo: CGSize) {
        if guidedPanelIndex > 0 {
            guidedPanelIndex -= 1
            withAnimation(.easeInOut(duration: 0.25)) { bufferManager.lockedRect = guidedPanels[guidedPanelIndex] }
        } else {
            let isLandscape = geo.width > geo.height
            prevPage(geo: geo, showingDual: effectiveDoublePage && isLandscape)
            if isGuidedReadingActive {
                refreshGuidedPanels()
                if guidedPanels.isEmpty { isGuidedReadingActive = false; updatePPL(in: geo) }
                else {
                    let lastIdx = guidedPanels.count - 1
                    guidedPanelIndex = lastIdx
                    withAnimation(.easeInOut(duration: 0.25)) { bufferManager.lockedRect = guidedPanels[lastIdx] }
                }
            }
        }
    }
}
