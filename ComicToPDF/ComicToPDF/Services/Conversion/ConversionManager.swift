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
    
    // MARK: - Editor Session Cache
    // Prevents "Death Spiral" by keeping the comic unzipped while editing
    private var editorCache: (pdfID: UUID, folder: URL, files: [URL])?
    private var activeExtractionTask: Task<(workingDir: URL, files: [URL]), Error>?
    
    // Guided View Data
    @Published var panelOverrides: [UUID: [Int: [PanelExtractor.Panel]]] = [:]
    
    // UI State
    @Published var isConverting = false
    @Published var conversionProgress: Double = 0.0
    @Published var processingStatus = ""
    @Published var statusMessage: String?
    
    // ✅ NEW: Global Alert State
    struct AppAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }
    @Published var appAlert: AppAlert?
    
    let thumbnailCache = NSCache<NSString, UIImage>()
    private let libraryFileName = "library_index.json"
    
    init() {
        loadLibrary()
        scanLibrary()
        createWelcomeFile()
        performStartupOptimization()
    }
    
    private func performStartupOptimization() {
        let key = "hasRunStartupOptimization"
        if UserDefaults.standard.bool(forKey: key) { return }
        
        let memory = ProcessInfo.processInfo.physicalMemory
        let ramGB = Double(memory) / 1024.0 / 1024.0 / 1024.0
        
        print("📱 [Optimization] Detecting Device Capabilities: \(String(format: "%.1f", ramGB)) GB RAM")
        
        if ramGB > 5.5 {
            // High End Device (iPad Pro M1/M2/M4, iPhone 14 Pro+, etc) -> >6GB
            // We can default to higher quality and enable advanced features
            conversionSettings.compressionQuality = .high
            // We don't force 'enablePanelSplit' because that changes UX, but we prepare quality.
        } else if ramGB < 3.5 {
            // Low End Device (~3GB or less) -> Older iPads, standard iPhones
            // Prioritize stability
            conversionSettings.compressionQuality = .compact
        } else {
            // Mid Range (4GB-5GB)
            conversionSettings.compressionQuality = .balanced
        }
        
        // Save that we have optimized
        UserDefaults.standard.set(true, forKey: key)
        saveSettings()
    }
    
    private func createWelcomeFile() {
        let fileManager = FileManager.default
        if let docDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            let welcomeURL = docDir.appendingPathComponent("Welcome.txt")
            if !fileManager.fileExists(atPath: welcomeURL.path) {
                let content = "Welcome to Inksync Pro!\n\nThis folder is where you can access your converted files.\nTo import comics, you can drag and drop them here or use the 'Import' button in the app."
                try? content.write(to: welcomeURL, atomically: true, encoding: .utf8)
            }
        }
    }
    
    func cleanupMemory() { thumbnailCache.removeAllObjects() }
    
    // MARK: - Persistence
    func saveLibrary() {
        struct LibraryIndex: Codable {
            let files: [ConvertedPDF]
            let collections: [PDFCollection]
            let settings: ConversionSettings
            let history: [ConvertedPDF]
            let devices: [KindleDevice]
            var panelOverrides: [UUID: [Int: [PanelExtractor.Panel]]]? = nil // ✅ NEW: Persistence
        }
        let index = LibraryIndex(files: convertedPDFs, collections: collections, settings: conversionSettings, history: sendHistory, devices: kindleDevices, panelOverrides: panelOverrides)
        if let url = fileURL(for: libraryFileName), let encoded = try? JSONEncoder().encode(index) {
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
            var panelOverrides: [UUID: [Int: [PanelExtractor.Panel]]]? = nil // ✅ NEW
        }
        guard let url = fileURL(for: libraryFileName), let data = try? Data(contentsOf: url), let index = try? JSONDecoder().decode(LibraryIndex.self, from: data) else { return }
        self.convertedPDFs = index.files
        self.collections = index.collections
        self.conversionSettings = index.settings
        self.sendHistory = index.history
        self.kindleDevices = index.devices
        self.panelOverrides = index.panelOverrides ?? [:] // ✅ Restore overrides
    }
    
    private func fileURL(for name: String) -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent(name)
    }
    
    func savePanelOverrides(for pdfID: UUID, pageIndex: Int, panels: [PanelExtractor.Panel]) async {
        if panelOverrides[pdfID] == nil { panelOverrides[pdfID] = [:] }
        panelOverrides[pdfID]?[pageIndex] = panels
        
        // FIX: Persist immediately to prevent data loss on app suspend or scanLibrary reload
        saveLibrary() 
    }
    
    // ✅ NEW: Bulk Save
    func savePanelOverrides(for pdfID: UUID, panels: [Int: [PanelExtractor.Panel]]) {
        self.panelOverrides[pdfID] = panels
        self.saveLibrary()
        print("✅ Restored panels for imported file (ID: \(pdfID))")
    }
    
    // ✅ NEW: Centralized manifest logic to fix panel loss
    func getCombinedManifest(for pdf: ConvertedPDF) async -> [Int: [PanelExtractor.Panel]] {
        var combined = panelOverrides[pdf.id] ?? [:]
        
        // Merge with source panels if available
        if let sourcePanels = await ConversionManager.extractSmartPanels(from: pdf.url) {
            for (pageIndex, panels) in sourcePanels {
                if combined[pageIndex] == nil {
                    combined[pageIndex] = panels
                }
            }
        }
        return combined
    }
    
    // MARK: - File Management
    func scanLibrary() {
        let fileManager = FileManager.default
        let docDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        

            // Recursive Scan
            // We use enumerator to find files deep in folders
            var newPDFs: [ConvertedPDF] = []
            let keys: [URLResourceKey] = [.nameKey, .isDirectoryKey, .fileSizeKey]
            
            if let enumerator = fileManager.enumerator(at: docDir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) {
                 for case let fileURL as URL in enumerator {
                     let ext = fileURL.pathExtension.lowercased()
                     if ["pdf", "cbz", "cbr", "zip", "epub"].contains(ext) {
                         // Check if already exists (Standardized Path Check)
                         if !convertedPDFs.contains(where: { $0.url.standardizedFileURL.path == fileURL.standardizedFileURL.path }) {
                             let fileSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                             let newPDF = ConvertedPDF(name: fileURL.lastPathComponent, url: fileURL, pageCount: 0, fileSize: fileSize, metadata: PDFMetadata(title: fileURL.lastPathComponent))
                             newPDFs.append(newPDF)
                         }
                     }
                 }
            }
            
            // Add new ones
            if !newPDFs.isEmpty {
                convertedPDFs.append(contentsOf: newPDFs)
                
                // Process Metadata & Thumbnails in Background
                for pdf in newPDFs {
                    Task {
                        // 1. Thumbnails
                        await self.generateCoverThumbnail(for: pdf)
                        
                        // 2. Extract Embedded Panels (if any)
                        if let validPanels = await ConversionManager.extractSmartPanels(from: pdf.url) {
                            await MainActor.run {
                                self.savePanelOverrides(for: pdf.id, panels: validPanels)
                            }
                        }
                    }
                }
                
                saveLibrary()
            }
            
            // Cleanup: Remove missing files
            convertedPDFs.removeAll { !fileManager.fileExists(atPath: $0.url.path) }
            

    }
    
    func deletePDF(_ pdf: ConvertedPDF) {
        try? FileManager.default.removeItem(at: pdf.url)
        if let idx = convertedPDFs.firstIndex(where: { $0.id == pdf.id }) {
            convertedPDFs.remove(at: idx)
            saveLibrary()
        }
    }
    
    func removeFromLibrary(_ pdf: ConvertedPDF) { deletePDF(pdf) }
    
    func addConvertedPDF(url: URL, pageCount: Int = 0, fileSize: Int64 = 0, duration: TimeInterval = 0) {
         let pdf = ConvertedPDF(name: url.lastPathComponent, url: url, pageCount: pageCount, fileSize: fileSize, metadata: PDFMetadata(title: url.lastPathComponent), collectionId: nil)
         convertedPDFs.append(pdf)
         saveLibrary()
         Task { await self.generateCoverThumbnail(for: pdf) }
     }
    
    func processImportedFiles(urls: [URL]) async {
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
    
    // MARK: - STABLE FILE EXTRACTION
    func extractImageFiles(from url: URL) async throws -> (workingDir: URL, files: [URL]) {
        // We capture the result from ZipUtilities
        let result = try await ZipUtilities.extractComic(from: url)
        
        // We remap 'imageURLs' to 'files' to satisfy the function signature
        return (workingDir: result.workingDir, files: result.imageURLs)
    }
    
    func extractImageURLs(from url: URL) async throws -> [URL] {
        return try await extractImageFiles(from: url).files
    }
    
    // Helper used by Editor for Single Page Load
    func extractFullPage(from pdf: ConvertedPDF, index: Int) async throws -> UIImage? {
        
        // 1. Check if we already have this comic open in our cache
        if let cache = editorCache, cache.pdfID == pdf.id {
            guard index < cache.files.count else { return nil }
            return ConversionManager.loadDownsampledImageStatic(at: cache.files[index], maxDimension: 1920)
        }
        
        // 2. If not cached, and not currently extracting, start a new extraction task
        if activeExtractionTask == nil {
            print("🚀 Starting new Editor Session for: \(pdf.name)")
            
            // We still use Task.detached to keep the initial call off the Main Actor
            activeExtractionTask = Task.detached(priority: .medium) {
                // The new ZipUtilities handles its own threading, so we just await it
                let result = try await ZipUtilities.extractComic(from: pdf.url)
                return (workingDir: result.workingDir, files: result.imageURLs)
            }
        }
        
        // 3. Wait for the extraction to finish (or use the running one)
        // This ensures that if 5 pages are requested at once, we only unzip ONE time.
        guard let task = activeExtractionTask else { return nil }
        let result = try await task.value
        
        // 4. Save to Cache
        self.editorCache = (pdf.id, result.workingDir, result.files)
        self.activeExtractionTask = nil // Clear the task so we are ready for next time
        
        // 5. Return the requested image
        guard index < result.files.count else { return nil }
        return ConversionManager.loadDownsampledImageStatic(at: result.files[index], maxDimension: 1920)
    }
    
    func endSession() {
        print("🛑 Ending Session...")
        
        // 1. Cancel the background unzipping IMMEDIATELY
        activeExtractionTask?.cancel()
        activeExtractionTask = nil
        
        // 2. Clear UI
        // We use MainActor.run just in case, though this class is @MainActor already.
        Task { @MainActor in
            self.editorCache = nil
            self.isConverting = false
            self.conversionProgress = 0.0
            self.statusMessage = "Ready"
        }
        
        // 3. Clean up disk (Add a slight delay to ensure the Task actually stopped writing)
        let cacheToDelete = self.editorCache
        
        // We delay the file deletion slightly to let the Task catch the cancellation error
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 1.0) {
            if let cache = cacheToDelete {
                 try? FileManager.default.removeItem(at: cache.folder)
                 print("🗑️ Cleaned up session folder: \(cache.folder.lastPathComponent)")
            }
        }
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
    func mergePDFs(_ pdfs: [ConvertedPDF], outputName: String, mangaMode: Bool) async {
        isConverting = true; processingStatus = "Merging..."; statusMessage = "Starting merge..."
        let fileManager = FileManager.default; let docDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let safeName = outputName.isEmpty ? "Merged_Collection" : outputName; let outputURL = docDir.appendingPathComponent("\(safeName).epub")
        let merger = EPUBMerger(); let sourceURLs = pdfs.map { $0.url }
        var inheritedCover: UIImage?
        if let firstPDF = pdfs.first { inheritedCover = getThumbnail(for: firstPDF) }
        do {
            var mergeSettings = ConversionSettings()
            mergeSettings.mangaMode = mangaMode
            try await Task.detached { try await merger.mergeEPUBs(sourceURLs: sourceURLs, outputURL: outputURL, settings: mergeSettings) }.value
            let fileSize = (try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            let newPDF = ConvertedPDF(name: outputURL.lastPathComponent, url: outputURL, pageCount: 0, fileSize: fileSize, metadata: PDFMetadata(title: safeName))
            // convertedPDFs.append(newPDF) // Rely on scanLibrary to avoid duplicates
            if let cover = inheritedCover { thumbnailCache.setObject(cover, forKey: outputURL.path as NSString); objectWillChange.send() }
            else { Task { await self.generateCoverThumbnail(for: newPDF) } }
            isConverting = false; statusMessage = "✅ Merge Complete!"; scanLibrary()
            try? await Task.sleep(nanoseconds: 3 * 1_000_000_000); self.statusMessage = nil
        } catch { isConverting = false; statusMessage = "Merge Error: \(error.localizedDescription)" }
    }
    
    func convertComic(_ pdf: ConvertedPDF, mangaMode: Bool) async {
        isConverting = true; conversionProgress = 0.0; processingStatus = "Converting..."; statusMessage = "Starting..."
        let converter = CBZToEPUBConverter(); var jobSettings = conversionSettings; jobSettings.mangaMode = mangaMode; 
        
        let combinedManifest = await getCombinedManifest(for: pdf)
        
        do {
            let newURLs = try await converter.convert(sourceURL: pdf.url, settings: jobSettings, manualManifest: combinedManifest) { progress in Task { @MainActor in self.conversionProgress = progress; self.processingStatus = "Converting \(Int(progress * 100))%" } }
            isConverting = false; conversionProgress = 1.0; statusMessage = "✅ Conversion Complete! (\(newURLs.count) files)"; scanLibrary()
            try? await Task.sleep(nanoseconds: 3 * 1_000_000_000); self.statusMessage = nil
        } catch { isConverting = false; statusMessage = "Error: \(error.localizedDescription)" }
    }
    
    func convertQueue(_ pdfs: [ConvertedPDF]) async {
        guard !pdfs.isEmpty else { return }
        isConverting = true
        
        for (index, pdf) in pdfs.enumerated() {
            if Task.isCancelled { break }
            
            let currentNum = index + 1
            let total = pdfs.count
            
            await MainActor.run {
                self.processingStatus = "Converting \(currentNum) of \(total)"
                self.statusMessage = "Processing \(pdf.name)..."
                self.conversionProgress = 0.0
            }
            
            let converter = CBZToEPUBConverter()
            var jobSettings = conversionSettings
            // We use global settings for the batch. If specific manga settings are needed, we default to global for now.
            
            let combinedManifest = await getCombinedManifest(for: pdf)
            
            do {
                _ = try await converter.convert(sourceURL: pdf.url, settings: jobSettings, manualManifest: combinedManifest) { progress in
                    Task { @MainActor in
                        self.conversionProgress = progress
                        self.processingStatus = "Converting \(currentNum) of \(total) (\(Int(progress * 100))%)"
                    }
                }
                // Scan after each successful conversion so user sees progress
                await MainActor.run { self.scanLibrary() }
            } catch {
                print("❌ Batch Error for \(pdf.name): \(error)")
                await MainActor.run { self.statusMessage = "Error on \(pdf.name)" }
                try? await Task.sleep(nanoseconds: 1 * 1_000_000_000)
            }
        }
        
        isConverting = false
    }
    func convertAndMerge(sourceFiles: [ConvertedPDF], outputName: String, mangaMode: Bool) async {
        guard !sourceFiles.isEmpty else { return }
        isConverting = true
        
        var generatedEPUBs: [URL] = []
        let fileManager = FileManager.default
        
        // 1. Convert Loop
        for (index, file) in sourceFiles.enumerated() {
            if Task.isCancelled { break }
            
            let currentNum = index + 1
            await MainActor.run {
                self.processingStatus = "Step 1/2: Converting \(currentNum) of \(sourceFiles.count)"
                self.statusMessage = "Converting \(file.name)..."
                self.conversionProgress = 0.0
            }
            
            let converter = CBZToEPUBConverter()
            var jobSettings = conversionSettings
            // ✅ Override Manga Mode for this batch
            jobSettings.mangaMode = mangaMode
            
            let combinedManifest = await getCombinedManifest(for: file)
            
            do {
                let resultingURLs = try await converter.convert(sourceURL: file.url, settings: jobSettings, manualManifest: combinedManifest) { progress in
                    Task { @MainActor in
                        self.conversionProgress = progress
                    }
                }
                generatedEPUBs.append(contentsOf: resultingURLs)
                
                // ✅ NEW: Inject Metadata into Generated EPUBs
                // This ensures that if the user re-imports this EPUB, the panels are preserved.
                // We inject the full set of overrides; irrelevant indices will simply be ignored by the importer.
                for epubURL in resultingURLs {
                    try? await injectMetadata(into: epubURL, panels: combinedManifest, metadata: file.metadata)
                }
                
            } catch {
                print("❌ Batch Merge Error on \(file.name): \(error)")
                await MainActor.run { self.statusMessage = "Failed: \(file.name)" }
                try? await Task.sleep(nanoseconds: 2 * 1_000_000_000)
                isConverting = false
                return
            }
        }
        
        // 2. Merge Phase
        guard !generatedEPUBs.isEmpty else {
            isConverting = false; return
        }
        
        await MainActor.run {
            self.processingStatus = "Step 2/2: Merging..."
            self.statusMessage = "Merging \(generatedEPUBs.count) files..."
            self.conversionProgress = 0.5 // Indeterminateish
        }
        
        // Create output URL
        let documentsDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let outputFilename = (outputName.isEmpty ? "Merged Collection" : outputName) + ".epub"
        let finalOutputURL = documentsDir.appendingPathComponent(outputFilename)
        
        // Use global settings for the merge container
        var mergeSettings = conversionSettings
        mergeSettings.mangaMode = mangaMode
        
        let merger = EPUBMerger()
        do {
            try await merger.mergeEPUBs(sourceURLs: generatedEPUBs, outputURL: finalOutputURL, settings: mergeSettings)
            print("✅ Merge Success: \(finalOutputURL)")
            
            // 3. Cleanup Intermediates
            await MainActor.run { self.statusMessage = "Cleaning up..." }
            for url in generatedEPUBs {
                try? fileManager.removeItem(at: url)
            }
            
            // 4. Finish
            await MainActor.run {
                self.scanLibrary()
                self.statusMessage = "✅ Merge Complete!"
                self.processingStatus = ""
                self.conversionProgress = 1.0
                self.isConverting = false
            }
            try? await Task.sleep(nanoseconds: 3 * 1_000_000_000)
            await MainActor.run { self.statusMessage = nil }
            
        } catch {
            print("❌ Merge Failed: \(error)")
            await MainActor.run {
                self.statusMessage = "Merge Failed: \(error.localizedDescription)"
                self.isConverting = false
            }
        }
    }

    // MARK: - Thumbnails & Helpers
    func generateCoverThumbnail(for pdf: ConvertedPDF) async {
        let url = pdf.url
        let image = await Task.detached(priority: .userInitiated) {
            return ConversionManager.extractCoverImageStatic(from: url)
        }.value
        if let image {
            self.thumbnailCache.setObject(image, forKey: url.path as NSString)
            self.objectWillChange.send()
        }
    }
    
    func getThumbnail(for pdf: ConvertedPDF) -> UIImage? {
        if let cached = thumbnailCache.object(forKey: pdf.url.path as NSString) { return cached }
        Task { await generateCoverThumbnail(for: pdf) }
        return UIImage(systemName: "doc.text.fill")
    }
    
    nonisolated static func extractCoverImageStatic(from url: URL) -> UIImage? {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" {
            guard let document = PDFDocument(url: url), let page = document.page(at: 0) else { return nil }
            return page.thumbnail(of: CGSize(width: 300, height: 450), for: .mediaBox)
        }

        if ["cbz", "cbr", "zip", "epub"].contains(ext) {
            // ✅ Security Scope Safety (Paranoid Check)
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            
            do {
                // Remove 'try?' to let errors propagate to the catch block
                let archive = try Archive(url: url, accessMode: .read)
                
                // ✅ Fix: Use localized sort to match Finder/ZipUtilities (1, 2, 10 vs 1, 10, 2)
                let sortedEntries = archive.makeIterator().sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                
                for entry in sortedEntries {
                    // Skip directories explicit check
                    if entry.type == .directory { continue }
                    
                    let entryExt = (entry.path as NSString).pathExtension.lowercased()
                    if ["jpg", "jpeg", "png", "webp"].contains(entryExt) {
                        if entry.path.contains("__MACOSX") || entry.path.hasPrefix(".") { continue }
                        
                        var data = Data()
                        do {
                            _ = try archive.extract(entry) { data.append($0) }
                            if let image = UIImage(data: data) {
                                return image
                            }
                        } catch {
                            print("Failed to extract entry for thumbnail: \(entry.path)")
                        }
                    }
                }
            } catch {
                print("Thumbnail Extraction Error for \(url.lastPathComponent): \(error)")
            }
        }
        return nil
    }
    
    // ✅ NEW: Extract Smart Panels from ComicInfo.xml
    static func extractSmartPanels(from url: URL) async -> [Int: [PanelExtractor.Panel]]? {
        print("🔍 [SmartPanels] Inspecting: \(url.lastPathComponent)")
        guard let archive = try? Archive(url: url, accessMode: .read) else {
            print("❌ [SmartPanels] Could not open archive: \(url.lastPathComponent)")
            return nil
        }
        
        guard let entry = archive["ComicInfo.xml"] else {
            print("⚠️ [SmartPanels] No ComicInfo.xml found in: \(url.lastPathComponent)")
            return nil
        }
        
        var xmlData = Data()
        do {
            _ = try archive.extract(entry) { xmlData.append($0) }
        } catch {
            print("❌ [SmartPanels] Failed to extract XML data")
            return nil
        }
        
        // Debug: Print XML prefix
        // let snippet = String(data: xmlData.prefix(200), encoding: .utf8) ?? "Invalid Data"
        // print("📄 XML Snippet: \(snippet)...")
        
        let parser = ComicInfoPanelParser(data: xmlData)
        let result = parser.parse()
        print("✅ [SmartPanels] Parsed \(result.count) pages with panels from \(url.lastPathComponent)")
        
        // Prevent overwriting with empty data if ComicInfo exists but has no panels
        return result.isEmpty ? nil : result
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
    
    func renamePDF(_ pdf: ConvertedPDF, to newName: String) {
        let cleanName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, cleanName != pdf.name else { return }
        
        let fileManager = FileManager.default
        let docDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let newURL = docDir.appendingPathComponent(cleanName).appendingPathExtension(pdf.url.pathExtension)
        
        // Prevent overwrite
        if fileManager.fileExists(atPath: newURL.path) {
            // Simple handling: fail or alert. For now, we will append a counter if we were fancy, but let's just return to avoid data loss.
            print("Rename failed: File exists")
            return
        }
        
        do {
            try fileManager.moveItem(at: pdf.url, to: newURL)
            
            // Update Model
            if let idx = convertedPDFs.firstIndex(where: { $0.id == pdf.id }) {
                let updatedPDF = ConvertedPDF(
                    id: pdf.id,
                    name: cleanName,
                    url: newURL,
                    pageCount: pdf.pageCount,
                    fileSize: pdf.fileSize,
                    metadata: pdf.metadata,
                    collectionId: pdf.collectionId,
                    isFavorite: pdf.isFavorite,
                    coverImageData: pdf.coverImageData
                )
                convertedPDFs[idx] = updatedPDF
                
                // Move Thumbnail Cache
                if let image = thumbnailCache.object(forKey: pdf.url.path as NSString) {
                    thumbnailCache.setObject(image, forKey: newURL.path as NSString)
                    thumbnailCache.removeObject(forKey: pdf.url.path as NSString)
                }
                
                saveLibrary()
                objectWillChange.send()
            }
        } catch {
            print("Rename Error: \(error)")
        }
    }
    
    func createCollection(name: String, icon: String, color: String) {
        collections.append(PDFCollection(id: UUID(), name: name, icon: icon, color: color, creationDate: Date()))
        saveLibrary()
    }
    func deleteCollection(_ collection: PDFCollection) {
        collections.removeAll { $0.id == collection.id }
        for i in 0..<convertedPDFs.count { if convertedPDFs[i].collectionId == collection.id { convertedPDFs[i].collectionId = nil } }
        saveLibrary()
    }
    func movePDFToCollection(_ pdf: ConvertedPDF, collectionId: UUID?) {
        if let idx = convertedPDFs.firstIndex(where: { $0.id == pdf.id }) { convertedPDFs[idx].collectionId = collectionId; saveLibrary() }
    }
    
    // Page Ops
    func deletePages(from pdf: ConvertedPDF, pageIndices: Set<Int>) async throws {
        let sourceURL = pdf.url
        
        try await Task.detached {
            let fileManager = FileManager.default
            let tempID = UUID().uuidString
            let tempDir = fileManager.temporaryDirectory.appendingPathComponent(tempID)
            let tempArchiveURL = fileManager.temporaryDirectory.appendingPathComponent("\(tempID).cbz")
            
            try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: tempDir); try? fileManager.removeItem(at: tempArchiveURL) }
            
            guard let sourceArchive = try? Archive(url: sourceURL, accessMode: .read),
                  let destArchive = try? Archive(url: tempArchiveURL, accessMode: .create) else {
                throw NSError(domain: "ArchiveError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not open archive"])
            }
            
            // 1. Map Entries to Indices (reproducing sorting logic)
            // We sort by path to match how we displayed them (Natural Sort)
            let sortedEntries = sourceArchive.makeIterator().sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            let imageEntries = sortedEntries.filter { entry in
                let ext = (entry.path as NSString).pathExtension.lowercased()
                return ["jpg", "jpeg", "png", "webp"].contains(ext) && !entry.path.contains("__MACOSX") && !entry.path.hasPrefix(".")
            }
            
            // Identify paths to remove
            var pathsToRemove: Set<String> = []
            for (index, entry) in imageEntries.enumerated() {
                if pageIndices.contains(index) {
                    pathsToRemove.insert(entry.path)
                }
            }
            
            // 2. Stream Copy (Extract Temp -> Add -> Delete Temp)
            // This avoids unzipping the entire 4GB file at once.
            for entry in sourceArchive {
                if !pathsToRemove.contains(entry.path) {
                    let tempFile = tempDir.appendingPathComponent(entry.path.components(separatedBy: "/").last ?? "temp")
                    
                    // Extract Single Entry
                    _ = try sourceArchive.extract(entry, to: tempFile)
                    
                    // Add to New Archive (Deflate)
                    // Fix: Cast uncompressedSize to Int64
                    try destArchive.addEntry(with: entry.path, type: entry.type, uncompressedSize: Int64(entry.uncompressedSize), modificationDate: entry.fileAttributes[.modificationDate] as? Date ?? Date(), permissions: entry.fileAttributes[.posixPermissions] as? UInt16, compressionMethod: .deflate, bufferSize: 8192, progress: nil) { position, size in
                        // Stream from file
                        let fileHandle = try? FileHandle(forReadingFrom: tempFile)
                        try? fileHandle?.seek(toOffset: UInt64(position))
                        return fileHandle?.readData(ofLength: size) ?? Data()
                    }
                    
                    // Cleanup Single Entry
                    try? fileManager.removeItem(at: tempFile)
                }
            }
            
            // 3. Swap Files
            if fileManager.fileExists(atPath: sourceURL.path) { try fileManager.removeItem(at: sourceURL) }
            try fileManager.moveItem(at: tempArchiveURL, to: sourceURL)
            
        }.value
        scanLibrary()
    }
    func reorderPages(_ pdf: ConvertedPDF, newOrder: [Int]) async throws -> URL {
        // Physical Reorder: We create a new CBZ with files renamed to match the new order.
        let fileManager = FileManager.default
        let url = pdf.url
        let tempID = UUID().uuidString
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(tempID)
        let tempArchiveURL = fileManager.temporaryDirectory.appendingPathComponent("\(tempID).cbz")
        
        // ✅ NEW: Prepare Panel Transfer
        // Get current full state (Source + Edits)
        let combinedManifest = await getCombinedManifest(for: pdf)
        var newPanels: [Int: [PanelExtractor.Panel]] = [:]
        
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir); try? fileManager.removeItem(at: tempArchiveURL) }
        
        guard let sourceArchive = try? Archive(url: url, accessMode: .read),
              let destArchive = try? Archive(url: tempArchiveURL, accessMode: .create) else {
            throw NSError(domain: "ArchiveError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not open archive"])
        }
        
        // 1. Get Sorted Entries (Canonical Order - Natural Sort)
        let sortedEntries = sourceArchive.makeIterator().sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        let imageEntries = sortedEntries.filter { entry in
            let ext = (entry.path as NSString).pathExtension.lowercased()
            return ["jpg", "jpeg", "png", "webp"].contains(ext) && !entry.path.contains("__MACOSX") && !entry.path.hasPrefix(".")
        }
        
        // 2. Process based on newOrder
        // newOrder[i] = originalIndex. So if newOrder[0] = 5, the first page of new file is the 6th page of old file.
        for (newIndex, originalIndex) in newOrder.enumerated() {
            guard originalIndex < imageEntries.count else { continue }
            let entry = imageEntries[originalIndex]
            
            // Transfer Panels to new index
            if let panels = combinedManifest[originalIndex] {
                newPanels[newIndex] = panels
            }
            
            // Extract
            let ext = (entry.path as NSString).pathExtension.lowercased()
            let tempFile = tempDir.appendingPathComponent(entry.path.components(separatedBy: "/").last ?? "temp")
            _ = try sourceArchive.extract(entry, to: tempFile)
            
            // Rename for New Archive (page_00001.jpg)
            let newName = "page_\(String(format: "%05d", newIndex)).\(ext)"
            
            // Add
            try destArchive.addEntry(with: newName, type: .file, uncompressedSize: Int64(entry.uncompressedSize), modificationDate: Date(), permissions: 0o644, compressionMethod: .deflate, bufferSize: 8192, progress: nil) { position, size in
                let fileHandle = try? FileHandle(forReadingFrom: tempFile)
                try? fileHandle?.seek(toOffset: UInt64(position))
                return fileHandle?.readData(ofLength: size) ?? Data()
            }
            
            try? fileManager.removeItem(at: tempFile)
        }
        
        // 3. Swap
        if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
        try fileManager.moveItem(at: tempArchiveURL, to: url)
        
        scanLibrary()
        
        // ✅ NEW: Update overrides and inject metdata
        await MainActor.run {
            self.panelOverrides[pdf.id] = newPanels
            self.saveLibrary()
        }
        try? await injectMetadata(into: url, panels: newPanels, metadata: pdf.metadata)
        
        return url
    }
    
    // MARK: - Trimming Logic
    func trimPages(from pdf: ConvertedPDF, pageIndices: Set<Int>, trim: (top: Double, bottom: Double, left: Double, right: Double)) async throws {
        // Validate type: Must be an archive
        let ext = pdf.url.pathExtension.lowercased()
        guard ["cbz", "cbr", "zip", "epub"].contains(ext) else {
            throw NSError(domain: "TrimError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Trimming is only supported for CBZ, ZIP, or EPUB files."])
        }
        
        let sourceURL = pdf.url
        
        try await Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            let tempID = UUID().uuidString
            let tempDir = fileManager.temporaryDirectory.appendingPathComponent(tempID)
            let tempArchiveURL = fileManager.temporaryDirectory.appendingPathComponent("\(tempID).cbz")
            
            try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: tempDir); try? fileManager.removeItem(at: tempArchiveURL) }
            
            guard let sourceArchive = try? Archive(url: sourceURL, accessMode: .read),
                  let destArchive = try? Archive(url: tempArchiveURL, accessMode: .create) else {
                throw NSError(domain: "ArchiveError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not open archive"])
            }
            
            let sortedEntries = sourceArchive.makeIterator().sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            let imageEntries = sortedEntries.filter { entry in
                let ext = (entry.path as NSString).pathExtension.lowercased()
                return ["jpg", "jpeg", "png", "webp"].contains(ext) && !entry.path.contains("__MACOSX") && !entry.path.hasPrefix(".")
            }
            
            // Map entries to indices to identify which ones to trim
            // Since sortedEntries contains non-images too (maybe), 'imageEntries' index i corresponds to page i.
            // But we need to process ALL entries to rebuild the archive.
            
            var imageIndexCounter = 0
            
            for entry in sortedEntries {
                let isImage = ["jpg", "jpeg", "png", "webp"].contains((entry.path as NSString).pathExtension.lowercased()) && !entry.path.contains("__MACOSX") && !entry.path.hasPrefix(".")
                
                let currentImageIndex = isImage ? imageIndexCounter : -1
                if isImage { imageIndexCounter += 1 }
                
                let tempFile = tempDir.appendingPathComponent(entry.path.components(separatedBy: "/").last ?? "temp")
                
                // Extract
                _ = try sourceArchive.extract(entry, to: tempFile)
                
                // Processing
                var fileToRead = tempFile
                var shouldCleanupCrops = false
                
                if isImage && pageIndices.contains(currentImageIndex) {
                    // TRIM THIS IMAGE
                    if let image = UIImage(contentsOfFile: tempFile.path), let cgImage = image.cgImage {
                        let width = Double(cgImage.width)
                        let height = Double(cgImage.height)
                        
                        let x = width * trim.left
                        let y = height * trim.top // Vision is bottom-left, typically CoreGraphics via UIImage follows standard checks.
                        // Actually in CoreGraphics (0,0) is top-left for standard image buffers usually.
                        // Let's assume standardized orientation.
                        
                        let newWidth = width * (1.0 - trim.left - trim.right)
                        let newHeight = height * (1.0 - trim.top - trim.bottom)
                        
                        // Crop
                        if let croppedCG = cgImage.cropping(to: CGRect(x: x, y: y, width: newWidth, height: newHeight)) {
                            let croppedImage = UIImage(cgImage: croppedCG)
                            
                            // Save back to disk (overwrite or new temp)
                            let croppedFile = tempDir.appendingPathComponent("cropped_" + tempFile.lastPathComponent)
                            if let data = croppedImage.jpegData(compressionQuality: 0.8) { // Default to JPEG 0.8
                                try data.write(to: croppedFile)
                                fileToRead = croppedFile
                                shouldCleanupCrops = true
                            }
                        }
                    }
                }
                
                // Add to Destination
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
            
            // Swap
            if fileManager.fileExists(atPath: sourceURL.path) { try fileManager.removeItem(at: sourceURL) }
            try fileManager.moveItem(at: tempArchiveURL, to: sourceURL)
            
        }.value
        
        scanLibrary()
        
        // Clear cache if we edited the file currently open
        if self.editorCache?.pdfID == pdf.id {
             self.editorCache = nil
             // We don't force endSession because that might close the UI, but we clear the cache so next page load re-unzips.
        }
    }
    
    // Split / Extract Logic
    func extractPages(from pdf: ConvertedPDF, pageIndices: [Int], asImages: Bool) async throws -> URL {
        let fileManager = FileManager.default
        let newName = "\(pdf.name.replacingOccurrences(of: ".cbz", with: "").replacingOccurrences(of: ".pdf", with: ""))_Split"
        let outputURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("\(newName).cbz")
        
        // ✅ NEW: Prepare Panel Transfer
        // We map SourceIndex -> NewIndex
        let combinedManifest = await getCombinedManifest(for: pdf)
        var newFileOverrides: [Int: [PanelExtractor.Panel]] = [:]
        
        // Reuse reordering logic but only for specific indices and writing to new file
        let tempID = UUID().uuidString
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(tempID)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }
        
        // Scope the Archive creation so it releases the file lock immediately
        try {
            guard let sourceArchive = try? Archive(url: pdf.url, accessMode: .read),
                  let destArchive = try? Archive(url: outputURL, accessMode: .create) else {
                throw NSError(domain: "ArchiveError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not open archive"])
            }
            
            let sortedEntries = sourceArchive.makeIterator().sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            let imageEntries = sortedEntries.filter { entry in
                let ext = (entry.path as NSString).pathExtension.lowercased()
                return ["jpg", "jpeg", "png", "webp"].contains(ext) && !entry.path.contains("__MACOSX") && !entry.path.hasPrefix(".")
            }
            
            for (newIndex, originalIndex) in pageIndices.enumerated() {
                guard originalIndex < imageEntries.count else { continue }
                let entry = imageEntries[originalIndex]
                
                // 1. Transfer Panels (In Memory)
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
        }()
        
        scanLibrary()
        
        // ✅ NEW: Apply Panel Overrides to the newly created file (In Memory)
        if let newPDF = convertedPDFs.first(where: { $0.url.standardizedFileURL.path == outputURL.standardizedFileURL.path }) {
            self.panelOverrides[newPDF.id] = newFileOverrides
            saveLibrary()
        }
        
        // ✅ NEW: Inject Metadata into the File (On Disk)
        // This ensures exports/shares have the panels inside
        try? await injectMetadata(into: outputURL, panels: newFileOverrides, metadata: pdf.metadata)
        
        return outputURL
    }
    
    func extractPages(from pdf: ConvertedPDF, pageIndices: Range<Int>, asImages: Bool) async throws -> URL {
        return try await extractPages(from: pdf, pageIndices: Array(pageIndices), asImages: asImages)
    }
    
    // MARK: - Comic Vault Export
    // Renamed to clarify intent: We are creating a NEW export file with embedded metadata
    func exportForCloudSync(_ pdf: ConvertedPDF) async -> URL? {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory
        
        // 1. Create a Temporary Copy of the Source File
        // We do this to avoid modifying the original library file in place, 
        // ensuring "Export" is a non-destructive action.
        let exportName = pdf.url.lastPathComponent
        let exportURL = tempDir.appendingPathComponent(exportName)
        
        // Remove invalid old temp files
        try? fileManager.removeItem(at: exportURL)
        
        isConverting = true; processingStatus = "Preparing Export..."; statusMessage = "Embedding Metadata..."
        defer { isConverting = false; statusMessage = nil }
        
        do {
            // Copy Source -> Temp
            try fileManager.copyItem(at: pdf.url, to: exportURL)
            
            // 2. Prepare Panels Data (Retrieving from overrides or auto-detection if needed)
            // 2. Prepare Panels Data (Retrieving from overrides or auto-detection if needed)
            var panelsToInject = await getCombinedManifest(for: pdf)
            
            // We need to resolve the full panel set. 
            // Existing logic checked overrides first, then auto-detection.
            // We'll mimic that to build the dictionary for our helper.
            
            let files = try await extractImageURLs(from: pdf.url)
            
            for (index, fileURL) in files.enumerated() {
                if panelsToInject[index] == nil && conversionSettings.enablePanelSplit {
                     // Only run detection if we DON'T have a panel set yet
                     if let image = UIImage(contentsOfFile: fileURL.path) {
                        let detected = await PanelExtractor.detectPanels(in: image, mode: .automatic, mangaMode: conversionSettings.mangaMode)
                        if !detected.isEmpty {
                            panelsToInject[index] = detected
                        }
                    }
                }
                let progress = Double(index) / Double(files.count)
                Task { @MainActor in self.conversionProgress = progress }
            }
            
            // 3. Inject using Helper
            try? await injectMetadata(into: exportURL, panels: panelsToInject, metadata: pdf.metadata)
            
            return exportURL
            
        } catch {
            print("Export Failed: \(error)")
            return nil
        }
    }
    
    func exportForLocalSideload(_ pdf: ConvertedPDF) async -> URL? {
        // Track 2: Local High-Quality
        let fileManager = FileManager.default
        let docDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let exportDir = docDir.appendingPathComponent("KindleExports")
        
        try? fileManager.createDirectory(at: exportDir, withIntermediateDirectories: true, attributes: nil)
        
        let tempName = "Kindle_HQ_\(pdf.name)" // distinguishable name
        let targetURL = exportDir.appendingPathComponent(tempName)
        
        // Remove existing
        try? fileManager.removeItem(at: targetURL)
        
        do {
            try fileManager.copyItem(at: pdf.url, to: targetURL)
            
            // 2. Ensure OPF Metadata (ASIN/Layout)
            try await ensureKindleOPF(at: targetURL)
            
            // 3. Ensure ComicInfo/SmartPanels (Best Effort)
            let panels = await getCombinedManifest(for: pdf)
            if !panels.isEmpty {
                try await injectMetadata(into: targetURL, panels: panels, metadata: pdf.metadata)
            }
            
            return targetURL
        } catch {
            print("Local Export Failed: \(error)")
            return nil
        }
    }
    
    // Helper to generate the <Pages> block
    private func generatePagesXML(from panelsDict: [String: [SmartPanel]]) -> String {
        var xml = "  <Pages>\n"
        
        // Sort keys
        let sortedKeys = panelsDict.keys.compactMap { Int($0) }.sorted().map { String($0) }
        
        for key in sortedKeys {
            if let panels = panelsDict[key] {
                // ComicInfo uses Image="0" for the first page
                xml += "    <Page Image=\"\(key)\">\n"
                
                // There is no standard <Panels> tag in ComicInfo, so we use a custom <SmartPanels>
                // Or we can try to use standard schema attributes if possible, but detection has multiple panels per page.
                // We'll use a custom block inside Page.
                xml += "      <SmartPanels>\n"
                for panel in panels {
                    xml += "        <Panel x=\"\(panel.x)\" y=\"\(panel.y)\" width=\"\(panel.width)\" height=\"\(panel.height)\" />\n"
                }
                xml += "      </SmartPanels>\n"
                xml += "    </Page>\n"
            }
        }
        
        xml += "  </Pages>"
        return xml
    }
    
    // ✅ NEW: Embed currently saved panels into the source file (EPUB/CBZ)
    // ✅ NEW: Embed currently saved panels into the source file (EPUB/CBZ)
    func embedPanels(for pdf: ConvertedPDF) async {
        do {
            guard let panels = panelOverrides[pdf.id] else {
                await MainActor.run {
                    self.appAlert = AppAlert(title: "No Edits Found", message: "There are no saved panel edits for this file to embed.")
                }
                return
            }
            
            try await injectMetadata(into: pdf.url, panels: panels, metadata: pdf.metadata)
            
            await MainActor.run {
                self.appAlert = AppAlert(title: "Success", message: "Panels extracted from the database have been successfully embedded into '\(pdf.name)'.")
            }
        } catch {
            await MainActor.run {
                self.appAlert = AppAlert(title: "Embed Failed", message: error.localizedDescription)
            }
        }
    }
    
    // ✅ NEW: Reusable Metadata Injection
    func injectMetadata(into archiveURL: URL, panels: [Int: [PanelExtractor.Panel]], metadata: PDFMetadata) async throws {
        print("💾 [Injection] Starting metadata injection for: \(archiveURL.lastPathComponent). Panel Pages: \(panels.count)")
        
        // 1. Convert Panels to SmartPanels format
        var smartPanelsDict: [String: [SmartPanel]] = [:]
        for (index, pagePanels) in panels {
            let smartPanels = pagePanels.map { SmartPanel(x: $0.boundingBox.minX, y: $0.boundingBox.minY, width: $0.boundingBox.width, height: $0.boundingBox.height) }
            smartPanelsDict["\(index)"] = smartPanels
        }
        
        // 2. Generate XML
        var xmlContent = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        xmlContent += "<ComicInfo>\n"
        xmlContent += "  <Title>\(metadata.title)</Title>\n"
        if let series = metadata.series { xmlContent += "  <Series>\(series)</Series>\n" }
        // PageCount is implicit or we could calculate it, but optional for import reader usually
        xmlContent += generatePagesXML(from: smartPanelsDict)
        xmlContent += "\n</ComicInfo>"
        
        // 3. Write to Archive
        guard let xmlData = xmlContent.data(using: .utf8) else { return }
        
        // Use ZIPFoundation to update
        // Note: Archive(url:accessMode:) throws.
        let archive = try Archive(url: archiveURL, accessMode: .update)
        
        // Remove old if exists
        if let oldEntry = archive["ComicInfo.xml"] {
            try archive.remove(oldEntry)
        }
        
        
        try archive.addEntry(with: "ComicInfo.xml", type: .file, uncompressedSize: Int64(xmlData.count), modificationDate: Date(), permissions: 0o644, compressionMethod: .deflate, bufferSize: 8192, progress: nil) { position, size in
            let start = Int(position)
            let end = min(start + size, xmlData.count)
            return xmlData.subdata(in: start..<end)
        }
        
        // 4. (EPUB Only) Update Content XHTML for Guided View
        // ComicInfo handles "Round Trip" persistence (Importing back to App)
        // This handles "Export" persistence (Reading on Kindle)
        if archiveURL.pathExtension.lowercased() == "epub" {
            print("📘 [Injection] Detected EPUB. Updating XHTML content for \(panels.count) pages...")
            
            for (index, pagePanels) in panels {
                let pageNum = index + 1
                let xhtmlPath = String(format: "OEBPS/text/page_%04d.xhtml", pageNum)
                
                // 1. Find Image Name (Check standard formats)
                // We need the precise image filename to reference in the HTML
                var imageName: String? = nil
                let imageBase = String(format: "image_%04d", pageNum)
                let candidates = ["jpg", "jpeg", "png", "webp"]
                
                for ext in candidates {
                    let path = "OEBPS/images/\(imageBase).\(ext)"
                    if archive[path] != nil {
                        imageName = "\(imageBase).\(ext)"
                        break
                    }
                }
                
                // If we found the image, we can regenerate the XHTML
                if let validImageName = imageName {
                     let newXHTML = CBZToEPUBConverter.generateXHTML(imageName: validImageName, title: "Page \(pageNum)", panels: pagePanels)
                     
                     if let htmlData = newXHTML.data(using: .utf8) {
                         // Remove old XHTML
                         if let oldEntry = archive[xhtmlPath] {
                             try archive.remove(oldEntry)
                         }
                         
                         // Add new XHTML
                         try archive.addEntry(with: xhtmlPath, type: .file, uncompressedSize: Int64(htmlData.count), modificationDate: Date(), permissions: 0o644, compressionMethod: .deflate, bufferSize: 8192, progress: nil) { position, size in
                             let start = Int(position)
                             let end = min(start + size, htmlData.count)
                             return htmlData.subdata(in: start..<end)
                         }
                     }
                }
            }
        }
    }
    
    // MARK: - Kindle OPF Injection
    // Ensures ASIN and Fixed-Layout Metadata exist for Guided View support.
    private func ensureKindleOPF(at url: URL) async throws {
        // Re-implements the Hot-Fix logic to ensure ASIN and Fixed-Layout tags exist in the OPF.
        // This is critical for activating Guided View on Kindle devices.
        
        let fileManager = FileManager.default
        let tempExtractDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        
        // Optimize: We don't need to unzip everything, just the OPF. 
        // But ZIPFoundation update requires re-archiving or careful manipulation.
        // Simplest consistent way: Read Entry -> Modify -> Remove -> Add.
        
        guard let archive = try? Archive(url: url, accessMode: .update) else { return }
        
        // Find OPF
        guard let opfEntry = archive.makeIterator().first(where: { $0.path.hasSuffix(".opf") }) else { return }
        let opfPath = opfEntry.path
        
        var opfData = Data()
        _ = try archive.extract(opfEntry) { data in opfData.append(data) }
        
        guard var opfString = String(data: opfData, encoding: .utf8) else { return }
        var modified = false
        
        // 1. Check ASIN / UUID
        // Kindle treats 'urn:uuid:...' in dc:identifier as valid for layout activation
        if !opfString.contains("urn:amazon:asin") && !opfString.contains("urn:uuid:") {
            if let range = opfString.range(of: "<metadata") {
                if let endOfOpen = opfString[range.upperBound...].range(of: ">") {
                     let insertIndex = endOfOpen.upperBound
                     let asinUUID = UUID().uuidString
                     let tag = "\n    <dc:identifier id=\"uid\">urn:uuid:\(asinUUID)</dc:identifier>"
                     opfString.insert(contentsOf: tag, at: insertIndex)
                     modified = true
                }
            }
        }
        
        // 2. Check Fixed Layout
        if !opfString.contains("rendition:layout") {
             if let range = opfString.range(of: "</metadata>") {
                 let tag = "\n    <meta property=\"rendition:layout\">pre-paginated</meta>\n    <meta property=\"rendition:orientation\">auto</meta>\n    <meta property=\"rendition:spread\">auto</meta>\n    <meta name=\"fixed-layout\" content=\"true\"/>"
                 opfString.insert(contentsOf: tag, at: range.lowerBound)
                 modified = true
             }
        }
        
        if modified {
            if let newData = opfString.data(using: .utf8) {
                try archive.remove(opfEntry)
                try archive.addEntry(with: opfPath, type: .file, uncompressedSize: Int64(newData.count), modificationDate: Date(), permissions: 0o644, compressionMethod: .deflate, bufferSize: 8192, progress: nil) { position, size in
                     return newData.subdata(in: Int(position)..<min(Int(position)+size, newData.count))
                }
                print("✅ [KindleOPF] Injected Metadata into \(url.lastPathComponent)")
            }
        }
    }


