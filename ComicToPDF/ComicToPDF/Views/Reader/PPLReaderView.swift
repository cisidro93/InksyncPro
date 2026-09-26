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
    @AppStorage("showSpreadSeam")         private var showSpreadSeam      = false
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

    // ── Live In-Reader Panel Adjustment & Adaptive Learning ─────────────────
    @State private var isAdjustingActivePanel = false
    @State private var activePanelAdjustRect: NormalizedRect = .full
    @State private var originalPanelAdjustRect: NormalizedRect = .full
    @State private var activePanelDragHandle: PanelAdjustmentHandle? = nil
    @State private var dragStartAdjustRect: NormalizedRect = .full

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
        let isFade = false
        let fadeFraction = min(1.0, abs(swipeDragX) / max(w * 0.5, 1))

        ZStack(alignment: .center) {
            // ── Back layer: adjacent spread peeking ──────────────────────────
            if pageTurnStyle != .instant {
                if swipeDragX > 8 {
                    adjacentSpread(isNext: false, currentDual: currentDual, geo: geo)
                        .offset(x: isFade ? 0 : (swipeDragX - w))
                        .opacity(isFade ? Double(fadeFraction) : 1.0)
                        .allowsHitTesting(false)
                }
                if swipeDragX < -8 {
                    adjacentSpread(isNext: true, currentDual: currentDual, geo: geo)
                        .offset(x: isFade ? 0 : (swipeDragX + w))
                        .opacity(isFade ? Double(fadeFraction) : 1.0)
                        .allowsHitTesting(false)
                }
            }

            // ── Front layer: current spread, sliding with finger ──────────────
            ZStack {
                currentContent(geo: geo, currentDual: currentDual)
                
                // ✅ Phase 4: In-Line Handwriting
                PageCanvasOverlay(pdfID: pdfID, pageIndex: currentPageIndex, isMarkupEnabled: isDrawingMode)
            }
            .offset(x: (scale > 1.0 || isFade) ? 0 : swipeDragX,
                    y: 0)
            .opacity(isFade ? Double(1.0 - fadeFraction * 0.8) : 1.0)
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
        .gesture(zoomGesture(geo: geo), including: areNavigationGesturesEnabled ? .all : .none)
        .simultaneousGesture(swipeAndPanGesture(geo: geo), including: areNavigationGesturesEnabled ? .all : .none)
        .onTapGesture(count: 2) { loc in
            guard areNavigationGesturesEnabled else { return }
            handleDoubleTap(at: loc, geo: geo)
        }
        .onTapGesture { loc in
            guard areNavigationGesturesEnabled else { return }
            handleSingleTap(at: loc, geo: geo)
        }
        .overlay(alignment: .bottom) {
            // Guided Reading panel progress indicator
            if isGuidedReadingActive && !guidedPanels.isEmpty && !isAdjustingActivePanel {
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

                    Rectangle()
                        .fill(Color.primary.opacity(0.18))
                        .frame(width: 1, height: 12)

                    Button {
                        HapticEngine.selection()
                        startPanelAdjustment()
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "slider.horizontal.2.square")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Adjust")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                        }
                        .foregroundColor(.orange)
                    }
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
        .overlay {
            if isAdjustingActivePanel {
                livePanelAdjustmentOverlay(geo: geo)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    .zIndex(600)
            }
        }
    }

    private var areNavigationGesturesEnabled: Bool {
        !isDrawingMode && !isAdjustingActivePanel
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
            let isCover = currentPageIndex == 0
            let rect: NormalizedRect = {
                if isCover {
                    // For a wraparound cover, front cover is on the right half in Western/LTR
                    return isMangaMode
                        ? (splitHalf == 0 ? leftHalf : rightHalf)
                        : (splitHalf == 0 ? rightHalf : leftHalf)
                } else {
                    return isMangaMode
                        ? (splitHalf == 0 ? rightHalf : leftHalf)
                        : (splitHalf == 0 ? leftHalf  : rightHalf)
                }
            }()
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
            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                swipeDragX = 0
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 200_000_000)
                nextPage(geo: geo.size, targetDual: showingDual)
                swipeDragX = 0
                withAnimation(.spring(response: 0.22, dampingFraction: 0.9)) { swipeDragX = 0 }
                isCommittingSwipe = false
            }
        } else if triggerPrev && currentPageIndex > 0 {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                swipeDragX = 0
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 160_000_000)
                prevPage(geo: geo.size, targetDual: showingDual)
                swipeDragX = 0
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
        CGFloat(img.width) > CGFloat(img.height) * 1.1
    }

    // MARK: - Guided Reading Engine

    private func refreshGuidedPanels() {
        guard let pdfID = pdfID else { return }
        let model = PageModelStore.shared.getPageModel(for: pdfID, pageIndex: currentPageIndex)
        var panels = sortPanelsInReadingOrder(model.panels, isManga: isMangaMode)
        if panels.isEmpty, let cgImg = bufferManager.currentImage {
            let uiImg = UIImage(cgImage: cgImg)
            let strides = PanelExtractor.generateSmartStrides(for: uiImg, isDualPage: false, mangaMode: isMangaMode)
            panels = strides.map { s in
                NormalizedRect(
                    x: Double(s.boundingBox.minX * 1000.0),
                    y: Double(s.boundingBox.minY * 1000.0),
                    width: Double(s.boundingBox.width * 1000.0),
                    height: Double(s.boundingBox.height * 1000.0)
                )
            }
        }
        // Micro-panel viewport stabilization: expand tiny panels (< 7% page area) to a comfortable
        // cinematic reading box (at least 28% width, 20% height) centered on the panel, preventing 15x camera whips.
        guidedPanels = panels.map { stabilizeGuidedViewport($0) }
    }

    /// Sorts NormalizedRect panels using recursive XY-cut spatial decomposition.
    private func sortPanelsInReadingOrder(_ rects: [NormalizedRect], isManga: Bool) -> [NormalizedRect] {
        guard rects.count > 1 else { return rects }
        return recursiveXYCutSort(rects, isManga: isManga)
    }

    private func recursiveXYCutSort(_ rects: [NormalizedRect], isManga: Bool) -> [NormalizedRect] {
        guard rects.count > 1 else { return rects }

        // 1. Horizontal Split (Top vs Bottom)
        let sortedY = rects.sorted { $0.maxY < $1.maxY }
        let tolerance = 15.0 // 1.5% in 1000 space
        var maxTopY = sortedY[0].maxY
        for i in 0..<(sortedY.count - 1) {
            maxTopY = max(maxTopY, sortedY[i].maxY)
            let remainingMinY = sortedY[(i + 1)...].map(\.minY).min() ?? 0.0
            if remainingMinY >= (maxTopY - tolerance) {
                let topSet = Array(sortedY[0...i])
                let bottomSet = Array(sortedY[(i + 1)...])
                return recursiveXYCutSort(topSet, isManga: isManga) + recursiveXYCutSort(bottomSet, isManga: isManga)
            }
        }

        // 2. Vertical Split (Left vs Right)
        let sortedX = rects.sorted { $0.maxX < $1.maxX }
        var maxLeftX = sortedX[0].maxX
        for i in 0..<(sortedX.count - 1) {
            maxLeftX = max(maxLeftX, sortedX[i].maxX)
            let remainingMinX = sortedX[(i + 1)...].map(\.minX).min() ?? 0.0
            if remainingMinX >= (maxLeftX - tolerance) {
                let leftSet = Array(sortedX[0...i])
                let rightSet = Array(sortedX[(i + 1)...])
                if isManga {
                    return recursiveXYCutSort(rightSet, isManga: isManga) + recursiveXYCutSort(leftSet, isManga: isManga)
                } else {
                    return recursiveXYCutSort(leftSet, isManga: isManga) + recursiveXYCutSort(rightSet, isManga: isManga)
                }
            }
        }

        // 3. Fallback: Proximity tier sort
        return rects.sorted { a, b in
            if abs(a.origin.y - b.origin.y) > 50 { return a.origin.y < b.origin.y }
            return isManga ? (a.origin.x > b.origin.x) : (a.origin.x < b.origin.x)
        }
    }

    /// Sanitizes and stabilizes panel viewports for cinematic Guided Reading.
    /// Micro-panels (< 7% page area) are padded to a minimum comfortable viewport size
    /// (at least 28% width, 20% height), preventing dizzying 15x camera whips.
    private func stabilizeGuidedViewport(_ rect: NormalizedRect) -> NormalizedRect {
        let minW: Double = 280.0 // 28% of page width
        let minH: Double = 200.0 // 20% of page height
        
        let targetW = max(rect.width, minW)
        let targetH = max(rect.height, minH)
        
        var targetX = rect.x - (targetW - rect.width) / 2.0
        var targetY = rect.y - (targetH - rect.height) / 2.0
        
        // Clamp to 0..1000 boundaries
        if targetX < 0 { targetX = 0 }
        if targetY < 0 { targetY = 0 }
        if targetX + targetW > 1000.0 { targetX = max(0.0, 1000.0 - targetW) }
        if targetY + targetH > 1000.0 { targetY = max(0.0, 1000.0 - targetH) }
        
        return NormalizedRect(x: targetX, y: targetY, width: targetW, height: targetH)
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

    // MARK: - Live In-Reader Panel Adjustment & Adaptive Learning

    private enum PanelAdjustmentHandle: Equatable {
        case topLeft, topRight, bottomLeft, bottomRight
        case topEdge, bottomEdge, leftEdge, rightEdge
        case move
    }

    private func startPanelAdjustment() {
        guard guidedPanelIndex < guidedPanels.count else { return }
        originalPanelAdjustRect = guidedPanels[guidedPanelIndex]
        activePanelAdjustRect = guidedPanels[guidedPanelIndex]
        withAnimation(.easeInOut(duration: 0.25)) {
            bufferManager.lockedRect = .full
            isAdjustingActivePanel = true
        }
    }

    private func commitPanelAdjustment() {
        guard let pdfID = pdfID, guidedPanelIndex < guidedPanels.count else {
            isAdjustingActivePanel = false
            return
        }

        let oldRect = originalPanelAdjustRect
        let newRect = activePanelAdjustRect

        // 1. Commit new panel geometry to PageModelStore
        var model = PageModelStore.shared.getPageModel(for: pdfID, pageIndex: currentPageIndex)
        if model.panels.isEmpty {
            model.panels = guidedPanels
        }
        if guidedPanelIndex < model.panels.count {
            model.panels[guidedPanelIndex] = newRect
        } else {
            model.panels.append(newRect)
        }
        PageModelStore.shared.savePageModel(model, for: pdfID)

        // 2. Feed correction to AdaptiveLearningManager for continuous personalization
        AdaptiveLearningManager.shared.recordUserAdjustedPanel(oldRect: oldRect, newRect: newRect)

        // 3. Update active guided reading sequence
        guidedPanels[guidedPanelIndex] = newRect

        // 4. Smoothly focus camera into the new panel
        HapticEngine.success()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            bufferManager.lockedRect = newRect
            isAdjustingActivePanel = false
        }
    }

    private func cancelPanelAdjustment() {
        withAnimation(.easeInOut(duration: 0.25)) {
            if guidedPanelIndex < guidedPanels.count {
                bufferManager.lockedRect = guidedPanels[guidedPanelIndex]
            }
            isAdjustingActivePanel = false
        }
    }

    private func nudgePanel(dx: Double, dy: Double) {
        let newX = max(0.0, min(1000.0 - activePanelAdjustRect.width, activePanelAdjustRect.x + dx))
        let newY = max(0.0, min(1000.0 - activePanelAdjustRect.height, activePanelAdjustRect.y + dy))
        activePanelAdjustRect = NormalizedRect(
            x: newX,
            y: newY,
            width: activePanelAdjustRect.width,
            height: activePanelAdjustRect.height
        )
        HapticEngine.selection()
    }

    private func expandPanel(by delta: Double) {
        let newW = max(50.0, min(1000.0, activePanelAdjustRect.width + (delta * 2.0)))
        let newH = max(50.0, min(1000.0, activePanelAdjustRect.height + (delta * 2.0)))
        let newX = max(0.0, min(1000.0 - newW, activePanelAdjustRect.x - delta))
        let newY = max(0.0, min(1000.0 - newH, activePanelAdjustRect.y - delta))
        activePanelAdjustRect = NormalizedRect(x: newX, y: newY, width: newW, height: newH)
        HapticEngine.selection()
    }

    @ViewBuilder
    private func panelDragHandle(
        handle: PanelAdjustmentHandle,
        position: CGPoint,
        renderW: CGFloat,
        renderH: CGFloat
    ) -> some View {
        let isCorner = handle == .topLeft || handle == .topRight || handle == .bottomLeft || handle == .bottomRight
        let isMove = handle == .move

        ZStack {
            Color.clear
                .frame(width: isMove ? 50 : 44, height: isMove ? 50 : 44)
                .contentShape(Rectangle())

            if isMove {
                Circle()
                    .fill(Color.orange.opacity(0.85))
                    .frame(width: 22, height: 22)
                    .overlay(
                        Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                    )
                    .shadow(color: .black.opacity(0.4), radius: 3)
            } else if isCorner {
                Circle()
                    .fill(Color.white)
                    .frame(width: 14, height: 14)
                    .overlay(Circle().stroke(Color.orange, lineWidth: 2.5))
                    .shadow(color: .black.opacity(0.4), radius: 3)
            } else {
                Capsule()
                    .fill(Color.white)
                    .frame(
                        width: (handle == .topEdge || handle == .bottomEdge) ? 22 : 6,
                        height: (handle == .topEdge || handle == .bottomEdge) ? 6 : 22
                    )
                    .overlay(Capsule().stroke(Color.orange, lineWidth: 1.5))
                    .shadow(color: .black.opacity(0.4), radius: 3)
            }
        }
        .position(position)
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { val in
                    if activePanelDragHandle != handle {
                        activePanelDragHandle = handle
                        dragStartAdjustRect = activePanelAdjustRect
                    }
                    let dx1000 = (val.translation.width / renderW) * 1000.0
                    let dy1000 = (val.translation.height / renderH) * 1000.0

                    var rX = dragStartAdjustRect.x
                    var rY = dragStartAdjustRect.y
                    var rW = dragStartAdjustRect.width
                    var rH = dragStartAdjustRect.height

                    switch handle {
                    case .topLeft:
                        let maxDx = rW - 50.0
                        let maxDy = rH - 50.0
                        let cDx = min(dx1000, maxDx)
                        let cDy = min(dy1000, maxDy)
                        rX = max(0.0, dragStartAdjustRect.x + cDx)
                        rY = max(0.0, dragStartAdjustRect.y + cDy)
                        rW = max(50.0, dragStartAdjustRect.maxX - rX)
                        rH = max(50.0, dragStartAdjustRect.maxY - rY)
                    case .topRight:
                        let maxDy = rH - 50.0
                        let cDy = min(dy1000, maxDy)
                        rY = max(0.0, dragStartAdjustRect.y + cDy)
                        rH = max(50.0, dragStartAdjustRect.maxY - rY)
                        rW = max(50.0, min(1000.0 - rX, dragStartAdjustRect.width + dx1000))
                    case .bottomLeft:
                        let maxDx = rW - 50.0
                        let cDx = min(dx1000, maxDx)
                        rX = max(0.0, dragStartAdjustRect.x + cDx)
                        rW = max(50.0, dragStartAdjustRect.maxX - rX)
                        rH = max(50.0, min(1000.0 - rY, dragStartAdjustRect.height + dy1000))
                    case .bottomRight:
                        rW = max(50.0, min(1000.0 - rX, dragStartAdjustRect.width + dx1000))
                        rH = max(50.0, min(1000.0 - rY, dragStartAdjustRect.height + dy1000))
                    case .topEdge:
                        let maxDy = rH - 50.0
                        let cDy = min(dy1000, maxDy)
                        rY = max(0.0, dragStartAdjustRect.y + cDy)
                        rH = max(50.0, dragStartAdjustRect.maxY - rY)
                    case .bottomEdge:
                        rH = max(50.0, min(1000.0 - rY, dragStartAdjustRect.height + dy1000))
                    case .leftEdge:
                        let maxDx = rW - 50.0
                        let cDx = min(dx1000, maxDx)
                        rX = max(0.0, dragStartAdjustRect.x + cDx)
                        rW = max(50.0, dragStartAdjustRect.maxX - rX)
                    case .rightEdge:
                        rW = max(50.0, min(1000.0 - rX, dragStartAdjustRect.width + dx1000))
                    case .move:
                        rX = max(0.0, min(1000.0 - rW, dragStartAdjustRect.x + dx1000))
                        rY = max(0.0, min(1000.0 - rH, dragStartAdjustRect.y + dy1000))
                    }

                    activePanelAdjustRect = NormalizedRect(x: rX, y: rY, width: rW, height: rH)
                }
                .onEnded { _ in
                    activePanelDragHandle = nil
                    HapticEngine.selection()
                }
        )
    }

    @ViewBuilder
    private func livePanelAdjustmentOverlay(geo: GeometryProxy) -> some View {
        let viewW = geo.size.width
        let viewH = geo.size.height

        if let cgImg = bufferManager.currentImage {
            let imgW = CGFloat(cgImg.width)
            let imgH = CGFloat(cgImg.height)
            let imgRatio = imgW / max(1.0, imgH)
            let containerRatio = viewW / max(1.0, viewH)

            let renderW: CGFloat = (imgRatio > containerRatio) ? viewW : (viewH * imgRatio)
            let renderH: CGFloat = (imgRatio > containerRatio) ? (viewW / imgRatio) : viewH
            let originX = (viewW - renderW) / 2.0
            let originY = (viewH - renderH) / 2.0

            let pX = originX + (renderW * (activePanelAdjustRect.x / 1000.0))
            let pY = originY + (renderH * (activePanelAdjustRect.y / 1000.0))
            let pW = max(20.0, renderW * (activePanelAdjustRect.width / 1000.0))
            let pH = max(20.0, renderH * (activePanelAdjustRect.height / 1000.0))

            ZStack {
                // Dimmed backdrop highlighting the active panel cutout
                Color.black.opacity(0.45).ignoresSafeArea()
                    .contentShape(Rectangle())

                // Active Panel Focus Boundary
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.orange, style: StrokeStyle(lineWidth: 2.5, dash: [6, 4]))
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.12)))
                    .frame(width: pW, height: pH)
                    .position(x: pX + pW / 2.0, y: pY + pH / 2.0)
                    .shadow(color: Color.orange.opacity(0.5), radius: 8)

                // Move Center Handle
                panelDragHandle(handle: .move, position: CGPoint(x: pX + pW / 2.0, y: pY + pH / 2.0), renderW: renderW, renderH: renderH)

                // 4 Corner Handles
                panelDragHandle(handle: .topLeft, position: CGPoint(x: pX, y: pY), renderW: renderW, renderH: renderH)
                panelDragHandle(handle: .topRight, position: CGPoint(x: pX + pW, y: pY), renderW: renderW, renderH: renderH)
                panelDragHandle(handle: .bottomLeft, position: CGPoint(x: pX, y: pY + pH), renderW: renderW, renderH: renderH)
                panelDragHandle(handle: .bottomRight, position: CGPoint(x: pX + pW, y: pY + pH), renderW: renderW, renderH: renderH)

                // 4 Edge Handles
                panelDragHandle(handle: .topEdge, position: CGPoint(x: pX + pW / 2.0, y: pY), renderW: renderW, renderH: renderH)
                panelDragHandle(handle: .bottomEdge, position: CGPoint(x: pX + pW / 2.0, y: pY + pH), renderW: renderW, renderH: renderH)
                panelDragHandle(handle: .leftEdge, position: CGPoint(x: pX, y: pY + pH / 2.0), renderW: renderW, renderH: renderH)
                panelDragHandle(handle: .rightEdge, position: CGPoint(x: pX + pW, y: pY + pH / 2.0), renderW: renderW, renderH: renderH)

                // Top Floating Control Bar: Reset, Cancel, Save & Learn
                VStack {
                    HStack(spacing: 12) {
                        Button {
                            cancelPanelAdjustment()
                        } label: {
                            Text("Cancel")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(.ultraThinMaterial, in: Capsule())
                        }

                        Spacer()

                        // Panel Dimensions Badge
                        Text("W: \(Int(activePanelAdjustRect.width / 10))%  H: \(Int(activePanelAdjustRect.height / 10))%")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.black.opacity(0.6)))

                        Spacer()

                        Button {
                            commitPanelAdjustment()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "brain.head.profile")
                                    .font(.system(size: 12, weight: .bold))
                                Text("Save & Learn")
                                    .font(.system(size: 13, weight: .bold, design: .rounded))
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(Color.orange, in: Capsule())
                            .shadow(color: Color.orange.opacity(0.4), radius: 6, y: 2)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, max(geo.safeAreaInsets.top, 16.0))

                    Spacer()

                    // Bottom Floating Nudge & Scale Toolbar
                    HStack(spacing: 10) {
                        // Directional Nudges
                        HStack(spacing: 4) {
                            Button { nudgePanel(dx: -10, dy: 0) } label: {
                                Image(systemName: "arrow.left")
                                    .font(.system(size: 12, weight: .bold))
                                    .frame(width: 32, height: 32)
                            }
                            Button { nudgePanel(dx: 10, dy: 0) } label: {
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 12, weight: .bold))
                                    .frame(width: 32, height: 32)
                            }
                            Button { nudgePanel(dx: 0, dy: -10) } label: {
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 12, weight: .bold))
                                    .frame(width: 32, height: 32)
                            }
                            Button { nudgePanel(dx: 0, dy: 10) } label: {
                                Image(systemName: "arrow.down")
                                    .font(.system(size: 12, weight: .bold))
                                    .frame(width: 32, height: 32)
                            }
                        }
                        .foregroundColor(.white)
                        .background(Capsule().fill(Color.inkSurfaceRaised.opacity(0.92)))

                        Rectangle()
                            .fill(Color.white.opacity(0.2))
                            .frame(width: 1, height: 20)

                        // Padding adjustments
                        HStack(spacing: 4) {
                            Button { expandPanel(by: -10) } label: {
                                Image(systemName: "arrow.down.right.and.arrow.up.left")
                                    .font(.system(size: 11, weight: .bold))
                                    .frame(width: 32, height: 32)
                            }
                            Button { expandPanel(by: 10) } label: {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .font(.system(size: 11, weight: .bold))
                                    .frame(width: 32, height: 32)
                            }
                        }
                        .foregroundColor(.white)
                        .background(Capsule().fill(Color.inkSurfaceRaised.opacity(0.92)))

                        Rectangle()
                            .fill(Color.white.opacity(0.2))
                            .frame(width: 1, height: 20)

                        Button {
                            activePanelAdjustRect = originalPanelAdjustRect
                            HapticEngine.selection()
                        } label: {
                            Text("Reset")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().stroke(Color.primary.opacity(0.15), lineWidth: 0.8))
                    .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
                    .padding(.bottom, max(geo.safeAreaInsets.bottom, 24.0))
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
