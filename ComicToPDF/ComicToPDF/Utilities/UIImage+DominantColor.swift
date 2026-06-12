import UIKit
import SwiftUI

// MARK: - UIImage + Dominant Color
//
// Lightweight dominant color extraction for ambient chrome tinting.
// Samples a small downscaled version of the image so it runs quickly
// even on large comic page images.
//
// Algorithm: downsample to 16×16, average the RGB of all pixels,
// then boost saturation so the tint is perceptible against dark UI.

extension UIImage {

    /// Returns the dominant (area-averaged) color as a SwiftUI Color.
    /// Falls back to `.clear` if the image has no pixel data.
    /// Safe to call from any context — all operations are pure CGContext pixel math.
    nonisolated func dominantColor(saturate factor: CGFloat = 1.8) -> Color {
        guard let cgImage = self.cgImage else { return .clear }

        // Downsample to tiny rect — fast kernal average
        let size = CGSize(width: 16, height: 16)
        let rect = CGRect(origin: .zero, size: size)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var rawData = [UInt8](repeating: 0, count: 4 * Int(size.width) * Int(size.height))
        guard let context = CGContext(
            data: &rawData,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 4 * Int(size.width),
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return .clear }

        context.draw(cgImage, in: rect)

        var totalR: CGFloat = 0
        var totalG: CGFloat = 0
        var totalB: CGFloat = 0
        let pixelCount = Int(size.width * size.height)

        for i in stride(from: 0, to: pixelCount * 4, by: 4) {
            totalR += CGFloat(rawData[i])
            totalG += CGFloat(rawData[i + 1])
            totalB += CGFloat(rawData[i + 2])
        }

        let r = totalR / CGFloat(pixelCount) / 255.0
        let g = totalG / CGFloat(pixelCount) / 255.0
        let b = totalB / CGFloat(pixelCount) / 255.0

        // Boost saturation so the tint reads on dark backgrounds
        let base = UIColor(red: r, green: g, blue: b, alpha: 1.0)
        var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0, alpha: CGFloat = 0
        base.getHue(&hue, saturation: &sat, brightness: &bri, alpha: &alpha)
        let boosted = UIColor(hue: hue, saturation: min(sat * factor, 1.0), brightness: bri, alpha: 1.0)
        return Color(boosted)
    }
}
