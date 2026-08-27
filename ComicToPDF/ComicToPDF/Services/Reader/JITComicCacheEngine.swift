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
    private var mipmapCache: [String: UIImage] = [:]
    private var activePreloadTasks: [String: Task<Void, Never>] = [:]
    
    private var currentTier: DeviceMemoryTier = .current
    private var isUnderMemoryPressure: Bool = false
    
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
        return memoryCache[key] ?? mipmapCache[key]
    }
    
    // MARK: - Internal Storage & Memory Eviction
    
    private func storeImage(_ image: UIImage, forKey key: String) {
        let maxLimit = isUnderMemoryPressure ? 2 : currentTier.maxFullResPages
        
        while memoryCache.count >= maxLimit {
            if let oldestKey = memoryCache.keys.first {
                memoryCache.removeValue(forKey: oldestKey)
            }
        }
        memoryCache[key] = image
        activePreloadTasks.removeValue(forKey: key)
    }
    
    private func storeMipmap(_ image: UIImage, forKey key: String) {
        if mipmapCache.count >= 16 {
            if let oldestKey = mipmapCache.keys.first {
                mipmapCache.removeValue(forKey: oldestKey)
            }
        }
        mipmapCache[key] = image
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
        Logger.shared.log("JITComicCacheEngine: Received memory warning. Dropping cache down to 2 active pages.", category: "Memory", type: .error)
        isUnderMemoryPressure = true
        
        // Cancel all in-flight prefetch tasks
        activePreloadTasks.values.forEach { $0.cancel() }
        activePreloadTasks.removeAll()
        
        // Purge mipmaps and clamp full-res cache
        mipmapCache.removeAll()
        while memoryCache.count > 2 {
            if let firstKey = memoryCache.keys.first {
                memoryCache.removeValue(forKey: firstKey)
            }
        }
        
        // Release streaming sessions
        Task {
            await ArchiveStreamEngine.shared.closeAllSessions()
        }
        
        // Restore normal governor behavior after 10 seconds
        Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            self.resetMemoryPressureFlag()
        }
    }
    
    private func resetMemoryPressureFlag() {
        self.isUnderMemoryPressure = false
    }
    
    public func clearCache() {
        memoryCache.removeAll()
        mipmapCache.removeAll()
        activePreloadTasks.values.forEach { $0.cancel() }
        activePreloadTasks.removeAll()
    }
}
