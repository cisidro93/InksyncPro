import Foundation
import UIKit
import Combine
import ZIPFoundation

/// Specifically isolates ZIP extraction and heavy memory handling into a strict concurrent context.
/// Prevents the Main Actor from getting choked during 'Death Spiral' unzips.
actor EditorSessionManager {
    static let shared = EditorSessionManager()
    
    // Cache stores the source archive URL so hit-check is a simple equality comparison.
    private var editorCache: (sourceURL: URL, pdfID: UUID, folder: URL, files: [URL])?
    private var activeExtractionTask: Task<(workingDir: URL, files: [URL]), Error>?

    // MARK: - Cached Extraction

    /// Extracts all image files from `url`, with a session-level cache keyed by source URL.
    /// Concurrent callers coalesce onto the single in-flight `activeExtractionTask` so
    /// a large archive is never decompressed more than once per session.
    func extractImageFiles(from url: URL) async throws -> (workingDir: URL, files: [URL]) {
        let canonical = url.standardizedFileURL

        // ── Cache hit ─────────────────────────────────────────────────────────
        if let cache = editorCache, cache.sourceURL == canonical {
            return (workingDir: cache.folder, files: cache.files)
        }

        // ── Coalesce concurrent callers onto the single in-flight task ────────
        if let existing = activeExtractionTask {
            return try await existing.value
        }

        // ── Cold path: extract and cache ──────────────────────────────────────
        let task = Task.detached(priority: .userInitiated) {
            let result = try await ZipUtilities.extractComic(from: url)
            return (workingDir: result.workingDir, files: result.imageURLs)
        }
        activeExtractionTask = task

        do {
            let result = try await task.value
            editorCache = (sourceURL: canonical, pdfID: UUID(), folder: result.workingDir, files: result.files)
            activeExtractionTask = nil
            return result
        } catch {
            activeExtractionTask = nil
            throw error
        }
    }

    func extractImageURLs(from url: URL) async throws -> [URL] {
        return try await extractImageFiles(from: url).files
    }
    
    func extractFullPage(pdfID: UUID, pdfURL: URL, index: Int) async throws -> UIImage? {
        let canonical = pdfURL.standardizedFileURL

        // ── Cache hit by pdfID OR by source URL ───────────────────────────────
        if let cache = editorCache, cache.pdfID == pdfID || cache.sourceURL == canonical {
            guard index < cache.files.count else { return nil }
            return ConversionManager.loadDownsampledImageStatic(at: cache.files[index], maxDimension: 1920)
        }

        // Different file opened — evict stale cache before extracting
        if editorCache != nil { await endSession(manager: nil) }

        // ── Coalesce onto any in-flight task ──────────────────────────────────
        if let existingTask = activeExtractionTask {
            let result = try await existingTask.value
            editorCache = (sourceURL: canonical, pdfID: pdfID, folder: result.workingDir, files: result.files)
            guard index < result.files.count else { return nil }
            return ConversionManager.loadDownsampledImageStatic(at: result.files[index], maxDimension: 1920)
        }

        // ── Cold extract ──────────────────────────────────────────────────────
        let newTask = Task.detached(priority: .userInitiated) {
            let result = try await ZipUtilities.extractComic(from: pdfURL)
            return (workingDir: result.workingDir, files: result.imageURLs)
        }
        self.activeExtractionTask = newTask
        let result = try await newTask.value
        self.editorCache = (sourceURL: canonical, pdfID: pdfID, folder: result.workingDir, files: result.files)
        self.activeExtractionTask = nil

        guard index < result.files.count else { return nil }
        return ConversionManager.loadDownsampledImageStatic(at: result.files[index], maxDimension: 1920)
    }

    func clearCache(for pdfID: UUID) {
        if editorCache?.pdfID == pdfID {
            editorCache = nil
        }
    }
    
    /// Ends the current ZIP editing session and clears the cache/disk
    func endSession(manager: ConversionManager?) async {
        activeExtractionTask?.cancel()
        activeExtractionTask = nil
        
        if let manager = manager {
            await MainActor.run {
                if manager.processingStatus.contains("Importing") == false {
                     manager.statusMessage = "Ready"
                }
            }
        }
        
        let cacheToDelete = self.editorCache
        self.editorCache = nil
        
        if let cache = cacheToDelete {
             Task { @MainActor in
                 let bgTask = UIApplication.shared.beginBackgroundTask(expirationHandler: nil)
                 Task.detached(priority: .background) {
                     try? await Task.sleep(for: .seconds(1))
                     try? FileManager.default.removeItem(at: cache.folder)
                     await MainActor.run {
                         UIApplication.shared.endBackgroundTask(bgTask)
                     }
                 }
             }
        }
    }
}
