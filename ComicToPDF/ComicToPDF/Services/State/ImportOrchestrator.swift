import Foundation
import ZIPFoundation
import SwiftUI

/// A dedicated Orchestrator that natively extracts and inherits the incredibly heavy background operations required to parse multi-gigabyte ZIP/CBZ streams and PDF pages cleanly without tying up the Application's main Presentation state object.
@MainActor
class ImportOrchestrator {
    static let shared = ImportOrchestrator()
    private init() {}
    
    func importFolderStructure(from folderURL: URL, manager: ConversionManager) async {
        await MainActor.run { manager.isConverting = true; manager.processingStatus = "Preparing Folder Sync..." }
        defer { Task { await MainActor.run { manager.isConverting = false; manager.processingStatus = "" } } }
        
        let existingNames = await MainActor.run { Set(manager.convertedPDFs.map { $0.name }) }

        let newPDFs: [ConvertedPDF] = await Task.detached(priority: .userInitiated) { () -> [ConvertedPDF] in
            let accessing = folderURL.startAccessingSecurityScopedResource()
            defer { if accessing { folderURL.stopAccessingSecurityScopedResource() } }
            
            do {
                let bookmarkData = try folderURL.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
                await MainActor.run {
                    if !manager.watchedFolders.contains(where: { $0.bookmarkData == bookmarkData }) {
                        let watched = ConversionManager.WatchedFolder(name: folderURL.lastPathComponent, bookmarkData: bookmarkData)
                        manager.watchedFolders.append(watched)
                        manager.saveLibrary()
                    }
                }
            } catch {
                Logger.shared.log("Note: Could not create persistent bookmark for folder: \(error.localizedDescription). Reverting to one-time copy.", category: "Import")
            }
            
            let fileManager = FileManager.default
            let documentsDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            var newlyImported: [ConvertedPDF] = []
            
            await MainActor.run { manager.processingStatus = "Scanning \(folderURL.lastPathComponent)..." }
            
            let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
            guard let enumerator = fileManager.enumerator(at: folderURL, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
            
            var fileCount = 0
            while let fileURL = enumerator.nextObject() as? URL {
                fileCount += 1
                if fileCount % 10 == 0 {
                    let currentCount = fileCount
                    await MainActor.run { manager.processingStatus = "Scanning \(folderURL.lastPathComponent) (\(currentCount) items)..." }
                    await Task.yield()
                }
                
                guard let resourceValues = try? fileURL.resourceValues(forKeys: Set(keys)),
                      let isDirectory = resourceValues.isDirectory, !isDirectory else { continue }
                
                let ext = fileURL.pathExtension.lowercased()
                guard ["cbz", "zip", "epub"].contains(ext) else { continue }
                
                let fileName = fileURL.lastPathComponent
                let destURL = documentsDir.appendingPathComponent(fileName)
                
                if existingNames.contains(fileName) || newlyImported.contains(where: { $0.name == fileName }) { continue }
                
                do {
                    await MainActor.run { manager.processingStatus = "Importing \(fileName)..." }
                    if fileManager.fileExists(atPath: destURL.path) { try fileManager.removeItem(at: destURL) }
                    try fileManager.copyItem(at: fileURL, to: destURL)
                    
                    let attr = try fileManager.attributesOfItem(atPath: destURL.path)
                    let size = attr[.size] as? Int64 ?? 0
                    
                    let seriesName = fileURL.deletingLastPathComponent().lastPathComponent
                    var smartDisplayName = fileName
                    var smartMetadata = PDFMetadata(title: fileName)
                    smartMetadata.series = seriesName
                    
                    let contentExt = destURL.pathExtension.lowercased()
                    var cType: ContentType = .book
                    if contentExt == "pdf" || contentExt == "epub" { cType = .book } else { cType = .comic }
                    
                    if let xmlData = try? LocalComicInfoService.shared.fetchNonDestructiveMetadata(from: destURL) {
                        smartDisplayName = xmlData.displayName
                        smartMetadata.title = xmlData.parsedTitle ?? smartDisplayName
                        smartMetadata.series = xmlData.parsedSeries ?? seriesName
                        smartMetadata.issueNumber = xmlData.parsedNumber
                        smartMetadata.tags.append("Auto XML Scrape")
                    }
                    
                    let pdf = ConvertedPDF(
                        name: smartDisplayName,
                        url: destURL,
                        pageCount: 0,
                        fileSize: size,
                        metadata: smartMetadata,
                        contentType: cType
                    )
                    newlyImported.append(pdf)
                } catch {
                    Logger.shared.log("Failed to sync \(fileName): \(error.localizedDescription)", category: "Import", type: .error)
                }
            }
            return newlyImported
        }.value
        
        await MainActor.run {
            for pdf in newPDFs {
                manager.convertedPDFs.removeAll(where: { $0.url.lastPathComponent == pdf.url.lastPathComponent })
                manager.convertedPDFs.append(pdf)
            }
            manager.saveLibrary()
        }
    }
    
    func importFilesAsSeries(urls: [URL], manager: ConversionManager) async {
        await MainActor.run { manager.isConverting = true; manager.processingStatus = "Preparing Import..." }
        defer { Task { await MainActor.run { manager.isConverting = false; manager.processingStatus = "" } } }
        
        let existingNames = await MainActor.run { Set(manager.convertedPDFs.map { $0.name }) }
        let isVaultUnlocked = await MainActor.run { !SecurityManager.shared.isVaultLocked }

        await MainActor.run { ImportMonitorManager.shared.startImport(totalCount: urls.count) }
        
        let importedPDFs: [ConvertedPDF] = await Task.detached(priority: .userInitiated) { () -> [ConvertedPDF] in
            let fileManager = FileManager.default
            let documentsDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            var newPDFs: [ConvertedPDF] = []
            
            for url in urls {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                
                let fileName = url.lastPathComponent
                let destURL = documentsDir.appendingPathComponent(fileName)
                
                if existingNames.contains(fileName) || newPDFs.contains(where: { $0.name == fileName }) {
                    await ImportMonitorManager.shared.incrementSuccess()
                    continue
                }
                
                do {
                    if fileManager.fileExists(atPath: destURL.path) { try fileManager.removeItem(at: destURL) }
                    try fileManager.copyItem(at: url, to: destURL)
                    let attr = try fileManager.attributesOfItem(atPath: destURL.path)
                    let size = attr[.size] as? Int64 ?? 0
                    
                    var cType: ContentType = .book
                    let ext = destURL.pathExtension.lowercased()
                    if ext == "pdf" || ext == "epub" { cType = .book } else { cType = .comic }
                    
                    var smartDisplayName = fileName
                    var smartMetadata = PDFMetadata(title: fileName)
                    
                    if let xmlData = try? LocalComicInfoService.shared.fetchNonDestructiveMetadata(from: destURL) {
                        smartDisplayName = xmlData.displayName
                        smartMetadata.title = xmlData.parsedTitle ?? smartDisplayName
                        smartMetadata.series = xmlData.parsedSeries
                        smartMetadata.issueNumber = xmlData.parsedNumber
                        smartMetadata.tags.append("Auto XML Scrape")
                    }
                    
                    var pdf = ConvertedPDF(
                        name: smartDisplayName,
                        url: destURL,
                        pageCount: 0,
                        fileSize: size,
                        metadata: smartMetadata,
                        contentType: cType
                    )
                    pdf.isPrivate = isVaultUnlocked
                    newPDFs.append(pdf)
                    
                    await ImportMonitorManager.shared.incrementSuccess()
                } catch {
                    Logger.shared.log("importFilesAsSeries: Failed to copy \(fileName): \(error.localizedDescription)", category: "Import", type: .error)
                    await ImportMonitorManager.shared.incrementFailure()
                }
            }
            return newPDFs
        }.value
        
        await MainActor.run { ImportMonitorManager.shared.completeImport() }
        guard !importedPDFs.isEmpty else { return }
        
        var clusters: [String: [ConvertedPDF]] = [:]
        
        for pdf in importedPDFs {
            let name = pdf.name as NSString
            let regex = try? NSRegularExpression(pattern: "\\[.*?\\]|\\(.*?\\)", options: [])
            let noBrackets = regex?.stringByReplacingMatches(in: name as String, options: [], range: NSRange(location: 0, length: name.length), withTemplate: "") ?? pdf.name
            
            let withoutExt = (noBrackets as NSString).deletingPathExtension
            var seriesName = withoutExt.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "-_.")))
            
