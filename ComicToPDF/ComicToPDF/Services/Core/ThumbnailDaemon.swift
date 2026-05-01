import Foundation
import UIKit
import Combine

/// A dedicated background worker that silently extracts and caches thumbnails
/// for massive external Linked Libraries, ensuring 0% impact on the Main Thread.
actor ThumbnailDaemon {
    static let shared = ThumbnailDaemon()
    
    private let cacheDirectory: URL
    private var isRunning = false
    
    private init() {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("ThumbnailCache", isDirectory: true)
        if !fm.fileExists(atPath: tempDir.path) {
            try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        }
        self.cacheDirectory = tempDir
    }
    
    /// Starts a low-priority background crawl to extract missing thumbnails for a given list of PDFs.
    func startCrawling(pdfs: [ConvertedPDF]) {
        guard !isRunning else { return }
        isRunning = true
        
        Task.detached(priority: .background) { [weak self] in
            guard let self = self else { return }
            await self.processQueue(pdfs: pdfs)
        }
    }
    
    private func processQueue(pdfs: [ConvertedPDF]) async {
        for pdf in pdfs {
            // Check if already cached
            let cachedURL = cacheDirectory.appendingPathComponent("\(pdf.id.uuidString).webp")
            if FileManager.default.fileExists(atPath: cachedURL.path) {
                continue
            }
            
            // Resolve URL securely for Linked Libraries
            let url: URL
            var accessedURL: URL? = nil
            if case .linked(let bm) = pdf.sourceMode,
               let resolved = try? BookmarkResolver.shared.resolve(bm) {
                let didAccess = resolved.startAccessingSecurityScopedResource()
                url = resolved
                if didAccess { accessedURL = resolved }
            } else {
                url = pdf.url
            }
            
            // Extract static cover image
            if let image = PhysicalFileSystemRouter.extractCoverImageStatic(from: url) {
                // Downsample heavily for grid performance
                let thumbnail = image.preparingThumbnail(of: CGSize(width: 240, height: 360)) ?? image
                // WebP is highly optimized, but iOS doesn't have native WebP export without CoreImage tricks.
                // Using highly compressed JPEG as an alternative to WebP for native speed.
                if let data = thumbnail.jpegData(compressionQuality: 0.5) {
                    try? data.write(to: cachedURL, options: .atomic)
                }
            }
            
            accessedURL?.stopAccessingSecurityScopedResource()
            
            // Yield to avoid starving the system
            await Task.yield()
        }
        
        isRunning = false
    }
    
    /// Fetch a pre-cached thumbnail from the fast temporary cache.
    func getCachedThumbnail(for pdfID: UUID) -> UIImage? {
        let cachedURL = cacheDirectory.appendingPathComponent("\(pdfID.uuidString).webp")
        guard FileManager.default.fileExists(atPath: cachedURL.path),
              let data = try? Data(contentsOf: cachedURL),
              let image = UIImage(data: data) else {
            return nil
        }
        return image
    }
}
