import Foundation

/// A thread-safe registry to track files currently being written to by the WiFi server.
/// This prevents background tasks like the LibraryScanner from reading incomplete archives.
///
/// Thread safety is managed using `NSLock`. Standardized and symlink-resolved URLs are used
/// to prevent sandbox-path mismatch issues (e.g. `/var/` vs `/private/var/` prefixes on iOS).
final class ActiveUploadRegistry: @unchecked Sendable {
    static let shared = ActiveUploadRegistry()
    
    private let lock = NSLock()
    private var activeURLs = Set<URL>()
    
    private init() {}
    
    /// Normalizes the URL by standardizing and resolving symlinks (crucial for iOS sandboxed container paths).
    private func normalize(_ url: URL) -> URL {
        return url.standardizedFileURL.resolvingSymlinksInPath()
    }
    
    /// Registers a URL as actively uploading.
    func register(_ url: URL) {
        let normalized = normalize(url)
        lock.lock()
        activeURLs.insert(normalized)
        lock.unlock()
    }
    
    /// Unregisters a URL when the upload is complete or failed.
    func unregister(_ url: URL) {
        let normalized = normalize(url)
        lock.lock()
        activeURLs.remove(normalized)
        lock.unlock()
    }
    
    /// Checks if a given URL is currently being uploaded.
    func isUploading(_ url: URL) -> Bool {
        let normalized = normalize(url)
        lock.lock()
        defer { lock.unlock() }
        return activeURLs.contains(normalized)
    }
    
    /// Flushes all registered URLs. Called on server start/stop to guarantee no stale state.
    func clear() {
        lock.lock()
        activeURLs.removeAll()
        lock.unlock()
    }
}
