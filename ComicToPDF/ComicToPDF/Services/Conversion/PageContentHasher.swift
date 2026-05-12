import Foundation
import UIKit
import CryptoKit

// Pure SHA-256 thumbprint of page visual content.
// Used to anchor annotations across format conversions that reorder pages.
// Renders a 256×256 thumbnail via CGContext, hashes the raw pixels.
// Returns nil on failure — callers must handle gracefully.

struct PageContentHasher {

    static func sha256Hex(of image: UIImage) -> String? {
        guard let cgImage = image.cgImage else { return nil }

        let size = CGSize(width: 256, height: 256)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: Int(size.width),
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        context.draw(cgImage, in: CGRect(origin: .zero, size: size))

        guard let rawData = context.data else { return nil }
        let byteCount = Int(size.width) * Int(size.height)
        let buffer = Data(bytes: rawData, count: byteCount)

        let digest = SHA256.hash(data: buffer)
        return digest.map { String(format: "%02hhx", $0) }.joined()
    }

    static func sha256Hex(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02hhx", $0) }.joined()
    }
}
