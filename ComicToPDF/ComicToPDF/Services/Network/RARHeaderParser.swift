import Foundation

// MARK: - RAREntry
// Represents one file within a remote RAR archive's sequential header region.

struct RAREntry {
    let name: String
    let dataOffset: UInt64     // Byte offset of compressed data in the archive
    let packedSize: UInt64     // Compressed size on disk
    let unpackedSize: UInt64   // Original size (what we'll get after decompress)
    let method: UInt8          // Compression method: 0x30 = store (no compress)
    let isStored: Bool         // True when method == 0x30 (safe for direct byte-range)

    var isPageImage: Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return ["jpg", "jpeg", "png", "webp"].contains(ext)
            && !name.hasPrefix("._")
            && name != ".DS_Store"
    }
}

// MARK: - RARHeaderParser
// Fetches the first ~32KB of a remote RAR file and parses RAR4 / RAR5 block headers
// to locate the first image entry. If that entry is stored (method 0x30), we can
// fetch its raw bytes with a single additional range request.
//
// RAR4 format (most CBR files):
//   Signature: 52 61 72 21 1A 07 00
//   Archive header: crc(2) + type(1) + flags(2) + size(2)
//   File block:     crc(2) + type(0x74)(1) + flags(2) + packed(4) + unpacked(4) +
//                   os(1) + fileCRC(4) + date(4) + rarVer(1) + method(1) + nameLen(2) +
//                   attrs(4) [+ high packed(4) + high unpacked(4)] + name + data
//
// RAR5 format (newer files):
//   Signature: 52 61 72 21 1A 07 01 00
//   Uses vint (variable-length integer) encoding.

enum RARParseError: LocalizedError {
    case notRar
    case noImageFound
    case compressedEntryUnsupported
    case fetchFailed

    var errorDescription: String? {
        switch self {
        case .notRar:                     return "File is not a valid RAR archive."
        case .noImageFound:               return "No image file found in the RAR archive header region."
        case .compressedEntryUnsupported: return "First image is compressed — cannot extract without full decompressor."
        case .fetchFailed:                return "Failed to fetch RAR header bytes from remote URL."
        }
    }
}

struct RARHeaderParser {

    // MARK: - Public API

    /// Fetches the first 32KB of a remote RAR file and returns the first stored image entry.
    /// - Parameters:
    ///   - url: Authenticated (pre-signed) direct download URL for the CBR file.
    ///   - authHeader: Optional Bearer token (nil for Dropbox temporary links).
    static func fetchFirstEntry(from url: URL, authHeader: String? = nil) async throws -> RAREntry {
        let fetchSize: UInt64 = 65_536   // 64KB — enough for all file headers in typical CBR

        var request = URLRequest(url: url)
        if let auth = authHeader { request.setValue(auth, forHTTPHeaderField: "Authorization") }
        request.setValue("bytes=0-\(fetchSize - 1)", forHTTPHeaderField: "Range")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 206 || http.statusCode == 200 else {
            throw RARParseError.fetchFailed
        }

        return try parseFirstImageEntry(from: data, baseOffset: 0)
    }

    /// Fetches the raw bytes of an already-located stored RAREntry.
    static func fetchEntryData(entry: RAREntry, from url: URL, authHeader: String? = nil) async throws -> Data {
        guard entry.isStored else { throw RARParseError.compressedEntryUnsupported }

        let end = entry.dataOffset + entry.packedSize - 1
        var request = URLRequest(url: url)
        if let auth = authHeader { request.setValue(auth, forHTTPHeaderField: "Authorization") }
        request.setValue("bytes=\(entry.dataOffset)-\(end)", forHTTPHeaderField: "Range")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 206 || http.statusCode == 200 else {
            throw RARParseError.fetchFailed
        }
        return data
    }

    // MARK: - Parser

