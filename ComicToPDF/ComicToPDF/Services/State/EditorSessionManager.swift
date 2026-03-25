import Foundation
import UIKit
import Combine
import ZIPFoundation

/// Specifically isolates ZIP extraction and heavy memory handling into a strict concurrent context.
/// Prevents the Main Actor from getting choked during 'Death Spiral' unzips.
actor EditorSessionManager {
    static let shared = EditorSessionManager()
    
    private var editorCache: (pdfID: UUID, folder: URL, files: [URL])?
    private var activeExtractionTask: Task<(workingDir: URL, files: [URL]), Error>?
    
    func extractImageFiles(from url: URL) async throws -> (workingDir: URL, files: [URL]) {
        let result = try await ZipUtilities.extractComic(from: url)
        return (workingDir: result.workingDir, files: result.imageURLs)
    }
    
    func extractImageURLs(from url: URL) async throws -> [URL] {
        return try await extractImageFiles(from: url).files
    }
    
    func extractFullPage(pdfID: UUID, pdfURL: URL, index: Int) async throws -> UIImage? {
        if let cache = editorCache, cache.pdfID == pdfID {
            guard index < cache.files.count else { return nil }
            return ConversionManager.loadDownsampledImageStatic(at: cache.files[index], maxDimension: 1920)
        }
        
        if let oldCache = editorCache, oldCache.pdfID != pdfID {
            await endSession(manager: nil) 
        }
        
        if let existingTask = activeExtractionTask {
             let result = try await existingTask.value
             if true { 
                 self.editorCache = (pdfID, result.workingDir, result.files)
                 guard index < result.files.count else { return nil }
                 return ConversionManager.loadDownsampledImageStatic(at: result.files[index], maxDimension: 1920)
             }
        }
        
        let newTask = Task.detached(priority: .userInitiated) {
            let result = try await ZipUtilities.extractComic(from: pdfURL)
            return (workingDir: result.workingDir, files: result.imageURLs)
        }
        
        self.activeExtractionTask = newTask
        let result = try await newTask.value
        
        self.editorCache = (pdfID, result.workingDir, result.files)
        self.activeExtractionTask = nil
        
        guard index < result.files.count else { return nil }
        return ConversionManager.loadDownsampledImageStatic(at: result.files[index], maxDimension: 1920)
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
             let bgTask = UIApplication.shared.beginBackgroundTask(expirationHandler: nil)
             DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 1.0) {
                 try? FileManager.default.removeItem(at: cache.folder)
                 UIApplication.shared.endBackgroundTask(bgTask)
             }
        }
    }
}
