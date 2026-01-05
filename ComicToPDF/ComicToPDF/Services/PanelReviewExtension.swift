import Foundation
import UIKit
import ImageIO // ✅ Needed for image sizing
import ZIPFoundation

extension ConversionManager {
    
    // ✅ FIX: Removed 'private' and simplified logic
    func performPanelReview(sourceEPUB: URL, settings: EPUBSettings) async throws -> (PanelEditSession?, Int) {
        
        // 1. Setup Session
        let sessionID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("PanelSession_\(sessionID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        // 2. Unzip EPUB
        try FileManager.default.unzipItem(at: sourceEPUB, to: tempDir)
        
        // 3. Find Images
        let resourceKeys: [URLResourceKey] = [.nameKey, .isDirectoryKey]
        guard let enumerator = FileManager.default.enumerator(at: tempDir, includingPropertiesForKeys: resourceKeys, options: [.skipsHiddenFiles]) else {
            throw NSError(domain: "PanelReview", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to enumerate temp files"])
        }
        
        var imageURLs: [URL] = []
        // ✅ FIX: Safer loop for Swift 6 / Async contexts
        while let fileURL = enumerator.nextObject() as? URL {
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
        var pages: [PanelEditSession.PageEditData] = []
        
        for (index, url) in imageURLs.enumerated() {
            // ✅ FIX: Use local helper instead of PanelEditorView.static
            if let size = getImageSize(url: url) {
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
    
    // ✅ HELPER: Local implementation to avoid cross-file dependency issues
    private func getImageSize(url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return nil }
        if let width = properties[kCGImagePropertyPixelWidth as String] as? CGFloat,
           let height = properties[kCGImagePropertyPixelHeight as String] as? CGFloat {
            return CGSize(width: width, height: height)
        }
        return nil
    }
}
