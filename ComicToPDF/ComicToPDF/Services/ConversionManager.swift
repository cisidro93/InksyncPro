import SwiftUI
import PDFKit
import ZIPFoundation

@MainActor
class ConversionManager: ObservableObject {
    @Published var convertedPDFs: [ConvertedPDF] = []
    @Published var collections: [PDFCollection] = []
    @Published var conversionPresets: [ConversionPreset] = []
    @Published var kindleDevices: [KindleDevice] = []
    @Published var sendHistory: [ConvertedPDF] = []
    @Published var activeTasks: [AppBackgroundTask] = []
    @Published var conversionSettings = ConversionSettings()
    
    // Enterprise: Manual Overrides
    @Published var panelOverrides: [UUID: [Int: [PanelExtractor.Panel]]] = [:]
    
    // UI State
    @Published var isConverting = false
    @Published var conversionProgress: Double = 0.0
    @Published var processingStatus = ""
    @Published var statusMessage: String?
    
    @Published var showingPanelEditor = false
    @Published var currentPanelSession: PanelEditSession?
    @Published var panelEditorCompletion: ((PanelEditSession?) -> Void)?
    
    let thumbnailCache = NSCache<NSString, UIImage>()
    private let libraryFileName = "library_index.json"
    
    init() {
        loadLibrary()
        scanLibrary()
    }
    
    // MARK: - Memory Management
    func cleanupMemory() {
        thumbnailCache.removeAllObjects()
    }
    
    // MARK: - Persistence
    func saveLibrary() {
        struct LibraryIndex: Codable {
            let files: [ConvertedPDF]
            let collections: [PDFCollection]
            let settings: ConversionSettings
            let history: [ConvertedPDF]
            let devices: [KindleDevice]
        }
        let index = LibraryIndex(files: convertedPDFs, collections: collections, settings: conversionSettings, history: sendHistory, devices: kindleDevices)
        if let url = fileURL(for: libraryFileName), let encoded = try? JSONEncoder().encode(index) { try? encoded.write(to: url) }
    }
    func savePDFs() { saveLibrary() }
    func loadLibrary() {
        struct LibraryIndex: Codable {
            let files: [ConvertedPDF]
            let collections: [PDFCollection]
            let settings: ConversionSettings
            let history: [ConvertedPDF]
            let devices: [KindleDevice]
        }
        guard let url = fileURL(for: libraryFileName), let data = try? Data(contentsOf: url), let index = try? JSONDecoder().decode(LibraryIndex.self, from: data) else { return }
        self.convertedPDFs = index.files
        self.collections = index.collections
        self.conversionSettings = index.settings
        self.sendHistory = index.history
        self.kindleDevices = index.devices
    }
    private func fileURL(for name: String) -> URL? { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent(name) }
    
    func savePanelOverrides(for pdfID: UUID, pageIndex: Int, panels: [PanelExtractor.Panel]) async {
        if panelOverrides[pdfID] == nil { panelOverrides[pdfID] = [:] }
        panelOverrides[pdfID]?[pageIndex] = panels
    }
    
