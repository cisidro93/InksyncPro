import Foundation

/// A thread-safe registry to track files currently being written to by the WiFi server.
/// This prevents background tasks like the LibraryScanner from reading incomplete archives.
///
/// Thread safety is managed using `NSLock`. Standardized and symlink-resolved URLs are used
/// to prevent sandbox-path mismatch issues (e.g. `/var/` vs `/private/var/` prefixes on iOS).
final class ActiveUploadRegistry: @unchecked Sendable {
    static let shared = ActiveUploadRegistry()
    
    private let lock = NSLock()
    private var activePaths = Set<String>()
    
    private init() {}
    
    /// Normalizes the URL by standardizing and resolving symlinks (crucial for iOS sandboxed container paths).
    private func normalizePath(_ url: URL) -> String {
        return url.standardizedFileURL.resolvingSymlinksInPath().path
    }
    
    /// Registers a URL path as actively uploading.
    func register(_ url: URL) {
        let path = normalizePath(url)
        lock.lock()
        activePaths.insert(path)
        lock.unlock()
    }
    
    /// Unregisters a URL path when the upload is complete or failed.
    func unregister(_ url: URL) {
        let path = normalizePath(url)
        lock.lock()
        activePaths.remove(path)
        lock.unlock()
    }
    
    /// Checks if a given URL path is currently being uploaded.
    func isUploading(_ url: URL) -> Bool {
        let path = normalizePath(url)
        lock.lock()
        defer { lock.unlock() }
        return activePaths.contains(path)
    }
    
    /// Flushes all registered URL paths. Called on server start/stop to guarantee no stale state.
    func clear() {
        lock.lock()
        activePaths.removeAll()
        lock.unlock()
    }
}
