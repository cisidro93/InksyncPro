import Foundation
import ZIPFoundation

/// Global actor-isolated manager to serialize access and reuse open file handles
/// for ZIP archives, preventing repetitive disk operations and CPU overhead.
public actor ArchiveManager {
    public static let shared = ArchiveManager()
    
    private var cachedArchive: Archive?
    private var cachedURL: URL?
    
    private init() {}
    
    /// Extracts entry data for a given file path from a ZIP archive.
    /// Uses standard String path to look up the entry within the cached Archive.
    public func extractEntry(from url: URL, path: String) throws -> Data {
        let archive = try getArchive(for: url)
        guard let entry = archive[path] else {
            throw NSError(domain: "ArchiveManager", code: 404, userInfo: [NSLocalizedDescriptionKey: "Entry not found in archive: \(path)"])
        }
        var data = Data()
        _ = try archive.extract(entry, bufferSize: 32768) { chunk in
            data.append(chunk)
        }
        return data
    }
    
    private func getArchive(for url: URL) throws -> Archive {
        if let cached = cachedArchive, cachedURL == url {
            return cached
        }
        
        // Close / clean up old cache
        cachedArchive = nil
        cachedURL = nil
        
        let archive = try Archive(url: url, accessMode: .read, pathEncoding: .utf8)
        cachedArchive = archive
        cachedURL = url
        return archive
    }
    
    /// Clear active archive cache when reading session finishes
    public func clearCache() {
        cachedArchive = nil
        cachedURL = nil
    }
}
