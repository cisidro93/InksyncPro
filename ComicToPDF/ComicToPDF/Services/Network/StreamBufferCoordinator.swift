import Foundation

/// Actor to coordinate read-ahead buffering of book/comic pages streamed over network,
/// providing auto-retries, connection recovery, and memory-safe transient caching.
public actor StreamBufferCoordinator {
    
    public static let shared = StreamBufferCoordinator()
    
    private var buffer: [Int: Data] = [:]
    private var activeDownloads: [Int: Task<Data, Error>] = [:]
    private var maxBufferSize = 15 // Hold up to 15 pages in transient network buffer
    private let maxRetries = 4
    
    private init() {}
    
    /// Clears the current buffer and in-flight downloads.
    public func reset() {
        for task in activeDownloads.values {
            task.cancel()
        }
        activeDownloads.removeAll()
        buffer.removeAll()
        Logger.shared.log("StreamBufferCoordinator: Buffer reset.", category: "NetworkSync", type: .info)
    }
    
    /// Requests page data. If cached in buffer, returns instantly. Otherwise downloads with retry logic.
    public func getPageData(at index: Int, from url: URL) async throws -> Data {
        if let cached = buffer[index] {
            return cached
        }
        
        // If there's an active download task for this index, await it
        if let activeTask = activeDownloads[index] {
            return try await activeTask.value
        }
        
        // Create new download task
        let downloadTask = Task<Data, Error> {
            do {
                let data = try await fetchWithRetry(url: url, index: index)
                self.cacheData(index, data: data)
                return data
            } catch {
                self.clearActiveDownload(index)
                throw error
            }
        }
        
        activeDownloads[index] = downloadTask
        let result = try await downloadTask.value
        activeDownloads.removeValue(forKey: index)
        return result
    }
    
    /// Pre-fetches a list of indices in the background.
    public func prefetchPages(indices: [Int], urls: [Int: URL]) {
        for index in indices {
            guard let url = urls[index], buffer[index] == nil, activeDownloads[index] == nil else { continue }
            
            let prefetchTask = Task<Data, Error> {
                let data = try await fetchWithRetry(url: url, index: index)
                self.cacheData(index, data: data)
                return data
            }
            activeDownloads[index] = prefetchTask
        }
    }
    
    private func cacheData(_ index: Int, data: Data) {
        buffer[index] = data
        activeDownloads.removeValue(forKey: index)
        limitBufferSize(keepAround: index)
    }
    
    private func clearActiveDownload(_ index: Int) {
        activeDownloads.removeValue(forKey: index)
    }
    
    /// Fetches URL data with exponential backoff retry logic to handle temporary network drops.
    private func fetchWithRetry(url: URL, index: Int) async throws -> Data {
        var lastError: Error?
        var delayNanoseconds: UInt64 = 1_000_000_000 // Start with 1 second delay
        
        for attempt in 1...maxRetries {
            if Task.isCancelled {
                throw CancellationError()
            }
            
            do {
                Logger.shared.log("StreamBufferCoordinator: Downloading page \(index), attempt \(attempt)/\(maxRetries)", category: "NetworkSync", type: .info)
                
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                    let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                    throw NSError(domain: "StreamBufferError", code: code, userInfo: [NSLocalizedDescriptionKey: "HTTP invalid status code \(code)"])
                }
                
                Logger.shared.log("StreamBufferCoordinator: Successfully downloaded page \(index)", category: "NetworkSync", type: .success)
                return data
            } catch {
                lastError = error
                Logger.shared.log("StreamBufferCoordinator: Attempt \(attempt) failed for page \(index): \(error.localizedDescription)", category: "NetworkSync", type: .warning)
                
                if attempt < maxRetries {
                    // Exponential backoff wait (with a little jitter)
                    try await Task.sleep(nanoseconds: delayNanoseconds)
                    delayNanoseconds *= 2
                }
            }
        }
        
        throw lastError ?? NSError(domain: "StreamBufferError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to download after \(maxRetries) attempts"])
    }
    
    /// Prunes the buffer to keep memory footprints stable.
    private func limitBufferSize(keepAround index: Int) {
        if buffer.count <= maxBufferSize { return }
        
        let sortedKeys = buffer.keys.sorted {
            abs($0 - index) < abs($1 - index)
        }
        
        let keysToKeep = Set(sortedKeys.prefix(maxBufferSize))
        let keysToRemove = buffer.keys.filter { !keysToKeep.contains($0) }
        
        for key in keysToRemove {
            buffer.removeValue(forKey: key)
        }
        
        Logger.shared.log("StreamBufferCoordinator pruned network buffer. Cache size: \(buffer.count) pages.", category: "NetworkSync", type: .info)
    }
    
    /// Purge buffer under memory pressure warnings.
    public func purgeBuffer() {
        for task in activeDownloads.values {
            task.cancel()
        }
        activeDownloads.removeAll()
        buffer.removeAll()
        Logger.shared.log("StreamBufferCoordinator: Purged network buffer due to memory pressure.", category: "NetworkSync", type: .warning)
    }
}
