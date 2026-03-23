import Foundation
import UIKit
import SwiftUI

/// Safely handles all iOS Storage interactions, including disk persistence, thumbnail caching into Application Support, and atomic NSFileCoordinator bindings independent from the Presentation logic.
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
        let key = pdf.id.uuidString as NSString
        if let cached = manager.thumbnailCache.object(forKey: key) { return cached }
        
        return await Task.detached(priority: .userInitiated) { () -> UIImage? in
            if let url = self.getCoverURL(for: pdf), FileManager.default.fileExists(atPath: url.path) {
                if let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
                    let thumbnail = image.preparingThumbnail(of: CGSize(width: 240, height: 360)) ?? image
                    await MainActor.run { manager.thumbnailCache.setObject(thumbnail, forKey: key) }
                    return thumbnail
                }
            }
            if let data = pdf.coverImageData, let image = UIImage(data: data) { return image }
            return nil
        }.value
    }
    
    func saveCoverImage(_ data: Data, for pdf: ConvertedPDF, manager: ConversionManager) {
        guard let coverURL = getCoverURL(for: pdf) else { return }
        try? data.write(to: coverURL)
        
        if let image = UIImage(data: data) {
            let thumbnail = image.preparingThumbnail(of: CGSize(width: 240, height: 360)) ?? image
            let key = pdf.id.uuidString as NSString
            manager.thumbnailCache.setObject(thumbnail, forKey: key)
        }
        
        if let index = manager.convertedPDFs.firstIndex(where: { $0.id == pdf.id }) {
            manager.convertedPDFs[index].coverImageData = nil
            manager.objectWillChange.send()
        }
    }
    
    func deletePDF(_ pdf: ConvertedPDF, manager: ConversionManager) {
        do {
            try FileManager.default.removeItem(at: pdf.url)
            if let coverURL = getCoverURL(for: pdf) {
                try? FileManager.default.removeItem(at: coverURL)
            }
            Logger.shared.log("Deleted File and Cover: \(pdf.name)", category: "Library")
        } catch {
            Logger.shared.log("Failed to delete file: \(error)", category: "Library", type: .error)
        }
        
        if let idx = manager.convertedPDFs.firstIndex(where: { $0.id == pdf.id }) {
            manager.convertedPDFs.remove(at: idx)
            manager.saveLibrary()
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
        
        let url = pdf.url
        let image = await Task.detached(priority: .background) { () -> UIImage? in
            return ConversionManager.extractCoverImageStatic(from: url)
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
        for pdf in pdfsNeedingCovers { Task(priority: .background) { await generateCoverThumbnail(for: pdf, manager: manager) } }
    }
    
    func loadThumbnailAsync(for pdf: ConvertedPDF, manager: ConversionManager) async {
        if manager.thumbnailCache.object(forKey: pdf.id.uuidString as NSString) != nil { return }
        
        if let coverURL = self.getCoverURL(for: pdf),
           let data = try? Data(contentsOf: coverURL),
           let image = UIImage(data: data) {
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
        if let cached = manager.thumbnailCache.object(forKey: pdf.id.uuidString as NSString) { return cached }
        Task.detached(priority: .userInitiated) {
            if let coverURL = self.getCoverURL(for: pdf),
               let data = try? Data(contentsOf: coverURL),
               let image = UIImage(data: data) {
                await MainActor.run {
                    manager.thumbnailCache.setObject(image, forKey: pdf.id.uuidString as NSString)
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
        
        var nsError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: currentURL, options: .forMoving, writingItemAt: newURL, options: .forReplacing, error: &nsError) { newTarget1, newTarget2 in
            do {
                try fileManager.moveItem(at: newTarget1, to: newTarget2)
            } catch {
                Logger.shared.log("Move Failure: \(error)", category: "FileSystem", type: .error)
            }
        }
        
        if let fail = nsError { throw fail }
        
        DispatchQueue.main.async {
            manager.convertedPDFs[idx].url = newURL
            manager.convertedPDFs[idx].name = newURL.lastPathComponent
            manager.saveLibrary()
        }
    }
}

