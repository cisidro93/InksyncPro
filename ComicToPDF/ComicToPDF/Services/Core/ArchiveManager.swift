import Foundation
import ZIPFoundation

/// Global actor-isolated manager to serialize access and reuse open file handles
/// for ZIP archives, preventing repetitive disk operations and CPU overhead.
public actor ArchiveManager {
    public static let shared = ArchiveManager()
    
    private var cachedArchive: Archive?
    private var cachedURL: URL?
    private var cachedEntries: [String: Entry] = [:]
    private var cachedSortedImagePaths: [String] = []
    
    private init() {}
    
    /// Returns the sorted list of image entry paths within a ZIP archive.
    /// Caches the result to avoid redundant directory traversal and sorting (performance optimization).
    public func getSortedImagePaths(for url: URL) throws -> [String] {
        if cachedURL == url && !cachedSortedImagePaths.isEmpty {
            return cachedSortedImagePaths
        }
        
        let (_, entries) = try getArchiveAndEntries(for: url)
        
        let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "gif", "heic"]
        let sortedPaths = entries.keys.filter { path in
            let name = (path as NSString).lastPathComponent
            guard !path.contains("__MACOSX"), !name.hasPrefix("._"), name != ".DS_Store", !path.hasSuffix("/") else { return false }
            let ext = (name as NSString).pathExtension.lowercased()
            return imageExtensions.contains(ext)
        }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        
        self.cachedSortedImagePaths = sortedPaths
        return sortedPaths
    }

    /// Extracts entry data for a given file path from a ZIP archive.
    /// Uses standard String path to look up the entry within the cached Archive.
    public func extractEntry(from url: URL, path: String) throws -> Data {
        try Task.checkCancellation()
        
        let (archive, entries) = try getArchiveAndEntries(for: url)
        guard let entry = entries[path] else {
            throw NSError(domain: "ArchiveManager", code: 404, userInfo: [NSLocalizedDescriptionKey: "Entry not found in archive: \(path)"])
        }
        
        try Task.checkCancellation()
        
        var data = Data()
        data.reserveCapacity(Int(entry.uncompressedSize))
        _ = try archive.extract(entry, bufferSize: 262144) { chunk in
            if Task.isCancelled {
                throw CancellationError()
            }
            data.append(chunk)
        }
        return data
    }
    
    private func getArchiveAndEntries(for url: URL) throws -> (Archive, [String: Entry]) {
        if let cached = cachedArchive, cachedURL == url {
            return (cached, cachedEntries)
        }
        
        // Close / clean up old cache
        cachedArchive = nil
        cachedURL = nil
        cachedEntries = [:]
        cachedSortedImagePaths = []
        
        let archive = try Archive(url: url, accessMode: .read, pathEncoding: .utf8)
        
        // Build O(1) dictionary mapping path -> Entry
        var entriesMap: [String: Entry] = [:]
        for entry in archive {
            entriesMap[entry.path] = entry
        }
        
        cachedArchive = archive
        cachedURL = url
        cachedEntries = entriesMap
        
        return (archive, entriesMap)
    }
    
    /// Clear active archive cache when reading session finishes
    public func clearCache() {
        cachedArchive = nil
        cachedURL = nil
        cachedEntries = [:]
        cachedSortedImagePaths = []
    }
}

