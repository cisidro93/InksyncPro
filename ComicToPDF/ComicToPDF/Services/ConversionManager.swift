import SwiftUI
import PDFKit
import ZIPFoundation

class ConversionManager: ObservableObject {
    @Published var convertedPDFs: [ConvertedPDF] = []
    @Published var collections: [PDFCollection] = []
    @Published var conversionPresets: [ConversionPreset] = []
    @Published var kindleDevices: [KindleDevice] = []
    @Published var sendHistory: [ConvertedPDF] = []
    @Published var activeTasks: [AppBackgroundTask] = []
    @Published var conversionSettings = ConversionSettings()
    
    // UI State
    @Published var isConverting = false
    @Published var processingStatus = ""
    @Published var statusMessage: String?
    
    // Editor State
    @Published var showingPanelEditor = false
    @Published var currentPanelSession: PanelEditSession?
    @Published var panelEditorCompletion: ((PanelEditSession?) -> Void)?
    
    let thumbnailCache = NSCache<NSString, UIImage>()
    private let libraryFileName = "library_index.json"
    
    init() {
        loadLibrary()
        scanLibrary()
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
        
        let index = LibraryIndex(
            files: convertedPDFs,
            collections: collections,
            settings: conversionSettings,
            history: sendHistory,
            devices: kindleDevices
        )
        
        if let url = fileURL(for: libraryFileName),
           let encoded = try? JSONEncoder().encode(index) {
            try? encoded.write(to: url)
        }
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
        
        guard let url = fileURL(for: libraryFileName),
              let data = try? Data(contentsOf: url),
              let index = try? JSONDecoder().decode(LibraryIndex.self, from: data) else { return }
        
        self.convertedPDFs = index.files
        self.collections = index.collections
        self.conversionSettings = index.settings
        self.sendHistory = index.history
        self.kindleDevices = index.devices
    }
    
