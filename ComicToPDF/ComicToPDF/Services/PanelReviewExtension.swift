import Foundation
import UIKit
// import ZIPFoundation // ZIPFoundation is likely already imported in ConversionManager, but if this is an extension, it needs imports if used directly. 
// However, the code uses FileManager to unzip.
// The user code snippet uses `import ZIPFoundation` commented: `// Ensure this is available`.
// I will include it.
import ZIPFoundation

extension ConversionManager {
    // ✅ FIX: Removed 'private' so LibraryView can call it
    func performPanelReview(sourceEPUB: URL, settings: EPUBSettings) async throws -> (PanelEditSession?, Int) {
        
        // 1. Setup Session
        let sessionID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("PanelSession_\(sessionID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        // 2. Unzip EPUB (Simplistic Unzip for review)
        // Note: FileManager.default.unzipItem comes from ZIPFoundation.
        try FileManager.default.unzipItem(at: sourceEPUB, to: tempDir)
        
        // 3. Find Images
        let resourceKeys = Set<URLResourceKey>([.nameKey, .isDirectoryKey])
        guard let enumerator = FileManager.default.enumerator(at: tempDir, includingPropertiesForKeys: Array(resourceKeys), options: [.skipsHiddenFiles]) else {
            throw NSError(domain: "PanelReview", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to enumerate temp files"])
        }
        
        var imageURLs: [URL] = []
        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            if ["jpg", "jpeg", "png", "webp"].contains(ext) {
                imageURLs.append(fileURL)
            }
        }
        imageURLs.sort { $0.lastPathComponent < $1.lastPathComponent }
        
        guard !imageURLs.isEmpty else {
            throw NSError(domain: "PanelReview", code: 3, userInfo: [NSLocalizedDescriptionKey: "No images found in file"])
        }
        
        // 4. Create Panel Session Data
        // For this quick review, we create a dummy session with 1 panel per page (full page)
        // In a real scenario, this would run PanelExtractor on each image
        var pages: [PanelEditSession.PageEditData] = []
        
        for (index, url) in imageURLs.enumerated() {
            // We need image dimensions to create normalized rects
            if let size = PanelEditorView.getImageSize(url: url) {
                // Create a default full-page panel
                let fullRect = CGRect(origin: .zero, size: size)
                let panel = EditablePanel(rect: fullRect, order: 1)
                
                let pageData = PanelEditSession.PageEditData(
                    pageNumber: index + 1,
                    imageURL: url,
                    panels: [panel]
                )
                pages.append(pageData)
            }
        }
        
        let session = PanelEditSession(pages: pages, readingDirection: settings.readingDirection, sessionTempDirectory: tempDir)
        
        return (session, pages.count)
    }
}
