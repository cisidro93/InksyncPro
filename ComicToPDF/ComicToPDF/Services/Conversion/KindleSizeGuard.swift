import Foundation
import UIKit

/// Analyses a completed EPUB and warns the user if it will exceed Amazon's Send to Kindle
/// email limit (50MB) or web uploader limit (200MB). Automatically suggests split mode.
enum KindleSizeGuard {

    /// Amazon's hard limits in bytes
    static let emailLimitBytes: Int64 = 50 * 1_024 * 1_024       // 50 MB
    static let webUploaderLimitBytes: Int64 = 200 * 1_024 * 1_024 // 200 MB

    enum DeliveryOutcome {
        case withinEmailLimit               // ≤ 50 MB — email or app delivery fine
        case withinWebLimit                 // 50–200 MB — web uploader only
        case exceedsAllLimits               // > 200 MB — USB transfer only
    }

    /// Evaluate the file at the given URL and return the appropriate outcome + a user-facing message.
    static func evaluate(epubURL: URL) -> (outcome: DeliveryOutcome, message: String, fileSizeMB: Double)? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: epubURL.path),
              let fileSize = attributes[.size] as? Int64 else { return nil }

        let mb = Double(fileSize) / 1_024.0 / 1_024.0

        switch fileSize {
        case ..<emailLimitBytes:
            return (.withinEmailLimit, String(format: "%.1f MB — within the 50 MB email limit. ✅", mb), mb)
        case emailLimitBytes..<webUploaderLimitBytes:
            return (.withinWebLimit, String(format: "%.1f MB — too large for email (50 MB limit). Use amazon.com/sendtokindle (200 MB limit).", mb), mb)
        default:
            return (.exceedsAllLimits, String(format: "%.1f MB — exceeds all Send to Kindle limits (200 MB). Transfer via USB instead.", mb), mb)
        }
    }

    /// Present a non-blocking notification banner via ConversionManager when an EPUB
    /// exceeds the email limit. Call this from ConversionOrchestrator after writing the EPUB.
    @MainActor
    static func auditAndNotify(epubURL: URL, manager: ConversionManager) {
        guard let result = evaluate(epubURL: epubURL) else { return }

        switch result.outcome {
        case .withinEmailLimit:
            // No action needed — all good
            break
        case .withinWebLimit:
            manager.appAlert = AppAlert(
                title: "📚 Kindle Delivery Note",
                message: "\(result.message)\n\nTap the Share button → Send to Kindle, or visit amazon.com/sendtokindle on your Mac."
            )
        case .exceedsAllLimits:
            manager.appAlert = AppAlert(
                title: "⚠️ File Too Large for Kindle",
                message: "\(result.message)\n\nTip: Use the split mode option in Settings (Max Volume Size) to automatically break large collections into Kindle-friendly parts."
            )
        }

        Logger.shared.log("KindleSizeGuard: \(epubURL.lastPathComponent) → \(result.outcome) (\(String(format: "%.1f", result.fileSizeMB)) MB)", category: "Kindle")
    }
}
