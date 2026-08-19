import Foundation
import UIKit
import ImageIO
import Compression
import Darwin
import ZIPFoundation

// MARK: - Streamed Image Entry Model

/// Represents a single image entry mapped within a streaming CBZ/ZIP archive.
public struct StreamedImageEntry: Sendable, Identifiable, Equatable {
    public var id: String { filename }
    public let filename: String
    public let localHeaderOffset: UInt64
    public let compressedSize: UInt64
    public let uncompressedSize: UInt64
    public let compressionMethod: UInt16 // 0 = Stored, 8 = Deflated
    
    public init(
        filename: String,
        localHeaderOffset: UInt64,
        compressedSize: UInt64,
        uncompressedSize: UInt64,
        compressionMethod: UInt16
    ) {
        self.filename = filename
        self.localHeaderOffset = localHeaderOffset
        self.compressedSize = compressedSize
        self.uncompressedSize = uncompressedSize
        self.compressionMethod = compressionMethod
    }
}

// MARK: - Memory-Mapped Archive Session

/// High-performance zero-copy archive stream reader utilizing POSIX `mmap` and `libcompression`.
/// Reads CBZ/ZIP archives directly from virtual memory without creating intermediate `/tmp` files.
public final class MemoryMappedArchiveSession: @unchecked Sendable {
    private let fd: Int32
    private let mappedPointer: UnsafeMutableRawPointer
    private let mappedLength: Int
    private let entries: [StreamedImageEntry]
    private var isClosed: Bool = false
    private let lock = NSLock()
    
    public var imageEntries: [StreamedImageEntry] { entries }
    public var entryCount: Int { entries.count }
    
    public init?(fileURL: URL) {
        let path = fileURL.path
        let fileDescriptor = open(path, O_RDONLY)
        guard fileDescriptor >= 0 else { return nil }
        
        var statBuf = stat()
        guard fstat(fileDescriptor, &statBuf) == 0, statBuf.st_size > 22 else {
            close(fileDescriptor)
            return nil
        }
        
        let length = Int(statBuf.st_size)
        guard let pointer = mmap(nil, length, PROT_READ, MAP_SHARED, fileDescriptor, 0),
              pointer != MAP_FAILED else {
            close(fileDescriptor)
            return nil
        }
        
        self.fd = fileDescriptor
        self.mappedPointer = pointer
        self.mappedLength = length
        
        // Parse ZIP Central Directory to build index
        self.entries = Self.parseCentralDirectory(pointer: pointer, length: length)
    }
    
    deinit {
        closeSession()
    }
    
    public func closeSession() {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        munmap(mappedPointer, mappedLength)
        close(fd)
        isClosed = true
    }
    
    // MARK: - On-Demand Image Decompression
    
    /// Decompresses a single page image directly into memory.
    public func decompressPageImage(at index: Int) -> UIImage? {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed, index >= 0, index < entries.count else { return nil }
        let entry = entries[index]
        
        var decodedImage: UIImage? = nil
        autoreleasepool {
            guard let decompressedData = decompressEntryData(entry: entry) else { return }
            guard let imageSource = CGImageSourceCreateWithData(decompressedData as CFData, nil),
                  let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else { return }
            decodedImage = UIImage(cgImage: cgImage)
        }
        return decodedImage
    }
    
    private func decompressEntryData(entry: StreamedImageEntry) -> Data? {
        guard entry.localHeaderOffset + 30 <= UInt64(mappedLength) else { return nil }
        
        let localHeaderPtr = mappedPointer.advanced(by: Int(entry.localHeaderOffset))
        
        // Verify Local File Header Signature 0x04034b50 (PK\x03\x04)
        let sig = localHeaderPtr.load(as: UInt32.self)
        guard sig == 0x04034b50 else { return nil }
        
        let nameLen = Int(localHeaderPtr.advanced(by: 26).load(as: UInt16.self))
        let extraLen = Int(localHeaderPtr.advanced(by: 28).load(as: UInt16.self))
        let dataOffset = Int(entry.localHeaderOffset) + 30 + nameLen + extraLen
        
        guard dataOffset + Int(entry.compressedSize) <= mappedLength else { return nil }
        let rawDataPtr = mappedPointer.advanced(by: dataOffset)
        
        if entry.compressionMethod == 0 {
            // Stored (no compression)
            return Data(bytes: rawDataPtr, count: Int(entry.uncompressedSize))
        } else if entry.compressionMethod == 8 {
            // Deflated (zlib compression)
            let uncompressedSize = Int(entry.uncompressedSize)
            guard uncompressedSize > 0 else { return nil }
            
            var destData = Data(count: uncompressedSize)
            let decodedBytes = destData.withUnsafeMutableBytes { (destBuffer: UnsafeMutableRawBufferPointer) -> Int in
                guard let destBase = destBuffer.baseAddress else { return 0 }
                return compression_decode_buffer(
                    destBase.assumingMemoryBound(to: UInt8.self),
                    uncompressedSize,
                    rawDataPtr.assumingMemoryBound(to: UInt8.self),
                    Int(entry.compressedSize),
                    nil,
                    COMPRESSION_ZLIB
                )
            }
            
            guard decodedBytes > 0 else { return nil }
            return destData
        }
        
        return nil
    }
    
