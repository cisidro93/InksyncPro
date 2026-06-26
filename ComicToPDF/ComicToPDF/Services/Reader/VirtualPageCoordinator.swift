import Foundation
import PDFKit

/// Coordinates page index mapping across multiple comic files in a virtual omnibus,
/// allowing sequential reading of separate files as if they were a single volume.
struct VirtualPageCoordinator: Sendable {
    let files: [ConvertedPDF]
    
    /// Pre-calculated dynamic page range offsets
    private let pageOffsets: [Int]
    
    /// Total pages in this virtual volume
    let totalPageCount: Int
    
    init(files: [ConvertedPDF]) {
        self.files = files
        
        var offsets: [Int] = []
        var runningSum = 0
        for file in files {
            offsets.append(runningSum)
            runningSum += max(file.pageCount, 1)
        }
        self.pageOffsets = offsets
        self.totalPageCount = runningSum
    }
    
    /// Resolves a global page index to a specific file and its local page index
    /// - Parameter globalIndex: 0-based global page index
    /// - Returns: Tuple containing the matched file and the local 0-based page index, or nil if out of bounds
    func resolvePage(at globalIndex: Int) -> (file: ConvertedPDF, localPageIndex: Int)? {
        guard globalIndex >= 0 && globalIndex < totalPageCount else { return nil }
        
        // Find the file whose range covers globalIndex
        // Binary search since pageOffsets is sorted
        var low = 0
        var high = files.count - 1
        var fileIndex = 0
        
        while low <= high {
            let mid = (low + high) / 2
            if pageOffsets[mid] <= globalIndex {
                fileIndex = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        
        let file = files[fileIndex]
        let localIndex = globalIndex - pageOffsets[fileIndex]
        return (file: file, localPageIndex: localIndex)
    }
    
    /// Gets the formatted page title for UI overlay
    /// - Parameter globalIndex: 0-based global page index
    func pageTitle(at globalIndex: Int) -> String {
        guard let resolved = resolvePage(at: globalIndex) else { return "Page \(globalIndex + 1)" }
        let issueName = resolved.file.metadata.issueNumber.map { "#\($0)" } ?? resolved.file.name
        return "\(issueName) - Page \(resolved.localPageIndex + 1)"
    }
}
