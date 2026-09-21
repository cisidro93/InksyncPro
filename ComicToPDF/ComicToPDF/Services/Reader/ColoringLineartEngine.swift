import UIKit
import PDFKit
import CoreImage
import CoreGraphics

// MARK: - ColoringLineartEngine

/// High-performance GPU-accelerated transparent lineart extraction service.
/// Transforms a PDFPage or raster coloring page into a transparent lineart mask:
/// - White paper background becomes 100% transparent (`alpha = 0.0`).
/// - Black contour lines remain 100% opaque black (`alpha = 1.0`).
/// - Grayscale edge pixels retain smooth antialiasing.
/// This allows Apple Pencil drawing layers underneath to show through vibrantly,
/// while original black lines remain crisp and visible on top at all times.
public actor ColoringLineartEngine {
    public static let shared = ColoringLineartEngine()

    private let cache = NSCache<NSString, UIImage>()
    private let ciContext: CIContext

    private init() {
        // Use Metal-accelerated GPU context for sub-millisecond filtering
        self.ciContext = CIContext(options: [
            .useSoftwareRenderer: false,
            .priorityRequestLow: false
        ])
        cache.countLimit = 30
        cache.totalCostLimit = 64 * 1024 * 1024 // 64 MB
        
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { _ in
            Task {
                await ColoringLineartEngine.shared.clearCache()
            }
        }
        
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: nil
        ) { _ in
            Task {
                await ColoringLineartEngine.shared.clearCache()
            }
        }
    }

    /// Extracts a transparent lineart mask from a PDFPage at the specified target size.
    public func extractLineartMask(
        for page: PDFPage,
        pageIndex: Int,
        pdfID: UUID?,
        targetSize: CGSize,
        scale: CGFloat = 2.0
    ) async -> UIImage? {
        guard targetSize.width > 1 && targetSize.height > 1 else { return nil }

        let cacheKey = "\(pdfID?.uuidString ?? "doc")_\(pageIndex)_\(Int(targetSize.width))x\(Int(targetSize.height))" as NSString
        if let cached = cache.object(forKey: cacheKey) {
            return cached
        }

        let renderWidth = max(1, Int(targetSize.width * scale))
        let renderHeight = max(1, Int(targetSize.height * scale))
        let renderSize = CGSize(width: renderWidth, height: renderHeight)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(size: renderSize, format: format)
        let rawPageImage = renderer.image { ctx in
            let cgContext = ctx.cgContext
            cgContext.setFillColor(UIColor.white.cgColor)
            cgContext.fill(CGRect(origin: .zero, size: renderSize))

            cgContext.saveGState()
            // PDF coordinate system is flipped vertically relative to UIKit
            cgContext.translateBy(x: 0, y: CGFloat(renderHeight))
            cgContext.scaleBy(x: CGFloat(renderWidth) / page.bounds(for: .cropBox).width,
                              y: -CGFloat(renderHeight) / page.bounds(for: .cropBox).height)
            page.draw(with: .cropBox, to: cgContext)
            cgContext.restoreGState()
        }

        guard let cgImage = rawPageImage.cgImage else { return nil }
        let ciImage = CIImage(cgImage: cgImage)

        // CIColorMatrix: map luminance into alpha, and set RGB to 0 (black)
        // Output R = 0
        // Output G = 0
        // Output B = 0
        // Output A = 1.0 - (0.299 * R + 0.587 * G + 0.114 * B)
        let colorMatrix = CIFilter(name: "CIColorMatrix")
        colorMatrix?.setValue(ciImage, forKey: kCIInputImageKey)
        colorMatrix?.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputRVector")
        colorMatrix?.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputGVector")
        colorMatrix?.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputBVector")
        colorMatrix?.setValue(CIVector(x: -0.299, y: -0.587, z: -0.114, w: 0), forKey: "inputAVector")
        colorMatrix?.setValue(CIVector(x: 0, y: 0, z: 0, w: 1.0), forKey: "inputBiasVector")

        guard let outputCI = colorMatrix?.outputImage,
              let processedCG = ciContext.createCGImage(outputCI, from: outputCI.extent) else {
            return nil
        }

        let maskImage = UIImage(cgImage: processedCG, scale: scale, orientation: .up)
        cache.setObject(maskImage, forKey: cacheKey)
        return maskImage
    }

    /// Convenience method extracting lineart mask directly from a PDFPage using its cropBox dimensions
    public func lineartMask(for page: PDFPage) async -> UIImage? {
        guard let doc = page.document else { return nil }
        let index = doc.index(for: page)
        let bounds = page.bounds(for: .cropBox)
        guard bounds.width > 1 && bounds.height > 1 else { return nil }
        let pdfID = (doc.documentURL != nil) ? UUID(uuidString: doc.documentURL!.lastPathComponent) : nil
        return await extractLineartMask(for: page, pageIndex: index, pdfID: pdfID, targetSize: bounds.size)
    }

    /// Clears lineart memory cache when low memory warning occurs or document closes
    public func clearCache() {
        cache.removeAllObjects()
    }
}