    // MARK: - Central Directory Parser
    
    private static func parseCentralDirectory(pointer: UnsafeMutableRawPointer, length: Int) -> [StreamedImageEntry] {
        // Search backwards for End of Central Directory (EOCD) signature 0x06054b50 (PK\x05\x06)
        let maxCommentLength = 65535
        let searchStart = max(0, length - maxCommentLength - 22)
        var eocdOffset: Int? = nil
        
        for i in stride(from: length - 22, through: searchStart, by: -1) {
            let sig = pointer.advanced(by: i).load(as: UInt32.self)
            if sig == 0x06054b50 {
                eocdOffset = i
                break
            }
        }
        
        guard let eocdPos = eocdOffset else { return [] }
        let eocdPtr = pointer.advanced(by: eocdPos)
        
        let totalEntries = Int(eocdPtr.advanced(by: 10).load(as: UInt16.self))
        let cdOffset = Int(eocdPtr.advanced(by: 16).load(as: UInt32.self))
        
        guard cdOffset < length else { return [] }
        var currentCDPtr = pointer.advanced(by: cdOffset)
        var results: [StreamedImageEntry] = []
        
        for _ in 0..<totalEntries {
            let sig = currentCDPtr.load(as: UInt32.self)
            guard sig == 0x02014b50 else { break } // PK\x01\x02
            
            let method = currentCDPtr.advanced(by: 10).load(as: UInt16.self)
            let compSize = UInt64(currentCDPtr.advanced(by: 20).load(as: UInt32.self))
            let uncompSize = UInt64(currentCDPtr.advanced(by: 24).load(as: UInt32.self))
            let nameLen = Int(currentCDPtr.advanced(by: 28).load(as: UInt16.self))
            let extraLen = Int(currentCDPtr.advanced(by: 30).load(as: UInt16.self))
            let commentLen = Int(currentCDPtr.advanced(by: 32).load(as: UInt16.self))
            let localHeaderOffset = UInt64(currentCDPtr.advanced(by: 42).load(as: UInt32.self))
            
            let namePtr = currentCDPtr.advanced(by: 46)
            let filename = String(decoding: UnsafeBufferPointer(start: namePtr.assumingMemoryBound(to: UInt8.self), count: nameLen), as: UTF8.self)
            
            if isImageFile(filename) {
                results.append(
                    StreamedImageEntry(
                        filename: filename,
                        localHeaderOffset: localHeaderOffset,
                        compressedSize: compSize,
                        uncompressedSize: uncompSize,
                        compressionMethod: method
                    )
                )
            }
            
            currentCDPtr = currentCDPtr.advanced(by: 46 + nameLen + extraLen + commentLen)
        }
        
        // Natural alphabetical sort for consistent comic page ordering
        return results.sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
    }
    
    private static func isImageFile(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ["jpg", "jpeg", "png", "webp", "gif", "heic", "avif"].contains(ext)
    }
}

// MARK: - Global Archive Streaming Engine Actor

/// Actor managing active memory-mapped archive streaming sessions.
public actor ArchiveStreamEngine {
    public static let shared = ArchiveStreamEngine()
    
    private var activeSessions: [URL: MemoryMappedArchiveSession] = [:]
    
    public init() {}
    
    /// Opens or retrieves an existing memory-mapped session for a comic archive.
    public func openSession(for archiveURL: URL) -> MemoryMappedArchiveSession? {
        if let session = activeSessions[archiveURL] {
            return session
        }
        guard let session = MemoryMappedArchiveSession(fileURL: archiveURL) else { return nil }
        activeSessions[archiveURL] = session
        Logger.shared.log("ArchiveStreamEngine: Memory-mapped \(archiveURL.lastPathComponent) with \(session.entryCount) page entries", category: "Archive")
        return session
    }
    
    /// Closes and unmaps an active streaming session.
    public func closeSession(for archiveURL: URL) {
        if let session = activeSessions.removeValue(forKey: archiveURL) {
            session.closeSession()
            Logger.shared.log("ArchiveStreamEngine: Closed and unmapped session for \(archiveURL.lastPathComponent)", category: "Archive")
        }
    }
    
    /// Loads a page image from an archive session on demand.
    public func loadPageImage(archiveURL: URL, pageIndex: Int) -> UIImage? {
        guard let session = openSession(for: archiveURL) else { return nil }
        return session.decompressPageImage(at: pageIndex)
    }

    /// Releases all active memory mappings upon memory warnings or reader dismissals.
    public func closeAllSessions() {
        for (_, session) in activeSessions {
            session.closeSession()
        }
        activeSessions.removeAll()
    }
}

