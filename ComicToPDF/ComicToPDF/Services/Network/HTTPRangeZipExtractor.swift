import Foundation
import zlib

/// A specialized utility that streams individual files from a remote ZIP/CBZ archive
/// using HTTP Byte-Range requests, without downloading the entire archive.
class HTTPRangeZipExtractor {
    
    struct ZipEntry: Identifiable {
        let id = UUID()
        let name: String
        let uncompressedSize: Int
        let compressedSize: Int
        let offset: Int64
        let compressionMethod: Int
        let fileNameLength: Int
        let extraFieldLength: Int
    }
    
    let remoteURL: URL
    let authHeader: String?
    
    private(set) var entries: [ZipEntry] = []
    private var totalFileSize: Int64 = 0
    
    // MARK: - Caching & Prefetching
    private let chunkCache = NSCache<NSString, NSData>()
    private var inflightTasks: [String: Task<Data, Error>] = [:]
    
    init(url: URL, authHeader: String? = nil) {
        self.remoteURL = url
        self.authHeader = authHeader
    }
    
    /// Parses the ZIP architecture over the network.
    /// 1. HEAD request for file size.
    /// 2. Fetch the End of Central Directory (EOCD).
    /// 3. Fetch and parse the Central Directory.
    func prepare() async throws {
        // 1. Get file size
        var headReq = URLRequest(url: remoteURL)
        headReq.httpMethod = "HEAD"
        if let auth = authHeader { headReq.addValue(auth, forHTTPHeaderField: "Authorization") }
        
        let (_, response) = try await URLSession.shared.data(for: headReq)
        guard let httpResponse = response as? HTTPURLResponse,
              let contentLengthStr = httpResponse.allHeaderFields["Content-Length"] as? String,
              let contentLength = Int64(contentLengthStr) else {
            throw NSError(domain: "ZipExtractor", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not determine Content-Length"])
        }
        self.totalFileSize = contentLength
        
        // 2. Find EOCD
        // EOCD is near the end. Fetch last 65536 bytes (or less if file is small)
        let fetchSize = min(contentLength, 65536)
        let startByte = contentLength - fetchSize
        
        let eocdData = try await fetchRange(start: startByte, end: contentLength - 1)
        
        // Search backwards for EOCD signature 0x06054b50 (Little Endian: 50 4b 05 06)
        guard let eocdOffsetInChunk = findEOCDSignature(in: eocdData) else {
            throw NSError(domain: "ZipExtractor", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not find EOCD signature"])
        }
        
        // Parse EOCD to find Central Directory offset and size
        // CD Size is at offset 12 (4 bytes), CD Offset is at offset 16 (4 bytes)
        let cdSize = eocdData.extractUInt32(at: eocdOffsetInChunk + 12)
        let cdOffset = eocdData.extractUInt32(at: eocdOffsetInChunk + 16)
        
        // 3. Fetch Central Directory
        let cdData = try await fetchRange(start: Int64(cdOffset), end: Int64(cdOffset + cdSize - 1))
        
        // 4. Parse Central Directory
        self.entries = parseCentralDirectory(data: cdData)
    }
    
    func extractFile(named name: String) async throws -> Data {
        guard let entry = entries.first(where: { $0.name == name }) else {
            throw NSError(domain: "ZipExtractor", code: 404, userInfo: [NSLocalizedDescriptionKey: "File not found in archive"])
        }
        return try await extractFile(entry: entry)
    }
    
    func extractFile(entry: ZipEntry) async throws -> Data {
        let cacheKey = entry.name as NSString
        
        // 1. Check Cache
        if let cached = chunkCache.object(forKey: cacheKey) {
            return cached as Data
        }
        
        // 2. Check if already fetching
        if let existingTask = inflightTasks[entry.name] {
            return try await existingTask.value
        }
        
        // 3. Start new fetch
        let task = Task<Data, Error> {
            let data = try await performExtraction(entry: entry)
            chunkCache.setObject(data as NSData, forKey: cacheKey)
            inflightTasks[entry.name] = nil
            return data
        }
        inflightTasks[entry.name] = task
        return try await task.value
    }
    
    /// Pre-fetches entries into memory. Call this to mask network latency.
    func prefetch(entries: [ZipEntry]) {
        for entry in entries {
            let cacheKey = entry.name as NSString
            if chunkCache.object(forKey: cacheKey) == nil && inflightTasks[entry.name] == nil {
                let task = Task<Data, Error> {
                    let data = try await performExtraction(entry: entry)
                    chunkCache.setObject(data as NSData, forKey: cacheKey)
                    inflightTasks[entry.name] = nil
                    return data
                }
                inflightTasks[entry.name] = task
            }
        }
    }
    
    private func performExtraction(entry: ZipEntry) async throws -> Data {
        // Optimization: Fetch Local File Header + compressed payload in one go.
        // We assume extra fields won't exceed 1024 bytes (usually 0-32 bytes).
        let safeBuffer: Int64 = 1024
        let expectedFetchSize = 30 + Int64(entry.fileNameLength) + safeBuffer + Int64(entry.compressedSize)
        
        // Fetch chunk
        let chunkEnd = min(entry.offset + expectedFetchSize, totalFileSize - 1)
        let chunkData = try await fetchRange(start: entry.offset, end: chunkEnd)
        
        // Parse Local File Header
        // Signature: 0x04034b50
        guard chunkData.count >= 30, chunkData.extractUInt32(at: 0) == 0x04034b50 else {
            throw NSError(domain: "ZipExtractor", code: 5, userInfo: [NSLocalizedDescriptionKey: "Invalid Local File Header signature"])
        }
        
        let actualNameLength = Int(chunkData.extractUInt16(at: 26))
        let actualExtraLength = Int(chunkData.extractUInt16(at: 28))
        
        let payloadStart = 30 + actualNameLength + actualExtraLength
        
        if payloadStart + entry.compressedSize > chunkData.count {
            // Unlikely fallback: The extra fields were massive, our buffer wasn't enough.
            // We need to fetch the exact payload explicitly.
            let explicitStart = entry.offset + Int64(payloadStart)
            let explicitData = try await fetchRange(start: explicitStart, end: explicitStart + Int64(entry.compressedSize) - 1)
            return try decompress(data: explicitData, method: entry.compressionMethod, expectedSize: entry.uncompressedSize)
        }
        
        // Slice the payload out of our single chunk
        let payload = chunkData.subdata(in: payloadStart..<(payloadStart + entry.compressedSize))
        
        // Decompress
        return try decompress(data: payload, method: entry.compressionMethod, expectedSize: entry.uncompressedSize)
    }
    
    // MARK: - Private Binary Parsing
    
    private func fetchRange(start: Int64, end: Int64) async throws -> Data {
        var request = URLRequest(url: remoteURL)
        if let auth = authHeader { request.addValue(auth, forHTTPHeaderField: "Authorization") }
        request.addValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 || httpResponse.statusCode == 206 else {
            throw NSError(domain: "ZipExtractor", code: 3, userInfo: [NSLocalizedDescriptionKey: "HTTP Range request failed"])
        }
        return data
    }
    
    private func findEOCDSignature(in data: Data) -> Int? {
        // EOCD Signature: [0x50, 0x4B, 0x05, 0x06]
        let sig: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
        
        // Search backwards
        for i in stride(from: data.count - 4, through: 0, by: -1) {
            if data[i] == sig[0] && data[i+1] == sig[1] && data[i+2] == sig[2] && data[i+3] == sig[3] {
                return i
            }
        }
        return nil
    }
    
    private func parseCentralDirectory(data: Data) -> [ZipEntry] {
        var parsed: [ZipEntry] = []
        var offset = 0
        
        // CD Signature: 0x02014b50
        while offset + 46 <= data.count {
            let sig = data.extractUInt32(at: offset)
            if sig != 0x02014b50 { break } // End of Central Directory
            
            let compressionMethod = Int(data.extractUInt16(at: offset + 10))
            let compressedSize = Int(data.extractUInt32(at: offset + 20))
            let uncompressedSize = Int(data.extractUInt32(at: offset + 24))
            let nameLen = Int(data.extractUInt16(at: offset + 28))
            let extraLen = Int(data.extractUInt16(at: offset + 30))
            let commentLen = Int(data.extractUInt16(at: offset + 32))
            let localHeaderOffset = Int64(data.extractUInt32(at: offset + 42))
            
            // Extract Name
            let nameData = data.subdata(in: (offset + 46)..<(offset + 46 + nameLen))
            let name = String(data: nameData, encoding: .utf8) ?? String(data: nameData, encoding: .ascii) ?? "Unknown"
            
            parsed.append(ZipEntry(
                name: name,
                uncompressedSize: uncompressedSize,
                compressedSize: compressedSize,
                offset: localHeaderOffset,
                compressionMethod: compressionMethod,
                fileNameLength: nameLen,
                extraFieldLength: extraLen
            ))
            
            offset += 46 + nameLen + extraLen + commentLen
        }
        
        // Sort entries alphabetically so paging is correct
        return parsed.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    
    private func decompress(data: Data, method: Int, expectedSize: Int) throws -> Data {
        if method == 0 {
            // STORED (No compression)
            return data
        } else if method == 8 {
            // DEFLATED
            return try data.rawDeflateDecompressed(expectedSize: expectedSize)
        } else {
            throw NSError(domain: "ZipExtractor", code: 6, userInfo: [NSLocalizedDescriptionKey: "Unsupported compression method: \(method)"])
        }
    }
}

// MARK: - Data Binary Utilities

extension Data {
    fileprivate func extractUInt16(at offset: Int) -> UInt16 {
        return self.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self) }
    }
    
    fileprivate func extractUInt32(at offset: Int) -> UInt32 {
        return self.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
    }
}

// MARK: - Raw Deflate Decompression using zlib

extension Data {
    /// Decompresses raw deflate data (RFC 1951) lacking zlib headers.
    fileprivate func rawDeflateDecompressed(expectedSize: Int) throws -> Data {
        var stream = z_stream()
        // -15 enables raw deflate mode (no zlib wrapper)
        var status = inflateInit2_(&stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else {
            throw NSError(domain: "ZipExtractor", code: 7, userInfo: [NSLocalizedDescriptionKey: "Failed to initialize zlib inflate"])
        }
        defer { inflateEnd(&stream) }
        
        var output = Data(capacity: expectedSize)
        
        try self.withUnsafeBytes { inputPointer in
            guard let baseAddress = inputPointer.baseAddress else {
                throw NSError(domain: "ZipExtractor", code: 8, userInfo: [NSLocalizedDescriptionKey: "Invalid data pointer"])
            }
            
            // In Swift 6, bindMemory must be handled safely
            let boundPointer = baseAddress.assumingMemoryBound(to: UInt8.self)
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: boundPointer)
            stream.avail_in = uInt(self.count)
            
            let chunkSize = 32768
            let buffer = UnsafeMutablePointer<Bytef>.allocate(capacity: chunkSize)
            defer { buffer.deallocate() }
            
            repeat {
                stream.next_out = buffer
                stream.avail_out = uInt(chunkSize)
                
                status = inflate(&stream, Z_NO_FLUSH)
                
                let bytesDecoded = chunkSize - Int(stream.avail_out)
                if bytesDecoded > 0 {
                    output.append(buffer, count: bytesDecoded)
                }
            } while status == Z_OK
        }
        
        guard status == Z_STREAM_END || status == Z_OK else {
            throw NSError(domain: "ZipExtractor", code: 9, userInfo: [NSLocalizedDescriptionKey: "Failed to decompress data (zlib status: \(status))"])
        }
        
        return output
    }
}
