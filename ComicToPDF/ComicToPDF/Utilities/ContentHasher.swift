import Foundation
import CryptoKit

enum ContentHasher {

    /// Computes SHA-256 of a file at the given URL.
    /// READ-ONLY — never modifies, moves, or copies the file.
    /// Caller must hold an open security-scoped resource before calling.
    /// Returns lowercase hex string, or nil if the file cannot be read.
    static func sha256(of url: URL) -> String? {
        guard let stream = InputStream(url: url) else { return nil }
        stream.open()
        defer { stream.close() }

        var hasher = SHA256()
        let bufferSize = 65_536
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let bytesRead = stream.read(buffer, maxLength: bufferSize)
            guard bytesRead > 0 else { break }
            hasher.update(data: Data(bytes: buffer, count: bytesRead))
        }

        return hasher.finalize().compactMap { String(format: "%02x", $0) }.joined()
    }
}
