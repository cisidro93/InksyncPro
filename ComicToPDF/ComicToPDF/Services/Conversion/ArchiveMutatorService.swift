import Foundation
import ZIPFoundation
import UIKit

@MainActor
class ArchiveMutatorService {
    static let shared = ArchiveMutatorService()
    
    // MARK: - Linked File Write Guard
    
    /// Throws if a linked file is on a read-only drive.
    /// All mutating operations call this first before touching the file.
    private func assertWritable(_ pdf: ConvertedPDF) async throws {
        guard pdf.isLinked else { return }  // Local files always writable
        guard let bm = pdf.driveBookmarkData else { return }
        
        let writable = await BookmarkResolver.shared.checkWritable(bm)
        if !writable {
            throw NSError(
                domain: "ArchiveMutatorService.LinkedFile",
                code: 403,
                userInfo: [NSLocalizedDescriptionKey: "This file is stored on a read-only external drive. Download it to your device first to edit it."]
            )
        }
    }
    
    // MARK: - Page Deletion
    func deletePages(from pdf: ConvertedPDF, pageIndices: Set<Int>, manager: ConversionManager) async throws {
        try await assertWritable(pdf)
        guard !pageIndices.isEmpty else { return }
        await MainActor.run { TaskEngine.shared.processingStatus = "Deleting \(pageIndices.count) pages..." }

        // ✅ FIX: Resolve security-scoped URL for linked drive files before any I/O.
        // pdf.url is the raw registration path — it needs an active scope token to read.
        let resolvedURL: URL
        var needsStopAccess = false
        if case .linked(let bm) = pdf.sourceMode, let resolved = try? BookmarkResolver.shared.resolve(bm) {
            needsStopAccess = resolved.startAccessingSecurityScopedResource()
            resolvedURL = resolved
        } else {
            resolvedURL = pdf.url
        }

        let result = try await EditorSessionManager.shared.extractImageFiles(from: resolvedURL)
        let tempDir = result.workingDir
        let imageFiles = result.files

        defer {
            if needsStopAccess { resolvedURL.stopAccessingSecurityScopedResource() }
            try? FileManager.default.removeItem(at: tempDir)
            Task { @MainActor in TaskEngine.shared.processingStatus = "" }
        }

        let sortedIndices = pageIndices.sorted(by: >)
        var deletedCount = 0
        
        for index in sortedIndices {
            if index < imageFiles.count {
                let fileURL = imageFiles[index]
                try FileManager.default.removeItem(at: fileURL)
                deletedCount += 1
            }
        }
        
        guard deletedCount > 0 else { return }
        
        let newCBZURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".cbz")
        try await ZipUtilities.zipDirectory(tempDir, to: newCBZURL)
        
        if FileManager.default.fileExists(atPath: pdf.url.path) {
            try FileManager.default.removeItem(at: pdf.url)
        }
        try FileManager.default.moveItem(at: newCBZURL, to: pdf.url)
        
        let attr = try FileManager.default.attributesOfItem(atPath: pdf.url.path)
        let newSize = attr[.size] as? Int64 ?? 0
        