    private static func parseFirstImageEntry(from data: Data, baseOffset: UInt64) throws -> RAREntry {
        let bytes = [UInt8](data)

        // ── Detect RAR format ────────────────────────────────────────────────────
        let rar4Sig: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00]
        let rar5Sig: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00]

        if bytes.count >= 8 && Array(bytes[0..<8]) == rar5Sig {
            return try parseRAR5(bytes: bytes, baseOffset: baseOffset)
        } else if bytes.count >= 7 && Array(bytes[0..<7]) == rar4Sig {
            return try parseRAR4(bytes: bytes, baseOffset: baseOffset)
        } else {
            throw RARParseError.notRar
        }
    }

    // MARK: - RAR4 Parser

    private static func parseRAR4(bytes: [UInt8], baseOffset: UInt64) throws -> RAREntry {
        var offset = 7  // skip signature

        while offset + 7 < bytes.count {
            // Block header: CRC(2) Type(1) Flags(2) Size(2)
            let blockType = bytes[offset + 2]
            let flags = readU16LE(bytes, offset: offset + 3)
            let blockSize = Int(readU16LE(bytes, offset: offset + 5))

            guard blockSize >= 7 else { break }

            if blockType == 0x74 {  // File header block
                // File block: after the 7-byte base header:
                // packed(4) unpacked(4) OS(1) fileCRC(4) date(4) version(1) method(1) nameLen(2) attrs(4)
                guard offset + 32 < bytes.count else { break }

                let packed   = UInt64(readU32LE(bytes, offset: offset + 7))
                let unpacked = UInt64(readU32LE(bytes, offset: offset + 11))
                let method   = bytes[offset + 23]
                let nameLen  = Int(readU16LE(bytes, offset: offset + 25))

                // HIGH size words if flag 0x100 is set
                var highPacked: UInt64 = 0
                var highUnpacked: UInt64 = 0
                var headerExtra = 0
                if flags & 0x100 != 0 {
                    highPacked   = UInt64(readU32LE(bytes, offset: offset + 7 + 20 + 4))
                    highUnpacked = UInt64(readU32LE(bytes, offset: offset + 7 + 20 + 8))
                    headerExtra  = 8
                }

                let nameStart = offset + 32 + headerExtra
                guard nameStart + nameLen <= bytes.count else { break }

                let nameBytes = Array(bytes[nameStart..<nameStart + nameLen])
                let name = String(bytes: nameBytes, encoding: .utf8)
                    ?? String(bytes: nameBytes, encoding: .isoLatin1)
                    ?? ""

                let finalPacked   = (highPacked   << 32) | packed
                let finalUnpacked = (highUnpacked << 32) | unpacked
                // dataOffset = absolute byte position in the archive where this
                // file's data begins (immediately after the variable-length name).
                // nameStart is already relative to the start of `bytes` which begins
                // at baseOffset=0 for a local fetch, so the absolute offset is
                // baseOffset + nameStart + nameLen.
                let dataOffset = baseOffset + UInt64(nameStart + nameLen)

                let entry = RAREntry(
                    name: name,
                    dataOffset: dataOffset,
                    packedSize: finalPacked,
                    unpackedSize: finalUnpacked,
                    method: method,
                    isStored: method == 0x30  // 0x30 = store, no compression
                )

                if entry.isPageImage {
                    return entry
                }

                // Advance past this block: header bytes + packed data bytes.
                // blockSize covers only the header (up to and including the name),
                // so the packed data is additive.
                offset += blockSize + Int(finalPacked)
            } else {
                // Skip non-file block
                offset += blockSize
            }
        }

        throw RARParseError.noImageFound
    }

    // MARK: - RAR5 Parser

    private static func parseRAR5(bytes: [UInt8], baseOffset: UInt64) throws -> RAREntry {
        var offset = 8  // skip 8-byte signature

        while offset + 4 < bytes.count {
            // RAR5 block structure:
            // HeaderCRC32(4) + HeaderSize(vint) + HeaderType(vint) + HeaderFlags(vint) + [ExtraData] + [DataSize(vint)]
            let headerCRCEnd = offset + 4
            guard headerCRCEnd < bytes.count else { break }

            var pos = headerCRCEnd
            guard let (headerSize, s1) = readVInt(bytes, at: pos), s1 > 0 else { break }
            pos += s1

            guard let (headerType, s2) = readVInt(bytes, at: pos), s2 > 0 else { break }
            pos += s2

            guard let (headerFlags, s3) = readVInt(bytes, at: pos), s3 > 0 else { break }
            pos += s3

            let blockEnd = headerCRCEnd + Int(headerSize)

            // HTYPE_FILE = 2
            if headerType == 2 {
                // File header: FileFlags(vint) + UnpackedSize(vint) + Attributes(vint) +
                //              [mtime(4)] + [DataCRC32(4)] + CompressionInfo(vint) + HostOS(vint) + NameLen(vint) + Name
                var fpos = pos

                guard let (fileFlags,  sf) = readVInt(bytes, at: fpos), sf > 0 else { break }
                fpos += sf

                guard let (unpackedSize, su) = readVInt(bytes, at: fpos), su > 0 else { break }
                fpos += su

                guard let (_, sa) = readVInt(bytes, at: fpos), sa > 0 else { break } // attrs
                fpos += sa

                if fileFlags & 0x0002 != 0 { fpos += 4 }  // mtime present
                if fileFlags & 0x0004 != 0 { fpos += 4 }  // CRC32 present

                guard let (compressionInfo, sc) = readVInt(bytes, at: fpos), sc > 0 else { break }
                fpos += sc

                guard let (_, so) = readVInt(bytes, at: fpos), so > 0 else { break } // hostOS
                fpos += so

                guard let (nameLen, sn) = readVInt(bytes, at: fpos), sn > 0 else { break }
                fpos += sn

                let nameEnd = fpos + Int(nameLen)
                guard nameEnd <= bytes.count else { break }
                let nameBytes = Array(bytes[fpos..<nameEnd])
                let name = String(bytes: nameBytes, encoding: .utf8) ?? ""

                // compressionInfo bits 8..14 = version, bit 3 = solid, bits 0..5 = method (0=store)
                let compMethod = UInt8(compressionInfo & 0x3F)
                let isStored = (compMethod == 0)

                // DataSize vint immediately follows the block header (if HFLAG_DATA_AREA set).
                // headerFlags bit 1 = has data area. We must consume the correct number of
                // vint bytes — discarding the count and always adding 1 misaligns the stream.
                var dataSize: UInt64 = 0
                var dataSizeVintLen = 0
                if headerFlags & 0x0002 != 0 {
                    if let (ds, dsLen) = readVInt(bytes, at: blockEnd) {
                        dataSize = ds
                        dataSizeVintLen = dsLen
                    }
                }

                // dataOffset points to the first byte of the file's payload.
                // In RAR5 the DataSize vint precedes the data when a data area is present.
                let dataOffset = baseOffset + UInt64(blockEnd) + UInt64(dataSizeVintLen)

                let entry = RAREntry(
                    name: name,
                    dataOffset: dataOffset,
                    packedSize: dataSize,
                    unpackedSize: unpackedSize,
                    method: compMethod,
                    isStored: isStored
                )

                if entry.isPageImage {
                    return entry
                }
            }

            // Advance to next block: move to blockEnd, then skip the data area if present.
            // Use the correctly-consumed vint byte count so we don't misalign.
            offset = blockEnd
            if headerFlags & 0x0002 != 0 {
                if let (ds, dsLen) = readVInt(bytes, at: offset) {
                    offset += dsLen + Int(ds)   // skip vint itself + data bytes
                }
            }
        }

        throw RARParseError.noImageFound
    }

    // MARK: - Byte helpers

    private static func readU16LE(_ bytes: [UInt8], offset: Int) -> UInt16 {
        guard offset + 1 < bytes.count else { return 0 }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func readU32LE(_ bytes: [UInt8], offset: Int) -> UInt32 {
        guard offset + 3 < bytes.count else { return 0 }
        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    /// RAR5 variable-length integer: each byte contributes 7 bits; MSB = "more bytes follow".
    private static func readVInt(_ bytes: [UInt8], at offset: Int) -> (UInt64, Int)? {
        var result: UInt64 = 0
        var shift = 0
        var bytesRead = 0
        var pos = offset
        while pos < bytes.count && bytesRead < 10 {
            let b = bytes[pos]
            result |= UInt64(b & 0x7F) << shift
            shift += 7
            bytesRead += 1
            pos += 1
            if b & 0x80 == 0 { return (result, bytesRead) }
        }
        return nil
    }
}