            if let range = withoutExt.range(of: "\\s*(v|vol|volume|c|ch|chapter|issue)?\\s*\\d+.*$", options: [.regularExpression, .caseInsensitive]) {
                seriesName = String(withoutExt[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "-_.")))
            }
            
            if seriesName.count < 3 {
                seriesName = pdf.name.components(separatedBy: CharacterSet.decimalDigits).first?.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "-_."))) ?? "Ungrouped"
                
                if seriesName == "Ungrouped" || seriesName.count < 3 {
                    await manager.generateCoverThumbnail(for: pdf)
                    if let coverURL = manager.getOriginalCoverURL(for: pdf) as URL?,
                       let aiDetectedTitle = await CoverVisionAnalyzer.detectTitle(from: coverURL) {
                        seriesName = aiDetectedTitle
                        Logger.shared.log("Vision AI clustered '\(pdf.name)' into '\(aiDetectedTitle)'", category: "AI")
                    } else {
                        seriesName = "Ungrouped"
                    }
                }
            }
            
            if seriesName.isEmpty { seriesName = "Ungrouped" }
            clusters[seriesName, default: []].append(pdf)
        }
        
        let finalClusters = clusters
        await MainActor.run {
            for (series, clusterPDFs) in finalClusters {
                if clusterPDFs.count > 1 && series != "Ungrouped" {
                    Task { await self.finalizeSeriesImport(pdfs: clusterPDFs, seriesName: series, manager: manager) }
                } else {
                    for pdf in clusterPDFs {
                        manager.convertedPDFs.removeAll(where: { $0.url.lastPathComponent == pdf.url.lastPathComponent })
                        manager.convertedPDFs.append(pdf)
                    }
                }
            }
            
            manager.saveLibrary()
            
            for pdf in importedPDFs {
                Task { await manager.generateCoverThumbnail(for: pdf) }
            }
        }
    }
    
    func finalizeSeriesImport(pdfs: [ConvertedPDF], seriesName: String, manager: ConversionManager) async {
        await MainActor.run {
            let targetCollection: PDFCollection
            if let existing = manager.collections.first(where: { $0.name == seriesName }), !seriesName.isEmpty {
                targetCollection = existing
            } else if !seriesName.isEmpty {
                let newCol = PDFCollection(id: UUID(), name: seriesName, icon: "books.vertical", color: "orange", creationDate: Date())
                manager.collections.append(newCol)
                targetCollection = newCol
            } else {
                for pdf in pdfs {
                    manager.convertedPDFs.removeAll(where: { $0.url.lastPathComponent == pdf.url.lastPathComponent })
                    manager.convertedPDFs.append(pdf)
                }
                manager.saveLibrary()
                return
            }
            
            for var pdf in pdfs {
                pdf.collectionId = targetCollection.id
                pdf.metadata.series = seriesName
                manager.convertedPDFs.removeAll(where: { $0.url.lastPathComponent == pdf.url.lastPathComponent })
                manager.convertedPDFs.append(pdf)
            }
            manager.saveLibrary()
        }
        for pdf in pdfs { Task { await manager.generateCoverThumbnail(for: pdf) } }
    }
    
    func assignToSeries(_ pdf: ConvertedPDF, seriesName: String, manager: ConversionManager) {
        let targetCollection: PDFCollection
        if let existing = manager.collections.first(where: { $0.name == seriesName }) {
            targetCollection = existing
        } else {
            let newCol = PDFCollection(id: UUID(), name: seriesName, icon: "books.vertical", color: "orange", creationDate: Date())
            manager.collections.append(newCol)
            targetCollection = newCol
        }
        
        if let index = manager.convertedPDFs.firstIndex(where: { $0.id == pdf.id }) {
            manager.convertedPDFs[index].collectionId = targetCollection.id
            manager.convertedPDFs[index].metadata.series = seriesName
        }
        manager.saveLibrary()
    }
    
    func syncWatchedFolders(manager: ConversionManager) async {
        let localFolders = await MainActor.run { manager.watchedFolders }
        guard !localFolders.isEmpty else { return }
        
        await MainActor.run { manager.isConverting = true; manager.processingStatus = "Background Folder Sync..." }
        defer { Task { await MainActor.run { manager.isConverting = false; manager.processingStatus = "" } } }
        
        let existingNames = await MainActor.run { Set(manager.convertedPDFs.map { $0.name }) }
        
        let newPDFs: [ConvertedPDF] = await Task.detached(priority: .userInitiated) { () -> [ConvertedPDF] in
            let fileManager = FileManager.default
            let documentsDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            var newlyImported: [ConvertedPDF] = []
            var staleBookmarkIndices: [Int] = []
            
            for (index, folder) in localFolders.enumerated() {
                var isStale = false
                do {
                    await MainActor.run { manager.processingStatus = "Resolving \(folder.name)..." }
                    let resolvedURL = try URL(resolvingBookmarkData: folder.bookmarkData, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &isStale)
                    
                    if isStale {
                        staleBookmarkIndices.append(index)
                        continue
                    }
                    
                    let accessing = resolvedURL.startAccessingSecurityScopedResource()
                    defer { if accessing { resolvedURL.stopAccessingSecurityScopedResource() } }
                    
                    let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
                    guard let enumerator = fileManager.enumerator(at: resolvedURL, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { continue }
                    
                    var fileCount = 0
                    while let fileURL = enumerator.nextObject() as? URL {
                        fileCount += 1
                        if fileCount % 10 == 0 {
                            let currentCount = fileCount
                            await MainActor.run { manager.processingStatus = "Scanning \(folder.name) (\(currentCount) items)..." }
                            await Task.yield()
                        }
                        
                        guard let resourceValues = try? fileURL.resourceValues(forKeys: Set(keys)),
                              let isDirectory = resourceValues.isDirectory, !isDirectory else { continue }
                        
                        let ext = fileURL.pathExtension.lowercased()
                        guard ["cbz", "zip", "epub"].contains(ext) else { continue }
                        
                        let fileName = fileURL.lastPathComponent
                        let destURL = documentsDir.appendingPathComponent(fileName)
                        
                        if existingNames.contains(fileName) || newlyImported.contains(where: { $0.name == fileName }) { continue }
                        
                        do {
                            await MainActor.run { manager.processingStatus = "Syncing \(fileName)..." }
                            if fileManager.fileExists(atPath: destURL.path) { try fileManager.removeItem(at: destURL) }
                            try fileManager.copyItem(at: fileURL, to: destURL)
                            
                            let attr = try fileManager.attributesOfItem(atPath: destURL.path)
                            let size = attr[.size] as? Int64 ?? 0
                            
                            let seriesName = fileURL.deletingLastPathComponent().lastPathComponent
                            var metadata = PDFMetadata(title: fileName)
                            metadata.series = seriesName
                            
                            let contentExt = destURL.pathExtension.lowercased()
                            var cType: ContentType = .book
                            if contentExt == "pdf" { cType = .book }
                            else if contentExt == "epub" { cType = .book }
                            else { cType = .comic }
                            
                            let pdf = ConvertedPDF(
                                name: fileName,
                                url: destURL,
                                pageCount: 0,
                                fileSize: size,
                                metadata: metadata,
                                contentType: cType
                            )
                            newlyImported.append(pdf)
                        } catch {
                            Logger.shared.log("Failed to sync \(fileName): \(error.localizedDescription)", category: "Import", type: .error)
                        }
                    }
                } catch {
                    Logger.shared.log("Could not resolve bookmark for \(folder.name): \(error.localizedDescription)", category: "Import")
                }
            }
            
            if !staleBookmarkIndices.isEmpty {
                let finalStale = staleBookmarkIndices
                await MainActor.run {
                    for i in finalStale.sorted(by: >) { manager.watchedFolders.remove(at: i) }
                    manager.saveLibrary()
                }
            }
            return newlyImported
        }.value
        
        if newPDFs.isEmpty { return }
        await MainActor.run {
            for var newPdf in newPDFs {
                if let seriesName = newPdf.metadata.series, !seriesName.isEmpty {
                    if let existingCol = manager.collections.first(where: { $0.name == seriesName }) {
                        newPdf.collectionId = existingCol.id
                    } else {
                        let newCol = PDFCollection(id: UUID(), name: seriesName, icon: "folder", color: "blue", creationDate: Date())
                        manager.collections.append(newCol)
                        newPdf.collectionId = newCol.id
                    }
                }
                manager.convertedPDFs.removeAll(where: { $0.url.lastPathComponent == newPdf.url.lastPathComponent })
                manager.convertedPDFs.append(newPdf)
            }
            manager.saveLibrary()
        }
        for pdf in newPDFs { Task { await manager.generateCoverThumbnail(for: pdf) } }
    }
    
    func detectContentType(from url: URL, manager: ConversionManager) -> ContentType {
        let ext = url.pathExtension.lowercased()
        let filename = url.deletingPathExtension().lastPathComponent.lowercased()
        
        let mangaKeywords = ["manga", "tankobon", "volume", "chapter", "inuyasha", "shonen", "shoujo", "seinen", "josei"]
        if mangaKeywords.contains(where: { filename.contains($0) }) { return .manga }
        
        switch ext {
        case "cbz", "zip": return manager.conversionSettings.mangaMode ? .manga : .comic
        case "pdf":
            let importer = PDFImporter()
            return importer.hasTextContent(url: url) ? .book : .hybrid
        case "epub":
            do {
                guard let archive = try? Archive(url: url, accessMode: .read, pathEncoding: .utf8) else { return .book }
                if let containerEntry = archive["META-INF/container.xml"] {
                    var containerData = Data()
                    _ = try archive.extract(containerEntry) { data in containerData.append(data) }
                    
                    if let containerStr = String(data: containerData, encoding: .utf8),
                       let opfPath = containerStr.components(separatedBy: "full-path=\"").last?.components(separatedBy: "\"").first,
                       let opfEntry = archive[opfPath] {
                        
                        var opfData = Data()
                        _ = try archive.extract(opfEntry) { data in opfData.append(data) }
                        
                        if let opfStr = String(data: opfData, encoding: .utf8) {
                            let lowerOPF = opfStr.lowercased()
                            if lowerOPF.contains("pre-paginated") || lowerOPF.contains("comic-book") || lowerOPF.contains("manga") {
                                return .hybrid
                            }
                        }
                    }
                }
            } catch { return .book }
            return .book
        default: return .hybrid
        }
    }
    
    func importPDF(url: URL, manager: ConversionManager) async {
        let fileName = url.deletingPathExtension().lastPathComponent
        await MainActor.run { manager.processingStatus = "Importing \(fileName)..." }
        
        do {
            let tempPDFURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
            try FileManager.default.copyItem(at: url, to: tempPDFURL)
            defer { try? FileManager.default.removeItem(at: tempPDFURL) }
            
            let importer = PDFImporter()
            let settings = manager.conversionSettings
            
            let (extractedCount, newCoverData) = try await Task.detached(priority: .userInitiated) { () -> (Int, Data?) in
                let pageCount = importer.getPageCount(url: tempPDFURL)
                guard pageCount > 0 else { throw PDFImporter.ImportError.emptyPDF }
                
                let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: tempDir) }
                
                let maxConcurrent = 4 
                
                return try await withThrowingTaskGroup(of: (Int, Data?).self) { group in
                    var processedCount = 0
                    var firstPageData: Data? = nil
                    
                    for index in 0..<pageCount {
                        if index >= maxConcurrent {
                           if let result = try await group.next() {
                               if result.0 == 0 { firstPageData = result.1 }
                               processedCount += 1
                               
                               let currentCount = processedCount
                               let progress = Double(currentCount) / Double(pageCount)
                               await MainActor.run {
                                   manager.processingStatus = "Importing Page \(currentCount) of \(pageCount)"
                                   manager.conversionProgress = progress
                               }
                           }
                        }
                        
                        group.addTask {
                             try autoreleasepool {
                                let image = try importer.extractPage(url: tempPDFURL, pageIndex: index, dpi: 300)
                                let imageName = String(format: "page_%04d.jpg", index + 1)
                                let imageURL = tempDir.appendingPathComponent(imageName)
                                
                                if let data = image.jpegData(compressionQuality: settings.compressionQuality.value) {
                                    try data.write(to: imageURL)
                                    return (index, index == 0 ? data : nil)
                                }
                                return (index, nil)
                             }
                        }
                    }
                    
                    for try await result in group {
                        if result.0 == 0 { firstPageData = result.1 }
                        processedCount += 1
                        let currentCount = processedCount
                        let progress = Double(currentCount) / Double(pageCount)
                        await MainActor.run {
                            manager.processingStatus = "Importing Page \(currentCount) of \(pageCount)"
                            manager.conversionProgress = progress
                        }
                    }
                    
                    let cbzName = fileName + ".cbz"
                    let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    let cbzURL = docDir.appendingPathComponent(cbzName)
                    
                    if FileManager.default.fileExists(atPath: cbzURL.path) {
                        try FileManager.default.removeItem(at: cbzURL)
                    }
                    try await ZipUtilities.zipDirectory(tempDir, to: cbzURL)
                    
                    return (pageCount, firstPageData)
                }
            }.value
            
            let contentType = detectContentType(from: url, manager: manager)
            
            let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let cbzName = fileName + ".cbz"
            let cbzURL = docDir.appendingPathComponent(cbzName)
            let attributes = try FileManager.default.attributesOfItem(atPath: cbzURL.path)
            let fileSize = attributes[.size] as? Int64 ?? 0
            
            let newPDF = ConvertedPDF(
                id: UUID(), name: fileName, url: cbzURL,
                pageCount: extractedCount, fileSize: fileSize,
                metadata: PDFMetadata(title: fileName), contentType: contentType
            )
            
            if let coverData = newCoverData {
                manager.saveCoverImage(coverData, for: newPDF)
            }
            
            await MainActor.run {
                manager.convertedPDFs.append(newPDF)
                manager.saveLibrary()
                manager.processingStatus = ""
            }
            
        } catch {
            await MainActor.run {
                manager.processingStatus = "PDF import failed: \(error.localizedDescription)"
                manager.appAlert = AppAlert(title: "Import Failed", message: "Could not import PDF: \(error.localizedDescription)")
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await MainActor.run { manager.processingStatus = "" }
        }
    }
}