        await MainActor.run {
            if let idx = manager.convertedPDFs.firstIndex(where: { $0.id == pdf.id }) {
                manager.convertedPDFs[idx].pageCount -= deletedCount
                manager.convertedPDFs[idx].fileSize = newSize
                PageModelStore.shared.deletePageModels(for: pdf.id)
                manager.saveLibrary()
            }
            Logger.shared.log("Deleted \(deletedCount) pages from \(pdf.name)", category: "Edit")
        }
    }
    
    // MARK: - Page Reordering
    func reorderPages(_ pdf: ConvertedPDF, newOrder: [Int], manager: ConversionManager) async throws -> URL {
        try await assertWritable(pdf)
        let fileManager = FileManager.default

        // ✅ FIX: Resolve security-scoped URL for linked drive files.
        let url: URL
        var needsStopAccess = false
        if case .linked(let bm) = pdf.sourceMode, let resolved = try? BookmarkResolver.shared.resolve(bm) {
            needsStopAccess = resolved.startAccessingSecurityScopedResource()
            url = resolved
        } else {
            url = pdf.url
        }
        defer { if needsStopAccess { url.stopAccessingSecurityScopedResource() } }

        let tempID = UUID().uuidString
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(tempID)
        let tempArchiveURL = fileManager.temporaryDirectory.appendingPathComponent("\(tempID).cbz")
        
        let combinedManifest = await manager.getCombinedManifest(for: pdf)
        var newPanels: [Int: [PanelExtractor.Panel]] = [:]
        
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir); try? fileManager.removeItem(at: tempArchiveURL) }
        
        guard let sourceArchive = try? Archive(url: url, accessMode: .read, pathEncoding: .utf8),
              let destArchive = try? Archive(url: tempArchiveURL, accessMode: .create, pathEncoding: .utf8) else {
            throw NSError(domain: "ArchiveError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not open archive"])
        }
        
        let sortedEntries = sourceArchive.makeIterator().sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        let imageEntries = sortedEntries.filter { entry in
            let ext = (entry.path as NSString).pathExtension.lowercased()
            return ["jpg", "jpeg", "png", "webp"].contains(ext) && !entry.path.contains("__MACOSX") && !entry.path.hasPrefix(".")
        }
        
        for (newIndex, originalIndex) in newOrder.enumerated() {
            try autoreleasepool {
                guard originalIndex < imageEntries.count else { return }
                let entry = imageEntries[originalIndex]
                
                if let panels = combinedManifest[originalIndex] {
                    newPanels[newIndex] = panels
                }
                
                let ext = (entry.path as NSString).pathExtension.lowercased()
                let tempFile = tempDir.appendingPathComponent(entry.path.components(separatedBy: "/").last ?? "temp")
                _ = try sourceArchive.extract(entry, to: tempFile)
                
                let newName = "page_\(String(format: "%05d", newIndex)).\(ext)"
                
                try destArchive.addEntry(with: newName, type: .file, uncompressedSize: Int64(entry.uncompressedSize), modificationDate: Date(), permissions: 0o644, compressionMethod: .deflate, bufferSize: 8192, progress: nil) { position, size in
                    let fileHandle = try? FileHandle(forReadingFrom: tempFile)
                    try? fileHandle?.seek(toOffset: UInt64(position))
                    return fileHandle?.readData(ofLength: size) ?? Data()
                }
                
                try? fileManager.removeItem(at: tempFile)
            }
        }
        
        if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
        try fileManager.moveItem(at: tempArchiveURL, to: url)
        
        manager.scanLibrary()
        
        await MainActor.run {
            PageModelStore.shared.saveAllLegacyVisionPanels(newPanels, for: pdf.id)
            manager.saveLibrary()
        }
        try? await manager.injectMetadata(into: url, panels: newPanels, metadata: pdf.metadata)
        
        return url
    }
    
    // MARK: - Trimming Pages
    func trimPages(from pdf: ConvertedPDF, pageIndices: Set<Int>, trim: (top: Double, bottom: Double, left: Double, right: Double), manager: ConversionManager) async throws {
        try await assertWritable(pdf)
        let ext = pdf.url.pathExtension.lowercased()
        guard ["cbz", "zip", "epub"].contains(ext) else {
            throw NSError(domain: "TrimError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Trimming is only supported for CBZ, ZIP, or EPUB files."])
        }

        // ✅ FIX: Resolve security-scoped URL for linked drive files.
        // Must hold the scope open for the ENTIRE detached task, not just URL resolution.
        let sourceURL: URL
        var needsStopAccess = false
        if case .linked(let bm) = pdf.sourceMode, let resolved = try? BookmarkResolver.shared.resolve(bm) {
            needsStopAccess = resolved.startAccessingSecurityScopedResource()
            sourceURL = resolved
        } else {
            sourceURL = pdf.url
        }
        defer { if needsStopAccess { sourceURL.stopAccessingSecurityScopedResource() } }

        try await Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            let tempID = UUID().uuidString
            let tempDir = fileManager.temporaryDirectory.appendingPathComponent(tempID)
            let tempArchiveURL = fileManager.temporaryDirectory.appendingPathComponent("\(tempID).cbz")
            
            try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: tempDir); try? fileManager.removeItem(at: tempArchiveURL) }
            
            guard let sourceArchive = try? Archive(url: sourceURL, accessMode: .read, pathEncoding: .utf8),
                  let destArchive = try? Archive(url: tempArchiveURL, accessMode: .create, pathEncoding: .utf8) else {
                throw NSError(domain: "ArchiveError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not open archive"])
            }
            
            let sortedEntries = sourceArchive.makeIterator().sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            
            var imageIndexCounter = 0
            
            for entry in sortedEntries {
                try autoreleasepool {
                    let isImage = ["jpg", "jpeg", "png", "webp"].contains((entry.path as NSString).pathExtension.lowercased()) && !entry.path.contains("__MACOSX") && !entry.path.hasPrefix(".")
                    
                    let currentImageIndex = isImage ? imageIndexCounter : -1
                    if isImage { imageIndexCounter += 1 }
                    
                    let tempFile = tempDir.appendingPathComponent(entry.path.components(separatedBy: "/").last ?? "temp")
                    _ = try sourceArchive.extract(entry, to: tempFile)
                    
                    var fileToRead = tempFile
                    var shouldCleanupCrops = false
                    
                    if isImage && pageIndices.contains(currentImageIndex) {
                        if let image = UIImage(contentsOfFile: tempFile.path), let cgImage = image.cgImage {
                            let width = Double(cgImage.width)
                            let height = Double(cgImage.height)
                            let x = width * trim.left
                            let y = height * trim.top
                            let newWidth = width * (1.0 - trim.left - trim.right)
                            let newHeight = height * (1.0 - trim.top - trim.bottom)
                            
                            if let croppedCG = cgImage.cropping(to: CGRect(x: x, y: y, width: newWidth, height: newHeight)) {
                                let croppedImage = UIImage(cgImage: croppedCG)
                                let croppedFile = tempDir.appendingPathComponent("cropped_" + tempFile.lastPathComponent)
                                if let data = croppedImage.jpegData(compressionQuality: 0.8) {
                                    try data.write(to: croppedFile)
                                    fileToRead = croppedFile
                                    shouldCleanupCrops = true
                                }
                            }
                        }
                    }
                    
                    let attr = try fileManager.attributesOfItem(atPath: fileToRead.path)
                    let fileSize = attr[.size] as? Int64 ?? 0
                    
                    try destArchive.addEntry(with: entry.path, type: entry.type, uncompressedSize: fileSize, modificationDate: Date(), permissions: 0o644, compressionMethod: .deflate, bufferSize: 8192, progress: nil) { position, size in
                        let fileHandle = try? FileHandle(forReadingFrom: fileToRead)
                        try? fileHandle?.seek(toOffset: UInt64(position))
                        return fileHandle?.readData(ofLength: size) ?? Data()
                    }
                    
                    try? fileManager.removeItem(at: tempFile)
                    if shouldCleanupCrops { try? fileManager.removeItem(at: fileToRead) }
                }
            }
            
            if fileManager.fileExists(atPath: sourceURL.path) { try fileManager.removeItem(at: sourceURL) }
            try fileManager.moveItem(at: tempArchiveURL, to: sourceURL)
            
        }.value
        
        manager.scanLibrary()
        
        Task {
            await EditorSessionManager.shared.clearCache(for: pdf.id)
        }
        
        if pageIndices.contains(0) {
            await MainActor.run {
                manager.thumbnailCache.removeObject(forKey: pdf.url.path as NSString) // Fixed from uuidString to URL path
            }
            
            if pdf.metadata.selectedCoverID == nil {
                await manager.generateCoverThumbnail(for: pdf)
            }
            
            await MainActor.run {
                manager.objectWillChange.send() 
            }
        }
    }
    
    // MARK: - Extract Cover Variant
    func extractCoverVariant(from pdf: ConvertedPDF, pageIndex: Int, manager: ConversionManager) async throws {
        let fileManager = FileManager.default
        let coversDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent("Covers")
        try? fileManager.createDirectory(at: coversDir, withIntermediateDirectories: true)
        
        guard let archive = try? Archive(url: pdf.url, accessMode: .read, pathEncoding: .utf8) else {
            throw NSError(domain: "CoverError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not open archive"])
        }
        
        let sortedEntries = archive.makeIterator().sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        let imageEntries = sortedEntries.filter { entry in
            let ext = (entry.path as NSString).pathExtension.lowercased()
            return ["jpg", "jpeg", "png", "webp"].contains(ext) && !entry.path.contains("__MACOSX") && !entry.path.hasPrefix(".")
        }
        
        guard pageIndex >= 0 && pageIndex < imageEntries.count else { return }
        
        let targetEntry = imageEntries[pageIndex]
        let tempID = UUID().uuidString
        let tempURL = fileManager.temporaryDirectory.appendingPathComponent(tempID)
        
        _ = try archive.extract(targetEntry, to: tempURL)
        
        guard let extractedImage = UIImage(contentsOfFile: tempURL.path),
              let jpegData = extractedImage.jpegData(compressionQuality: 0.9) else {
            try? fileManager.removeItem(at: tempURL)
            throw NSError(domain: "CoverError", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to render image payload"])
        }
        
        try? fileManager.removeItem(at: tempURL) 
        
        let variantID = UUID()
        let variantURL = coversDir.appendingPathComponent("\(variantID.uuidString).jpg")
        try jpegData.write(to: variantURL)
        
        await MainActor.run {
            if let idx = manager.convertedPDFs.firstIndex(where: { $0.id == pdf.id }) {
                manager.convertedPDFs[idx].metadata.coverVariants[variantID] = variantURL
                manager.saveLibrary()
                manager.objectWillChange.send() 
            }
        }
    }

    // MARK: - Extract Pages
    func extractPages(from pdf: ConvertedPDF, pageIndices: [Int], asImages: Bool, manager: ConversionManager) async throws -> URL {
        let fileManager = FileManager.default
        let newName = "\(pdf.name.replacingOccurrences(of: ".cbz", with: "").replacingOccurrences(of: ".pdf", with: ""))_Split"
        let outputURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent("\(newName).cbz")
        
        let combinedManifest = await manager.getCombinedManifest(for: pdf)
        var newFileOverrides: [Int: [PanelExtractor.Panel]] = [:]
        
        let tempID = UUID().uuidString
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(tempID)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }
        
        try {
            guard let sourceArchive = try? Archive(url: pdf.url, accessMode: .read, pathEncoding: .utf8),
                  let destArchive = try? Archive(url: outputURL, accessMode: .create, pathEncoding: .utf8) else {
                throw NSError(domain: "ArchiveError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not open archive"])
            }
            
            let sortedEntries = sourceArchive.makeIterator().sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            let imageEntries = sortedEntries.filter { entry in
                let ext = (entry.path as NSString).pathExtension.lowercased()
                return ["jpg", "jpeg", "png", "webp"].contains(ext) && !entry.path.contains("__MACOSX") && !entry.path.hasPrefix(".")
            }
            
            for (newIndex, originalIndex) in pageIndices.enumerated() {
                try autoreleasepool {
                    guard originalIndex < imageEntries.count else { return }
                    let entry = imageEntries[originalIndex]
                    
                    if let panels = combinedManifest[originalIndex] {
                        newFileOverrides[newIndex] = panels
                    }
                    
                    let ext = (entry.path as NSString).pathExtension.lowercased()
                    let tempFile = tempDir.appendingPathComponent(entry.path.components(separatedBy: "/").last ?? "temp")
                    _ = try sourceArchive.extract(entry, to: tempFile)
                    
                    let newPageName = "page_\(String(format: "%05d", newIndex)).\(ext)"
                    
                    try destArchive.addEntry(with: newPageName, type: .file, uncompressedSize: Int64(entry.uncompressedSize), modificationDate: Date(), permissions: 0o644, compressionMethod: .deflate, bufferSize: 8192, progress: nil) { position, size in
                        let fileHandle = try? FileHandle(forReadingFrom: tempFile)
                        try? fileHandle?.seek(toOffset: UInt64(position))
                        return fileHandle?.readData(ofLength: size) ?? Data()
                    }
                    try? fileManager.removeItem(at: tempFile)
                }
            }
        }()
        
        manager.scanLibrary()
        
        if let newPDF = manager.convertedPDFs.first(where: { $0.url.standardizedFileURL.path == outputURL.standardizedFileURL.path }) {
            PageModelStore.shared.saveAllLegacyVisionPanels(newFileOverrides, for: newPDF.id)
            manager.saveLibrary()
        }
        
        try? await manager.injectMetadata(into: outputURL, panels: newFileOverrides, metadata: pdf.metadata)
        
        return outputURL
    }
}
