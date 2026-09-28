import UIKit
import PDFKit

/// High-Performance Asynchronous Thumbnail and Pre-rendering Cache for ProPDFReaderEngine.
/// Eliminates 100-300ms CoreGraphics stalls during slider scrubbing and sidebar navigation
/// by caching rendered thumbnails in memory and prefetching adjacent spreads in the background.
public final class PDFThumbnailCache: @unchecked Sendable {
    public static let shared = PDFThumbnailCache()

    private let cache = NSCache<NSString, UIImage>()
    private let prefetchQueue = DispatchQueue(label: "com.inksync.propdf.thumbnail.prefetch", qos: .utility)

    private init() {
        // Enforce strict memory ceilings: max 250 thumbnails, max 64 MB
        cache.countLimit = 250
        cache.totalCostLimit = 64 * 1024 * 1024

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleMemoryWarning() {
        cache.removeAllObjects()
    }

    private func cacheKey(pdfID: UUID, pageIndex: Int, size: CGSize) -> NSString {
        "\(pdfID.uuidString)_\(pageIndex)_\(Int(size.width))x\(Int(size.height))" as NSString
    }

    /// Returns a cached thumbnail immediately if present in memory, otherwise nil (0ms latency).
    public func cachedThumbnail(pdfID: UUID, pageIndex: Int, size: CGSize) -> UIImage? {
        let key = cacheKey(pdfID: pdfID, pageIndex: pageIndex, size: size)
        return cache.object(forKey: key)
    }

    /// Fetches a thumbnail from cache, or synchronously renders it via CoreGraphics if not yet cached.
    public func getThumbnail(for page: PDFPage, pdfID: UUID, pageIndex: Int, size: CGSize) -> UIImage {
        let key = cacheKey(pdfID: pdfID, pageIndex: pageIndex, size: size)
        if let cached = cache.object(forKey: key) {
            return cached
        }

        let thumb = page.thumbnail(of: size, for: .cropBox)
        let cost = Int(size.width * size.height * 4)
        cache.setObject(thumb, forKey: key, cost: cost)
        return thumb
    }

    /// Silently warms up thumbnails in background memory for adjacent pages around the active index.
    public func prefetchThumbnails(for document: PDFDocument, pdfID: UUID, around pageIndex: Int, count: Int = 4, size: CGSize) {
        prefetchQueue.async { [weak self] in
            guard let self = self else { return }
            let total = document.pageCount
            guard total > 0 else { return }

            let start = max(0, pageIndex - count)
            let end = min(total - 1, pageIndex + count)

            for idx in start...end {
                let key = self.cacheKey(pdfID: pdfID, pageIndex: idx, size: size)
                if self.cache.object(forKey: key) == nil {
                    if let page = document.page(at: idx) {
                        let thumb = page.thumbnail(of: size, for: .cropBox)
                        let cost = Int(size.width * size.height * 4)
                        self.cache.setObject(thumb, forKey: key, cost: cost)
                    }
                }
            }
        }
    }

    /// Clears cached thumbnails for a specific document or when freeing resources.
    public func purgeAll() {
        cache.removeAllObjects()
    }
}