// MARK: - Safe Fallback Protocol Bridge

/// Unified abstraction protocol for comic archive page extraction and streaming.
public protocol ArchiveStreamingProtocol: Sendable {
    func extractPage(at index: Int) async throws -> CGImage
    func close() async
}

// MARK: - Verified Baseline Legacy Zip Fallback Engine

/// Fallback engine utilizing verified in-memory ZIPFoundation decompression.
public final class LegacyZipEngine: Sendable {
    public static let shared = LegacyZipEngine()
    
    public init() {}
    
    public func loadPageImage(archiveURL: URL, pageIndex: Int) async throws -> UIImage {
        guard let archive = try? ZIPFoundation.Archive(url: archiveURL, accessMode: .read, pathEncoding: .utf8) else {
            throw ArchiveStreamError.fileNotFound(archiveURL)
        }
        
        let imageExtensions = Set(["jpg", "jpeg", "png", "webp", "gif", "heic", "avif"])
        let entries = archive
            .filter { entry in
                entry.type != .directory && imageExtensions.contains((entry.path as NSString).pathExtension.lowercased())
            }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        
        guard pageIndex >= 0 && pageIndex < entries.count else {
            throw ArchiveStreamError.pageExtractionFailed(pageIndex)
        }
        
        let targetEntry = entries[pageIndex]
        var data = Data()
        _ = try archive.extract(targetEntry) { chunk in
            data.append(chunk)
        }
        
        guard let image = UIImage(data: data) else {
            throw ArchiveStreamError.cgImageConversionFailed
        }
        return image
    }
    
    public func extractPage(at index: Int, from archiveURL: URL) async throws -> CGImage {
        let image = try await loadPageImage(archiveURL: archiveURL, pageIndex: index)
        guard let cgImage = image.cgImage else {
            throw ArchiveStreamError.cgImageConversionFailed
        }
        return cgImage
    }
}

// MARK: - Safe Archive Stream Dispatcher

/// Dispatches comic page loading to zero-copy memory-mapped streaming or the verified legacy fallback engine.
public final class ArchiveStreamDispatcher: Sendable {
    public static let shared = ArchiveStreamDispatcher()
    
    public init() {}
    
    /// Loads a page image from an archive according to user preferences, falling back gracefully on error.
    public func loadPage(index: Int, from archiveURL: URL) async throws -> UIImage {
        let useZeroCopy = await MainActor.run { EBookPreferences.shared.useZeroCopyStreaming }
        
        if useZeroCopy {
            if let image = await ArchiveStreamEngine.shared.loadPageImage(archiveURL: archiveURL, pageIndex: index) {
                return image
            }
            Logger.shared.log("ArchiveStreamDispatcher: Zero-copy streaming failed for \(archiveURL.lastPathComponent) p.\(index); falling back to legacy engine", category: "Archive", type: .warning)
        }
        
        // Existing, verified baseline fallback
        return try await LegacyZipEngine.shared.loadPageImage(archiveURL: archiveURL, pageIndex: index)
    }
    
    /// Extracts a CGImage for low-level Metal or CoreGraphics pipelines.
    public func extractCGImage(at index: Int, from archiveURL: URL) async throws -> CGImage {
        let uiImage = try await loadPage(index: index, from: archiveURL)
        guard let cg = uiImage.cgImage else {
            throw ArchiveStreamError.cgImageConversionFailed
        }
        return cg
    }
}

public enum ArchiveStreamError: LocalizedError, Sendable {
    case fileNotFound(URL)
    case pageExtractionFailed(Int)
    case cgImageConversionFailed
    
    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let url):
            return "Archive file not found at \(url.path)."
        case .pageExtractionFailed(let index):
            return "Failed to extract page \(index) from archive."
        case .cgImageConversionFailed:
            return "Failed to convert decompressed page to CGImage."
        }
    }
}
