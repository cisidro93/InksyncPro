import Foundation
import UIKit
import Combine
import ZIPFoundation

/// Resolves the 'God Object' bottleneck by handling intensive O(N) file system enumeration strictly off the Main Thread.
actor LibraryScanner {
    static let shared = LibraryScanner()
    
    func scanLibrary(addedByMode: AppUIMode? = nil, manager: ConversionManager) async {
        let fileManager = FileManager.default
        let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        var newPDFs: [ConvertedPDF] = []
        let keys: [URLResourceKey] = [.nameKey, .isDirectoryKey, .fileSizeKey]
        
        let currentPaths = await MainActor.run {
            manager.convertedPDFs.map { $0.url.lastPathComponent }
        }
        
        let pathSet = Set(currentPaths)
        
        // 1. Scan Documents directory natively
        if let enumerator = fileManager.enumerator(at: docDir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) {
            while let fileURL = enumerator.nextObject() as? URL {
                await Task.yield()
                
                // Ignore recovered vault folders from previous tests
                if fileURL.path.contains("Recovered_Vault") || fileURL.path.contains("LibraryVault") { continue }
                
                let ext = fileURL.pathExtension.lowercased()
                if ["pdf", "cbz", "zip", "epub"].contains(ext) {
                    let filename = fileURL.lastPathComponent
                    if !pathSet.contains(filename) {
                        let fileSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                        var newPDF = ConvertedPDF(name: filename, url: fileURL, pageCount: 0, fileSize: fileSize, metadata: PDFMetadata(title: filename))
                        newPDF.addedByMode = addedByMode ?? .pro
                        newPDFs.append(newPDF)
                    }
                }
            }
        }
        
        let finalNewPDFs = newPDFs
        if !finalNewPDFs.isEmpty {
            await MainActor.run {
                manager.convertedPDFs.append(contentsOf: finalNewPDFs)
                Logger.shared.log("Library Scanned: Found \(finalNewPDFs.count) new files (mode: \(addedByMode?.rawValue ?? "Pro"))", category: "Library")
                manager.saveLibrary()
            }
        }
        
        let pdfsToProcess = await MainActor.run {
            manager.convertedPDFs.filter { $0.pageCount == 0 }
        }
        
        if !pdfsToProcess.isEmpty {
            for pdf in pdfsToProcess {
                Task {
                    await manager.generateCoverThumbnail(for: pdf)
                    
                    let count = await Task.detached(priority: .background) {
                        return PhysicalFileSystemRouter.getPageCountStatic(from: pdf.url)
                    }.value
                    
                    if count > 0 {
                        await MainActor.run {
                            if let idx = manager.convertedPDFs.firstIndex(where: { $0.id == pdf.id }) {
                                manager.convertedPDFs[idx].pageCount = count
                            }
                        }
                    }
                    
                    if let validPanels = try? await manager.extractSmartPanels(from: pdf.url) {
                        await MainActor.run {
                            manager.savePanelOverrides(for: pdf.id, panels: validPanels)
                        }
                    }
                }
            }
        }
        
        let allPDFs = await MainActor.run { manager.convertedPDFs }
        let missingIDs = allPDFs.filter { !fileManager.fileExists(atPath: $0.url.path) && !fileManager.fileExists(atPath: docDir.appendingPathComponent($0.url.lastPathComponent).path) }.map { $0.id }
        
        // Let's also enforce deduplication on memory so duplicates already created are pruned for the user
        var uniquePDFs: [ConvertedPDF] = []
        var seenNames = Set<String>()
        for pdf in allPDFs {
            if !seenNames.contains(pdf.url.lastPathComponent) {
                seenNames.insert(pdf.url.lastPathComponent)
                uniquePDFs.append(pdf)
            }
        }
        
        let requiresPrune = !missingIDs.isEmpty || uniquePDFs.count != allPDFs.count
        
        if requiresPrune {
            let finalUnique = uniquePDFs // Prevent concurrent capture warning
            await MainActor.run {
                manager.convertedPDFs = finalUnique
                manager.convertedPDFs.removeAll { missingIDs.contains($0.id) }
                Logger.shared.log("Library Pruned: Removed duplicates or sandbox-shifted files", category: "Library")
                manager.saveLibrary()
            }
        }
    }
}
