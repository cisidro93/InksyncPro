import Foundation
import UIKit
import Combine

/// A dedicated background worker that silently extracts and caches thumbnails
/// for massive external Linked Libraries, ensuring 0% impact on the Main Thread.
actor ThumbnailDaemon {
    static let shared = ThumbnailDaemon()
    
    private let cacheDirectory: URL
    private var isRunning = false
    
    // Bounded NSCache automatically evicts under memory pressure and sets strict byte/item ceilings.
    // Eliminates the unbounded dictionary heap bloat (+128MB) identified in the Apple IPS CPU resource diagnostic.
    private let memoryCache: NSCache<NSUUID, UIImage> = {
        let cache = NSCache<NSUUID, UIImage>()
        cache.totalCostLimit = 40 * 1024 * 1024 // 40 MB ceiling
        cache.countLimit = 150 // Max 150 covers in memory
        return cache
    }()
    
    private init() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        let cacheDir = appSupport.appendingPathComponent("ThumbnailCache", isDirectory: true)
        if !fm.fileExists(atPath: cacheDir.path) {
            try? fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            // Exclude cache directory from iCloud backups to comply with App Store Guideline 5.1.1
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            var mutableCacheDir = cacheDir
            try? mutableCacheDir.setResourceValues(resourceValues)
        }
        self.cacheDirectory = cacheDir

        // Listen to memory warnings to clear cache dynamically and protect low-end devices
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { _ in
            Task {
                await ThumbnailDaemon.shared.clearMemoryCache()
            }
        }
    }
    
    /// Starts a low-priority background crawl to extract missing thumbnails for a given list of PDFs.
    func startCrawling(pdfs: [ConvertedPDF]) {
        guard !isRunning else { return }
        
        // Guard against starting background extraction while device is under severe thermal stress
        if ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
            Logger.shared.log("ThumbnailDaemon: Skipping crawl due to thermal pressure (\(ProcessInfo.processInfo.thermalState.rawValue))", category: "System")
            return
        }
        
        isRunning = true
        
        Task.detached(priority: .background) { [weak self] in
            guard let self = self else { return }
            await self.processQueue(pdfs: pdfs)
        }
    }
    
    // Controlled background extraction capped at 2 concurrent tasks (or 1 under Low Power / Thermal Fair).
    // Prevents Apple Watchdog 50% CPU over 180s timeout while keeping disk I/O smooth.
    private func processQueue(pdfs: [ConvertedPDF]) async {
        let isLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        let isThermalConstrained = ProcessInfo.processInfo.thermalState != .nominal
        let maxConcurrency = (isLowPower || isThermalConstrained) ? 1 : 2

        // 1. Filter for PDFs missing disk thumbnails without decompressing existing images into RAM
        var missingPDFs: [ConvertedPDF] = []
        for pdf in pdfs {
            let cachedURL = cacheDirectory.appendingPathComponent("\(pdf.id.uuidString).webp")
            if FileManager.default.fileExists(atPath: cachedURL.path) {
                // Disk thumbnail already exists — do NOT load or decompress into RAM during scan
                continue
            } else if let coverData = pdf.coverImageData {
                // Deduplication: cover already extracted during file registration — persist to disk atomically
                try? coverData.write(to: cachedURL, options: .atomic)
            } else {
                missingPDFs.append(pdf)
            }
        }

        guard !missingPDFs.isEmpty else {
            isRunning = false
            return
        }

        // 2. Extract missing thumbnails using cooperative task group
        await withTaskGroup(of: Void.self) { group in
            var inFlight = 0
            var pending = missingPDFs.makeIterator()

            func enqueue() {
                // Abort further work if thermal state escalates to serious or critical
                if ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
                    return
                }

                guard let pdf = pending.next() else { return }
                let cachedURL = cacheDirectory.appendingPathComponent("\(pdf.id.uuidString).webp")

                group.addTask(priority: .background) {
                    await Task.yield()

                    // Resolve URL securely for Linked Libraries
                    let url: URL
                    var accessedURL: URL? = nil
                    if case .linked(let bm) = pdf.sourceMode,
                       let resolved = try? BookmarkResolver.shared.resolve(bm) {
                        let didAccess = resolved.startAccessingSecurityScopedResource()
                        url = resolved
                        if didAccess { accessedURL = resolved }
                    } else {
                        url = pdf.url
                    }

                    let thumbnailImage: UIImage? = autoreleasepool {
                        var rawImage = PhysicalFileSystemRouter.extractCoverImageStatic(from: url)
                        if rawImage == nil && url.pathExtension.lowercased() == "epub" {
                            rawImage = PhysicalFileSystemRouter.generateTypographicCover(title: pdf.name, author: pdf.metadata.author ?? "")
                        }
                        guard let image = rawImage else { return nil }
                        let thumbnail = image.preparingThumbnail(of: CGSize(width: 300, height: 450)) ?? image
                        if let data = thumbnail.jpegData(compressionQuality: 0.85) {
                            try? data.write(to: cachedURL, options: .atomic)
                            return thumbnail
                        }
                        return nil
                    }

                    if let thumbnail = thumbnailImage {
                        // Populate bounded in-memory cache
                        await ThumbnailDaemon.shared.cacheInMemory(thumbnail, for: pdf.id)
                    }

                    accessedURL?.stopAccessingSecurityScopedResource()
                }
                inFlight += 1
            }

            // Seed initial slots
            for _ in 0..<min(maxConcurrency, missingPDFs.count) { enqueue() }

            for await _ in group {
                inFlight -= 1
                enqueue() // refill slot cooperatively
            }
        }

        isRunning = false
    }

    /// Called to populate the bounded in-memory cache after a thumbnail is written or loaded.
    func cacheInMemory(_ image: UIImage, for pdfID: UUID) {
        let cost = Int(image.size.width * image.size.height * 4)
        memoryCache.setObject(image, forKey: pdfID as NSUUID, cost: cost)
    }

    /// Fetch a pre-cached thumbnail. Bounded O(1) in-memory lookup.
    /// Falls back to disk on-demand as library items scroll into view, warming NSCache.
    func getCachedThumbnail(for pdfID: UUID) -> UIImage? {
        // Fast path: in-memory hit
        if let cached = memoryCache.object(forKey: pdfID as NSUUID) { return cached }

        // On-demand disk load: load single image when scrolled into view and warm cache
        let cachedURL = cacheDirectory.appendingPathComponent("\(pdfID.uuidString).webp")
        guard FileManager.default.fileExists(atPath: cachedURL.path),
              let data = try? Data(contentsOf: cachedURL),
              let image = UIImage(data: data) else { return nil }
        cacheInMemory(image, for: pdfID)
        return image
    }
    
    /// Clear the cached thumbnail from memory and disk for a specific PDF.
    func clearCache(for pdfID: UUID) {
        memoryCache.removeObject(forKey: pdfID as NSUUID)
        let cachedURL = cacheDirectory.appendingPathComponent("\(pdfID.uuidString).webp")
        try? FileManager.default.removeItem(at: cachedURL)
    }

    /// Clear all thumbnails currently held in memory to reclaim system resources.
    func clearMemoryCache() {
        memoryCache.removeAllObjects()
        Logger.shared.log("ThumbnailDaemon: Purged in-memory cache due to memory pressure", category: "System")
    }
}
