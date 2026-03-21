import SwiftUI

struct PPLReaderView: View {
    let pages: [URL]
    @Binding var currentPageIndex: Int
    var onCenterTap: () -> Void
    @StateObject private var bufferManager = PageBufferManager.shared
    
    // High-Frequency Gesture Tracking
    @State private var scale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var dragOffset: CGSize = .zero
    
    var body: some View {
        GeometryReader { geo in
            ZStack {
                if bufferManager.isLoading && bufferManager.currentImage == nil {
                    ProgressView("Buffering Metal Canvas...")
                        .scaleEffect(1.2)
                } else {
                    MetalCanvasView(
                        image: bufferManager.currentImage,
                        lockedRect: bufferManager.lockedRect,
                        isPPLEnabled: bufferManager.isPPLEnabled
                    )
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
                                        nextPage(geo: geo.size)
                                    } else if val.translation.width > 60 {
                                        prevPage(geo: geo.size)
                                    }
                                }
                            }
                    )
                    // Zero-Latency Edge Tap Gestures
                    .onTapGesture { location in
                        if scale <= 1.0 {
                            let width = geo.size.width
                            if location.x < width * 0.3 {
                                prevPage(geo: geo.size)
                            } else if location.x > width * 0.7 {
                                nextPage(geo: geo.size)
                            } else {
                                onCenterTap()
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
            .background(Color.black)
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
        if currentPageIndex + 1 < pages.count {
            Haptics.shared.playImpact(style: .light)
            currentPageIndex += 1
        }
    }
    
    private func prevPage(geo: CGSize) {
        if currentPageIndex > 0 {
            Haptics.shared.playImpact(style: .light)
            currentPageIndex -= 1
        }
    }
}
