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
    
    // ✅ Phase 1: Smart Margin Cropping
    var isAutoCropEnabled: Bool {
        UserDefaults.standard.bool(forKey: "isAutoCropEnabled")
    }
    
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
                  let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { 
                
                await MainActor.run {
                    Logger.shared.log("PageBufferManager: Failed to render page at index: \(index). Malformed Image Array or IO Failure.", category: "Engine", type: .error)
                }
                
                return nil 
            }
            
            // ✅ Phase 1: Smart Margin Cropping
            // Strips white bounding boxes off before pumping to the Metal engine, saving RAM and increasing visual real estate.
            let cropEnabled = await MainActor.run { return self.isAutoCropEnabled }
            if cropEnabled {
                return Self.autoCropMargins(from: cgImage)
            }
            
            return cgImage
        }.value
    }
    
    // ✅ Phase 1: Smart Margin Cropping Core Engine
    static func autoCropMargins(from image: CGImage) -> CGImage {
        // CoreImage has a native CITextImageGenerator or CIFilter meant to crop to bounding box, 
        // but an even faster way for comics is CIDetector or simply filtering to contrast boundaries.
        // `CIColorControls` + `CIAreaMinMax` can be slow. 
        // A direct Accelerate or vImage function is fastest, but CoreImage pipeline is acceptable for background tasks.
        
        // Fast path: use CoreImage to find the bounding box of non-border pixels.
        // We will look for edges using `CICrop` after extracting the foreground.
        let ciImage = CIImage(cgImage: image)
        
        let filter = CIFilter(name: "CIMaskToAlpha")!
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        
        // For white borders, we might need to invert first, but simply creating a bounding box based on the highest contrast gradient bounds is safer.
        // Actually, Apple's `isAutoCrop` could be implemented safely via Accelerate. Let's use a heuristic fixed percentage crop if complex analysis fails, OR simpler: we'll build a heuristic manual edge scan.
        
        guard let data = image.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return image }
        
        let width = image.width
        let height = image.height
        let bytesPerRow = image.bytesPerRow
        let bytesPerPixel = image.bitsPerPixel / 8
        
        if bytesPerPixel < 3 { return image } // unsupported format fallback
        
        let threshold: UInt8 = 245 // Almost white
        
        // Scan Top
        var top = 0
        outerTop: for y in 0..<height {
            let rowOffset = y * bytesPerRow
            for x in stride(from: 0, to: width, by: 10) { // sampling every 10px for speed
                let pixelOffset = rowOffset + (x * bytesPerPixel)
                let r = ptr[pixelOffset]
                let g = ptr[pixelOffset + 1]
                let b = ptr[pixelOffset + 2]
                if r < threshold || g < threshold || b < threshold { break outerTop }
            }
            top = y
        }
        
        // Scan Bottom
        var bottom = height - 1
        outerBottom: for y in stride(from: height - 1, through: 0, by: -1) {
            let rowOffset = y * bytesPerRow
            for x in stride(from: 0, to: width, by: 10) {
                let pixelOffset = rowOffset + (x * bytesPerPixel)
                let r = ptr[pixelOffset]
                let g = ptr[pixelOffset + 1]
                let b = ptr[pixelOffset + 2]
                if r < threshold || g < threshold || b < threshold { break outerBottom }
            }
            bottom = y
        }
        
        // Scan Left
        var left = 0
        outerLeft: for x in 0..<width {
            for y in stride(from: top, to: bottom, by: 10) {
                let pixelOffset = (y * bytesPerRow) + (x * bytesPerPixel)
                let r = ptr[pixelOffset]
                let g = ptr[pixelOffset + 1]
                let b = ptr[pixelOffset + 2]
                if r < threshold || g < threshold || b < threshold { break outerLeft }
            }
            left = x
        }
        
        // Scan Right
        var right = width - 1
        outerRight: for x in stride(from: width - 1, through: 0, by: -1) {
            for y in stride(from: top, to: bottom, by: 10) {
                let pixelOffset = (y * bytesPerRow) + (x * bytesPerPixel)
                let r = ptr[pixelOffset]
                let g = ptr[pixelOffset + 1]
                let b = ptr[pixelOffset + 2]
                if r < threshold || g < threshold || b < threshold { break outerRight }
            }
            right = x
        }
        
        // Add a 10px padding buffer back to prevent clipping artwork exactly on the line
        let padding = 10
        top = max(0, top - padding)
        bottom = min(height - 1, bottom + padding)
        left = max(0, left - padding)
        right = min(width - 1, right + padding)
        
        let cropRect = CGRect(x: left, y: top, width: right - left, height: bottom - top)
        
        // Safety check to ensure we didn't just crop the entire page
        if cropRect.width < CGFloat(width) * 0.3 || cropRect.height < CGFloat(height) * 0.3 {
            return image
        }
        
        return image.cropping(to: cropRect) ?? image
    }
}
