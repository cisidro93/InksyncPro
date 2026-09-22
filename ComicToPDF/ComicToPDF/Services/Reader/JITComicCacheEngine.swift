import Foundation
import UIKit

// MARK: - Device Hardware Memory Tier Profile

/// Hardware memory classification based on physical device RAM.
public enum DeviceMemoryTier: Sendable {
    case highPro      // > 6 GB RAM (M-Series iPad Pro 11"/13", M-Series Mac)
    case standardMid  // 3 GB - 6 GB RAM (A-Series iPad Air/Mini, iPhone 14/15/16 Pro)
    case lowMemory    // < 3 GB RAM (Standard iPad, Base iPhones)
    
    public static var current: DeviceMemoryTier {
        let ramBytes = ProcessInfo.processInfo.physicalMemory
        let ramGB = Double(ramBytes) / (1024.0 * 1024.0 * 1024.0)
        
        if ramGB >= 5.8 {
            return .highPro
        } else if ramGB >= 2.8 {
            return .standardMid
        } else {
            return .lowMemory
        }
    }
    
    public var maxFullResPages: Int {
        switch self {
        case .highPro:     return 20
        case .standardMid: return 8
        case .lowMemory:   return 4
        }
    }
    
    public var prefetchRadius: Int {
        switch self {
        case .highPro:     return 4
        case .standardMid: return 2
        case .lowMemory:   return 1
        }
    }
    
    public var generateMipmaps: Bool {
        switch self {
        case .highPro:     return false
        case .standardMid: return true
        case .lowMemory:   return true
        }
    }
}

// MARK: - Device-Aware RAM Cache Governor Actor