    // MARK: - File Management
    func scanLibrary() {
        let fileManager = FileManager.default
        let docDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        do {
            let fileURLs = try fileManager.contentsOfDirectory(at: docDir, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])
            let allowed = ["cbz", "cbr", "pdf", "epub", "zip"]
            let diskFiles = fileURLs.filter { allowed.contains($0.pathExtension.lowercased()) }
            
            convertedPDFs.removeAll { pdf in !diskFiles.contains(where: { $0.lastPathComponent == pdf.url.lastPathComponent }) }
            
            for url in diskFiles {
                if !convertedPDFs.contains(where: { $0.url.lastPathComponent == url.lastPathComponent }) {
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                    let newPDF = ConvertedPDF(name: url.lastPathComponent, url: url, pageCount: 0, fileSize: Int64(size), metadata: PDFMetadata(title: url.lastPathComponent), collectionId: nil)
                    convertedPDFs.append(newPDF)
                    Task { await self.generateCoverThumbnail(for: newPDF) }
                }
            }
            for pdf in convertedPDFs { if thumbnailCache.object(forKey: pdf.url.path as NSString) == nil { Task { await self.generateCoverThumbnail(for: pdf) } } }
            saveLibrary()
        } catch { print("Scan Error: \(error)") }
    }
    func deletePDF(_ pdf: ConvertedPDF) {
        try? FileManager.default.removeItem(at: pdf.url)
        if let idx = convertedPDFs.firstIndex(where: { $0.id == pdf.id }) { convertedPDFs.remove(at: idx); saveLibrary() }
    }
    func removeFromLibrary(_ pdf: ConvertedPDF) { deletePDF(pdf) }
    func addConvertedPDF(url: URL, pageCount: Int = 0, fileSize: Int64 = 0, duration: TimeInterval = 0) {
         let pdf = ConvertedPDF(name: url.lastPathComponent, url: url, pageCount: pageCount, fileSize: fileSize, metadata: PDFMetadata(title: url.lastPathComponent), collectionId: nil)
         convertedPDFs.append(pdf)
         saveLibrary()
         Task { await self.generateCoverThumbnail(for: pdf) }
     }
    
    // MARK: - Safe Image Loading (OOM Fix)
    
    // ✅ NEW: Returns File URLs instead of massive Image Arrays
    func extractImageFiles(from url: URL) async throws -> (workingDir: URL, files: [URL]) {
        return try await Task.detached {
            let fileManager = FileManager.default
            let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
            
            try fileManager.unzipItem(at: url, to: tempDir)
            
            var imageURLs: [URL] = []
            let validExts = ["jpg", "jpeg", "png", "webp"]
            let subPaths = try fileManager.subpathsOfDirectory(atPath: tempDir.path)
            let imagePaths = subPaths.filter { validExts.contains(($0 as NSString).pathExtension.lowercased()) }.sorted()
            
            for subPath in imagePaths {
                imageURLs.append(tempDir.appendingPathComponent(subPath))
            }
            
            return (tempDir, imageURLs)
        }.value
    }
    
    func extractFullPage(from pdf: ConvertedPDF, index: Int) async throws -> UIImage? {
        return try await Task.detached {
            let fileManager = FileManager.default
            let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: tempDir) }
            
            try fileManager.unzipItem(at: pdf.url, to: tempDir)
            
            let validExts = ["jpg", "jpeg", "png", "webp"]
            let subPaths = try fileManager.subpathsOfDirectory(atPath: tempDir.path)
            let imagePaths = subPaths.filter { validExts.contains(($0 as NSString).pathExtension.lowercased()) }.sorted()
            
            guard index < imagePaths.count else { return nil }
            let fullPath = tempDir.appendingPathComponent(imagePaths[index])
            return ConversionManager.loadDownsampledImageStatic(at: fullPath, maxDimension: 1920)
        }.value
    }
    
    nonisolated static func loadDownsampledImageStatic(at url: URL, maxDimension: CGFloat) -> UIImage? {
        let options: [CFString: Any] = [ kCGImageSourceShouldCache: false ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary) else { return nil }
        
        let downsampleOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    // MARK: - Merge & Convert
    func mergePDFs(_ pdfs: [ConvertedPDF], outputName: String) async {
        isConverting = true; processingStatus = "Merging..."; statusMessage = "Starting merge..."
        let fileManager = FileManager.default; let docDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let safeName = outputName.isEmpty ? "Merged_Collection" : outputName; let outputURL = docDir.appendingPathComponent("\(safeName).epub")
        let merger = EPUBMerger(); let sourceURLs = pdfs.map { $0.url }
        var inheritedCover: UIImage?
        if let firstPDF = pdfs.first { inheritedCover = getThumbnail(for: firstPDF) }
        do {
            try await Task.detached { try await merger.mergeEPUBs(sourceURLs: sourceURLs, outputURL: outputURL, settings: ConversionSettings()) }.value
            let fileSize = (try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            let newPDF = ConvertedPDF(name: outputURL.lastPathComponent, url: outputURL, pageCount: 0, fileSize: fileSize, metadata: PDFMetadata(title: safeName))
            convertedPDFs.append(newPDF)
            if let cover = inheritedCover { thumbnailCache.setObject(cover, forKey: outputURL.path as NSString); objectWillChange.send() }
            else { Task { await self.generateCoverThumbnail(for: newPDF) } }
            isConverting = false; statusMessage = "✅ Merge Complete!"; scanLibrary()
            try? await Task.sleep(nanoseconds: 3 * 1_000_000_000); self.statusMessage = nil
        } catch { isConverting = false; statusMessage = "Merge Error: \(error.localizedDescription)" }
    }
    
    func convertComic(_ pdf: ConvertedPDF, mangaMode: Bool) async {
        isConverting = true; conversionProgress = 0.0; processingStatus = "Converting..."; statusMessage = "Starting..."
        let converter = CBZToEPUBConverter(); var jobSettings = conversionSettings; jobSettings.mangaMode = mangaMode; let fileOverrides = panelOverrides[pdf.id]
        do {
            let newURLs = try await converter.convert(sourceURL: pdf.url, settings: jobSettings, manualManifest: fileOverrides) { progress in Task { @MainActor in self.conversionProgress = progress; self.processingStatus = "Converting \(Int(progress * 100))%" } }
            for newURL in newURLs {
                let newFile = ConvertedPDF(name: newURL.lastPathComponent, url: newURL, pageCount: 0, fileSize: (try? newURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0, metadata: PDFMetadata(title: newURL.lastPathComponent))
                convertedPDFs.append(newFile)
            }
            isConverting = false; conversionProgress = 1.0; statusMessage = "✅ Conversion Complete! (\(newURLs.count) files)"; scanLibrary()
            try? await Task.sleep(nanoseconds: 3 * 1_000_000_000); self.statusMessage = nil
        } catch { isConverting = false; statusMessage = "Error: \(error.localizedDescription)" }
    }

    // MARK: - Thumbnails & Helpers
    func generateCoverThumbnail(for pdf: ConvertedPDF) async {
        let url = pdf.url
        let image = await Task.detached(priority: .userInitiated) { return ConversionManager.extractCoverImageStatic(from: url) }.value
        if let image { self.thumbnailCache.setObject(image, forKey: url.path as NSString); self.objectWillChange.send() }
    }
    func getThumbnail(for pdf: ConvertedPDF) -> UIImage? {
        if let cached = thumbnailCache.object(forKey: pdf.url.path as NSString) { return cached }
        Task { await generateCoverThumbnail(for: pdf) }
        return UIImage(systemName: "doc.text.fill")
    }
    nonisolated static func extractCoverImageStatic(from url: URL) -> UIImage? {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" { guard let document = PDFDocument(url: url), let page = document.page(at: 0) else { return nil }; return page.thumbnail(of: CGSize(width: 300, height: 450), for: .mediaBox) }
        if ["cbz", "cbr", "zip", "epub"].contains(ext) {
            guard let archive = try? Archive(url: url, accessMode: .read) else { return nil }
            let imageExtensions = ["jpg", "jpeg", "png", "webp"]
            let sortedEntries = archive.makeIterator().sorted { $0.path < $1.path }
            for entry in sortedEntries {
                let entryExt = (entry.path as NSString).pathExtension.lowercased()
                if imageExtensions.contains(entryExt) {
                    if entry.path.contains("__MACOSX") || entry.path.hasPrefix(".") { continue }
                    var data = Data()
                    do { _ = try archive.extract(entry) { chunk in data.append(chunk) }; return UIImage(data: data) } catch { continue }
                }
            }
        }
        return nil
    }
    func processImportedFiles(urls: [URL]) async {
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource(); defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                let fileName = url.lastPathComponent; let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]; let destURL = docDir.appendingPathComponent(fileName)
                if FileManager.default.fileExists(atPath: destURL.path) { try FileManager.default.removeItem(at: destURL) }
                try FileManager.default.copyItem(at: url, to: destURL)
            } catch { print("Import Failed: \(error)") }
        }
        scanLibrary()
    }
    
    // MARK: - Collection Management
    func createCollection(name: String, icon: String, color: String) { collections.append(PDFCollection(id: UUID(), name: name, icon: icon, color: color, creationDate: Date())); saveLibrary() }
    func deleteCollection(_ collection: PDFCollection) { collections.removeAll { $0.id == collection.id }; for i in 0..<convertedPDFs.count { if convertedPDFs[i].collectionId == collection.id { convertedPDFs[i].collectionId = nil } }; saveLibrary() }
    func movePDFToCollection(_ pdf: ConvertedPDF, collectionId: UUID?) { if let idx = convertedPDFs.firstIndex(where: { $0.id == pdf.id }) { convertedPDFs[idx].collectionId = collectionId; saveLibrary() } }
    
    // MARK: - PAGE EDITING
    
    func deletePages(from pdf: ConvertedPDF, pageIndices: Set<Int>) async throws {
        let sourceURL = pdf.url
        try await Task.detached {
            let fileManager = FileManager.default
            let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: tempDir) }
            
            try fileManager.unzipItem(at: sourceURL, to: tempDir)
            
            let keys: [URLResourceKey] = [.nameKey, .isDirectoryKey]
            guard let enumerator = fileManager.enumerator(at: tempDir, includingPropertiesForKeys: keys) else { return }
            
            var imageURLs: [URL] = []
            let validExts = ["jpg", "jpeg", "png", "webp"]
            while let fileURL = enumerator.nextObject() as? URL {
                if validExts.contains(fileURL.pathExtension.lowercased()) {
                    imageURLs.append(fileURL)
                }
            }
            imageURLs.sort { $0.lastPathComponent < $1.lastPathComponent }
            
            // Delete selected
            for (index, url) in imageURLs.enumerated() {
                if pageIndices.contains(index) {
                    try fileManager.removeItem(at: url)
                }
            }
            
            // Re-zip
            let newURL = tempDir.appendingPathComponent("repacked.cbz")
            try fileManager.zipItem(at: tempDir, to: newURL)
            
            if fileManager.fileExists(atPath: sourceURL.path) { try fileManager.removeItem(at: sourceURL) }
            try fileManager.moveItem(at: newURL, to: sourceURL)
        }.value
        scanLibrary()
    }
    
    func reorderPages(in url: URL, newOrder: [Int]) async throws -> URL {
        return try await Task.detached {
            let fileManager = FileManager.default
            let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: tempDir) }
            
            try fileManager.unzipItem(at: url, to: tempDir)
            
            let keys: [URLResourceKey] = [.nameKey]
            guard let enumerator = fileManager.enumerator(at: tempDir, includingPropertiesForKeys: keys) else { return url }
            
            var imageURLs: [URL] = []
            let validExts = ["jpg", "jpeg", "png", "webp"]
            while let fileURL = enumerator.nextObject() as? URL {
                if validExts.contains(fileURL.pathExtension.lowercased()) { imageURLs.append(fileURL) }
            }
            imageURLs.sort { $0.lastPathComponent < $1.lastPathComponent }
            
            guard imageURLs.count == newOrder.count else { return url }
            
            let stagingDir = tempDir.appendingPathComponent("staging")
            try fileManager.createDirectory(at: stagingDir, withIntermediateDirectories: true)
            
            for (newIndex, oldIndex) in newOrder.enumerated() {
                if oldIndex < imageURLs.count {
                    let oldURL = imageURLs[oldIndex]
                    let ext = oldURL.pathExtension
                    let newName = String(format: "page_%05d.%@", newIndex, ext)
                    try fileManager.copyItem(at: oldURL, to: stagingDir.appendingPathComponent(newName))
                }
            }
            
            for url in imageURLs { try? fileManager.removeItem(at: url) }
            let stagedFiles = try fileManager.contentsOfDirectory(at: stagingDir, includingPropertiesForKeys: nil)
            for file in stagedFiles {
                try fileManager.moveItem(at: file, to: tempDir.appendingPathComponent(file.lastPathComponent))
            }
            try fileManager.removeItem(at: stagingDir)
            
            let newCBZ = tempDir.appendingPathComponent("reordered.cbz")
            try fileManager.zipItem(at: tempDir, to: newCBZ)
            
            if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
            try fileManager.moveItem(at: newCBZ, to: url)
            
            return url
        }.value
    }
    
    func extractPages(from pdf: ConvertedPDF, pageIndices: [Int], asImages: Bool) async throws -> URL {
        return try await Task.detached {
            let fileManager = FileManager.default
            let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: tempDir) }
            
            try fileManager.unzipItem(at: pdf.url, to: tempDir)
            
            let keys: [URLResourceKey] = [.nameKey]
            var imageURLs: [URL] = []
            let enumerator = fileManager.enumerator(at: tempDir, includingPropertiesForKeys: keys)
            let validExts = ["jpg", "jpeg", "png", "webp"]
            
            while let fileURL = enumerator?.nextObject() as? URL {
                if validExts.contains(fileURL.pathExtension.lowercased()) { imageURLs.append(fileURL) }
            }
            imageURLs.sort { $0.lastPathComponent < $1.lastPathComponent }
            
            let indicesSet = Set(pageIndices)
            var keptURLs: [URL] = []
            
            for (index, url) in imageURLs.enumerated() {
                if indicesSet.contains(index) { keptURLs.append(url) }
            }
            
            guard !keptURLs.isEmpty else { throw NSError(domain: "Extraction", code: 1, userInfo: [NSLocalizedDescriptionKey: "No pages selected"]) }
            
            let destDir = fileManager.temporaryDirectory.appendingPathComponent("Extracted_\(UUID().uuidString)")
            try fileManager.createDirectory(at: destDir, withIntermediateDirectories: true)
            
            for (i, url) in keptURLs.enumerated() {
                let newName = String(format: "page_%05d.jpg", i)
                try fileManager.copyItem(at: url, to: destDir.appendingPathComponent(newName))
            }
            
            let finalName = "\(pdf.name)_extracted.cbz"
            let finalURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(finalName)
            if fileManager.fileExists(atPath: finalURL.path) { try fileManager.removeItem(at: finalURL) }
            try fileManager.zipItem(at: destDir, to: finalURL)
            
            return finalURL
        }.value
    }
    
    func extractPages(from pdf: ConvertedPDF, pageIndices: Range<Int>, asImages: Bool) async throws -> URL {
        return try await extractPages(from: pdf, pageIndices: Array(pageIndices), asImages: asImages)
    }
    
    func extractImageURLs(from url: URL) async throws -> [URL] {
        return []
    }
    
    // Helpers
    func autoOrganize() {}
    func findDuplicates() async -> [DuplicateGroup] { return [] }
    func calculateStorageInfo() -> StorageInfo { let total = convertedPDFs.reduce(0) { $0 + $1.fileSize }; return StorageInfo(used: total, totalSize: 10_000_000_000, appUsage: total) }
    func createBackupData() -> BackupData { return BackupData(version: "1.0", date: Date(), settings: conversionSettings, collections: collections, presets: conversionPresets) }
    func restoreFromBackup(_ backup: BackupData) { self.conversionSettings = backup.settings; self.collections = backup.collections; self.conversionPresets = backup.presets; saveLibrary() }
    func addKindleDevice(_ device: KindleDevice) { kindleDevices.append(device); saveLibrary() }
    func removeKindleDevice(_ device: KindleDevice) { kindleDevices.removeAll { $0.id == device.id }; saveLibrary() }
    func updateKindleDevice(_ device: KindleDevice) { if let idx = kindleDevices.firstIndex(where: { $0.id == device.id }) { kindleDevices[idx] = device; saveLibrary() } }
    func setDefaultKindleDevice(_ device: KindleDevice) { for i in 0..<kindleDevices.count { kindleDevices[i].isDefault = (kindleDevices[i].id == device.id) }; saveLibrary() }
    func clearSendHistory() { sendHistory.removeAll(); saveLibrary() }
    func saveSettings() { saveLibrary() }
    func savePreset(_ preset: ConversionPreset) { conversionPresets.append(preset); saveLibrary() }
    func deletePreset(_ preset: ConversionPreset) { conversionPresets.removeAll { $0.id == preset.id }; saveLibrary() }
    func updatePDFMetadata(_ pdf: ConvertedPDF, metadata: PDFMetadata) { if let idx = convertedPDFs.firstIndex(where: { $0.id == pdf.id }) { convertedPDFs[idx].metadata = metadata; saveLibrary() } }
}
