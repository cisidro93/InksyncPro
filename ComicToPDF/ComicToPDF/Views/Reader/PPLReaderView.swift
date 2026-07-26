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
    @EnvironmentObject var settingsManager: AppSettingsManager

    // ── Zoom / pan state ──────────────────────────────────────────────────────
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var dragOffset: CGSize = .zero
    @State private var momentumAnimator = MomentumAnimator()

    // ── Live swipe peel state ─────────────────────────────────────────────────
    @State private var swipeDragX: CGFloat = 0
    @State private var isCommittingSwipe = false

    // ── Settings ──────────────────────────────────────────────────────────────
    @AppStorage("autoLandscapeDualPage")  private var autoLandscapeDualPage = true
    @AppStorage("autoSplitPortraitSpreads") private var autoSplitPortraitSpreads = true
    @AppStorage("tapZoneStyle")           private var tapZoneStyleRaw     = TapZoneStyle.classic.rawValue
    @AppStorage("pageTurnStyle")          private var pageTurnStyleRaw    = PageTurnStyle.flip3D.rawValue
    @AppStorage("showSpreadSeam")         private var showSpreadSeam      = true
    @AppStorage("isAutoCropEnabled")      private var isAutoCropEnabled   = false
    @AppStorage("isZoomLockEnabled")      private var isZoomLockEnabled   = false

    private var tapZoneStyle:  TapZoneStyle  { TapZoneStyle(rawValue: tapZoneStyleRaw)   ?? .classic }
    private var pageTurnStyle: PageTurnStyle { PageTurnStyle(rawValue: pageTurnStyleRaw) ?? .flip3D }

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
            let targetDual   = effectiveDoublePage && isLandscape
            let currentDual  = bufferManager.currentSpread != nil

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
                    pageContent(geo: geo, currentDual: currentDual)
                        .contextMenu { contextMenuItems() }
                }
            }
            .onAppear       { setupBuffer(geo: geo, dual: targetDual) }
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
                advanceBuffer(to: newIndex, geo: geo, dual: targetDual)
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
            .onChange(of: isAutoCropEnabled) { _, _ in setupBuffer(geo: geo, dual: targetDual) }
            .onDisappear {
                momentumAnimator.stop()
            }
        }
    }

    // MARK: - Page Content with Live Peel

    @ViewBuilder
    private func pageContent(geo: GeometryProxy, currentDual: Bool) -> some View {
        let w = geo.size.width

        ZStack(alignment: .center) {
            // ── Back layer: adjacent spread peeking ──────────────────────────
            if pageTurnStyle != .instant {
                if swipeDragX > 8 {
                    adjacentSpread(isNext: false, currentDual: currentDual, geo: geo)
                        .offset(x: swipeDragX - w)
                        .allowsHitTesting(false)
                }
                if swipeDragX < -8 {
                    adjacentSpread(isNext: true, currentDual: currentDual, geo: geo)
                        .offset(x: swipeDragX + w)
                        .allowsHitTesting(false)
                }
            }

            // ── Front layer: current spread, sliding with finger ──────────────
            ZStack {
                currentContent(geo: geo, currentDual: currentDual)
                
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
        // If drawing mode is on, we let PKCanvasView handle gestures and disable reader zoom/pan (unless Pencil-Only is active)
        .gesture((isDrawingMode && !settingsManager.conversionSettings.pencilOnlyDrawing) ? nil : zoomGesture(geo: geo))
        .simultaneousGesture((isDrawingMode && !settingsManager.conversionSettings.pencilOnlyDrawing) ? nil : swipeAndPanGesture(geo: geo))
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
                        .foregroundStyle(Color.primary)
                    Text("· Double-tap to exit")
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(Color.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
                .padding(.bottom, 100)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: guidedPanelIndex)
            }
        }
    }

    // MARK: - Current Content

    @ViewBuilder
    private func currentContent(geo: GeometryProxy, currentDual: Bool) -> some View {
        if currentDual {
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
                .id("dual-solo-\(spread?.leadIndex ?? 0)")
        } else {
            HStack(spacing: 0) {
                if let left = leftImg {
                    MetalCanvasView(image: left, lockedRect: .full, isPPLEnabled: false, alignment: isMangaMode ? .leading : .trailing)
                        .id("dual-left-\(spread?.leadIndex ?? 0)")
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
                    MetalCanvasView(image: right, lockedRect: .full, isPPLEnabled: false, alignment: isMangaMode ? .trailing : .leading)
                        .id("dual-right-\(spread?.leadIndex ?? 0)")
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
                .id("single-split-\(currentPageIndex)")
        } else {
            MetalCanvasView(image: bufferManager.currentImage,
                            lockedRect: bufferManager.lockedRect,
                            isPPLEnabled: bufferManager.isPPLEnabled)
                .id("single-full-\(currentPageIndex)")
        }
    }

    // MARK: - Adjacent Spread (peel preview layer)

    @ViewBuilder
    private func adjacentSpread(isNext: Bool, currentDual: Bool, geo: GeometryProxy) -> some View {
        if currentDual {
            let spread = isNext ? bufferManager.nextSpread : bufferManager.prevSpread
            dualSpreadView(geo: geo, spread: spread)
        } else {
            let img = isNext ? bufferManager.nextImage : bufferManager.prevImage
            MetalCanvasView(image: img, lockedRect: .full, isPPLEnabled: false)
                .id("adj-\(isNext ? 1 : 0)-\(currentPageIndex)")
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
                if targetScale < 1.0 {
                    scale = 1.0 - (1.0 - targetScale) * 0.5
                } else if targetScale > 5.0 {
                    scale = 5.0 + (targetScale - 5.0) * 0.3
                } else {
                    scale = targetScale
                }
            }
            .onEnded { _ in
                withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                    if scale < 1.0 {
                        scale = 1.0
                        offset = .zero
                        Haptics.shared.playImpact(style: .light)
                    } else if scale > 5.0 {
                        scale = 5.0
                        Haptics.shared.playImpact(style: .light)
                    }
                    lastScale = scale
                    updatePPL(in: geo.size)
                }
            }
    }

    private func swipeAndPanGesture(geo: GeometryProxy) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { val in
                guard !isCommittingSwipe else { return }
                momentumAnimator.stop()
                if scale > 1.0 {
                    // Rubber-band resistance at pan boundaries
                    let maxOffsetX = geo.size.width * (scale - 1) / 2
                    let maxOffsetY = geo.size.height * (scale - 1) / 2
                    
                    var dx = val.translation.width
                    var dy = val.translation.height
                    
                    let intendedX = offset.width + dx
                    let intendedY = offset.height + dy
                    
                    if intendedX > maxOffsetX { dx = maxOffsetX - offset.width + (intendedX - maxOffsetX) * 0.3 }
                    else if intendedX < -maxOffsetX { dx = -maxOffsetX - offset.width + (intendedX + maxOffsetX) * 0.3 }
                    
                    if intendedY > maxOffsetY { dy = maxOffsetY - offset.height + (intendedY - maxOffsetY) * 0.3 }
                    else if intendedY < -maxOffsetY { dy = -maxOffsetY - offset.height + (intendedY + maxOffsetY) * 0.3 }
                    
                    dragOffset = CGSize(width: dx, height: dy)
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
                guard !isCommittingSwipe else { return }
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
                nextPage(geo: geo.size, targetDual: showingDual)
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
                prevPage(geo: geo.size, targetDual: showingDual)
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
        offset.width  += dragOffset.width
        offset.height += dragOffset.height
        dragOffset = .zero
        
        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
            updatePPL(in: geo.size)
        }

        let vel = val.velocity
        guard abs(vel.width) > 30 || abs(vel.height) > 30 else { return }

        momentumAnimator.start(
            velocity: vel,
            currentOffset: offset,
            scale: scale,
            geoSize: geo.size
        ) { newOffset in
            offset = newOffset
            updatePPL(in: geo.size)
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
        guard !isCommittingSwipe else { return }
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
        guard !isCommittingSwipe else { return }
        guard scale <= 1.0 || isZoomLockEnabled || isGuidedReadingActive else { return }
        let w = geo.size.width
        let isLandscape = geo.size.width > geo.size.height
        let targetDual = effectiveDoublePage && isLandscape
        let zones = tapZoneStyle.zones
        let touchX = location.x

        if isGuidedReadingActive {
            if touchX < w * zones.leftEdge {
                if isMangaMode { nextGuidedPanel(geo: geo.size) } else { prevGuidedPanel(geo: geo.size) }
            } else if touchX > w * zones.rightEdge {
                if isMangaMode { prevGuidedPanel(geo: geo.size) } else { nextGuidedPanel(geo: geo.size) }
            } else {
                onCenterTap()
            }
        } else {
            if touchX < w * zones.leftEdge {
                if isMangaMode { nextPage(geo: geo.size, targetDual: targetDual) } else { prevPage(geo: geo.size, targetDual: targetDual) }
            } else if touchX > w * zones.rightEdge {
                if isMangaMode { prevPage(geo: geo.size, targetDual: targetDual) } else { nextPage(geo: geo.size, targetDual: targetDual) }
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

    private func nextPage(geo: CGSize, targetDual: Bool) {
        let isSpread     = bufferManager.currentImage.map { isWideSpread($0) } ?? false
        let isPortrait   = geo.height > geo.width

        if isPortrait && isSpread && autoSplitPortraitSpreads {
            if splitHalf == 0 { splitHalf = 1; return } else { splitHalf = 0 }
        }

        if targetDual && !bufferManager.activeSpreads.isEmpty {
            let nextIndex = bufferManager.currentSpreadIndex + 1
            if nextIndex < bufferManager.activeSpreads.count {
                Haptics.shared.playImpact(style: .light)
                currentPageIndex = bufferManager.activeSpreads[nextIndex].leadIndex
            } else {
                Haptics.shared.playImpact(style: .rigid)
                NotificationCenter.default.post(name: NSNotification.Name("Reader_EndOfBookReached"), object: nil)
            }
            return
        }

        let next = currentPageIndex + 1
        if next < pages.count {
            Haptics.shared.playImpact(style: .light)
            currentPageIndex = next
        } else {
            Haptics.shared.playImpact(style: .rigid)
            NotificationCenter.default.post(name: NSNotification.Name("Reader_EndOfBookReached"), object: nil)
        }
    }

    private func prevPage(geo: CGSize, targetDual: Bool) {
        let isSpread     = bufferManager.currentImage.map { isWideSpread($0) } ?? false
        let isPortrait   = geo.height > geo.width

        if isPortrait && isSpread && autoSplitPortraitSpreads {
            if splitHalf == 1 { splitHalf = 0; return } else { splitHalf = 1 }
        }

        if targetDual && !bufferManager.activeSpreads.isEmpty {
            let prevIndex = bufferManager.currentSpreadIndex - 1
            if prevIndex >= 0 {
                Haptics.shared.playImpact(style: .light)
                currentPageIndex = bufferManager.activeSpreads[prevIndex].leadIndex
            } else {
                Haptics.shared.playImpact(style: .rigid)
            }
            return
        }

        let prev = currentPageIndex - 1
        if prev >= 0 {
            Haptics.shared.playImpact(style: .light)
            currentPageIndex = prev
        } else {
            Haptics.shared.playImpact(style: .rigid)
        }
    }

    // MARK: - Buffer Setup

    private func setupBuffer(geo: GeometryProxy, dual: Bool) {
        let isLandscape = geo.size.width > geo.size.height
        let targetDual = dual && isLandscape

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
                dual: targetDual,
                isMangaMode: isMangaMode
            )
        } else {
            bufferManager.setup(pages: pages, isMangaMode: isMangaMode)
            if targetDual {
                if let targetIdx = bufferManager.activeSpreads.firstIndex(where: { $0.leadIndex == currentPageIndex }) {
                    bufferManager.renderDual(spreadIndex: targetIdx, bounds: geo.size)
                } else {
                    bufferManager.renderDual(spreadIndex: 0, bounds: geo.size)
                }
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
        if dual && !bufferManager.activeSpreads.isEmpty {
            let targetIdx = bufferManager.activeSpreads.firstIndex(where: { $0.leadIndex == index }) ?? bufferManager.currentSpreadIndex
            bufferManager.renderDual(spreadIndex: targetIdx, bounds: geo.size)
        } else {
            bufferManager.render(pageIndex: index, bounds: geo.size)
        }
    }

    private func resetOnResize(to size: CGSize, dual: Bool) {
        guard size.width > 0, size.height > 0 else { return }
        // Cancel any in-flight momentum or swipe-commit task so stale geometry
        // can't mutate state after the screen has already rotated.
        momentumAnimator.stop()
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

        // ✅ Rotation crash fix: eagerly clear ALL spread and image states BEFORE issuing the
        // new render. This guarantees bufferManager.currentImage is nil, forcing the
        // loadingIndicator to show. If we don't clear currentImage when switching from dual
        // to single, MetalCanvasView stays mounted during the MTKView's drawableSize transition,
        // which causes a Metal pipeline crash on device rotation.
        bufferManager.currentImage = nil
        bufferManager.currentSpread = nil
        bufferManager.nextImage = nil
        bufferManager.nextSpread = nil
        bufferManager.prevImage = nil
        bufferManager.prevSpread = nil

        if dual && !bufferManager.activeSpreads.isEmpty {
            let targetIdx = bufferManager.activeSpreads.firstIndex(where: { $0.leadIndex == currentPageIndex }) ?? bufferManager.currentSpreadIndex
            bufferManager.renderDual(spreadIndex: targetIdx, bounds: size)
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
        // Manual pinch/tap zoom uses native SwiftUI scaleEffect to avoid double-dipping with Metal's PPL crop.
        // This ensures tap-to-zoom is professionally clean and works flawlessly on dual-page spreads.
        bufferManager.isPPLEnabled = false
        
        // Clamp the pan offset so the image doesn't fly off screen
        let maxOffsetX = size.width * (scale - 1) / 2
        let maxOffsetY = size.height * (scale - 1) / 2
        offset.width = max(-maxOffsetX, min(maxOffsetX, offset.width))
        offset.height = max(-maxOffsetY, min(maxOffsetY, offset.height))
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
            nextPage(geo: geo, targetDual: effectiveDoublePage && isLandscape)
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
            prevPage(geo: geo, targetDual: effectiveDoublePage && isLandscape)
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

// ── Momentum DisplayLink Proxy ────────────────────────────────────────────────
@MainActor
private class MomentumDisplayLinkProxy: NSObject {
    private weak var target: MomentumAnimator?
    
    init(target: MomentumAnimator) {
        self.target = target
        super.init()
    }
    
    @objc func tick(_ dl: CADisplayLink) {
        target?.tick(dl)
    }
}

// ── Momentum Animator Class ──────────────────────────────────────────────────
@MainActor
class MomentumAnimator: NSObject {
    private var displayLink: CADisplayLink?
    private var vx: CGFloat = 0
    private var vy: CGFloat = 0
    private var scale: CGFloat = 1.0
    private var geoSize: CGSize = .zero
    
    var offsetWidth: CGFloat = 0
    var offsetHeight: CGFloat = 0
    
    var onTick: ((CGSize) -> Void)?
    
    func start(velocity: CGSize, currentOffset: CGSize, scale: CGFloat, geoSize: CGSize, onTick: @escaping (CGSize) -> Void) {
        stop()
        
        self.vx = velocity.width * 0.012
        self.vy = velocity.height * 0.012
        self.offsetWidth = currentOffset.width
        self.offsetHeight = currentOffset.height
        self.scale = scale
        self.geoSize = geoSize
        self.onTick = onTick
        
        let proxy = MomentumDisplayLinkProxy(target: self)
        let dl = CADisplayLink(target: proxy, selector: #selector(MomentumDisplayLinkProxy.tick(_:)))
        if #available(iOS 15.0, *) {
            dl.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        }
        dl.add(to: .main, forMode: .common)
        self.displayLink = dl
    }
    
    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }
    
    fileprivate func tick(_ dl: CADisplayLink) {
        let dt = CGFloat(dl.duration)
        let decay = pow(0.90, dt / (1.0 / 60.0))
        vx *= decay
        vy *= decay
        
        offsetWidth  = max(-geoSize.width  * (scale - 1), min(geoSize.width  * (scale - 1), offsetWidth  + vx))
        offsetHeight = max(-geoSize.height * (scale - 1), min(geoSize.height * (scale - 1), offsetHeight + vy))
        
        onTick?(CGSize(width: offsetWidth, height: offsetHeight))
        
        if abs(vx) <= 0.5 && abs(vy) <= 0.5 {
            stop()
        }
    }
}
