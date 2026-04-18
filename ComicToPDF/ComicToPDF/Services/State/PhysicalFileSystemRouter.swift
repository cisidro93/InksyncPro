import Foundation
import UIKit
import SwiftUI
import PDFKit
import ZIPFoundation

/// Safely handles all iOS Storage interactions, including disk persistence, thumbnail caching into Application Support, and atomic NSFileCoordinator bindings independent from the Presentation logic.
@MainActor
class PhysicalFileSystemRouter {
    static let shared = PhysicalFileSystemRouter()
    private init() {}
    
    // MARK: - Core File IO Storage
    static func getCoversDirectory() -> URL {
        let fileManager = FileManager.default
        guard let appSupportDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return fileManager.temporaryDirectory
        }
        let coversDir = appSupportDir.appendingPathComponent("Covers", isDirectory: true)
        
        if !fileManager.fileExists(atPath: coversDir.path) {
            try? fileManager.createDirectory(at: coversDir, withIntermediateDirectories: true)
        }
        return coversDir
    }
    
    func getCoverURL(for pdf: ConvertedPDF) -> URL? {
        if let selectedID = pdf.metadata.selectedCoverID,
           let variantURL = pdf.metadata.coverVariants[selectedID],
           FileManager.default.fileExists(atPath: variantURL.path) {
            return variantURL
        }
        return getOriginalCoverURL(for: pdf)
    }

    func getOriginalCoverURL(for pdf: ConvertedPDF) -> URL {
        let coversDir = Self.getCoversDirectory()
        return coversDir.appendingPathComponent("cover_\(pdf.id.uuidString).jpg")
    }
    
    func migrateCoversToDisk(manager: ConversionManager) {
        var updated = false
        for i in 0..<manager.convertedPDFs.count {
            if let data = manager.convertedPDFs[i].coverImageData {
                if let coverURL = getCoverURL(for: manager.convertedPDFs[i]) {
                    try? data.write(to: coverURL)
                }
                manager.convertedPDFs[i].coverImageData = nil
                updated = true
            }
        }
        if updated { manager.saveLibrary() }
    }
    
    func loadCoverThumbnail(for pdf: ConvertedPDF, manager: ConversionManager) async -> UIImage? {
        let keyStr = pdf.id.uuidString
        if let cached = manager.thumbnailCache.object(forKey: keyStr as NSString) { return cached }
        // ✅ PERF: Resolve cover URL on MainActor *once*, before the background task.
        // Avoids an implicit actor-hop back to MainActor per cell during scroll.
        let coverURL = getCoverURL(for: pdf)
        return await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let url = coverURL,
                  FileManager.default.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  let image = UIImage(data: data) else {
                if let data = pdf.coverImageData, let image = UIImage(data: data) { return image }
                return nil
            }
            let thumbnail = image.preparingThumbnail(of: CGSize(width: 240, height: 360)) ?? image
            await MainActor.run { manager.thumbnailCache.setObject(thumbnail, forKey: keyStr as NSString) }
            return thumbnail
        }.value
    }
    
    func saveCoverImage(_ data: Data, for pdf: ConvertedPDF, manager: ConversionManager) {
        guard let coverURL = getCoverURL(for: pdf) else { return }
        try? data.write(to: coverURL)
        
        if let image = UIImage(data: data) {
            let thumbnail = image.preparingThumbnail(of: CGSize(width: 240, height: 360)) ?? image
            let key = pdf.id.uuidString as NSString
            // ✅ PERF: Cost annotation makes totalCostLimit enforcement accurate
            let cost = thumbnail.jpegData(compressionQuality: 0.8)?.count ?? 0
            manager.thumbnailCache.setObject(thumbnail, forKey: key, cost: cost)
        }
        
        if let index = manager.convertedPDFs.firstIndex(where: { $0.id == pdf.id }) {
            manager.convertedPDFs[index].coverImageData = nil
            // ✅ PERF: Removed objectWillChange.send() — NSCache mutations don't trigger SwiftUI renders.
            // Thumbnail state is managed by isolated @State in LibraryComponents.
        }
    }
    
    func deletePDF(_ pdf: ConvertedPDF, manager: ConversionManager) {
        // 1. Remove from UI state instantly for perceived zero-latency
        if let idx = manager.convertedPDFs.firstIndex(where: { $0.id == pdf.id }) {
            manager.convertedPDFs.remove(at: idx)
            manager.saveLibrary()
        }
        
        // 2. Offload the heavy file destruction to a background task
        let urlTarget = pdf.url
        let coverTarget = getCoverURL(for: pdf)
        let docName = pdf.name
        
        Task.detached(priority: .background) {
            do {
                if FileManager.default.fileExists(atPath: urlTarget.path) {
                    try FileManager.default.removeItem(at: urlTarget)
                }
                if let coverTarget = coverTarget, FileManager.default.fileExists(atPath: coverTarget.path) {
                    try? FileManager.default.removeItem(at: coverTarget)
                }
                Logger.shared.log("Deleted File and Cover in background: \(docName)", category: "Library")
            } catch {
                Logger.shared.log("Failed to delete file in background: \(error)", category: "Library", type: .error)
            }
        }
    }
    
    // MARK: - Heavy Graphics Generation
    func generateCoverThumbnail(for pdf: ConvertedPDF, manager: ConversionManager) async {
        if let variantID = pdf.metadata.selectedCoverID,
           let variantURL = pdf.metadata.coverVariants[variantID],
           FileManager.default.fileExists(atPath: variantURL.path),
           let data = try? Data(contentsOf: variantURL),
           let image = UIImage(data: data),
           let jpegData = image.jpegData(compressionQuality: 0.7) {
            saveCoverImage(jpegData, for: pdf, manager: manager)
            return
        }
        
        if let coverURL = getCoverURL(for: pdf), FileManager.default.fileExists(atPath: coverURL.path) { return }
        
        let url: URL
        if case .linked(let bm) = pdf.sourceMode, let resolved = try? BookmarkResolver.shared.resolve(bm) {
            url = resolved
        } else {
            url = pdf.url
        }
        
        let image = await Task.detached(priority: .background) { () -> UIImage? in
            return PhysicalFileSystemRouter.extractCoverImageStatic(from: url)
        }.value
        
        guard let image = image, let jpegData = image.jpegData(compressionQuality: 0.7) else { return }
        saveCoverImage(jpegData, for: pdf, manager: manager)
    }
    
    func backfillMissingThumbnails(manager: ConversionManager) {
        let pdfsNeedingCovers = manager.convertedPDFs.filter { pdf in
            guard let coverURL = getCoverURL(for: pdf) else { return true }
            return !FileManager.default.fileExists(atPath: coverURL.path)
        }
        guard !pdfsNeedingCovers.isEmpty else { return }
        // Process sequentially in a single background task to avoid I/O saturation
        Task(priority: .background) {
            for pdf in pdfsNeedingCovers {
                await generateCoverThumbnail(for: pdf, manager: manager)
            }
        }
    }
    
    func loadThumbnailAsync(for pdf: ConvertedPDF, manager: ConversionManager) async {
        if manager.thumbnailCache.object(forKey: pdf.id.uuidString as NSString) != nil { return }
        
        var generatedImage: UIImage? = nil
        if let coverURL = self.getCoverURL(for: pdf) {
            let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
            if let source = CGImageSourceCreateWithURL(coverURL as CFURL, sourceOptions) {
                let downsampleOptions = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 400
                ] as CFDictionary
                
                if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions) {
                    generatedImage = UIImage(cgImage: cgImage)
                }
            }
        }
        
        if let image = generatedImage {
            await MainActor.run {
                manager.thumbnailCache.setObject(image, forKey: pdf.id.uuidString as NSString)
                manager.objectWillChange.send()
            }
        } else {
            await self.generateCoverThumbnail(for: pdf, manager: manager)
            if manager.thumbnailCache.object(forKey: pdf.id.uuidString as NSString) != nil {
                await MainActor.run { manager.objectWillChange.send() }
            }
        }
    }
    
    func getThumbnail(for pdf: ConvertedPDF, manager: ConversionManager) -> UIImage? {
        let keyStr = pdf.id.uuidString
        if let cached = manager.thumbnailCache.object(forKey: keyStr as NSString) { return cached }
        Task.detached(priority: .userInitiated) {
            var generatedImage: UIImage? = nil
            if let coverURL = await self.getCoverURL(for: pdf) {
                let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
                if let source = CGImageSourceCreateWithURL(coverURL as CFURL, sourceOptions) {
                    let downsampleOptions = [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceShouldCacheImmediately: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 400
                    ] as CFDictionary
                    
                    if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions) {
                        generatedImage = UIImage(cgImage: cgImage)
                    }
                }
            }
            
            if let image = generatedImage {
                await MainActor.run {
                    manager.thumbnailCache.setObject(image, forKey: keyStr as NSString)
                    manager.objectWillChange.send()
                }
            } else {
                await self.generateCoverThumbnail(for: pdf, manager: manager)
            }
        }
        return nil
    }
    
    // MARK: - Native Thread-Safe Physical OS Interactions
    func safelyRenamePhysicalFile(pdf: ConvertedPDF, newName: String, manager: ConversionManager) throws {
        guard let idx = manager.convertedPDFs.firstIndex(where: { $0.id == pdf.id }) else {
            throw NSError(domain: "Database", code: 404, userInfo: [NSLocalizedDescriptionKey: "File not found within internal database loop."])
        }
        
        let fileManager = FileManager.default
        let currentURL = pdf.url
        guard fileManager.fileExists(atPath: currentURL.path) else {
            throw NSError(domain: "FileSystem", code: 404, userInfo: [NSLocalizedDescriptionKey: "The physical file no longer exists at original path."])
        }
        
        let pathExtension = currentURL.pathExtension
        let cleanName = newName.replacingOccurrences(of: "/", with: "-")
                               .replacingOccurrences(of: "\\", with: "-")
                               .replacingOccurrences(of: ":", with: "-")
        
        let targetDirectory = currentURL.deletingLastPathComponent()
        var newURL = targetDirectory.appendingPathComponent("\(cleanName).\(pathExtension)")
        
        var counter = 2
        while fileManager.fileExists(atPath: newURL.path) {
            let sequencedName = "\(cleanName)_v\(counter).\(pathExtension)"
            newURL = targetDirectory.appendingPathComponent(sequencedName)
            counter += 1
        }
        
        do {
            try fileManager.moveItem(at: currentURL, to: newURL)
        } catch {
            Logger.shared.log("Move Failure: \(error)", category: "FileSystem", type: .error)
            throw error
        }
        
        // ✅ PERF: @MainActor class — direct assignment, no dispatch needed
        manager.convertedPDFs[idx].url = newURL
        manager.convertedPDFs[idx].name = newURL.lastPathComponent
        manager.saveLibrary()
    }
    
    // MARK: - Extracted Static Disk Helpers
    nonisolated static func extractCoverImageStatic(from url: URL) -> UIImage? {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" {
            guard let document = PDFDocument(url: url) else { return nil }
            
            // Try up to the first 3 pages to find a portrait cover
            for i in 0..<min(document.pageCount, 3) {
                if let page = document.page(at: i) {
                    let bounds = page.bounds(for: .mediaBox)
                    // Skip if it's the first page and appears to be a 2-page spread
                    if i == 0 && bounds.width > bounds.height && document.pageCount > 1 {
                        continue
                    }
                    return page.thumbnail(of: CGSize(width: 300, height: 450), for: .mediaBox)
                }
            }
            
            // Fallback to page 0 if no portrait pages were found
            guard let page = document.page(at: 0) else { return nil }
            return page.thumbnail(of: CGSize(width: 300, height: 450), for: .mediaBox)
        }

        if ["cbz", "zip", "epub"].contains(ext) {
            // ✅ Security Scope Safety (Paranoid Check)
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            
            do {
                // Remove 'try?' to let errors propagate to the catch block
                let archive = try Archive(url: url, accessMode: .read)
                
                // ✅ Fix: Use localized sort to match Finder/ZipUtilities (1, 2, 10 vs 1, 10, 2)
                let sortedEntries = archive.makeIterator().sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                
                // Check mimetype for EPUBs
                if ext == "epub" {
                    if let mimetypeEntry = archive["mimetype"] {
                        Logger.shared.log("[Flight Recorder] [0] mimetype Size: \(mimetypeEntry.uncompressedSize)", category: "Debug")
                        
                        // Check Compression Method
                        let compressionMethod = mimetypeEntry.type == .file ? (mimetypeEntry.compressedSize == mimetypeEntry.uncompressedSize ? "STORED (Likely)" : "DEFLATED") : "UNKNOWN"
                        Logger.shared.log("[Flight Recorder] [0] Compression: \(compressionMethod) (C: \(mimetypeEntry.compressedSize) / U: \(mimetypeEntry.uncompressedSize))", category: "Debug")
                        
                        if mimetypeEntry.uncompressedSize == 20 {
                            Logger.shared.log("[Flight Recorder] ✅ Mimetype size is correct (20 bytes)", category: "Debug")
                        } else {
                            Logger.shared.log("[Flight Recorder] ❌ Mimetype size is WRONG: \(mimetypeEntry.uncompressedSize)", category: "Debug")
                        }
                        
                        var data = Data()
                        _ = try? archive.extract(mimetypeEntry, consumer: { data.append($0) })
                        if let content = String(data: data, encoding: .ascii) {
                           Logger.shared.log("[Flight Recorder] 📄 Mimetype Content: '\(content)'", category: "Debug")
                           if content != "application/epub+zip" {
                               Logger.shared.log("[Flight Recorder] ❌ Mimetype Content INVALID", category: "Debug")
                           }
                        }
                    } else {
                         Logger.shared.log("[Flight Recorder] ❌ Mimetype file MISSING!", category: "Debug")
                    }
                }

                var firstSpreadImage: UIImage? = nil
                var attempts = 0
                
                for entry in sortedEntries {
                    if Task.isCancelled { return nil } // ✅ Abort heavy Zip iteration if SwiftUI view was cancelled
                    // Skip directories explicit check
                    if entry.type == .directory { continue }
                    
                    let entryExt = (entry.path as NSString).pathExtension.lowercased()
                    if ["jpg", "jpeg", "png", "webp"].contains(entryExt) {
                        if entry.path.contains("__MACOSX") || entry.path.hasPrefix(".") { continue }
                        
                        var data = Data()
                        do {
                            _ = try archive.extract(entry) { data.append($0) }
                            if let image = UIImage(data: data) {
                                attempts += 1
                                
                                // Skip if it's the first page and appears to be a 2-page spread
                                if attempts == 1 && image.size.width > image.size.height {
                                    firstSpreadImage = image
                                    continue
                                }
                                
                                return image
                            }
                        } catch {
                            Logger.shared.log("Failed to extract \(entry.path): \(error.localizedDescription)", category: "Archive", type: .error)
                        }
                    }
                }
                
                return firstSpreadImage
            } catch {
                Logger.shared.log("Failed to extract archive: \(error.localizedDescription)", category: "Archive", type: .error)
            }
        }
        return nil
    }
    
    nonisolated static func getPageCountStatic(from url: URL) -> Int {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" {
            return PDFDocument(url: url)?.pageCount ?? 0
        }

        if ["cbz", "zip", "epub"].contains(ext) {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            
            guard let archive = try? Archive(url: url, accessMode: .read, pathEncoding: .utf8) else { return 0 }
            
            var count = 0
            for entry in archive {
                if entry.type == .directory { continue }
                let entryExt = (entry.path as NSString).pathExtension.lowercased()
                if ["jpg", "jpeg", "png", "webp"].contains(entryExt) {
                    if entry.path.contains("__MACOSX") || entry.path.hasPrefix(".") { continue }
                    count += 1
                }
            }
            return count
        }
        return 0
    }

    
    // ✅ NEW: Extract Smart Panels from ComicInfo.xml
}