// MARK: - Sidecar Models (Internal Use)
struct SmartPanel: Codable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

// MARK: - XML Parser Helper
class ComicInfoPanelParser: NSObject, XMLParserDelegate {
    private let data: Data
    private var result: [Int: [PanelExtractor.Panel]] = [:]
    
    // State
    private var currentPageIndex: Int?
    private var currentImageSize: CGSize? // ✅ Support for normalization
    private var currentPanels: [PanelExtractor.Panel] = []
    
    init(data: Data) {
        self.data = data
        super.init()
    }
    
    func parse() -> [Int: [PanelExtractor.Panel]] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return result
    }
    
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        let cleanName = elementName.components(separatedBy: ":").last ?? elementName
        
        func getAttr(_ key: String) -> String? {
            return attributeDict.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
        }
        
        if cleanName.caseInsensitiveCompare("Page") == .orderedSame {
            // Schema: <Page Image="0" ImageWidth="1000" ImageHeight="1500">
            if let imageStr = getAttr("Image"), let index = Int(imageStr) {
                currentPageIndex = index
                currentPanels = []
                
                // Capture Dimensions for Normalization
                if let wStr = getAttr("ImageWidth"), let w = Double(wStr),
                   let hStr = getAttr("ImageHeight"), let h = Double(hStr), w > 0, h > 0 {
                    currentImageSize = CGSize(width: w, height: h)
                } else {
                    currentImageSize = nil
                }
            }
        } else if cleanName.caseInsensitiveCompare("Panel") == .orderedSame {
            if let xVal = getAttr("x"), let x = Double(xVal),
               let yVal = getAttr("y"), let y = Double(yVal),
               let wVal = getAttr("width"), let w = Double(wVal),
               let hVal = getAttr("height"), let h = Double(hVal) {
                
                var rect = CGRect(x: x, y: y, width: w, height: h)
                
                // ✅ Auto-Normalize if values are in Pixels
                // Heuristic: If any value is > 2.0 (buffer for float errors), it's likely pixels.
                // Standard normalized panels are 0.0-1.0.
                let isPixels = x > 2.0 || y > 2.0 || w > 2.0 || h > 2.0
                
                if isPixels, let size = currentImageSize {
                    rect = CGRect(
                        x: x / size.width,
                        y: y / size.height,
                        width: w / size.width,
                        height: h / size.height
                    )
                }
                
                // Safety Clamp (0.0 - 1.0)
                // This ensures even slightly off calculations don't break the CSS
                /*
                rect = CGRect(
                    x: max(0, min(1, rect.minX)),
                    y: max(0, min(1, rect.minY)),
                    width: max(0, min(1, rect.width)),
                    height: max(0, min(1, rect.height))
                )
                */
                // Commented clamp out because sometimes panels might bleed slightly, 
                // but for Guided View 0-1 is strict. Let's trust the calc for now.
                
                let panel = PanelExtractor.Panel(boundingBox: rect)
                currentPanels.append(panel)
            }
        }
    }
    
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let cleanName = elementName.components(separatedBy: ":").last ?? elementName
        
        if cleanName.caseInsensitiveCompare("Page") == .orderedSame {
            if let index = currentPageIndex, !currentPanels.isEmpty {
                result[index] = currentPanels
            }
            currentPageIndex = nil
            currentImageSize = nil
            currentPanels = []
        }
    }
}
}