    private func fileURL(for name: String) -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent(name)
    }
    
    // MARK: - File Management
    
    func scanLibrary() {
        let fileManager = FileManager.default
        let docDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        do {
            let fileURLs = try fileManager.contentsOfDirectory(at: docDir, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])
            let allowed = ["cbz", "cbr", "pdf", "epub", "zip"]
            
            let diskFiles = fileURLs.filter { allowed.contains($0.pathExtension.lowercased()) }
            
            // Remove ghosts
            convertedPDFs.removeAll { pdf in
                !diskFiles.contains(where: { $0.lastPathComponent == pdf.url.lastPathComponent })
            }
            
            // Add new
            for url in diskFiles {
                if !convertedPDFs.contains(where: { $0.url.lastPathComponent == url.lastPathComponent }) {
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                    let newPDF = ConvertedPDF(
                        name: url.lastPathComponent,
                        url: url,
                        pageCount: 0,
                        fileSize: Int64(size),
                        metadata: PDFMetadata(title: url.lastPathComponent),
                        collectionId: nil
                    )
                    convertedPDFs.append(newPDF)
                }
            }
            
            DispatchQueue.main.async { self.saveLibrary() }
        } catch { print("Scan Error: \(error)") }
    }
    
    func deletePDF(_ pdf: ConvertedPDF) {
        try? FileManager.default.removeItem(at: pdf.url)
        if let idx = convertedPDFs.firstIndex(where: { $0.id == pdf.id }) {
            convertedPDFs.remove(at: idx)
            saveLibrary()
        }
    }
    
    func removeFromLibrary(_ pdf: ConvertedPDF) {
        deletePDF(pdf)
    }
    
    func addConvertedPDF(url: URL, pageCount: Int = 0, fileSize: Int64 = 0, duration: TimeInterval = 0) {
         let pdf = ConvertedPDF(name: url.lastPathComponent, url: url, pageCount: pageCount, fileSize: fileSize, metadata: PDFMetadata(title: url.lastPathComponent), collectionId: nil)
         convertedPDFs.append(pdf)
         saveLibrary()
     }
    
    // MARK: - Page Management (Core & Advanced)
    
    func extractImages(from url: URL, progressHandler: @escaping (Double) -> Void) async throws -> [UIImage] {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }
        
        try fileManager.unzipItem(at: url, to: tempDir)
        
        let keys: [URLResourceKey] = [.nameKey]
        let enumerator = fileManager.enumerator(at: tempDir, includingPropertiesForKeys: keys)
        var imageURLs: [URL] = []
        let validExts = ["jpg", "jpeg", "png", "webp"]
        
        while let fileURL = enumerator?.nextObject() as? URL {
            if validExts.contains(fileURL.pathExtension.lowercased()) {
                imageURLs.append(fileURL)
            }
        }
        
        imageURLs.sort { $0.lastPathComponent < $1.lastPathComponent }
        
        var images: [UIImage] = []
        for (index, imgURL) in imageURLs.enumerated() {
            if let image = UIImage(contentsOfFile: imgURL.path) {
                images.append(image)
            }
            progressHandler(Double(index) / Double(imageURLs.count))
        }
        return images
    }
    
    func deletePages(from pdf: ConvertedPDF, pageIndices: Set<Int>) async throws {
        let fileManager = FileManager.default
        let sourceURL = pdf.url
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }
        
        try fileManager.unzipItem(at: sourceURL, to: tempDir)
        
        let keys: [URLResourceKey] = [.nameKey]
        guard let enumerator = fileManager.enumerator(at: tempDir, includingPropertiesForKeys: keys) else { return }
        var imageURLs: [URL] = []
        let validExts = ["jpg", "jpeg", "png", "webp"]
        
        while let fileURL = enumerator?.nextObject() as? URL {
            if validExts.contains(fileURL.pathExtension.lowercased()) {
                imageURLs.append(fileURL)
            }
        }
        imageURLs.sort { $0.lastPathComponent < $1.lastPathComponent }
        
        for (index, url) in imageURLs.enumerated() {
            if pageIndices.contains(index) {
                try fileManager.removeItem(at: url)
            }
        }
        
        let newURL = tempDir.appendingPathComponent("repacked.cbz")
        try fileManager.zipItem(at: tempDir, to: newURL)
        
        if fileManager.fileExists(atPath: sourceURL.path) {
            try fileManager.removeItem(at: sourceURL)
        }
        try fileManager.moveItem(at: newURL, to: sourceURL)
        
        await MainActor.run { self.scanLibrary() }
    }
    
    func extractImageURLs(from url: URL) async throws -> [URL] {
        let fileManager = FileManager.default
        // In a real app, this should cache the unzipped content.
        // For this stub, we return empty or implement a temporary unzip similar to above.
        // Returning empty to satisfy compiler for non-core features, or implement if needed.
        return []
    }
    
    func extractPages(from pdf: ConvertedPDF, pageIndices: Range<Int>, asImages: Bool) async throws -> URL {
        // Stub implementation
        return pdf.url
    }
    
    func reorderPages(in url: URL, newOrder: [Int]) async throws -> URL {
        // Stub implementation
        return url
    }
    
    // MARK: - Collections & Organization
    
    func createCollection(name: String, icon: String, color: String) {
        let newCollection = PDFCollection(id: UUID(), name: name, icon: icon, color: color, creationDate: Date())
        collections.append(newCollection)
        saveLibrary()
    }
    
    func deleteCollection(_ collection: PDFCollection) {
        collections.removeAll { $0.id == collection.id }
        for i in 0..<convertedPDFs.count {
            if convertedPDFs[i].collectionId == collection.id {
                convertedPDFs[i].collectionId = nil
            }
        }
        saveLibrary()
    }
    
    func movePDFToCollection(_ pdf: ConvertedPDF, collectionId: UUID?) {
        if let idx = convertedPDFs.firstIndex(where: { $0.id == pdf.id }) {
            convertedPDFs[idx].collectionId = collectionId
            saveLibrary()
        }
    }
    
    func autoOrganize() {
        // Stub: Implement auto-grouping by series name
        print("Auto-organize triggered")
    }
    
    func findDuplicates() async -> [DuplicateGroup] {
        // Stub
        return []
    }
    
    func calculateStorageInfo() -> StorageInfo {
        let total = convertedPDFs.reduce(0) { $0 + $1.fileSize }
        return StorageInfo(used: total, totalSize: 10_000_000_000, appUsage: total)
    }
    
    // MARK: - Backup & Restore
    
    func createBackupData() -> BackupData {
        return BackupData(
            version: "1.0",
            date: Date(),
            settings: conversionSettings,
            collections: collections,
            presets: conversionPresets
        )
    }
    
    func restoreFromBackup(_ backup: BackupData) {
        self.conversionSettings = backup.settings
        self.collections = backup.collections
        self.conversionPresets = backup.presets
        saveLibrary()
    }
    
    // MARK: - Conversion
    
    func convertComic(_ pdf: ConvertedPDF) async {
        await MainActor.run { isConverting = true; processingStatus = "Converting..."; statusMessage = "Processing..." }
        let converter = CBZToEPUBConverter()
        
        do {
            let newURL = try await converter.convert(sourceURL: pdf.url, settings: conversionSettings) { progress in
                print("Progress: \(progress)")
            }
            
            await MainActor.run {
                let newFile = ConvertedPDF(
                    name: newURL.lastPathComponent,
                    url: newURL,
                    pageCount: 0,
                    fileSize: (try? newURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0,
                    metadata: PDFMetadata(title: newURL.lastPathComponent)
                )
                convertedPDFs.append(newFile)
                isConverting = false
                statusMessage = "✅ Conversion Complete!"
                scanLibrary()
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.statusMessage = nil }
            }
        } catch {
            await MainActor.run { isConverting = false; statusMessage = "Error: \(error.localizedDescription)" }
        }
    }
    
    func generateCoverThumbnail(for pdf: ConvertedPDF) {
        if let image = extractCoverImage(from: pdf.url) {
            thumbnailCache.setObject(image, forKey: pdf.url.path as NSString)
        }
    }
    
    // MARK: - Thumbnails & Helpers
    
    func getThumbnail(for pdf: ConvertedPDF) -> UIImage? {
        if let cached = thumbnailCache.object(forKey: pdf.url.path as NSString) { return cached }
        if let image = extractCoverImage(from: pdf.url) {
            thumbnailCache.setObject(image, forKey: pdf.url.path as NSString)
            return image
        }
        return UIImage(systemName: "doc.text.fill")
    }
    
    @MainActor
    func processImportedFiles(urls: [URL]) {
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                let fileName = url.lastPathComponent
                let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let destURL = docDir.appendingPathComponent(fileName)
                if FileManager.default.fileExists(atPath: destURL.path) { try FileManager.default.removeItem(at: destURL) }
                try FileManager.default.copyItem(at: url, to: destURL)
            } catch { print("Import Failed: \(error)") }
        }
        scanLibrary()
    }
    
    private func extractCoverImage(from url: URL) -> UIImage? {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" {
            if let doc = PDFDocument(url: url), let page = doc.page(at: 0) {
                return page.thumbnail(of: CGSize(width: 300, height: 400), for: .mediaBox)
            }
            return nil
        }
        if ["cbz", "cbr", "zip", "epub"].contains(ext) {
            guard let archive = Archive(url: url, accessMode: .read) else { return nil }
            let imageExtensions = ["jpg", "jpeg", "png", "webp"]
            let sortedEntries = archive.sorted { $0.path < $1.path }
            for entry in sortedEntries {
                let entryExt = (entry.path as NSString).pathExtension.lowercased()
                if imageExtensions.contains(entryExt) {
                    var imageData = Data()
                    do {
                        _ = try archive.extract(entry) { data in imageData.append(data) }
                        if let image = UIImage(data: imageData) { return image }
                    } catch { print("Extract Error: \(error)") }
                }
            }
        }
        return nil
    }
    
    // MARK: - Stubs for Kindle Devices
    
    func addKindleDevice(_ device: KindleDevice) { kindleDevices.append(device); saveLibrary() }
    func removeKindleDevice(_ device: KindleDevice) { kindleDevices.removeAll { $0.id == device.id }; saveLibrary() }
    func updateKindleDevice(_ device: KindleDevice) {
        if let idx = kindleDevices.firstIndex(where: { $0.id == device.id }) { kindleDevices[idx] = device; saveLibrary() }
    }
    func setDefaultKindleDevice(_ device: KindleDevice) {
        for i in 0..<kindleDevices.count { kindleDevices[i].isDefault = (kindleDevices[i].id == device.id) }
        saveLibrary()
    }
    func clearSendHistory() { sendHistory.removeAll(); saveLibrary() }
    func saveSettings() { saveLibrary() }
    func savePreset(_ preset: ConversionPreset) { conversionPresets.append(preset); saveLibrary() }
    func deletePreset(_ preset: ConversionPreset) { conversionPresets.removeAll { $0.id == preset.id }; saveLibrary() }
    func updatePDFMetadata(_ pdf: ConvertedPDF, metadata: PDFMetadata) {
        if let idx = convertedPDFs.firstIndex(where: { $0.id == pdf.id }) {
            convertedPDFs[idx].metadata = metadata
            saveLibrary()
        }
    }
}
