import Foundation

// MARK: - ZipEntry
// Represents one file within a remote ZIP archive.
// Offset and size allow us to issue a single HTTP Range request for just that file's bytes.

struct ZipEntry {
    let name: String
    let offset: UInt64          // byte offset of the Local File Header in the remote file
    let compressedSize: UInt64
    let uncompressedSize: UInt64
    let compressionMethod: UInt16 // 0 = Stored, 8 = Deflate
    let crc32: UInt32

    /// True if this entry is an image we can render as a comic page.
    var isPageImage: Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return ["jpg", "jpeg", "png", "webp", "heic"].contains(ext)
            && !name.contains("__MACOSX")
            && !name.hasPrefix("._")
            && name != ".DS_Store"
    }
}

// MARK: - ZipManifest
// The full index of a remote ZIP file, built from just its Central Directory bytes.

struct ZipManifest {
    let sourceURL: URL
    let authHeader: String?     // nil for Dropbox (pre-auth URLs); bearer token for Google Drive
    let totalFileSize: UInt64
    let entries: [ZipEntry]

    /// Image entries sorted naturally (Finder order), ready for page rendering.
    var pageEntries: [ZipEntry] {
        entries
            .filter { $0.isPageImage }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

// MARK: - ZipCentralDirectory
// Fetches and parses the ZIP End-of-Central-Directory (EOCD) record plus Central Directory
// headers from a remote URL using a single HTTP byte-range request.
//
// Protocol:
//  1. HEAD request  → get Content-Length (total file size)
//  2. Range request → fetch last min(65_536, fileSize) bytes → find EOCD signature
//  3. Parse EOCD   → locate Central Directory offset + size
//  4. Range request → fetch Central Directory bytes
//  5. Parse each Central Directory File Header → build [ZipEntry]
//
// This is exactly how unzip, 7-zip, and every OPDS client reads ZIP files without
// downloading the entire archive.

enum ZipCentralDirectoryError: LocalizedError {
    case fileTooSmall
    case eocdNotFound
    case centralDirectoryFetchFailed
    case invalidCentralDirectory
    case unsupportedZip64

    var errorDescription: String? {
        switch self {
        case .fileTooSmall:           return "The remote archive is too small to be a valid ZIP file."
        case .eocdNotFound:           return "Could not locate the ZIP central directory. The file may be corrupted."
        case .centralDirectoryFetchFailed: return "Failed to download the ZIP file index from cloud storage."
        case .invalidCentralDirectory: return "The ZIP file index is malformed or uses an unsupported format."
        case .unsupportedZip64:       return "ZIP64 archives larger than 4 GB are not yet supported for streaming."
        }
    }
}

struct ZipCentralDirectory {

    // MARK: - Public API

    /// Fetch and parse the central directory of a remote ZIP file.
    /// - Parameters:
    ///   - url: The authenticated (or pre-authenticated) URL of the remote ZIP.
    ///   - authHeader: Optional `Authorization` header value (e.g. `Bearer <token>` for Google Drive).
    ///                 Pass `nil` for Dropbox temporary links which are already pre-authenticated.
    static func fetch(from url: URL, authHeader: String? = nil) async throws -> ZipManifest {

        // ── Step 1: Get total file size via Range bytes=0-0 GET ──────────────────
        // We use a single-byte Range request instead of HEAD because Dropbox CDN
        // edge nodes frequently reject HEAD on pre-signed download URLs with a
        // connection-reset ("network connection was lost"). A bytes=0-0 GET is
        // universally supported and the Content-Range response header gives us the
        // total file size: "bytes 0-0/<total>".
        var sizeRequest = URLRequest(url: url)
        if let auth = authHeader { sizeRequest.setValue(auth, forHTTPHeaderField: "Authorization") }
        sizeRequest.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        sizeRequest.timeoutInterval = 15

        let (_, sizeResponse) = try await URLSession.shared.data(for: sizeRequest)
        guard let http = sizeResponse as? HTTPURLResponse,
              http.statusCode == 206 || http.statusCode == 200 else {
            throw ZipCentralDirectoryError.fileTooSmall
        }

        // Content-Range format: "bytes 0-0/<total>" (206) or fall back to Content-Length (200).
        let totalSize: UInt64
        if let rangeHeader = http.value(forHTTPHeaderField: "Content-Range"),
           let slashIdx = rangeHeader.lastIndex(of: "/") {
            let sizeStr = String(rangeHeader[rangeHeader.index(after: slashIdx)...])
            guard let parsed = UInt64(sizeStr), parsed > 22 else {
                throw ZipCentralDirectoryError.fileTooSmall
            }
            totalSize = parsed
        } else if let lengthStr = http.value(forHTTPHeaderField: "Content-Length"),
                  let parsed = UInt64(lengthStr), parsed > 22 {
            totalSize = parsed
        } else {
            throw ZipCentralDirectoryError.fileTooSmall
        }

        // ── Step 2: Fetch the tail of the file to find the EOCD ──────────────────
        // The EOCD record is at least 22 bytes and at most 65,557 bytes from the end
        // (due to the optional ZIP comment). Fetching 65,536 bytes covers all cases.
        let tailSize: UInt64 = min(65_536, totalSize)
        let tailStart = totalSize - tailSize

        var tailRequest = URLRequest(url: url)
        if let auth = authHeader { tailRequest.setValue(auth, forHTTPHeaderField: "Authorization") }
        tailRequest.setValue("bytes=\(tailStart)-\(totalSize - 1)", forHTTPHeaderField: "Range")

        let (tailData, tailResponse) = try await URLSession.shared.data(for: tailRequest)
        guard let tailHTTP = tailResponse as? HTTPURLResponse,
              tailHTTP.statusCode == 206 || tailHTTP.statusCode == 200 else {
            throw ZipCentralDirectoryError.eocdNotFound
        }

        // ── Step 3: Locate EOCD signature (0x06054b50, little-endian) ────────────
        let eocdSignature: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
        guard let eocdOffset = findLastOccurrence(of: eocdSignature, in: tailData) else {
            throw ZipCentralDirectoryError.eocdNotFound
        }

        let eocdData = tailData.subdata(in: eocdOffset..<tailData.count)
        guard eocdData.count >= 22 else { throw ZipCentralDirectoryError.eocdNotFound }

        // EOCD layout (all little-endian):
        // Offset  Size  Field
        //  0       4    Signature (0x06054b50)
        //  4       2    Disk number
        //  6       2    Disk with central dir start
        //  8       2    Entries on this disk
        // 10       2    Total entries
        // 12       4    Central directory size (bytes)
        // 16       4    Central directory offset
        // 20       2    Comment length
        let cdSize   = readU32LE(eocdData, offset: 12)
        let cdOffset = readU32LE(eocdData, offset: 16)

        // Detect ZIP64 (values of 0xFFFFFFFF indicate ZIP64 extension records)
        if cdSize == 0xFFFFFFFF || cdOffset == 0xFFFFFFFF {
            throw ZipCentralDirectoryError.unsupportedZip64
        }

        // ── Step 4: Fetch the Central Directory bytes ─────────────────────────────
        var cdRequest = URLRequest(url: url)
        if let auth = authHeader { cdRequest.setValue(auth, forHTTPHeaderField: "Authorization") }
        cdRequest.setValue("bytes=\(cdOffset)-\(UInt64(cdOffset) + UInt64(cdSize) - 1)", forHTTPHeaderField: "Range")

        let (cdData, cdResponse) = try await URLSession.shared.data(for: cdRequest)
        guard let cdHTTP = cdResponse as? HTTPURLResponse,
              cdHTTP.statusCode == 206 || cdHTTP.statusCode == 200 else {
            throw ZipCentralDirectoryError.centralDirectoryFetchFailed
        }

        // ── Step 5: Parse Central Directory File Headers ──────────────────────────
        let entries = try parseCentralDirectory(cdData)

        Logger.shared.log(
            "ZipCentralDirectory: Parsed \(entries.count) entries from '\(url.lastPathComponent)' (\(totalSize / 1024)KB total, \(cdSize)B CD)",
            category: "Cloud"
        )

        return ZipManifest(
            sourceURL: url,
            authHeader: authHeader,
            totalFileSize: totalSize,
            entries: entries
        )
    }

    // MARK: - Range Byte Fetch

    /// Fetches the compressed bytes for a single ZipEntry and decompresses them in-memory.
    /// No disk writes — the decompressed data is returned as raw `Data`.
    static func fetchEntryData(entry: ZipEntry, manifest: ZipManifest) async throws -> Data {
        // The Local File Header precedes the compressed data.
        // Its size is: 30 bytes fixed + filename length + extra field length.
        // We fetch a small probe first to learn those lengths, then fetch the payload.

        // ── Probe: read the Local File Header (30 bytes fixed portion) ─────────
        let probeEnd = entry.offset + 29
        var probeRequest = URLRequest(url: manifest.sourceURL)
        if let auth = manifest.authHeader { probeRequest.setValue(auth, forHTTPHeaderField: "Authorization") }
        probeRequest.setValue("bytes=\(entry.offset)-\(probeEnd)", forHTTPHeaderField: "Range")

        let (probeData, _) = try await URLSession.shared.data(for: probeRequest)
        guard probeData.count >= 30 else { throw ZipCentralDirectoryError.invalidCentralDirectory }

        // Local File Header layout:
        // 0-3   Signature (0x04034b50)
        // 26-27 File name length
        // 28-29 Extra field length
        let nameLen  = UInt64(readU16LE(probeData, offset: 26))
        let extraLen = UInt64(readU16LE(probeData, offset: 28))
        let dataStart = entry.offset + 30 + nameLen + extraLen
        let dataEnd   = dataStart + entry.compressedSize - 1

        // ── Fetch compressed payload ─────────────────────────────────────────────
        var payloadRequest = URLRequest(url: manifest.sourceURL)
        if let auth = manifest.authHeader { payloadRequest.setValue(auth, forHTTPHeaderField: "Authorization") }
        payloadRequest.setValue("bytes=\(dataStart)-\(dataEnd)", forHTTPHeaderField: "Range")

        let (compressedData, payloadResponse) = try await URLSession.shared.data(for: payloadRequest)
        guard let payloadHTTP = payloadResponse as? HTTPURLResponse,
              payloadHTTP.statusCode == 206 || payloadHTTP.statusCode == 200 else {
            throw ZipCentralDirectoryError.centralDirectoryFetchFailed
        }

        // ── Decompress ───────────────────────────────────────────────────────────
        switch entry.compressionMethod {
        case 0: // Stored — raw bytes
            return compressedData
        case 8: // Deflate — decompress with zlib (raw deflate, no header)
            return try compressedData.rawDeflateDecompressed(expectedSize: Int(entry.uncompressedSize))
        default:
            // Unsupported compression — return compressed data and let UIImage try
            return compressedData
        }
    }

    // MARK: - Private Parsing Helpers

    private static func parseCentralDirectory(_ data: Data) throws -> [ZipEntry] {
        var entries: [ZipEntry] = []
        var pos = 0
        let cdSignature: [UInt8] = [0x50, 0x4B, 0x01, 0x02]

        while pos + 46 <= data.count {
            // Verify Central Directory File Header signature
            guard data[pos] == cdSignature[0],
                  data[pos+1] == cdSignature[1],
                  data[pos+2] == cdSignature[2],
                  data[pos+3] == cdSignature[3] else {
                break // End of valid entries
            }

            // Central Directory File Header layout:
            // 0-3    Signature
            // 28-29  File name length
            // 30-31  Extra field length
            // 32-33  File comment length
            // 42-45  Local file header offset
            // 20-23  Compressed size
            // 24-27  Uncompressed size
            // 10-11  Compression method
            // 16-19  CRC-32

            let compressionMethod = readU16LE(data, offset: pos + 10)
            let crc32             = readU32LE(data, offset: pos + 16)
            let compressedSize    = UInt64(readU32LE(data, offset: pos + 20))
            let uncompressedSize  = UInt64(readU32LE(data, offset: pos + 24))
            let nameLen           = Int(readU16LE(data, offset: pos + 28))
            let extraLen          = Int(readU16LE(data, offset: pos + 30))
            let commentLen        = Int(readU16LE(data, offset: pos + 32))
            let localHeaderOffset = UInt64(readU32LE(data, offset: pos + 42))

            let nameStart = pos + 46
            let nameEnd   = nameStart + nameLen
            guard nameEnd <= data.count else { break }

            let nameData = data.subdata(in: nameStart..<nameEnd)
            let name = String(data: nameData, encoding: .utf8)
                    ?? String(data: nameData, encoding: .isoLatin1)
                    ?? "unknown_\(entries.count)"

            // Skip directories
            if !name.hasSuffix("/") {
                entries.append(ZipEntry(
                    name: name,
                    offset: localHeaderOffset,
                    compressedSize: compressedSize,
                    uncompressedSize: uncompressedSize,
                    compressionMethod: compressionMethod,
                    crc32: crc32
                ))
            }

            pos += 46 + nameLen + extraLen + commentLen
        }

        return entries
    }

    /// Find last occurrence of `pattern` in `data`, searching backward.
    private static func findLastOccurrence(of pattern: [UInt8], in data: Data) -> Int? {
        let bytes = [UInt8](data)
        let pLen  = pattern.count
        guard bytes.count >= pLen else { return nil }

        for i in stride(from: bytes.count - pLen, through: 0, by: -1) {
            if bytes[i..<(i + pLen)].elementsEqual(pattern) { return i }
        }
        return nil
    }

    // MARK: - Little-Endian Readers

    private static func readU16LE(_ data: Data, offset: Int) -> UInt16 {
        guard offset + 1 < data.count else { return 0 }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readU32LE(_ data: Data, offset: Int) -> UInt32 {
        guard offset + 3 < data.count else { return 0 }
        return UInt32(data[offset])
             | UInt32(data[offset + 1]) << 8
             | UInt32(data[offset + 2]) << 16
             | UInt32(data[offset + 3]) << 24
    }
}
