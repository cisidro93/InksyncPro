import Foundation
import UIKit
import CoreGraphics
import PDFKit
import ZIPFoundation

/// Background prefetch actor that manages predictive pre-rendering and caching of book/comic pages,
/// ensuring zero-latency page transitions and adaptive memory usage.
public actor PagePrefetchCoordinator {
    
    public enum DocumentType {
        case archive(url: URL, entries: [String])
        case files(urls: [URL])
        case pdf(url: URL)
    }
    
    private var docType: DocumentType?
    private var cachedPages: [Int: CGImage] = [:]
    private var prefetchTask: Task<Void, Never>?
    private var maxCacheCount = 8
    private var lastRequestedIndex = 0
    private var lastDirection = 1 // 1 for forward, -1 for backward
    
    public init() {}
    
    /// Configures the coordinator with a new document context. Clears the previous cache.
    public func configure(documentType: DocumentType) {
        prefetchTask?.cancel()
        prefetchTask = nil
        cachedPages.removeAll()
        self.docType = documentType
        self.lastRequestedIndex = 0
        self.lastDirection = 1
        Logger.shared.log("PagePrefetchCoordinator configured with new document context.", category: "Prefetch", type: .info)
    }
    
    /// Requests a page image. If cached, returns instantly. Otherwise, renders synchronously.
    /// Also triggers predictive prefetching for adjacent pages.
    public func getPage(at index: Int, targetSize: CGSize) async -> CGImage? {
        guard self.docType != nil else { return nil }
        
        // Update direction
        if index != lastRequestedIndex {
            lastDirection = index > lastRequestedIndex ? 1 : -1
            lastRequestedIndex = index
        }
        
        // Trigger predictive prefetch in background
        triggerPrefetch(around: index, direction: lastDirection, targetSize: targetSize)
        
        // Return from cache if available
        if let cached = cachedPages[index] {
            return cached
        }
        
        // Otherwise, render immediately on background thread
        let rendered = await renderPage(at: index, targetSize: targetSize)
        if let image = rendered {
            cachedPages[index] = image
            limitCacheSize(keepAround: index)
        }
        return rendered
    }
    
    /// Starts a background prefetch task for the expected reading window.
    private func triggerPrefetch(around index: Int, direction: Int, targetSize: CGSize) {
        prefetchTask?.cancel()
        
        prefetchTask = Task { [weak self] in
            guard let self = self else { return }
            
            // Define prefetch window based on reading direction
            // If moving forward (+1): prefetch index+1, index+2, index+3, and also hold index-1.
            // If moving backward (-1): prefetch index-1, index-2, index-3, and also hold index+1.
            var prefetchIndices: [Int] = []
            if direction >= 0 {
                prefetchIndices = [index + 1, index + 2, index + 3, index - 1]
            } else {
                prefetchIndices = [index - 1, index - 2, index - 3, index + 1]
            }
            
            // Filter invalid or already cached indices
            let indicesToLoad = await self.filterIndicesToLoad(prefetchIndices)
            
            for idx in indicesToLoad {
                if Task.isCancelled { break }
                
                let image = await self.renderPage(at: idx, targetSize: targetSize)
                if let img = image, !Task.isCancelled {
                    await self.cachePage(idx, image: img)
                }
            }
            
            if !Task.isCancelled {
                await self.limitCacheSize(keepAround: index)
            }
        }
    }
    
    private func filterIndicesToLoad(_ indices: [Int]) -> [Int] {
        return indices.filter { idx in
            guard idx >= 0 else { return false }
            
            // Check bounds based on document type
            switch docType {
            case .archive(_, let entries):
                if idx >= entries.count { return false }
            case .files(let urls):
                if idx >= urls.count { return false }
            case .pdf:
                // PDF page count is validated at render time via PDFRenderActor; always allow here.
                break
            case .none:
                return false
            }
            
            return cachedPages[idx] == nil
        }
    }
    
    private func cachePage(_ index: Int, image: CGImage) {
        cachedPages[index] = image
    }
    
    /// Renders a single page from the configured document context.
    private func renderPage(at index: Int, targetSize: CGSize) async -> CGImage? {
        guard let docType = self.docType, index >= 0 else { return nil }
        
        // Capture screen scale factor from main actor safely
        let scale = await MainActor.run { UIScreen.main.scale }
        
        switch docType {
        case .pdf(let url):
            // Load and render via the thread-safe PDFRenderActor
            let pageCount = await PDFRenderActor.shared.loadDocument(at: url)
            guard index < pageCount else { return nil }
            
            if let uiImage = await PDFRenderActor.shared.renderPage(at: index, scale: scale) {
                return uiImage.cgImage
            }
            return nil
            
        case .files(let urls):
            guard index < urls.count else { return nil }
            let url = urls[index]
            return await Task.detached(priority: .userInitiated) {
                var cgImage: CGImage? = nil
                autoreleasepool {
                    if let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
                        let maxDim = max(targetSize.width, targetSize.height) * scale
                        let options: [CFString: Any] = [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceThumbnailMaxPixelSize: Int(maxDim),
                            kCGImageSourceShouldCacheImmediately: true
                        ]
                        cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
                    }
                }
                return cgImage
            }.value
            
        case .archive(let url, let entries):
            guard index < entries.count else { return nil }
            let entryPath = entries[index]
            return await Task.detached(priority: .userInitiated) {
                var cgImage: CGImage? = nil
                autoreleasepool {
                    do {
                        // ZIPFoundation Archive operations
                        let archive = try ZIPFoundation.Archive(url: url, accessMode: .read)
                        guard let entry = archive[entryPath] else { return }
                        var data = Data()
                        _ = try archive.extract(entry) { chunk in
                            data.append(chunk)
                        }
                        
                        if let source = CGImageSourceCreateWithData(data as CFData, nil) {
                            let maxDim = max(targetSize.width, targetSize.height) * scale
                            let options: [CFString: Any] = [
                                kCGImageSourceCreateThumbnailFromImageAlways: true,
                                kCGImageSourceCreateThumbnailWithTransform: true,
                                kCGImageSourceThumbnailMaxPixelSize: Int(maxDim),
                                kCGImageSourceShouldCacheImmediately: true
                            ]
                            cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
                        }
                    } catch {
                        Logger.shared.log("Direct ZIP prefetch decompression failed for entry \(entryPath): \(error.localizedDescription)", category: "Prefetch", type: .error)
                    }
                }
                return cgImage
            }.value
        }
    }
    
    /// Limits the cache size by purging pages furthest from the current index.
    private func limitCacheSize(keepAround index: Int) {
        if cachedPages.count <= maxCacheCount { return }
        
        let sortedKeys = cachedPages.keys.sorted {
            abs($0 - index) < abs($1 - index)
        }
        
        // Keep the closest maxCacheCount pages, purge the rest
        let keysToKeep = Set(sortedKeys.prefix(maxCacheCount))
        let keysToRemove = cachedPages.keys.filter { !keysToKeep.contains($0) }
        
        for key in keysToRemove {
            cachedPages.removeValue(forKey: key)
        }
        
        Logger.shared.log("PagePrefetchCoordinator pruned cache. Current cache size: \(cachedPages.count) pages.", category: "Prefetch", type: .info)
    }
    
    /// Public API to purge the cache immediately under memory pressure.
    public func purgeCache() {
        prefetchTask?.cancel()
        prefetchTask = nil
        cachedPages.removeAll()
        Logger.shared.log("PagePrefetchCoordinator purged all cached pages due to memory pressure.", category: "Prefetch", type: .warning)
    }
}
