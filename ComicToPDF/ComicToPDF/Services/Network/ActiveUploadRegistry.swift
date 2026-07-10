import Foundation

/// A thread-safe registry to track files currently being written to by the WiFi server.
/// This prevents background tasks like the LibraryScanner from reading incomplete archives.
final class ActiveUploadRegistry: @unchecked Sendable {
    static let shared = ActiveUploadRegistry()
    
    private let lock = NSLock()
    private var activeURLs = Set<URL>()
    
    private init() {}
    
    /// Registers a URL as actively uploading.
    func register(_ url: URL) {
        lock.lock()
        activeURLs.insert(url.standardizedFileURL)
        lock.unlock()
    }
    
    /// Unregisters a URL when the upload is complete or failed.
    func unregister(_ url: URL) {
        lock.lock()
        activeURLs.remove(url.standardizedFileURL)
        lock.unlock()
    }
    
    /// Checks if a given URL is currently being uploaded.
    func isUploading(_ url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeURLs.contains(url.standardizedFileURL)
    }
}