/// Actor-isolated Just-In-Time (JIT) comic stream cache governor.
/// Dynamically scales in-memory page budgets according to device RAM hardware tiers,
/// streams pages via `ArchiveStreamEngine`, and handles low-memory pressure purges.
public actor JITComicCacheEngine {
    public static let shared = JITComicCacheEngine()
    
    private var memoryCache: [String: UIImage] = [:]
    private var memoryAccessOrder: [String] = []
    private var mipmapCache: [String: UIImage] = [:]
    private var mipmapAccessOrder: [String] = []
    private var activePreloadTasks: [String: Task<Void, Never>] = [:]
    
    private var currentTier: DeviceMemoryTier = .current
    private var isUnderMemoryPressure: Bool = false
    private var memoryPressureResetTask: Task<Void, Never>? = nil
    
    public init() {
        // Listen for OS Memory Pressure Warnings via Swift async notifications sequence
        Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: UIApplication.didReceiveMemoryWarningNotification) {
                await self?.handleMemoryWarning()
            }
        }
    }
    
    // MARK: - Prefetch API
    
    /// Prefetches adjacent pages around the active page using memory tier budgets.
    public func prefetchAdjacentPages(archiveURL: URL, currentOffset: Int, totalPages: Int) {
        let radius = isUnderMemoryPressure ? 1 : currentTier.prefetchRadius
        var indicesToFetch: [Int] = []
        
        for offset in 1...radius {
            let next = currentOffset + offset
            let prev = currentOffset - offset
            if next < totalPages { indicesToFetch.append(next) }
            if prev >= 0 { indicesToFetch.append(prev) }
        }
        
        for index in indicesToFetch {
            let key = cacheKey(archiveURL: archiveURL, index: index)
            guard memoryCache[key] == nil && activePreloadTasks[key] == nil else { continue }
            
            let isDistant = abs(index - currentOffset) > 1
            let shouldGenerateMipmap = isDistant && currentTier.generateMipmaps
            
            let task = Task(priority: .utility) {
                if let image = await self.loadPageImage(archiveURL: archiveURL, pageIndex: index) {
                    if shouldGenerateMipmap {
                        let mipmap = await self.downscaleMipmap(image: image)
                        self.storeMipmap(mipmap, forKey: key)
                    } else {
                        self.storeImage(image, forKey: key)
                    }
                }
            }
            activePreloadTasks[key] = task
        }
    }
    
    /// Synchronously retrieves full-resolution image or mipmap from memory cache if available.
    public func cachedImage(archiveURL: URL, index: Int) -> UIImage? {
        let key = cacheKey(archiveURL: archiveURL, index: index)
        if let img = memoryCache[key] {
            touchKey(key, in: &memoryAccessOrder)
            return img
        }
        if let mip = mipmapCache[key] {
            touchKey(key, in: &mipmapAccessOrder)
            return mip
        }
        return nil
    }
    
    // MARK: - Internal Storage & Memory Eviction
    
    private func touchKey(_ key: String, in orderList: inout [String]) {
        if let idx = orderList.firstIndex(of: key) {
            orderList.remove(at: idx)
        }
        orderList.append(key)
    }
    
    private func storeImage(_ image: UIImage, forKey key: String) {
        let maxLimit = isUnderMemoryPressure ? 2 : currentTier.maxFullResPages
        
        touchKey(key, in: &memoryAccessOrder)
        memoryCache[key] = image
        
        // Strict LRU eviction: remove the oldest (least recently accessed) pages first
        while memoryCache.count > maxLimit {
            if let oldestKey = memoryAccessOrder.first {
                memoryAccessOrder.removeFirst()
                memoryCache.removeValue(forKey: oldestKey)
            } else {
                break
            }
        }
        activePreloadTasks.removeValue(forKey: key)
    }
    
    private func storeMipmap(_ image: UIImage, forKey key: String) {
        touchKey(key, in: &mipmapAccessOrder)
        mipmapCache[key] = image
        
        while mipmapCache.count > 16 {
            if let oldestKey = mipmapAccessOrder.first {
                mipmapAccessOrder.removeFirst()
                mipmapCache.removeValue(forKey: oldestKey)
            } else {
                break
            }
        }
        activePreloadTasks.removeValue(forKey: key)
    }
    
    private func loadPageImage(archiveURL: URL, pageIndex: Int) async -> UIImage? {
        // Stream directly from memory-mapped session
        if let session = await ArchiveStreamEngine.shared.openSession(for: archiveURL) {
            return session.decompressPageImage(at: pageIndex)
        }
        return nil
    }
    
    private func downscaleMipmap(image: UIImage) async -> UIImage {
        let targetSize = CGSize(width: image.size.width * 0.65, height: image.size.height * 0.65)
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }
    
    private func cacheKey(archiveURL: URL, index: Int) -> String {
        return "\(archiveURL.path)#page_\(index)"
    }
    
    // MARK: - Memory Pressure Lifecycle
    
    /// Responds to OS memory pressure by aggressively releasing non-essential caches.
    public func handleMemoryWarning() {
        Logger.shared.log("JITComicCacheEngine: OS memory pressure handled — clamped cache to 2 active pages.", category: "Memory", type: .info)
        isUnderMemoryPressure = true
        
        // Cancel all in-flight prefetch tasks
        activePreloadTasks.values.forEach { $0.cancel() }
        activePreloadTasks.removeAll()
        
        // Purge mipmaps and clamp full-res cache
        mipmapCache.removeAll()
        mipmapAccessOrder.removeAll()
        
        // LRU Eviction: drop oldest accessed pages, preserving the 2 most recently viewed
        while memoryCache.count > 2 {
            if let oldestKey = memoryAccessOrder.first {
                memoryAccessOrder.removeFirst()
                memoryCache.removeValue(forKey: oldestKey)
            } else {
                break
            }
        }
        
        // Release streaming sessions
        Task {
            await ArchiveStreamEngine.shared.closeAllSessions()
        }
        
        // Restore normal governor behavior after 10 seconds (canceling prior timer to prevent races)
        memoryPressureResetTask?.cancel()
        memoryPressureResetTask = Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled else { return }
            self.resetMemoryPressureFlag()
        }
    }

    /// Proactively purges volatile in-memory decompressed textures when the app is placed in background.
    public func handleBackgroundPurge() {
        Logger.shared.log("JITComicCacheEngine: Proactive jetsam defense — flushed background caches.", category: "Memory", type: .info)
        activePreloadTasks.values.forEach { $0.cancel() }
        activePreloadTasks.removeAll()
        mipmapCache.removeAll()
        mipmapAccessOrder.removeAll()
        memoryCache.removeAll()
        memoryAccessOrder.removeAll()
        memoryPressureResetTask?.cancel()
        memoryPressureResetTask = nil
        Task {
            await ArchiveStreamEngine.shared.closeAllSessions()
        }
    }
    
    private func resetMemoryPressureFlag() {
        self.isUnderMemoryPressure = false
    }
    
    public func clearCache() {
        memoryCache.removeAll()
        memoryAccessOrder.removeAll()
        mipmapCache.removeAll()
        mipmapAccessOrder.removeAll()
        activePreloadTasks.values.forEach { $0.cancel() }
        activePreloadTasks.removeAll()
    }
}
