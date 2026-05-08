import SwiftUI

struct PPLReaderView: View {
    let pages: [URL]
    @Binding var currentPageIndex: Int
    var pdfID: UUID?
    var isMangaMode: Bool
    var isDoublePageOverride: Bool = false  // Landscape auto-dual-page from parent
    var onCenterTap: () -> Void
    @ObservedObject private var bufferManager = PageBufferManager.shared
    
    // High-Frequency Gesture Tracking
    @State private var scale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var dragOffset: CGSize = .zero
    
    @AppStorage("isDoublePageMode") private var isDoublePageStored = false
    
    // Effective double page: respects both the stored toggle AND the landscape override
    private var effectiveDoublePage: Bool { isDoublePageOverride || isDoublePageStored }
    
    // ✅ Phase 2: Spread Splitting State
    @State private var splitHalf: Int = 0 // 0 = first half, 1 = second half
    @AppStorage("autoSplitPortraitSpreads") private var autoSplitPortraitSpreads = true
    
    // ✅ Phase 1: Guided Reading State
    @State private var isGuidedReadingActive: Bool = false
    @State private var guidedPanelIndex: Int = 0
    @State private var guidedPanels: [NormalizedRect] = []
    
    var body: some View {
        GeometryReader { geo in
            ZStack {
                if bufferManager.isLoading && bufferManager.currentImage == nil {
                    ProgressView("Buffering Metal Canvas...")
                        .scaleEffect(1.2)
                } else {
                    // 🚨 PANELS PARITY: Zero-Memory Dual Spread Injection
                    // We utilize the preexisting asynchronous buffer predictions (`nextImage`)
                    // instead of synthesizing a merged bitmap, saving 40-70MB of RAM per swap.
                    HStack(spacing: 0) {
                        if effectiveDoublePage && geo.size.width > geo.size.height {
                            if isMangaMode {
                                // RTL (Manga) -> Next Page is on the Left
                                if let next = bufferManager.nextImage {
                                    MetalCanvasView(image: next, lockedRect: .full, isPPLEnabled: false)
                                }
                                MetalCanvasView(image: bufferManager.currentImage, lockedRect: bufferManager.lockedRect, isPPLEnabled: bufferManager.isPPLEnabled)
                            } else {
                                // LTR (Comic) -> Next Page is on the Right
                                MetalCanvasView(image: bufferManager.currentImage, lockedRect: bufferManager.lockedRect, isPPLEnabled: bufferManager.isPPLEnabled)
                                if let next = bufferManager.nextImage {
                                    MetalCanvasView(image: next, lockedRect: .full, isPPLEnabled: false)
                                }
                            }
                        } else {
                            // ✅ Phase 2: Spread Splitting (Portrait Detection)
                            splitSpreadOrSinglePage(geo: geo)
                        }
                    }
                    // Structural Transforms allow scaling before we trigger hard Coordinate Lock Math
                    .scaleEffect(scale)
                    .offset(x: offset.width + dragOffset.width, y: offset.height + dragOffset.height)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { val in
                                scale = min(max(val, 1.0), 5.0)
                            }
                            .onEnded { _ in
                                updatePPL(in: geo.size)
                            }
                    )
                    .simultaneousGesture(
                        DragGesture()
                            .onChanged { val in
                                if scale > 1.0 {
                                    dragOffset = val.translation
                                }
                            }
                            .onEnded { val in
                                if scale > 1.0 {
                                    offset.width += val.translation.width
                                    offset.height += val.translation.height
                                    dragOffset = .zero
                                    updatePPL(in: geo.size)
                                } else {
                                    // Zero-Latency Swipe Gestures for 1.0x Scale
                                    if val.translation.width < -60 {
                                        isMangaMode ? prevPage(geo: geo.size) : nextPage(geo: geo.size)
                                    } else if val.translation.width > 60 {
                                        isMangaMode ? nextPage(geo: geo.size) : prevPage(geo: geo.size)
                                    }
                                }
                            }
                    )
                    // Zero-Latency Edge Tap Gestures
                    .onTapGesture(count: 2) { location in
                        // Phase 1: Guided Reading Activation via Double Tap
                        if scale == 1.0 {
                            if isGuidedReadingActive {
                                isGuidedReadingActive = false
                                updatePPL(in: geo.size) // resets to full
                                return
                            } else {
                                refreshGuidedPanels()
                                if !guidedPanels.isEmpty {
                                    isGuidedReadingActive = true
                                    guidedPanelIndex = 0
                                    withAnimation(.easeInOut(duration: 0.25)) {
                                        bufferManager.lockedRect = guidedPanels[guidedPanelIndex]
                                        bufferManager.isPPLEnabled = true
                                    }
                                    Haptics.shared.playImpact(style: .medium)
                                    return
                                }
                            }
                        }
                        
                        // Fallback: Double Tap to Smart Zoom
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            if scale > 1.0 {
                                scale = 1.0
                                offset = .zero
                                updatePPL(in: geo.size)
                            } else {
                                // Smart Zoom (Fit Width Approximation)
                                scale = 2.0
                                
                                // Pan toward the tap location
                                let tapX = location.x - (geo.size.width / 2)
                                let tapY = location.y - (geo.size.height / 2)
                                offset = CGSize(width: -tapX * scale, height: -tapY * scale)
                                updatePPL(in: geo.size)
                            }
                        }
                    }
                    .onTapGesture { location in
                        if scale <= 1.0 || isGuidedReadingActive {
                            let width = geo.size.width
                            
                            // Route Tap to Guided Reading Navigation or Standard Page Turn
                            if isGuidedReadingActive {
                                if location.x < width * 0.3 {
                                    isMangaMode ? nextGuidedPanel(geo: geo.size) : prevGuidedPanel(geo: geo.size)
                                } else if location.x > width * 0.7 {
                                    isMangaMode ? prevGuidedPanel(geo: geo.size) : nextGuidedPanel(geo: geo.size)
                                } else {
                                    onCenterTap()
                                }
                            } else {
                                if location.x < width * 0.3 {
                                    isMangaMode ? nextPage(geo: geo.size) : prevPage(geo: geo.size)
                                } else if location.x > width * 0.7 {
                                    isMangaMode ? prevPage(geo: geo.size) : nextPage(geo: geo.size)
                                } else {
                                    onCenterTap()
                                }
                            }
                        }
                    }
                }
            }
            // Prime the Actor Engine
            .onAppear {
                bufferManager.setup(pages: pages)
                bufferManager.render(pageIndex: currentPageIndex, bounds: geo.size)
            }
            .onChange(of: currentPageIndex) { _, newIndex in
                bufferManager.render(pageIndex: newIndex, bounds: geo.size)
                // If PPL is enabled, the buffer renderer will automatically slice the buffer against the new page
            }
            // ROTATION FIX: Re-render with the new viewport size after orientation changes.
            // Also reset zoom/pan state — stale offsets are relative to the old orientation's coordinate space.
            .onChange(of: geo.size) { _, newSize in
                guard newSize.width > 0, newSize.height > 0 else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    scale = 1.0
                    offset = .zero
                    dragOffset = .zero
                }
                bufferManager.isPPLEnabled = false
                bufferManager.updateViewport(rect: .full)
                bufferManager.render(pageIndex: currentPageIndex, bounds: newSize)
            }
            .background(Color.black)
        }
    }
    
    @ViewBuilder
    private func splitSpreadOrSinglePage(geo: GeometryProxy) -> some View {
        let isPortrait = geo.size.height > geo.size.width
        let imgWidth = CGFloat(bufferManager.currentImage?.width ?? 0)
        let imgHeight = CGFloat(bufferManager.currentImage?.height ?? 1)
        let isSpread = imgWidth > imgHeight * 1.2
        
        if isPortrait && isSpread && autoSplitPortraitSpreads, let img = bufferManager.currentImage {
            // NormalizedRect is on a 0-1000 scale
            let rightHalf = NormalizedRect(x: 500, y: 0, width: 500, height: 1000)
            let leftHalf = NormalizedRect(x: 0, y: 0, width: 500, height: 1000)
            
            let rect: NormalizedRect = isMangaMode ? (splitHalf == 0 ? rightHalf : leftHalf) : (splitHalf == 0 ? leftHalf : rightHalf)
            
            MetalCanvasView(
                image: img,
                lockedRect: rect,
                isPPLEnabled: true
            )
        } else {
            MetalCanvasView(
                image: bufferManager.currentImage,
                lockedRect: bufferManager.lockedRect,
                isPPLEnabled: bufferManager.isPPLEnabled
            )
        }
    }
    
    // Core Engine Math: Transfers the infinite float scalar offset into Normalized Coordinates for the shader
    private func updatePPL(in size: CGSize) {
        if scale <= 1.0 {
            bufferManager.isPPLEnabled = false
            bufferManager.updateViewport(rect: .full)
            
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                offset = .zero
            }
            return
        }
        
        bufferManager.isPPLEnabled = true
        
        let visibleWidth = size.width / scale
        let visibleHeight = size.height / scale
        
        let x = ((size.width - visibleWidth) / 2.0) - (offset.width / scale)
        let y = ((size.height - visibleHeight) / 2.0) - (offset.height / scale)
        
        let rawRect = CGRect(x: x, y: y, width: visibleWidth, height: visibleHeight)
        let normalized = CoordinateConverter.normalize(rect: rawRect, in: size)
        
        bufferManager.updateViewport(rect: normalized)
    }
    
    private func nextPage(geo: CGSize) {
        let isPortrait = geo.height > geo.width
        let isSpread = bufferManager.currentImage != nil && CGFloat(bufferManager.currentImage!.width) > CGFloat(bufferManager.currentImage!.height) * 1.2
        
        if isPortrait && isSpread && autoSplitPortraitSpreads {
            if splitHalf == 0 {
                splitHalf = 1
                return // Absorbed
            } else {
                splitHalf = 0
            }
        }
        
        let hopCount = (effectiveDoublePage && geo.width > geo.height) ? 2 : 1
        if currentPageIndex + hopCount < pages.count + (hopCount - 1) {
            Haptics.shared.playImpact(style: .light)
            currentPageIndex += hopCount
        }
    }
    
    private func prevPage(geo: CGSize) {
        let isPortrait = geo.height > geo.width
        let isSpread = bufferManager.currentImage != nil && CGFloat(bufferManager.currentImage!.width) > CGFloat(bufferManager.currentImage!.height) * 1.2
        
        if isPortrait && isSpread && autoSplitPortraitSpreads {
            if splitHalf == 1 {
                splitHalf = 0
                return // Absorbed
            } else {
                splitHalf = 1
            }
        }
        
        let hopCount = (effectiveDoublePage && geo.width > geo.height) ? 2 : 1
        if currentPageIndex > 0 {
            Haptics.shared.playImpact(style: .light)
            currentPageIndex = max(0, currentPageIndex - hopCount)
        }
    }
    
    // MARK: - Guided Reading Engine
    private func refreshGuidedPanels() {
        guard let pdfID = pdfID else { return }
        let model = PageModelStore.shared.getPageModel(for: pdfID, pageIndex: currentPageIndex)
        // Sort panels to read top-to-bottom, right-to-left if Manga, otherwise top-to-bottom, left-to-right
        self.guidedPanels = model.panels.sorted { a, b in
            // Tolerate minor Y alignment variations (e.g. 5% of height) to group rows
            if abs(a.origin.y - b.origin.y) > 50 {
                return a.origin.y < b.origin.y // top first
            } else {
                return isMangaMode ? (a.origin.x > b.origin.x) : (a.origin.x < b.origin.x)
            }
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
                // Must wait briefly for the new page buffer to render, or just pre-calculate
                refreshGuidedPanels()
                guidedPanelIndex = 0
                if guidedPanels.isEmpty { 
                    isGuidedReadingActive = false
                    updatePPL(in: geo)
                } else { 
                    withAnimation(.easeInOut(duration: 0.25)) {
                        bufferManager.lockedRect = guidedPanels[guidedPanelIndex] 
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
