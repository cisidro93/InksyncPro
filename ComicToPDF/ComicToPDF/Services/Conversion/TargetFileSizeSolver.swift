import UIKit

/// Solver for calculating optimal per-page image compression metrics to hit a target file size (in MB).
struct TargetFileSizeSolver {
    
    struct Solution {
        let quality: CGFloat
        let maxDimension: CGFloat?
        let estimatedTotalBytes: Int64
    }
    
    /// Solves optimal JPEG quality factor and resolution bounds for a given document page count and target MB limit.
    static func solve(pageCount: Int, targetMB: Double, sampleImageSize: CGSize = CGSize(width: 2400, height: 3200)) -> Solution {
        let safePageCount = max(1, pageCount)
        let targetBytesPerContainer = Double(targetMB) * 1024.0 * 1024.0
        let targetBytesPerPage = targetBytesPerContainer / Double(safePageCount)
        
        // Standard high-res page at 95% JPEG is approx ~1.2 MB (1,250,000 bytes)
        let uncompressedPageBytes: Double = 1_250_000.0
        
        if targetBytesPerPage >= uncompressedPageBytes {
            // Target is generous — no quality reduction needed
            return Solution(
                quality: 0.95,
                maxDimension: nil,
                estimatedTotalBytes: Int64(uncompressedPageBytes * Double(safePageCount))
            )
        } else if targetBytesPerPage >= 750_000 {
            // Target allows high quality (750KB - 1.2MB per page)
            let ratio = (targetBytesPerPage - 750_000) / 500_000
            let q = 0.85 + (0.10 * ratio)
            return Solution(
                quality: CGFloat(min(0.95, max(0.85, q))),
                maxDimension: 2560.0,
                estimatedTotalBytes: Int64(targetBytesPerContainer)
            )
        } else if targetBytesPerPage >= 400_000 {
            // Target requires standard compression (400KB - 750KB per page)
            let ratio = (targetBytesPerPage - 400_000) / 350_000
            let q = 0.75 + (0.10 * ratio)
            return Solution(
                quality: CGFloat(min(0.85, max(0.75, q))),
                maxDimension: 2048.0,
                estimatedTotalBytes: Int64(targetBytesPerContainer)
            )
        } else {
            // Compact budget (under 400KB per page)
            let ratio = max(0, (targetBytesPerPage - 150_000) / 250_000)
            let q = 0.65 + (0.10 * ratio)
            return Solution(
                quality: CGFloat(min(0.75, max(0.60, q))),
                maxDimension: 1600.0,
                estimatedTotalBytes: Int64(targetBytesPerContainer)
            )
        }
    }
}
