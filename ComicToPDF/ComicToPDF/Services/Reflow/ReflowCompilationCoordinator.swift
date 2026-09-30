import Foundation
@preconcurrency import PDFKit

/// Coordinates asynchronous reflow layout generation, disk caching, single-flight task deduplication,
/// and background pre-warming to ensure instant, zero-delay presentation when entering reflow mode.
@MainActor
public final class ReflowCompilationCoordinator {
    public static let shared = ReflowCompilationCoordinator()

    private var activeCompilations: [String: Task<URL?, Never>] = [:]

    private init() {}

    public static let cacheVersion = "v8"

    private func cacheKey(pdfUUID: String, isClutterFiltered: Bool) -> String {
        return "\(pdfUUID)_\(isClutterFiltered ? "clean" : "raw")"
    }

    /// Resolves the file URL for the cached reflow HTML file.
    public func cachedReflowURL(pdfUUID: String, isClutterFiltered: Bool) -> URL? {
        guard let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let cacheFileName = "reflow_\(Self.cacheVersion)_\(isClutterFiltered ? "clean" : "raw").html"
        return cacheDir.appendingPathComponent("ReflowPDF/\(pdfUUID)/\(cacheFileName)")
    }

    /// Checks if the synthesized reflow HTML file already exists on disk.
    public func hasCachedReflow(pdfUUID: String, isClutterFiltered: Bool) -> Bool {
        guard let url = cachedReflowURL(pdfUUID: pdfUUID, isClutterFiltered: isClutterFiltered) else {
            return false
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Pre-warms the reflow layout in an asynchronous background task so it is ready before the user requests it.
    public func prewarm(
        document: PDFDocument,
        pdfUUID: String,
        documentTitle: String,
        isClutterFiltered: Bool
    ) {
        guard !hasCachedReflow(pdfUUID: pdfUUID, isClutterFiltered: isClutterFiltered) else { return }

        Task.detached(priority: .utility) {
            _ = await self.compileOrFetchReflow(
                document: document,
                pdfUUID: pdfUUID,
                documentTitle: documentTitle,
                isClutterFiltered: isClutterFiltered
            )
        }
    }

    /// Compiles reflow layout or returns existing cached file. Deduplicates multiple simultaneous requests into a single task.
    public func compileOrFetchReflow(
        document: PDFDocument,
        pdfUUID: String,
        documentTitle: String,
        isClutterFiltered: Bool
    ) async -> URL? {
        // Fast-path: Return cached file if already synthesized on disk
        if let cachedURL = cachedReflowURL(pdfUUID: pdfUUID, isClutterFiltered: isClutterFiltered),
           FileManager.default.fileExists(atPath: cachedURL.path) {
            return cachedURL
        }

        let key = cacheKey(pdfUUID: pdfUUID, isClutterFiltered: isClutterFiltered)

        // Deduplication: If compilation is already in flight for this document, await existing task
        if let ongoing = activeCompilations[key] {
            return await ongoing.value
        }

        let task = Task.detached(priority: .utility) {
            let blocks = await PDFSpatialParser.shared.parseDocument(document, skipClutter: isClutterFiltered)

            // Only extract images for pages that lack digital text blocks
            let textPages = Set(blocks.map { $0.pageIndex })
            let nonTextPages = Set(0..<document.pageCount).subtracting(textPages)
            let images = await PDFImageExtractor.shared.extractImages(
                from: document,
                pdfUUID: pdfUUID,
                nonTextPages: nonTextPages
            )

            let compiledURL = await ReflowDOMSynthesizer.shared.synthesizeHTML(
                pdfUUID: pdfUUID,
                documentTitle: documentTitle,
                blocks: blocks,
                images: images,
                isClutterFiltered: isClutterFiltered
            )

            return compiledURL
        }

        activeCompilations[key] = task
        let result = await task.value
        activeCompilations.removeValue(forKey: key)
        return result
    }
}
