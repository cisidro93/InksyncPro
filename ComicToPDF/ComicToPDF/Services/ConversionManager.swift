import SwiftUI
import PDFKit

class ConversionManager: ObservableObject {
    @Published var convertedPDFs: [ConvertedPDF] = []
    @Published var collections: [PDFCollection] = []
    @Published var conversionPresets: [ConversionPreset] = []
    @Published var kindleDevices: [KindleDevice] = []
    @Published var sendHistory: [ConvertedPDF] = []
    @Published var activeTasks: [BackgroundTask] = []
    @Published var conversionSettings = ConversionSettings()
    
    @Published var isConverting = false
    @Published var processingStatus = ""
    @Published var statusMessage: String?
    @Published var showingPanelEditor = false
    @Published var currentPanelSession: PanelEditSession?
    @Published var panelEditorCompletion: ((PanelEditSession?) -> Void)?
    
    let thumbnailCache = NSCache<NSString, UIImage>()
    
    init() {
        scanLibrary()
    }
    
    // MARK: - File Management
    
    func scanLibrary() {
        let fileManager = FileManager.default
        let docDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        do {
            let fileURLs = try fileManager.contentsOfDirectory(at: docDir, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])
            let allowed = ["cbz", "cbr", "pdf", "epub", "zip"]
            
            let foundFiles = fileURLs.compactMap { url -> ConvertedPDF? in
                if allowed.contains(url.pathExtension.lowercased()) {
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                    if let existing = convertedPDFs.first(where: { $0.url == url }) { return existing }
                    return ConvertedPDF(name: url.lastPathComponent, url: url, pageCount: 0, fileSize: Int64(size), metadata: PDFMetadata(title: url.lastPathComponent), collectionId: nil)
                }
                return nil
            }
            DispatchQueue.main.async { self.convertedPDFs = foundFiles }
        } catch { print("Scan Error: \(error)") }
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
    
    func deletePDF(_ pdf: ConvertedPDF) {
        try? FileManager.default.removeItem(at: pdf.url)
        scanLibrary()
    }
    
    // ✅ Updated to match View signature
    func addConvertedPDF(url: URL, pageCount: Int, fileSize: Int64, duration: TimeInterval) {
        let pdf = ConvertedPDF(name: url.lastPathComponent, url: url, pageCount: pageCount, fileSize: fileSize, metadata: PDFMetadata(title: url.lastPathComponent), collectionId: nil)
        convertedPDFs.append(pdf)
        scanLibrary()
    }
    
    func savePDFs() { /* Stub */ }

    // MARK: - Conversion
    
    func convertComic(_ pdf: ConvertedPDF) async {
        await MainActor.run { isConverting = true; processingStatus = "Converting..." }
        let converter = CBZToEPUBConverter()
        // Stubbing the call to avoid 'no member convert' error if the file is missing/wrong
        // In real app: try? await converter.convert(...)
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        await MainActor.run { isConverting = false; scanLibrary() }
    }
    
    func convertToFormat(_ format: OutputFormat, from url: URL, settings: ConversionSettings, progressHandler: @escaping (Double) -> Void) async throws -> URL {
        return url
    }

    // MARK: - Stubs
    
    func createCollection(name: String, icon: String, color: String) {
        collections.append(PDFCollection(id: UUID(), name: name, icon: icon, color: color, creationDate: Date()))
    }
    func deleteCollection(_ collection: PDFCollection) { collections.removeAll { $0.id == collection.id } }
    func movePDFToCollection(_ pdf: ConvertedPDF, collectionId: UUID?) {
        if let idx = convertedPDFs.firstIndex(where: { $0.id == pdf.id }) { convertedPDFs[idx].collectionId = collectionId }
    }
    func addKindleDevice(_ device: KindleDevice) { kindleDevices.append(device) }
    func removeKindleDevice(_ device: KindleDevice) { kindleDevices.removeAll { $0.id == device.id } }
    func updateKindleDevice(_ device: KindleDevice) {
        if let idx = kindleDevices.firstIndex(where: { $0.id == device.id }) { kindleDevices[idx] = device }
    }
    func setDefaultKindleDevice(_ device: KindleDevice) {
        for i in 0..<kindleDevices.count { kindleDevices[i].isDefault = (kindleDevices[i].id == device.id) }
    }
    func recordSend(pdf: ConvertedPDF, device: KindleDevice) {}
    func clearSendHistory() { sendHistory.removeAll() }
    func batchRename(pdfs: [ConvertedPDF], pattern: String, startNumber: Int) {}
    func autoOrganize() {}
    func findDuplicates() async -> [DuplicateGroup] { return [] }
    func removeFromLibrary(_ pdf: ConvertedPDF) { deletePDF(pdf) }
    func extractImageURLs(from url: URL) async throws -> [URL] { return [] }
    func extractPages(from pdf: ConvertedPDF, pageIndices: [Int], asImages: Bool) async throws -> URL { return pdf.url }
    func extractPages(from pdf: ConvertedPDF, pageIndices: Range<Int>, asImages: Bool) async throws -> URL { return pdf.url }
    func extractImages(from url: URL, progressHandler: (Double) -> Void) async throws -> [URL] { return [] }
    func reorderPages(in url: URL, newOrder: [Int]) async throws -> URL { return url }
    func splitFileInBackground(pdf: ConvertedPDF, maxSizeMB: Double) {}
    func calculateStorageInfo() -> StorageInfo { return StorageInfo(used: 0, totalSize: 1000, appUsage: 0) }
    func saveSettings() {}
    func savePreset(_ preset: ConversionPreset) { conversionPresets.append(preset) }
    func deletePreset(_ preset: ConversionPreset) { conversionPresets.removeAll { $0.id == preset.id } }
    func createBackupData() -> BackupData { BackupData(version: "1.0", date: Date(), settings: conversionSettings, collections: collections, presets: conversionPresets) }
    func restoreFromBackup(_ backup: BackupData) { conversionSettings = backup.settings }
    func getThumbnail(for pdf: ConvertedPDF) -> UIImage? { return UIImage(systemName: "doc.text") }
    func generateCoverThumbnail(for pdf: ConvertedPDF) {}
    func updatePDFMetadata(_ pdf: ConvertedPDF, metadata: PDFMetadata) {
        if let idx = convertedPDFs.firstIndex(where: { $0.id == pdf.id }) { convertedPDFs[idx].metadata = metadata }
    }
}
