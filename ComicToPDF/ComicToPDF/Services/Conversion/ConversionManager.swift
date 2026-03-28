import SwiftUI
import PDFKit
import ZIPFoundation
import Combine

@MainActor
class ConversionManager: ObservableObject {
    @Published var convertedPDFs: [ConvertedPDF] = []
    @Published var collections: [PDFCollection] = []
    @Published var conversionPresets: [ConversionPreset] = []
    @Published var kindleDevices: [KindleDevice] = []
    @Published var sendHistory: [ConvertedPDF] = []
    @Published var conversionSettings = ConversionSettings()
    
    // ✅ NEW: Persistent Watched Folders
    struct WatchedFolder: Codable, Identifiable, Equatable {
        var id: UUID = UUID()
        var name: String
        var bookmarkData: Data
    }
    @Published var watchedFolders: [WatchedFolder] = []
    
    // MARK: - Device Registry (Deep Module UX)
    // ✅ MOVED to DeviceRegistry.swift
    
    // MARK: - Series Grouping Prompt (Layer 3)
    struct PendingSeriesGroup: Identifiable {
        let id = UUID()
        let pdfs: [ConvertedPDF]
        let suggestedName: String
    }
    @Published var pendingSeriesGroup: PendingSeriesGroup? = nil
    
    // MARK: - Internal State
    private let libraryFileName = "library.json"
    internal var thumbnailCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 150
        cache.totalCostLimit = 1024 * 1024 * 300 // 300MB
        return cache
    }()
    
    // MARK: - Editor Session Cache
    // ✅ MOVED to WorkspaceSessionManager
    
    // ✅ Moved pageModel extraction and saving to WorkspaceSessionManager
    
    // UI State (Forwarded to TaskEngine)
    var isConverting: Bool { get { TaskEngine.shared.isConverting } set { TaskEngine.shared.isConverting = newValue } }
    var conversionProgress: Double { get { TaskEngine.shared.conversionProgress } set { TaskEngine.shared.conversionProgress = newValue } }
    var processingStatus: String { get { TaskEngine.shared.processingStatus } set { TaskEngine.shared.processingStatus = newValue } }
    var statusMessage: String? { get { TaskEngine.shared.statusMessage } set { TaskEngine.shared.statusMessage = newValue } }
    var appAlert: AppAlert? { get { TaskEngine.shared.appAlert } set { TaskEngine.shared.appAlert = newValue } }
    var activeTasks: [AppBackgroundTask] { get { TaskEngine.shared.activeTasks } set { TaskEngine.shared.activeTasks = newValue } }
    
    // ✅ Session Vault State
    @Published var isVaultUnlocked: Bool = false
    
    // MARK: - Panel Editor State
    @Published var isPresentingPanelEditor: Bool = false
    @Published var currentEditorImage: UIImage? = nil
    @Published var currentEditorPanels: [CGRect] = []
    
    // Non-published continuation for async waiting
    private var panelEditorContinuation: CheckedContinuation<[CGRect], Never>?
    
    func submitPanelEdits(_ rects: [CGRect]) {
        isPresentingPanelEditor = false
        currentEditorImage = nil
        currentEditorPanels = []
        panelEditorContinuation?.resume(returning: rects)
        panelEditorContinuation = nil
    }
    
    var visiblePDFs: [ConvertedPDF] {
        convertedPDFs.filter { $0.isPrivate == isVaultUnlocked }
    }
    
    /// Only Pro-mode files — used by the Pro Library to exclude Go conversions.
    var proLibraryPDFs: [ConvertedPDF] {
        convertedPDFs.filter { $0.isPrivate == isVaultUnlocked && $0.addedByMode == .pro }
    }
    
    // ✅ Secure Processing Core Integration
    private var progressSubscription: AnyCancellable?
    
    // ✅ Export Profiles Mode
    // (conversionPresets state is managed at the top of the file)
    
    init() {
        loadLibrary()
        scanLibrary()
        createWelcomeFile()
        performStartupOptimization()
        Task { await MainActor.run { self.migrateCoversToDisk() } }
        
        // Engine tracking delegated to TaskEngine.shared
        
        // ✅ Subscribe to Go-mode queue completion so files are correctly tagged
        NotificationCenter.default.addObserver(forName: NSNotification.Name("LibraryNeedsRescan"), object: nil, queue: .main) { [weak self] notification in
            let modeRaw = notification.userInfo?["mode"] as? String
            let mode: AppUIMode = (modeRaw == AppUIMode.go.rawValue) ? .go : .pro
            Task { @MainActor [weak self] in
                self?.scanLibrary(addedByMode: mode)
            }
        }
        
        // ✅ Subscribe to external state changes that require library serialization
        NotificationCenter.default.addObserver(forName: NSNotification.Name("LibraryNeedsSave"), object: nil, queue: .main) { [weak self] _ in
            self?.saveLibrary()
        }
    }
    
    private func handleEngineEvent(_ event: ConversionProgressEvent) {
        switch event {
        case .started(let file):
            self.isConverting = true
            self.processingStatus = "Starting: \(file.lastPathComponent)"
        case .progress(_, let current, let total, let message):
            self.conversionProgress = Double(current) / Double(total)
            self.processingStatus = message
        case .completed(_, _):
            self.isConverting = false
            self.processingStatus = ""
            self.scanLibrary() // Refresh
        case .failed(let url, let error):
            self.isConverting = false
            Logger.shared.log("Conversion Failed [\(url.lastPathComponent)]: \(error.localizedDescription)", category: "Engine", type: .error)
            self.appAlert = AppAlert(title: "Conversion Failed", message: error.localizedDescription)
        }
    }
    
    // MARK: - Omnibus Construction
    @MainActor
    func enqueueOmnibus(name: String, sourceFiles: [ConvertedPDF]) {
        let task = AppBackgroundTask(title: "Building Omnibus: \(name)", progress: 0.0)
        activeTasks.append(task)
        
        let urls = sourceFiles.map { $0.url }
        let startCover = sourceFiles.first?.coverImageData
        let settings = self.conversionSettings
        let saveDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        
        Task.detached(priority: .userInitiated) {
            do {
                let generatedFiles = try await EPUBMerger().mergeWithSmartSplit(
                    sourceURLs: urls,
                    baseOutputName: name,
                    targetDir: saveDir,
                    settings: settings,
                    overrideCoverData: startCover,
                    progressCallback: { progress in
                        Task { @MainActor in task.progress = progress }
                    }
                )
                
                Task { @MainActor in
                    for fileURL in generatedFiles {
                        do {
                            let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
                            let size = attrs[.size] as? Int64 ?? 0
                            
                            var newPDF = ConvertedPDF(
                                id: UUID(),
                                name: fileURL.deletingPathExtension().lastPathComponent,
                                url: fileURL,
                                pageCount: 0,
                                fileSize: size,
                                metadata: PDFMetadata(title: fileURL.deletingPathExtension().lastPathComponent),
                                contentType: .book
                            )
                            newPDF.lastOutputFormat = settings.outputFormat
                            newPDF.coverImageData = startCover
                            self.convertedPDFs.append(newPDF)
                        } catch {}
                    }
                    self.saveLibrary()
                    self.activeTasks.removeAll(where: { $0.id == task.id })
                    self.appAlert = AppAlert(title: "Omnibus Complete", message: "Successfully created \(generatedFiles.count) volumes for \(name)")
                }
            } catch {
                Task { @MainActor in
                    self.activeTasks.removeAll(where: { $0.id == task.id })
                    self.appAlert = AppAlert(title: "Omnibus Failed", message: error.localizedDescription)
                }
            }
        }
    }
    
    // Legacy Init Continuation...
    
    private func performStartupOptimization() {
        let key = "hasRunStartupOptimization"
        if UserDefaults.standard.bool(forKey: key) { return }
        
        let memory = ProcessInfo.processInfo.physicalMemory
        let ramGB = Double(memory) / 1024.0 / 1024.0 / 1024.0
        

        
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
        LibraryPersistenceManager.shared.createWelcomeFile()
    }
    
    func cleanupMemory() { thumbnailCache.removeAllObjects() }
    
    // MARK: - Persistence Façade
    private var saveTask: Task<Void, Never>?
    
    func saveLibrary() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            // 0.5s Debounce to prevent massive MainActor stalling during intensive loops
            try? await Task.sleep(nanoseconds: 500_000_000) 
            guard !Task.isCancelled else { return }
            LibraryPersistenceManager.shared.save(manager: self)
        }
    }
    
    func savePDFs() { saveLibrary() }
    
    // ✅ NEW: Custom Event Reordering
    func updateCollectionOrder(collectionID: UUID, newOrderIDs: [UUID]) {
        if let idx = collections.firstIndex(where: { $0.id == collectionID }) {
            collections[idx].manualSortOrder = newOrderIDs
            saveLibrary()
        }
    }
    
    func loadLibrary() {
        LibraryPersistenceManager.shared.load(manager: self)
    }
    
    func savePanelOverrides(for pdfID: UUID, pageIndex: Int, panels: [PanelExtractor.Panel]) async {
        if WorkspaceSessionManager.shared.panelOverrides[pdfID] == nil { WorkspaceSessionManager.shared.panelOverrides[pdfID] = [:] }
        WorkspaceSessionManager.shared.panelOverrides[pdfID]?[pageIndex] = panels
        saveLibrary() 
    }
    
    // ✅ NEW: Bulk Save
    func savePanelOverrides(for pdfID: UUID, panels: [Int: [PanelExtractor.Panel]]) {
        WorkspaceSessionManager.shared.panelOverrides[pdfID] = panels
        self.saveLibrary()
    }
    
    // MARK: - Cover Image Management (Memory Optimization)
    
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

    /// Returns the active cover (either the selected variant, or the original fallback)
    func getCoverURL(for pdf: ConvertedPDF) -> URL? {
        PhysicalFileSystemRouter.shared.getCoverURL(for: pdf)
    }

    /// Returns the absolute path to the original extracted cover image saved in Application Support
    func getOriginalCoverURL(for pdf: ConvertedPDF) -> URL {
        PhysicalFileSystemRouter.shared.getOriginalCoverURL(for: pdf)
    }
    
    /// Migrates legacy Data-based covers to disk-based storage
    func migrateCoversToDisk() {
        PhysicalFileSystemRouter.shared.migrateCoversToDisk(manager: self)
    }
    
    /// Thread-safe, memory-efficient cover loader
    func loadCoverThumbnail(for pdf: ConvertedPDF) async -> UIImage? {
        await PhysicalFileSystemRouter.shared.loadCoverThumbnail(for: pdf, manager: self)
    }
    
    /// Save cover image to disk and update cache
    func saveCoverImage(_ data: Data, for pdf: ConvertedPDF) {
        PhysicalFileSystemRouter.shared.saveCoverImage(data, for: pdf, manager: self)
    }
    
    // ✅ NEW: Advanced Metadata Update
    func updateMetadata(for pdf: ConvertedPDF, with newMetadata: PDFMetadata, newCover: UIImage?) {
        if let idx = convertedPDFs.firstIndex(where: { $0.id == pdf.id }) {
            convertedPDFs[idx].metadata = newMetadata
            convertedPDFs[idx].name = newMetadata.title // Sync filename for display
            
            if let img = newCover, let data = img.jpegData(compressionQuality: 0.85) {
                saveCoverImage(data, for: pdf)
            }
            
            saveLibrary()
            Logger.shared.log("Updated metadata for \(pdf.name)", category: "Metadata")
            
            // ✅ Pro Feature: Write back to file formats
            Task {
                do {
                    let ext = pdf.url.pathExtension.lowercased()
                    if ext == "cbz" || ext == "zip" {
                        try await ComicInfoWriter.write(metadata: newMetadata, to: pdf.url)
                        Logger.shared.log("Wrote metadata changes back to archive: \(pdf.name)", category: "Metadata")
                    } else if ext == "epub" {
                        // Attempt native EPUB injection
                        let panels = await getCombinedManifest(for: pdf)
                        try await injectMetadata(into: pdf.url, panels: panels, metadata: newMetadata)
                        Logger.shared.log("Injected updated metadata into EPUB: \(pdf.name)", category: "Metadata")
                    } else if ext == "pdf" {
                        Logger.shared.log("Metadata updated successfully in library for PDF: \(pdf.name)", category: "Metadata")
                    }
                } catch {
                    Logger.shared.log("Failed to write to archive: \(error.localizedDescription)", category: "Metadata", type: .error)
                }
            }
        }
    }
    
    // ✅ NEW: Centralized manifest logic to fix panel loss
    func getCombinedManifest(for pdf: ConvertedPDF) async -> [Int: [PanelExtractor.Panel]] {
        var combined = WorkspaceSessionManager.shared.panelOverrides[pdf.id] ?? [:]
        Logger.shared.log("Building Manifest for \(pdf.name) (ID: \(pdf.id))", category: "Manifest")
        
        // Merge with source panels if available
        if let sourcePanels = try? await extractSmartPanels(from: pdf.url) {
            Logger.shared.log("Merging \(sourcePanels.count) source pages into manifest", category: "Manifest")
            for (pageIndex, panels) in sourcePanels {
                if combined[pageIndex] == nil {
                    combined[pageIndex] = panels
                }
            }
        }
        return combined
    }
    
    // MARK: - File Management
    func scanLibrary(addedByMode: AppUIMode? = nil) {
        Task {
            // ✅ Delegated O(N) file enumeration to strictly concurrent Actor
            await LibraryScanner.shared.scanLibrary(addedByMode: addedByMode, manager: self)
        }
    }
    
    func deletePDF(_ pdf: ConvertedPDF) {
        PhysicalFileSystemRouter.shared.deletePDF(pdf, manager: self)
    }
    
    func removeFromLibrary(_ pdf: ConvertedPDF) { deletePDF(pdf) }
    
    // MARK: - Page Management
    
    /// Delete specific pages from a converted PDF (CBZ)
    /// - Parameters:
    ///   - pdf: The ConvertedPDF object to modify
    ///   - pageIndices: Set of 0-based page indices to remove
    func deletePages(from pdf: ConvertedPDF, pageIndices: Set<Int>) async throws {
        guard !pageIndices.isEmpty else { return }
        
        await MainActor.run { processingStatus = "Deleting \(pageIndices.count) pages..." }
        
        // 1. Extract CBZ to Temp Directory
        let result = try await ZipUtilities.extractComic(from: pdf.url)
        let tempDir = result.workingDir
        let imageFiles = result.imageURLs
        
        // Ensure cleanup even on error
        defer { 
            try? FileManager.default.removeItem(at: tempDir)
            Task { await MainActor.run { processingStatus = "" } }
        }

        // 2. Delete Selected Files
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
        
        // 3. Re-Create CBZ Archive
        let newCBZURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".cbz")
        try await ZipUtilities.zipDirectory(tempDir, to: newCBZURL)
        
        // 4. Atomically Swap Files
        if FileManager.default.fileExists(atPath: pdf.url.path) {
            try FileManager.default.removeItem(at: pdf.url)
        }
        try FileManager.default.moveItem(at: newCBZURL, to: pdf.url)
        
        // 5. Update Metadata
        let attr = try FileManager.default.attributesOfItem(atPath: pdf.url.path)
        let newSize = attr[.size] as? Int64 ?? 0
        
        await MainActor.run {
            if let idx = convertedPDFs.firstIndex(where: { $0.id == pdf.id }) {
                convertedPDFs[idx].pageCount -= deletedCount
                convertedPDFs[idx].fileSize = newSize
                
                // Remove associated data
                WorkspaceSessionManager.shared.panelOverrides[pdf.id] = nil
                
                saveLibrary()
            }
            Logger.shared.log("Deleted \(deletedCount) pages from \(pdf.name)", category: "Edit")
        }
    }
    
    func addConvertedPDF(url: URL, pageCount: Int = 0, fileSize: Int64 = 0, duration: TimeInterval = 0) {
         let pdf = ConvertedPDF(name: url.lastPathComponent, url: url, pageCount: pageCount, fileSize: fileSize, metadata: PDFMetadata(title: url.lastPathComponent), collectionId: nil)
         convertedPDFs.append(pdf)
         saveLibrary()
         Task { await self.generateCoverThumbnail(for: pdf) }
     }
    
    func processImportedFiles(urls: [URL]) async {
        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var skippedFiles: [String] = []
        var filesToProcess: [URL] = []
        
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            
            let ext = url.pathExtension.lowercased()
            let finalName: String
            if ext == "epub" {
                finalName = (url.lastPathComponent as NSString).deletingPathExtension + ".cbz"
            } else {
                finalName = url.lastPathComponent
            }
            let destURL = documentsDir.appendingPathComponent(finalName)
            
            if FileManager.default.fileExists(atPath: destURL.path) {
                skippedFiles.append(finalName)
            } else {
                filesToProcess.append(url)
            }
        }
        
        if !skippedFiles.isEmpty {
            let message = skippedFiles.count == 1 ? "Skipped duplicate file:\n\(skippedFiles[0])" : "Skipped \(skippedFiles.count) duplicate files."
            await MainActor.run {
                self.appAlert = AppAlert(title: "Duplicates Skipped", message: message)
            }
        }
        
        for url in filesToProcess {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            
            // ✅ NEW: Handle PDF imports differently
            let ext = url.pathExtension.lowercased()
            let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

            if ext == "pdf" {
                Task {
                    // ✅ Offload to ConversionEngine
                    do {
                        let _ = try await ConversionEngine.shared.performPDFImport(url: url, destFolder: documentsDir)
                        // Engine emits 'completed' which triggers scanLibrary()
                    } catch {
                        Logger.shared.log("Engine Import Failed: \(error)", category: "Import", type: .error)
                        await MainActor.run {
                            self.appAlert = AppAlert(title: "Import Failed", message: error.localizedDescription)
                        }
                    }
                }
                continue
            } else if ext == "epub" {
                 // ✅ NEW: EPUB Import
                 Task {
                     do {
                         // 1. Create Destination
                         let cleanName = (url.lastPathComponent as NSString).deletingPathExtension
                         let cbzName = cleanName + ".cbz"
                         let cbzURL = documentsDir.appendingPathComponent(cbzName)
                         
                         // 2. Extract Images via Helper
                         // We extract to a temporary folder first
                         let tempExtractDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                         try FileManager.default.createDirectory(at: tempExtractDir, withIntermediateDirectories: true)
                         
                         _ = try EPUBImporter.extractImages(from: url, to: tempExtractDir)
                         
                         // 3. Zip to CBZ
                         try await ZipUtilities.zipDirectory(tempExtractDir, to: cbzURL)
                         
                         // 4. Cleanup
                         try? FileManager.default.removeItem(at: tempExtractDir)
                         try? FileManager.default.removeItem(at: url) // Consume original? Usually yes for "Import"
                         
                         await MainActor.run {
                             self.scanLibrary()
                             self.appAlert = AppAlert(title: "Import Success", message: "Imported EPUB as Comic.")
                         }
                     } catch {
                         Logger.shared.log("EPUB Import Failed: \(error.localizedDescription)", category: "Import", type: .error)
                         await MainActor.run {
                             self.appAlert = AppAlert(title: "EPUB Import Failed", message: error.localizedDescription)
                         }
                     }
                 }
                 continue
            }
            
            // Existing CBZ/ZIP handling
            do {
                let fileName = url.lastPathComponent
                let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let destURL = docDir.appendingPathComponent(fileName)
                try FileManager.default.copyItem(at: url, to: destURL)
            } catch { 
                Logger.shared.log("Failed to copy imported file \(url.lastPathComponent): \(error.localizedDescription)", category: "Import", type: .error)
            }
        }
        scanLibrary()
    }
    
    // MARK: - iOS Watched Folder Persistent Sync
    
    // MARK: - Orchestrator FaÃ§ade Connectors
    func importFolderStructure(from folderURL: URL) async {
        await ImportOrchestrator.shared.importFolderStructure(from: folderURL, manager: self)
    }

    func importFilesAsSeries(urls: [URL]) async {
        await ImportOrchestrator.shared.importFilesAsSeries(urls: urls, manager: self)
    }

    func finalizeSeriesImport(pdfs: [ConvertedPDF], seriesName: String) async {
        await ImportOrchestrator.shared.finalizeSeriesImport(pdfs: pdfs, seriesName: seriesName, manager: self)
    }

    func assignToSeries(_ pdf: ConvertedPDF, seriesName: String) {
        ImportOrchestrator.shared.assignToSeries(pdf, seriesName: seriesName, manager: self)
    }

    func syncWatchedFolders() async {
        await ImportOrchestrator.shared.syncWatchedFolders(manager: self)
    }

    func detectContentType(from url: URL) -> ContentType {
        return ImportOrchestrator.shared.detectContentType(from: url, manager: self)
    }

    func importPDF(url: URL) async {
        await ImportOrchestrator.shared.importPDF(url: url, manager: self)
    }
    
    
    // MARK: - STABLE FILE EXTRACTION
    func extractImageFiles(from url: URL) async throws -> (workingDir: URL, files: [URL]) {
        return try await EditorSessionManager.shared.extractImageFiles(from: url)
    }
    
    func extractImageURLs(from url: URL) async throws -> [URL] {
        return try await EditorSessionManager.shared.extractImageURLs(from: url)
    }
    
    // Helper used by Editor for Single Page Load
    func extractFullPage(from pdf: ConvertedPDF, index: Int) async throws -> UIImage? {
        return try await EditorSessionManager.shared.extractFullPage(pdfID: pdf.id, pdfURL: pdf.url, index: index)
    }
    
    func endSession() {
        Task {
            await EditorSessionManager.shared.endSession(manager: self)
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
        let safeName = outputName.isEmpty ? "Merged Collection" : outputName; let outputURL = docDir.appendingPathComponent("\(safeName).epub")
        let merger = EPUBMerger(); let sourceURLs = pdfs.map { $0.url }
        var inheritedCover: UIImage?
        if let firstPDF = pdfs.first { inheritedCover = getThumbnail(for: firstPDF) }
        do {
            var mergeSettings = ConversionSettings()
            mergeSettings.mangaMode = mangaMode
            try await Task.detached { try await merger.mergeEPUBs(sourceURLs: sourceURLs, outputURL: outputURL, settings: mergeSettings) }.value
            let fileSize = (try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            
            // ✅ FIX: Sum original page counts to prevent scanLibrary() memory freezing lookup
            let totalPages = pdfs.reduce(0) { $0 + $1.pageCount }
            
            let newPDF = ConvertedPDF(name: outputURL.lastPathComponent, url: outputURL, pageCount: totalPages, fileSize: fileSize, metadata: PDFMetadata(title: safeName))
            await MainActor.run { self.convertedPDFs.append(newPDF) } // ✅ FIX: Append directly to skip expensive scan
            if let cover = inheritedCover { thumbnailCache.setObject(cover, forKey: outputURL.path as NSString); objectWillChange.send() }
            else { Task { await self.generateCoverThumbnail(for: newPDF) } }
            isConverting = false; statusMessage = "✅ Merge Complete!"; scanLibrary()
            Logger.shared.log("Merge Successful: \(outputName)", category: "Converter")
            try? await Task.sleep(nanoseconds: 3 * 1_000_000_000); self.statusMessage = nil
        } catch { 
            Logger.shared.log("Merge Failed: \(error)", category: "Converter", type: .error)
            isConverting = false; statusMessage = "Merge Error: \(error.localizedDescription)" 
        }
    }
    
    func convertComic(_ pdf: ConvertedPDF, mangaMode: Bool? = nil) async {
        await ConversionOrchestrator.shared.convertComic(pdf, mangaMode: mangaMode, manager: self)
    }
    
    func convertQueue(_ pdfs: [ConvertedPDF]) async {
        await ConversionOrchestrator.shared.convertQueue(pdfs, manager: self)
    }
    
    @discardableResult
    func convertAndMerge(sourceFiles: [ConvertedPDF], outputName: String, mangaMode: Bool, overrideSeries: String? = nil) async -> [ConvertedPDF] {
        return await ConversionOrchestrator.shared.convertAndMerge(sourceFiles: sourceFiles, outputName: outputName, mangaMode: mangaMode, overrideSeries: overrideSeries, manager: self)
    }
    // MARK: - Thumbnails & Helpers
    func generateCoverThumbnail(for pdf: ConvertedPDF) async {
        await PhysicalFileSystemRouter.shared.generateCoverThumbnail(for: pdf, manager: self)
    }
    
    func backfillMissingThumbnails() {
        PhysicalFileSystemRouter.shared.backfillMissingThumbnails(manager: self)
    }
    
    func loadThumbnailAsync(for pdf: ConvertedPDF) async {
        await PhysicalFileSystemRouter.shared.loadThumbnailAsync(for: pdf, manager: self)
    }
    
    func getThumbnail(for pdf: ConvertedPDF) -> UIImage? {
        PhysicalFileSystemRouter.shared.getThumbnail(for: pdf, manager: self)
    }
    
    func extractSmartPanels(from url: URL) async throws -> [Int: [PanelExtractor.Panel]]? {
        await MainActor.run { processingStatus = "Reading Source Panels..." } // Re-assert status
        
        Logger.shared.log("Inspection Started: \(url.lastPathComponent)", category: "SmartPanels")
        // Create Archive Accessor
        guard let archive = try? Archive(url: url, accessMode: .read, pathEncoding: .utf8) else {
            throw ConversionError.invalidFormat
        }
        
        // 1. Check for Embedded Metadata in OPF (New Standard)
        // Find OPF
        if let opfEntry = archive.makeIterator().first(where: { $0.path.hasSuffix(".opf") }) {
            var opfData = Data()
            // Extract OPF data
            if let _ = try? archive.extract(opfEntry, consumer: { opfData.append($0) }),
               let opfString = String(data: opfData, encoding: .utf8) {
                
                // Search for our specific tag and attributes strictly
                if let range = opfString.range(of: "name=\"inksync-comicinfo\""),
                   let suffix = Optional(opfString[range.upperBound...]),
                   let contentStart = suffix.range(of: "content=\""),
                   let contentSuffix = Optional(suffix[contentStart.upperBound...]),
                   let contentEnd = contentSuffix.range(of: "\"") {
                       
                    let base64 = String(contentSuffix[..<contentEnd.lowerBound])
                    if let xmlData = Data(base64Encoded: base64) {
                        Logger.shared.log("Found Embedded ComicInfo in OPF", category: "SmartPanels")
                        let parser = ComicInfoPanelParser(data: xmlData)
                        let result = parser.parse()
                        if !result.isEmpty {
                            await MainActor.run { processingStatus = "Metadata Found (Embedded)" }
                            try? await Task.sleep(nanoseconds: 500_000_000)
                            return result
                        }
                    }
                }
            }
        }
        
        // 2. Fallback: Physical File (Legacy)
        // Find ComicInfo.xml (Prioritize META-INF for new standard, then Root/OEBPS)
        var comicInfoEntry: Archive.Element? = nil
        
        if let entry = archive["META-INF/ComicInfo.xml"] {
            comicInfoEntry = entry
        } else if let entry = archive["ComicInfo.xml"] {
             comicInfoEntry = entry
        } else {
             // Fallback: Search for any ComicInfo.xml (e.g. inside OEBPS)
             comicInfoEntry = archive.makeIterator().first { $0.path.lowercased().hasSuffix("comicinfo.xml") }
        }
        
        // 3. Last Resort Fallback: panels.json (Legacy Normalized Panels)
        if comicInfoEntry == nil, let jsonEntry = archive["panels.json"] ?? archive.makeIterator().first(where: { $0.path.lowercased().hasSuffix("panels.json") }) {
            var jsonData = Data()
            do {
                _ = try archive.extract(jsonEntry) { jsonData.append($0) }
                let decoded = try JSONDecoder().decode([Int: [PanelExtractor.Panel]].self, from: jsonData)
                if !decoded.isEmpty {
                    await MainActor.run { processingStatus = "Metadata Found (panels.json)" }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    return decoded // panels.json was stored normalized
                }
            } catch {
                Logger.shared.log("Failed to parse legacy panels.json: \(error)", category: "SmartPanels", type: .error)
            }
        }
        
        guard let entry = comicInfoEntry else {
            Logger.shared.log("No ComicInfo or panels.json Metadata found", category: "SmartPanels")
            
            // Log what WAS found
            let files = archive.makeIterator().prefix(10).map { $0.path }
            Logger.shared.log("Files seen: \(files.joined(separator: ", "))...", category: "SmartPanels")
            
            await MainActor.run { processingStatus = "Skipping: No Metadata Found" }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            return nil
        }
        
        var xmlData = Data()
        do {
            _ = try archive.extract(entry) { xmlData.append($0) }
        } catch {
            Logger.shared.log("Failed to extract XML data", category: "SmartPanels")
            return nil
        }
        
        let parser = ComicInfoPanelParser(data: xmlData)
        var result = parser.parse()
        
        if result.isEmpty {
             await MainActor.run { processingStatus = "Skipping: Metadata Empty" }
             try? await Task.sleep(nanoseconds: 1_000_000_000)
             return nil
        }
        
        await MainActor.run { processingStatus = "Metadata Found (\(result.count) pages)" }
        try? await Task.sleep(nanoseconds: 500_000_000)
        
        // ✅ REPAIR: Check for Denormalized (Pixel) Coordinates
        let needsRepair = result.values.flatMap { $0 }.contains { panel in
            return panel.boundingBox.minX > 2.0 || panel.boundingBox.minY > 2.0 || panel.boundingBox.width > 2.0
        }
        
        if needsRepair {
             await MainActor.run { processingStatus = "Repairing Pixel Coordinates..." }
             Logger.shared.log("Detected Pixel Coordinates. Repairing...", category: "SmartPanels")
            
            // 1. Get Sorted Images (Canonical Order) to match XML "Page N"
            let sortedEntries = archive.makeIterator().sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            let imageEntries = sortedEntries.filter { entry in
                let ext = (entry.path as NSString).pathExtension.lowercased()
                return ["jpg", "jpeg", "png", "webp"].contains(ext) && !entry.path.contains("__MACOSX") && !entry.path.hasPrefix(".")
            }
            
            // 2. Iterate pages that need repair
            for (pageIndex, panels) in result {
                guard pageIndex < imageEntries.count else { continue }
                
                // Check if this specific page has pixels
                let pageHasPixels = panels.contains { $0.boundingBox.minX > 2.0 || $0.boundingBox.width > 2.0 }
                if pageHasPixels {
                    let entry = imageEntries[pageIndex]
                    
                    // Extract Header Only to get Size
                    // We extract just enough bytes or full file to memory (easier)
                    // Given these are images, we have to extract to read headers reliably unless we use custom ZIP parsing.
                    // For safety, we extract to memory.
                    var imageData = Data()
                    do {
                        _ = try archive.extract(entry) { imageData.append($0) }
                        
                        // Get Size
                        // We use a helper that doesn't fully decode if possible, or just UIImage
                        if let image = UIImage(data: imageData) {
                            let size = image.size
                            if size.width > 0 && size.height > 0 {
                                // NORMALIZE
                                let normalizedPanels = panels.map { panel -> PanelExtractor.Panel in
                                    let r = panel.boundingBox
                                    // If value is > 2, treat as pixel. Else assume normalized.
                                    let nx = (r.minX > 2.0) ? r.minX / size.width : r.minX
                                    let ny = (r.minY > 2.0) ? r.minY / size.height : r.minY
                                    let nw = (r.width > 2.0) ? r.width / size.width : r.width
                                    let nh = (r.height > 2.0) ? r.height / size.height : r.height
                                    
                                    return PanelExtractor.Panel(boundingBox: CGRect(x: nx, y: ny, width: nw, height: nh))
                                }
                                result[pageIndex] = normalizedPanels
                                Logger.shared.log("Repaired Page \(pageIndex) using size \(size)", category: "SmartPanels")
                            }
                        }
                    } catch {
                        Logger.shared.log("Repair failed for Page \(pageIndex): \(error)", category: "SmartPanels")
                    }
                }
            }
        }
        
        Logger.shared.log("Parsed \(result.count) pages", category: "SmartPanels")
        
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
        
        // Don't automatically append extension - user should provide the full name they want
        let newURL = docDir.appendingPathComponent(cleanName)
        
        // Prevent overwrite
        if fileManager.fileExists(atPath: newURL.path) {
            // Simple handling: fail or alert. For now, we will append a counter if we were fancy, but let's just return to avoid data loss.
            Logger.shared.log("Rename failed: File exists", category: "Library")
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
            Logger.shared.log("Rename Error: \(error)", category: "Library")
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
        
        guard let sourceArchive = try? Archive(url: url, accessMode: .read, pathEncoding: .utf8),
              let destArchive = try? Archive(url: tempArchiveURL, accessMode: .create, pathEncoding: .utf8) else {
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
            WorkspaceSessionManager.shared.panelOverrides[pdf.id] = newPanels
            self.saveLibrary()
        }
        try? await injectMetadata(into: url, panels: newPanels, metadata: pdf.metadata)
        
        return url
    }
    
    // MARK: - Trimming Logic
    func trimPages(from pdf: ConvertedPDF, pageIndices: Set<Int>, trim: (top: Double, bottom: Double, left: Double, right: Double)) async throws {
        // Validate type: Must be an archive
        let ext = pdf.url.pathExtension.lowercased()
        guard ["cbz", "zip", "epub"].contains(ext) else {
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
            
            guard let sourceArchive = try? Archive(url: sourceURL, accessMode: .read, pathEncoding: .utf8),
                  let destArchive = try? Archive(url: tempArchiveURL, accessMode: .create, pathEncoding: .utf8) else {
                throw NSError(domain: "ArchiveError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not open archive"])
            }
            
            let sortedEntries = sourceArchive.makeIterator().sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            _ = sortedEntries.filter { entry in
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
        Task {
            await EditorSessionManager.shared.clearCache(for: pdf.id)
        }
        
        // ✅ ADVANCED COVER STUDIO: Heuristic Re-evaluation
        if pageIndices.contains(0) {
            await MainActor.run {
                self.thumbnailCache.removeObject(forKey: pdf.id.uuidString as NSString)
            }
            
            // Remove Explicit Variant if active
            if pdf.metadata.selectedCoverID == nil {
                // If it's just the extracted default, force the system to find the new first valid portrait page
                await generateCoverThumbnail(for: pdf)
            }
            
            await MainActor.run {
                self.objectWillChange.send() // Force UI refresh for the new cover
            }
        }
    }
    
    // MARK: - Advanced Cover Studio
    func extractCoverVariant(from pdf: ConvertedPDF, pageIndex: Int) async throws {
        let fileManager = FileManager.default
        
        // Ensure "Covers" sandbox directory exists
        let coversDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Covers")
        try? fileManager.createDirectory(at: coversDir, withIntermediateDirectories: true)
        
        // 1. Unzip just that one page
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
        
        // 2. Load into UIImage to ensure format/size
        guard let extractedImage = UIImage(contentsOfFile: tempURL.path),
              let jpegData = extractedImage.jpegData(compressionQuality: 0.9) else {
            try? fileManager.removeItem(at: tempURL)
            throw NSError(domain: "CoverError", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to render image payload"])
        }
        
        try? fileManager.removeItem(at: tempURL) // Clean
        
        // 3. Save to Covers Sandbox
        let variantID = UUID()
        let variantURL = coversDir.appendingPathComponent("\(variantID.uuidString).jpg")
        try jpegData.write(to: variantURL)
        
        // 4. Update PDFManifest with the new Variant
        await MainActor.run {
            if let idx = self.convertedPDFs.firstIndex(where: { $0.id == pdf.id }) {
                self.convertedPDFs[idx].metadata.coverVariants[variantID] = variantURL
                self.saveLibrary()
                self.objectWillChange.send() // Refresh Cover Studio UI
            }
        }
    }
    
    func setActiveCoverVariant(_ variantID: UUID?, for pdf: ConvertedPDF) async {
        await MainActor.run {
            if let idx = self.convertedPDFs.firstIndex(where: { $0.id == pdf.id }) {
                self.convertedPDFs[idx].metadata.selectedCoverID = variantID
                
                // Clear the cache so it forces a reload of the new variant or fallback original
                self.thumbnailCache.removeObject(forKey: pdf.url.path as NSString)
                
                self.saveLibrary()
                self.objectWillChange.send()
            }
        }
        
        // Ensure standard thumbnail is generated for the new variant
        await generateCoverThumbnail(for: self.convertedPDFs.first(where: { $0.id == pdf.id }) ?? pdf)
    }
    
    // MARK: - Advanced Filesystem Engineering
    
    /// Physically renames the underlying .cbz, .epub, or .pdf on the iOS Storage and updates the database pointer.
    func safelyRenamePhysicalFile(pdf: ConvertedPDF, newName: String) throws {
        try PhysicalFileSystemRouter.shared.safelyRenamePhysicalFile(pdf: pdf, newName: newName, manager: self)
    }
    
    // MARK: - Chapter Detection
    func detectChapters(for pdf: ConvertedPDF) async {
        guard pdf.contentType == .book || pdf.contentType == .hybrid else { return }
        
        isConverting = true; processingStatus = "Scanning Chapters..."; statusMessage = "0%"
        defer { isConverting = false; statusMessage = nil; processingStatus = "" }
        
        do {
            let chapters = try await ChapterDetector.shared.detectChapters(in: pdf, languages: ["en-US"]) { progress in
                Task { @MainActor in
                    self.statusMessage = String(format: "%.0f%%", progress * 100)
                }
            }
            
            await MainActor.run {
                if let idx = convertedPDFs.firstIndex(where: { $0.id == pdf.id }) {
                    convertedPDFs[idx].chapters = chapters
                    saveLibrary()
                }
                processingStatus = "Found \(chapters.count) chapters!"
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            
        } catch {
             Logger.shared.log("Chapter detection failed: \(error)", category: "Editor", type: .error)
             await MainActor.run {
                 processingStatus = "Scan Failed"
             }
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
            WorkspaceSessionManager.shared.panelOverrides[newPDF.id] = newFileOverrides
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
        
        // ✅ NEW: Book Branch (Text EPUBs Pass-Through)
        if pdf.contentType == .book {
            let exportURL = tempDir.appendingPathComponent(pdf.name)
            try? fileManager.removeItem(at: exportURL)
            do {
                try fileManager.copyItem(at: pdf.url, to: exportURL)
                Logger.shared.log("Book Export: Safe pass-through for \(pdf.name)", category: "Export")
                return exportURL
            } catch {
                Logger.shared.log("❌ Book Export Failed: \(error.localizedDescription)", category: "Export", type: .error)
                return nil
            }
        }
        
        // ✅ NEW: PDF Branch
        if conversionSettings.outputFormat == .pdf {
            let exportName = pdf.name.replacingOccurrences(of: ".cbz", with: ".pdf")
            let exportURL = tempDir.appendingPathComponent(exportName)
            
            isConverting = true; processingStatus = "Generating PDF..."
            defer { 
                isConverting = false 
                Task { @MainActor in self.processingStatus = "" }
            }
            
            do {
                // 1. Extract Images
                let imageURLs = try await extractImageURLs(from: pdf.url)
                
                // 2. Generate PDF
                try PDFGenerator.generate(from: imageURLs, to: exportURL, mangaMode: conversionSettings.mangaMode, chapters: pdf.chapters, settings: conversionSettings) { progress in
                    Task { @MainActor in self.processingStatus = "Processing \(Int(progress * 100))%" }
                }
                
                return exportURL
            } catch {
                Logger.shared.log("❌ PDF Export Failed: \(error)", category: "Export")
                return nil
            }
        }
        
        // ... Existing EPUB Logic ...
        // 1. Create a Temporary Copy of the Source File
        // We do this to avoid modifying the original library file in place, 
        // ensuring "Export" is a non-destructive action.
        let exportName = pdf.url.lastPathComponent
        let exportURL = tempDir.appendingPathComponent(exportName)
        
        // Remove invalid old temp files
        try? fileManager.removeItem(at: exportURL)
        
        isConverting = true; processingStatus = "Preparing Export..."; statusMessage = "Embedding Metadata..."
        defer { 
            isConverting = false 
            statusMessage = nil 
            Task { @MainActor in self.processingStatus = "" }
        }
        
        do {
            Logger.shared.log("Starting Cloud Export for \(pdf.name)", category: "Export")
            // Copy Source -> Temp
            try fileManager.copyItem(at: pdf.url, to: exportURL)
            
            // 2. Prepare Panels Data (CONDITIONAL)
            var panelsToInject = [Int: [PanelExtractor.Panel]]()
            if conversionSettings.isGuidedView {
                panelsToInject = await getCombinedManifest(for: pdf)
                
                let files = try await extractImageURLs(from: pdf.url)
                
                for (index, fileURL) in files.enumerated() {
                    if panelsToInject[index] == nil && conversionSettings.enablePanelSplit {
                         if let image = UIImage(contentsOfFile: fileURL.path) {
                            let detected = await PanelExtractor.detectPanels(in: image, mode: .automatic, mangaMode: conversionSettings.mangaMode)
                            if !detected.isEmpty {
                                // Suspend and present PanelEditorView
                                let editedRects = await withCheckedContinuation { (continuation: CheckedContinuation<[CGRect], Never>) in
                                    Task { @MainActor in
                                        self.currentEditorImage = image
                                        self.currentEditorPanels = detected.map { $0.boundingBox }
                                        self.panelEditorContinuation = continuation
                                        self.isPresentingPanelEditor = true
                                    }
                                }
                                panelsToInject[index] = editedRects.map { PanelExtractor.Panel(boundingBox: $0) }
                            }
                        }
                    }
                    let progress = Double(index) / Double(files.count)
                    Task { @MainActor in self.conversionProgress = progress }
                }
            }
            
            // 3. Inject using Helper (ALWAYS REQUIRED FOR STRICT FIXED-LAYOUT)
            try? await injectMetadata(into: exportURL, panels: panelsToInject, metadata: pdf.metadata)
            
            return exportURL
            
        } catch {
            Logger.shared.log("❌ Cloud Export Failed: \(error)", category: "Export")
            return nil
        }
    }
    
    // MARK: - KFX Export
    func exportForKFX(_ pdf: ConvertedPDF) async -> URL? {
        isConverting = true
        processingStatus = "Building KFX Package..."
        statusMessage = "Extracting images and scripts..."
        
        defer {
            isConverting = false
            statusMessage = nil
            Task { @MainActor in self.processingStatus = "" }
        }
        
        do {
            let converter = CBZToEPUBConverter()
            let outputURL = try await converter.buildKFXPackage(
                sourceURL: pdf.url,
                settings: conversionSettings,
                metadata: pdf.metadata,
                progress: { progress in
                    Task { @MainActor in self.conversionProgress = progress }
                }
            )
            return outputURL
        } catch {
            Logger.shared.log("❌ KFX Export Failed: \\(error.localizedDescription)", category: "Export", type: .error)
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
        
        // ✅ NEW: Book Branch (Text EPUBs Pass-Through)
        if pdf.contentType == .book {
            do {
                try fileManager.copyItem(at: pdf.url, to: targetURL)
                Logger.shared.log("Book Export: Safe pass-through HQ for \(pdf.name)", category: "Export")
                return targetURL
            } catch {
                Logger.shared.log("❌ Book Export Failed: \(error.localizedDescription)", category: "Export", type: .error)
                return nil
            }
        }
        
        // ✅ NEW: PDF Branch
        if conversionSettings.outputFormat == .pdf {
            isConverting = true; processingStatus = "Generating PDF..."
            defer { isConverting = false; Task { @MainActor in self.processingStatus = "" } }
            
            do {
                let pdName = pdf.name.replacingOccurrences(of: ".cbz", with: ".pdf")
                let pdfURL = exportDir.appendingPathComponent(pdName)
                try? fileManager.removeItem(at: pdfURL) // Clean old
                
                // 1. Extract
                let imageURLs = try await extractImageURLs(from: pdf.url)
                
                // 2. Generate
                try PDFGenerator.generate(from: imageURLs, to: pdfURL, mangaMode: conversionSettings.mangaMode, chapters: pdf.chapters, settings: conversionSettings) { progress in
                    Task { @MainActor in self.processingStatus = "Processing \(Int(progress * 100))%" }
                }
                
                return pdfURL
            } catch {
                Logger.shared.log("❌ PDF Export Failed: \(error)", category: "Export")
                return nil
            }
        }
        
        do {
            // 1. Commit any pending edits
            saveLibrary()
            
            // 2. Call Engine (Standard EPUB Conversion)
            let finalEPUB = try await ConversionEngine.shared.process(url: pdf.url, settings: conversionSettings)
            // Engine extracts to temp, we need to move it to "KindleExports"
            let finalName = finalEPUB.lastPathComponent
            let destURL = exportDir.appendingPathComponent(finalName)
            if fileManager.fileExists(atPath: destURL.path) { try fileManager.removeItem(at: destURL) }
            try fileManager.moveItem(at: finalEPUB, to: destURL)
            
            return destURL
            
        } catch {
            Logger.shared.log("Export Failed: \(error)", category: "Export")
            return nil
        }
    }
    
    func embedPanels(for pdf: ConvertedPDF) async {
        await MetadataInjector.shared.embedPanels(for: pdf, manager: self)
    }
    
    func injectMetadata(into archiveURL: URL, panels: [Int: [PanelExtractor.Panel]], metadata: PDFMetadata) async throws {
        try await MetadataInjector.shared.injectMetadata(into: archiveURL, panels: panels, metadata: metadata, manager: self)
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

// MARK: - Pre-Flight Validation & Export

    enum ValidationResult {
        case success
        case warning(String)
        case failure(String)
    }
    
    func validateForExport(_ pdf: ConvertedPDF) -> ValidationResult {
        Logger.shared.log("Running Pre-Flight Check for: \(pdf.name)", category: "Validation")
        
        // 1. Check for Panels (if Guided View is active)
        if conversionSettings.isGuidedView {
            let panels = WorkspaceSessionManager.shared.panelOverrides[pdf.id] ?? [:]
            if panels.isEmpty {
                return .warning("Guided View is enabled, but no panels were detected. The EPUB will export with default full-page views.")
            }
            
            // 2. Deep Dive: Ordinal & Coordinate Checks
            for (pageIndex, pagePanels) in panels {
                // Check Density
                if pagePanels.count > 20 {
                    return .warning("Page \(pageIndex + 1) has \(pagePanels.count) panels. This may cause performance issues on older Kindle devices.")
                }
                
                // Check Bounds (Vision 0-1)
                for (pIndex, panel) in pagePanels.enumerated() {
                    let r = panel.boundingBox
                    if r.minX < -0.01 || r.maxX > 1.01 || r.minY < -0.01 || r.maxY > 1.01 {
                        // Allow 1% margin of error for float precision
                        return .failure("Page \(pageIndex + 1), Panel \(pIndex + 1) has invalid coordinates. Please re-scan this page.")
                    }
                    
                    if r.width < 0.05 || r.height < 0.05 {
                         return .warning("Page \(pageIndex + 1), Panel \(pIndex + 1) is extremely small (<5%). Check for artifacts.")
                    }
                }
            }
        }
        
        return .success
    }
    
    // MARK: - Export Orchestration
    func exportEPUB(pdf: ConvertedPDF) async {
        // 1. Validate
        let validation = validateForExport(pdf)
        switch validation {
        case .failure(let error):
            await MainActor.run {
                self.appAlert = AppAlert(title: "Pre-Flight Check Failed", message: error)
            }
            return
        case .warning(let message):
            // In a real app, we'd show a confirmation dialog here.
            // For now, we log it and proceed (or show alert).
            await MainActor.run {
                self.processingStatus = "Warning: \(message). Proceeding..."
            }
            try? await Task.sleep(nanoseconds: 2 * 1_000_000_000)
            
        case .success:
            break
        }
        
        // 2. Export
        do {
            // Commit any pending edits
            saveLibrary()
            
            // Call Engine
            let _ = try await ConversionEngine.shared.process(url: pdf.url, settings: conversionSettings)
            
            await MainActor.run {
                self.appAlert = AppAlert(title: "Export Success", message: "EPUB generated successfully.")
            }
            
        } catch {
            await MainActor.run {
                self.appAlert = AppAlert(title: "Export Failed", message: error.localizedDescription)
            }
        }
    }
    
    // MARK: - Collection Management
    
    func setExplicitSeriesCover(for pdf: ConvertedPDF) {
        Task { @MainActor in
            if let seriesName = pdf.metadata.series, !seriesName.isEmpty {
                if let index = self.collections.firstIndex(where: { $0.name == seriesName }) {
                    self.collections[index].explicitCoverFileID = pdf.id
                    self.saveLibrary()
                    // Force the pipeline to rebuild SeriesGroup lists
                    self.convertedPDFs = self.convertedPDFs
                }
            } else if let collectionId = pdf.collectionId {
                if let index = self.collections.firstIndex(where: { $0.id == collectionId }) {
                    self.collections[index].explicitCoverFileID = pdf.id
                    self.saveLibrary()
                }
            }
        }
    }
}
