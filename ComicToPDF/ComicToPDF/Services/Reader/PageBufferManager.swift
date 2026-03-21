import Foundation
import CoreGraphics
import CoreImage
import Combine
import ImageIO

@MainActor
class PageBufferManager: ObservableObject {
    static let shared = PageBufferManager()
    
    @Published var currentImage: CGImage?
    @Published var nextImage: CGImage?
    @Published var prevImage: CGImage?
    @Published var isLoading: Bool = false
    
    private var pageURLs: [URL] = []
    
    // Page Position Lock (PPL) State
    @Published var isPPLEnabled: Bool = false
    @Published var lockedRect: NormalizedRect = .full
    
    private var renderTask: Task<Void, Never>?
    
    func setup(pages: [URL]) {
        self.pageURLs = pages
        self.lockedRect = .full
        self.currentImage = nil
        self.nextImage = nil
        self.prevImage = nil
    }
    
    func updateViewport(rect: NormalizedRect) {
        // Debounce or directly update buffer bounds
        self.lockedRect = rect
    }
    
    func render(pageIndex: Int, bounds: CGSize) {
        renderTask?.cancel()
        
        renderTask = Task {
            self.isLoading = true
            
            // Concurrent render for maximum hardware utilization
            async let current = renderPage(at: pageIndex)
            async let next = (pageIndex + 1 < pageURLs.count) ? renderPage(at: pageIndex + 1) : nil
            async let prev = (pageIndex - 1 >= 0) ? renderPage(at: pageIndex - 1) : nil
            
            let (cImage, nImage, pImage) = await (current, next, prev)
            
            if Task.isCancelled { return }
            
            self.currentImage = cImage
            self.nextImage = nImage
            self.prevImage = pImage
            self.isLoading = false
        }
    }
    
    private func renderPage(at index: Int) async -> CGImage? {
        guard index >= 0 && index < pageURLs.count else { return nil }
        let url = pageURLs[index]
        
        // Detached hardware task for heavy lifting
        return await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            
            // If PPL is active, we crop directly out of the memory buffer to reduce Metal draw overdraw.
            // If not active, we return the full frame.
            // In a production PPL engine, if the lock is enabled, we math out the strict rect.
            // For now, we pass the massive full image down to Metal and let the GPU scale it flawlessly.
            return cgImage
        }.value
    }
}
