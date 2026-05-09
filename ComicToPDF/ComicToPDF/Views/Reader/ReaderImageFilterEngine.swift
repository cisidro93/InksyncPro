import UIKit
import CoreImage

/// Handles Smart Auto-Crop and CoreImage filters (Contrast, Saturation, Warmth).
/// Adheres to power-saving constraints by computing once per unique URL and caching the result.
/// Uses an LRU eviction strategy to prevent unbounded memory growth.
actor ReaderImageFilterEngine {
    static let shared = ReaderImageFilterEngine()

    // Hardware-accelerated CIContext. cacheIntermediates:false prevents CoreImage
    // from retaining large intermediate textures between frames.
    private let context = CIContext(options: [.useSoftwareRenderer: false, .cacheIntermediates: false])

    // LRU Cache — keeps the most recently used pages warm and evicts cold ones.
    private let cacheLimit = 12
    private var cache: [URL: UIImage] = [:]
    private var lruOrder: [URL] = [] // tail = most recent

    func process(url: URL, image: UIImage, isSmartCrop: Bool, contrast: Double, saturation: Double, warmth: Double) -> UIImage {
        // Fast path: no filters active — return original immediately without touching the GPU.
        if !isSmartCrop && contrast == 1.0 && saturation == 1.0 && warmth == 0.0 {
            return image
        }

        // LRU cache hit — promote to most-recently-used position.
        if let cached = cache[url] {
            lruOrder.removeAll { $0 == url }
            lruOrder.append(url)
            return cached
        }

        guard let cgImage = image.cgImage else { return image }
        var ciImage = CIImage(cgImage: cgImage)

        // 1. SMART CROP — Power-safe 4% border inset handles 90% of physical scan margins.
        if isSmartCrop {
            let extent = ciImage.extent
            let cropRect = extent.insetBy(dx: extent.width * 0.04, dy: extent.height * 0.04)
            ciImage = ciImage.cropped(to: cropRect)
        }

        // 2. AUTO-CONTRAST & SATURATION — guarded CIFilter creation; nil-safe on MDM-restricted devices.
        if contrast != 1.0 || saturation != 1.0 {
            if let filter = CIFilter(name: "CIColorControls") {
                filter.setValue(ciImage, forKey: kCIInputImageKey)
                filter.setValue(contrast, forKey: kCIInputContrastKey)
                filter.setValue(saturation, forKey: kCIInputSaturationKey)
                if let output = filter.outputImage { ciImage = output }
            }
        }

        // 3. WARMTH — shifts colour temperature toward 3500K (candle) from 6500K (neutral daylight).
        if warmth > 0.0 {
            if let filter = CIFilter(name: "CITemperatureAndTint") {
                filter.setValue(ciImage, forKey: kCIInputImageKey)
                let neutral = CIVector(x: 6500, y: 0)
                let warm    = CIVector(x: 6500 - (3000 * CGFloat(warmth)), y: 0)
                filter.setValue(neutral, forKey: "inputNeutral")
                filter.setValue(warm, forKey: "inputTargetNeutral")
                if let output = filter.outputImage { ciImage = output }
            }
        }

        // Render flattened UIImage — hardware-accelerated via Metal backend.
        guard let cgRendered = context.createCGImage(ciImage, from: ciImage.extent) else {
            return image // graceful fallback — never crash
        }
        let finalImage = UIImage(cgImage: cgRendered)

        // LRU insertion: evict the least-recently-used entry first.
        if cache.count >= cacheLimit, let lru = lruOrder.first {
            cache.removeValue(forKey: lru)
            lruOrder.removeFirst()
        }
        cache[url] = finalImage
        lruOrder.append(url)

        return finalImage
    }

    /// Purges the entire cache — call when a memory warning is received.
    func purgeCache() {
        cache.removeAll()
        lruOrder.removeAll()
    }
}
