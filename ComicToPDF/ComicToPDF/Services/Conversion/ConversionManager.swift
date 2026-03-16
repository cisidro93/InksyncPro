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
    @Published var activeTasks: [AppBackgroundTask] = []
    @Published var conversionSettings = ConversionSettings()
    
    // ✅ NEW: Persistent Watched Folders
    struct WatchedFolder: Codable, Identifiable, Equatable {
        var id: UUID = UUID()
        var name: String
        var bookmarkData: Data
    }
    @Published var watchedFolders: [WatchedFolder] = []
    
    // MARK: - Series Grouping Prompt (Layer 3)
    struct PendingSeriesGroup: Identifiable {
        let id = UUID()
        let pdfs: [ConvertedPDF]
        let suggestedName: String
    }
    @Published var pendingSeriesGroup: PendingSeriesGroup? = nil
    
    // MARK: - Internal State
    private let libraryFileName = "library.json"
    internal var thumbnailCache = NSCache<NSString, UIImage>()
    
    // MARK: - Editor Session Cache
    // Prevents "Death Spiral" by keeping the comic unzipped while editing
    private var editorCache: (pdfID: UUID, folder: URL, files: [URL])?
    private var activeExtractionTask: Task<(workingDir: URL, files: [URL]), Error>?
    
    // Guided View Data
    @Published var panelOverrides: [UUID: [Int: [PanelExtractor.Panel]]] = [:]
    
    // ✅ NEW: Precision Canvas Models (Normalized Coordinates)
    @Published var pageModels: [UUID: [Int: PageModel]] = [:]  
    
    // ✅ Helper to get or create PageModel
    func getPageModel(for pdfID: UUID, pageIndex: Int) -> PageModel {
        if let model = pageModels[pdfID]?[pageIndex] {
            return model
        }
        
        var newModel = PageModel(pageIndex: pageIndex)
        
        // Check legacy overrides and migrate if needed
        if let legacyPanels = panelOverrides[pdfID]?[pageIndex] {
             var allNormalized = true
             newModel.panels = legacyPanels.map { panel in
                let rect = panel.boundingBox
                // Heuristic: If values are small (strictly <= 1.1), normalize them (Vision 0-1).
                // If larger, assume they are already normalized (0-1000) or pixels.
                if rect.maxX <= 1.1 && rect.maxY <= 1.1 {
                     return NormalizedRect(x: rect.minX * 1000, y: rect.minY * 1000, width: rect.width * 1000, height: rect.height * 1000)
                } else {
                     // Large Values -> Could be 0-1000 (good) or Pixels (bad)
                     allNormalized = false
                     return NormalizedRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
                }
            }
            
            // If we migrated legacy panels, ONLY check if ALL were 0-1 (Vision)
            if !newModel.panels.isEmpty && allNormalized {
                 newModel.coordinateSystem = .normalized
            } else {
                 newModel.coordinateSystem = .unknown // Force validation in Editor
            }
        }
        return newModel
    }
    
    func savePageModel(_ model: PageModel, for pdfID: UUID) {
        if pageModels[pdfID] == nil { pageModels[pdfID] = [:] }
        // Ensure we save the coordinate system state
        var modelToSave = model
        if modelToSave.coordinateSystem == .unknown {
            // If saving an unknown model that has panels, assume it is now normalized? 
            // No, only if we actually validated it. 
            // But if it came from the editor, it's likely been validated or edited.
            // Let's safe-guard: if it has panels and we are saving, it's likely been touched.
            if !modelToSave.panels.isEmpty {
                modelToSave.coordinateSystem = .normalized
            }
        }
        pageModels[pdfID]?[model.pageIndex] = modelToSave
        
        // Sync back to legacy panelOverrides for Export/Injection compatibility
        // Convert NormalizedRect (0-1000 Top-Left) -> Vision Rect (0-1 Bottom-Left)
        let legacyPanels = model.panels.map { rect -> PanelExtractor.Panel in
            let x = rect.origin.x / 1000.0
            let y = rect.origin.y / 1000.0
            let w = rect.width / 1000.0
            let h = rect.height / 1000.0
            
            // Flip Y back to Vision (Bottom-Left)
            // y_vision = 1.0 - y_top_left - height
            let yVision = 1.0 - y - h
            
            let visionRect = CGRect(x: x, y: yVision, width: w, height: h)
            return PanelExtractor.Panel(boundingBox: visionRect)
        }
        
        if panelOverrides[pdfID] == nil {
            panelOverrides[pdfID] = [:]
        }
        panelOverrides[pdfID]?[model.pageIndex] = legacyPanels
        
        // Auto-save library changes
        saveLibrary()
    }
    
    // UI State
    @Published var isConverting = false
    @Published var conversionProgress: Double = 0.0
    @Published var processingStatus = ""
    @Published var statusMessage: String?
    @Published var appAlert: AppAlert?
    
    // ✅ Session Vault State
    @Published var isVaultUnlocked: Bool = false
    
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
        
        // Subscribe to Engine
        progressSubscription = ConversionEngine.shared.progressSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.handleEngineEvent(event)
            }
        
        // ✅ Subscribe to Go-mode queue completion so files are correctly tagged
        NotificationCenter.default.addObserver(forName: NSNotification.Name("LibraryNeedsRescan"), object: nil, queue: .main) { [weak self] notification in
            let modeRaw = notification.userInfo?["mode"] as? String
            let mode: AppUIMode = (modeRaw == AppUIMode.go.rawValue) ? .go : .pro
            Task { @MainActor [weak self] in
                self?.scanLibrary(addedByMode: mode)
            }
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
            var watchedFolders: [WatchedFolder]? = nil // ✅ NEW: Watched Folders
            var presets: [ConversionPreset]? = nil // ✅ NEW: Presets
        }
        let index = LibraryIndex(files: convertedPDFs, collections: collections, settings: conversionSettings, history: sendHistory, devices: kindleDevices, panelOverrides: panelOverrides, watchedFolders: watchedFolders, presets: conversionPresets)
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
            var watchedFolders: [WatchedFolder]? = nil // ✅ NEW
            var presets: [ConversionPreset]? = nil // ✅ NEW
        }
        guard let url = fileURL(for: libraryFileName), let data = try? Data(contentsOf: url), let index = try? JSONDecoder().decode(LibraryIndex.self, from: data) else { return }
        self.convertedPDFs = index.files
        self.collections = index.collections
        self.conversionSettings = index.settings
        self.sendHistory = index.history
        self.kindleDevices = index.devices
        self.panelOverrides = index.panelOverrides ?? [:] // ✅ Restore overrides
        self.watchedFolders = index.watchedFolders ?? [] // ✅ Restore Watched Folders
        self.conversionPresets = index.presets ?? [] // ✅ Restore Presets
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

    }
    
    // MARK: - Cover Image Management (Memory Optimization)
    
    func getCoverURL(for pdf: ConvertedPDF) -> URL? {
        let fileManager = FileManager.default
        guard let appSupportDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let coversDir = appSupportDir.appendingPathComponent("Covers", isDirectory: true)
        
        if !fileManager.fileExists(atPath: coversDir.path) {
            try? fileManager.createDirectory(at: coversDir, withIntermediateDirectories: true)
        }
        
        return coversDir.appendingPathComponent("cover_\(pdf.id.uuidString).jpg")
    }
    
    /// Migrates legacy Data-based covers to disk-based storage
    func migrateCoversToDisk() {
        var updated = false
        
        for i in 0..<convertedPDFs.count {
            if let data = convertedPDFs[i].coverImageData {
                if let coverURL = getCoverURL(for: convertedPDFs[i]) {
                    // Write to disk in App Support
                    try? data.write(to: coverURL)
                }
                
                // Clear from memory
                convertedPDFs[i].coverImageData = nil
                updated = true
            }
        }
        
        if updated {
            saveLibrary()
        }
    }
    
    /// Thread-safe, memory-efficient cover loader
    func loadCoverThumbnail(for pdf: ConvertedPDF) async -> UIImage? {
        let key = pdf.id.uuidString as NSString
        
        // 1. Check Cache
        if let cached = thumbnailCache.object(forKey: key) {
            return cached
        }
        
        // 2. Load from Disk (Background Thread)
        return await Task.detached(priority: .userInitiated) {
            // Path: cover_{UUID}.jpg
            if let url = await self.getCoverURL(for: pdf),
               FileManager.default.fileExists(atPath: url.path) {
                
                if let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
                    let thumbnail = image.preparingThumbnail(of: CGSize(width: 240, height: 360)) ?? image
                    await MainActor.run {
                        self.thumbnailCache.setObject(thumbnail, forKey: key)
                    }
                    return thumbnail
                }
            }
            
            // 3. Fallback: Check legacy data (Migration in progress?)
            if let data = pdf.coverImageData, let image = UIImage(data: data) {
                 return image
            }
            
            return nil
        }.value
    }
    
    /// Save cover image to disk and update cache
    func saveCoverImage(_ data: Data, for pdf: ConvertedPDF) {
        guard let coverURL = getCoverURL(for: pdf) else { return }
        try? data.write(to: coverURL)
        
        // Update Cache
        if let image = UIImage(data: data) {
            let thumbnail = image.preparingThumbnail(of: CGSize(width: 240, height: 360)) ?? image
            let key = pdf.id.uuidString as NSString
            thumbnailCache.setObject(thumbnail, forKey: key)
        }
        
        // Ensure memory property is nil (if we are updating an existing object that might have it)
        if let index = convertedPDFs.firstIndex(where: { $0.id == pdf.id }) {
            convertedPDFs[index].coverImageData = nil
        }
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
            
            // ✅ Pro Feature: Write back to ComicInfo.xml
            if pdf.url.pathExtension.lowercased() == "cbz" || pdf.url.pathExtension.lowercased() == "zip" {
                Task {
                    do {
                        try await ComicInfoWriter.write(metadata: newMetadata, to: pdf.url)
                        Logger.shared.log("Wrote metadata changes back to archive: \(pdf.name)", category: "Metadata")
                    } catch {
                        Logger.shared.log("Failed to write to archive: \(error.localizedDescription)", category: "Metadata", type: .error)
                    }
                }
            }
        }
    }
    
    // ✅ NEW: Centralized manifest logic to fix panel loss
    func getCombinedManifest(for pdf: ConvertedPDF) async -> [Int: [PanelExtractor.Panel]] {
        var combined = panelOverrides[pdf.id] ?? [:]
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
        let fileManager = FileManager.default
        let docDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        

            // Recursive Scan
            // We use enumerator to find files deep in folders
            var newPDFs: [ConvertedPDF] = []
            let keys: [URLResourceKey] = [.nameKey, .isDirectoryKey, .fileSizeKey]
            
            if let enumerator = fileManager.enumerator(at: docDir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) {
                 for case let fileURL as URL in enumerator {
                     let ext = fileURL.pathExtension.lowercased()
                    if ["pdf", "cbz", "zip", "epub"].contains(ext) {
                         // Check if already exists (Standardized Path Check)
                         if !convertedPDFs.contains(where: { $0.url.standardizedFileURL.path == fileURL.standardizedFileURL.path }) {
                             let fileSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                             // ✅ Tag new files with the mode that triggered this scan
                             let sourceMode = addedByMode ?? .pro
                             var newPDF = ConvertedPDF(name: fileURL.lastPathComponent, url: fileURL, pageCount: 0, fileSize: fileSize, metadata: PDFMetadata(title: fileURL.lastPathComponent))
                             newPDF.addedByMode = sourceMode
                             newPDFs.append(newPDF)
                         }
                     }
                 }
            }
            
            // Add new ones
            if !newPDFs.isEmpty {
                convertedPDFs.append(contentsOf: newPDFs)
                Logger.shared.log("Library Scanned: Found \(newPDFs.count) new files (mode: \(addedByMode?.rawValue ?? "Pro"))", category: "Library")
                saveLibrary()
            }
            
            // ✅ FIX: Process any file missing page count or metadata (catches Folder Sync & Series Import)
            let pdfsToProcess = convertedPDFs.filter { $0.pageCount == 0 }
            
            if !pdfsToProcess.isEmpty {
                // Process Metadata & Thumbnails in Background
                for pdf in pdfsToProcess {
                    Task {
                        // 1. Thumbnails
                        await self.generateCoverThumbnail(for: pdf)
                        
                        // 2. Page Count
                        let count = await Task.detached(priority: .background) {
                            return ConversionManager.getPageCountStatic(from: pdf.url)
                        }.value
                        
                        if count > 0 {
                            await MainActor.run {
                                if let idx = self.convertedPDFs.firstIndex(where: { $0.id == pdf.id }) {
                                    var updated = self.convertedPDFs[idx]
                                    updated.pageCount = count
                                    self.convertedPDFs[idx] = updated
                                }
                            }
                        }
                        
                        // 3. Extract Embedded Panels (if any)
                        if let validPanels = try? await self.extractSmartPanels(from: pdf.url) {
                            await MainActor.run {
                                self.savePanelOverrides(for: pdf.id, panels: validPanels)
                            }
                        }
                    }
                }
            }
            
            // Cleanup: Remove missing files
            let missingCount = convertedPDFs.filter { !fileManager.fileExists(atPath: $0.url.path) }.count
            if missingCount > 0 {
                convertedPDFs.removeAll { !fileManager.fileExists(atPath: $0.url.path) }
                Logger.shared.log("Removed \(missingCount) missing files from library", category: "Library")
            }
            

    }
    
    func deletePDF(_ pdf: ConvertedPDF) {
        do {
            try FileManager.default.removeItem(at: pdf.url)
            if let coverURL = getCoverURL(for: pdf) {
                try? FileManager.default.removeItem(at: coverURL)
            }
            Logger.shared.log("Deleted File and Cover: \(pdf.name)", category: "Library")
        } catch {
            Logger.shared.log("Failed to delete file: \(error)", category: "Library", type: .error)
        }
        
        if let idx = convertedPDFs.firstIndex(where: { $0.id == pdf.id }) {
            convertedPDFs.remove(at: idx)
            saveLibrary()
        }
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
                
                if convertedPDFs[idx].contentType != .book {
                     panelOverrides[pdf.id] = nil
                }
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
        for url in urls {
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
                if FileManager.default.fileExists(atPath: destURL.path) { 
                    try FileManager.default.removeItem(at: destURL) 
                    // ✅ FIX: Remove old reference so scanLibrary treats the replaced file as brand new
                    // This forces fresh panel extraction from the newly copied CBZ
                    await MainActor.run {
                        self.convertedPDFs.removeAll(where: { $0.url.lastPathComponent == fileName })
                    }
                }
                try FileManager.default.copyItem(at: url, to: destURL)
            } catch { 
                Logger.shared.log("Failed to copy imported file \(url.lastPathComponent): \(error.localizedDescription)", category: "Import", type: .error)
            }
        }
        scanLibrary()
    }
    
    // MARK: - iOS Watched Folder Persistent Sync
    
    func importFolderStructure(from folderURL: URL) async {

        // Perform deep import and bookmark creation asynchronously
        await MainActor.run { self.isConverting = true; self.processingStatus = "Preparing Folder Sync..." }
        defer { Task { await MainActor.run { self.isConverting = false; self.processingStatus = "" } } }
        
        let existingNames = await MainActor.run { Set(self.convertedPDFs.map { $0.name }) }

        let newPDFs: [ConvertedPDF] = await Task.detached(priority: .userInitiated) {
            // Lock security scope INSIDE the background thread to prevent MainActor delegate deadlock
            let accessing = folderURL.startAccessingSecurityScopedResource()
            defer { if accessing { folderURL.stopAccessingSecurityScopedResource() } }
            
            // 1. Opportunistically attempt to save bookmark for persistent sync while securely accessing
            do {
                let bookmarkData = try folderURL.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
                await MainActor.run {
                    if !self.watchedFolders.contains(where: { $0.bookmarkData == bookmarkData }) {
                        let watched = WatchedFolder(name: folderURL.lastPathComponent, bookmarkData: bookmarkData)
                        self.watchedFolders.append(watched)
                        self.saveLibrary()
                    }
                }
            } catch {
                Logger.shared.log("Note: Could not create persistent bookmark for folder: \(error.localizedDescription). Reverting to one-time copy.", category: "Import")
            }
            
            // 2. Scan and enumerate
            let fileManager = FileManager.default
            let documentsDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            var newlyImported: [ConvertedPDF] = []
            
            await MainActor.run { self.processingStatus = "Scanning \(folderURL.lastPathComponent)..." }
            
            let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
            guard let enumerator = fileManager.enumerator(at: folderURL, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
                return []
            }
            
            var fileCount = 0
            
            while let fileURL = enumerator.nextObject() as? URL {
                fileCount += 1
                if fileCount % 10 == 0 {
                    let currentCount = fileCount
                    await MainActor.run { self.processingStatus = "Scanning \(folderURL.lastPathComponent) (\(currentCount) items)..." }
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
                    await MainActor.run { self.processingStatus = "Importing \(fileName)..." }
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
            
            return newlyImported
        }.value
        
        await MainActor.run {
            for pdf in newPDFs {
                self.convertedPDFs.removeAll(where: { $0.url.lastPathComponent == pdf.url.lastPathComponent })
                self.convertedPDFs.append(pdf)
            }
            self.saveLibrary()
            self.scanLibrary()
        }
    }
    
    /// Imports an array of file URLs securely into the documents directory, tracking progress in the background.
    func importFilesAsSeries(urls: [URL]) async {
        await MainActor.run { self.isConverting = true; self.processingStatus = "Preparing Import..." }
        defer { Task { await MainActor.run { self.isConverting = false; self.processingStatus = "" } } }
        
        let existingNames = await MainActor.run { Set(self.convertedPDFs.map { $0.name }) }
        let isVaultUnlocked = await MainActor.run { !SecurityManager.shared.isVaultLocked }

        await ImportMonitorManager.shared.startImport(totalCount: urls.count)
        
        let importedPDFs: [ConvertedPDF] = await Task.detached(priority: .userInitiated) {
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
                    
                    var pdf = ConvertedPDF(
                        name: fileName,
                        url: destURL,
                        pageCount: 0,
                        fileSize: size,
                        metadata: PDFMetadata(title: fileName),
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
        
        // Mark Tracker Complete
        await ImportMonitorManager.shared.completeImport()
        guard !importedPDFs.isEmpty else { return }
        
        // --- Smart Auto-Grouping (String Similarity / Longest Common Prefix) ---
        var dominantSeries = ""
        var allSameSeries = false
        
        if importedPDFs.count > 1 {
            // Extract cleaned, alphanumeric prefixes from filenames, ignoring brackets and standard junk
            let cleanNames: [String] = importedPDFs.compactMap { pdf in
                let name = pdf.name as NSString
                // Matches groups like "[Group]" or "(Digital)" and removes them
                let regex = try? NSRegularExpression(pattern: "\\[.*?\\]|\\(.*?\\)", options: [])
                let noBrackets = regex?.stringByReplacingMatches(in: name as String, options: [], range: NSRange(location: 0, length: name.length), withTemplate: "") ?? pdf.name
                
                // Strip trailing numbers, volume markers, and extensions
                let withoutExt = (noBrackets as NSString).deletingPathExtension
                if let range = withoutExt.range(of: "\\s*(v|vol|volume|c|ch|chapter|issue)?\\s*\\d+.*$", options: [.regularExpression, .caseInsensitive]) {
                    return String(withoutExt[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "-_.")))
                }
                return withoutExt.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "-_.")))
            }.filter { !$0.isEmpty }
            
            if !cleanNames.isEmpty {
                // Find the Longest Common Prefix (LCP) across the cleaned names
                dominantSeries = cleanNames[0]
                for name in cleanNames.dropFirst() {
                    while !name.hasPrefix(dominantSeries) && !dominantSeries.isEmpty {
                        dominantSeries = String(dominantSeries.dropLast())
                    }
                }
                
                dominantSeries = dominantSeries.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "-_.")))
                
                // If a meaningful common prefix exists (e.g. "Bleach") that is at least 3 chars long, auto-group them.
                if dominantSeries.count >= 3 {
                    allSameSeries = true
                } else {
                    dominantSeries = "" // Fallback to manual prompt if LCP fails
                }
            }
        } else if let single = importedPDFs.first {
             dominantSeries = single.name.components(separatedBy: CharacterSet.decimalDigits).first?.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "-_."))) ?? ""
        }
        
        // Back to Main Actor for State Updates and Covers
        await MainActor.run {
            if allSameSeries && importedPDFs.count > 1 {
                // Unambiguous — all files agree on series. Add directly, skip Layer 3 prompt.
                Task { await self.finalizeSeriesImport(pdfs: importedPDFs, seriesName: dominantSeries) }
                Logger.shared.log("Auto-grouped \(importedPDFs.count) files into series '\(dominantSeries)'", category: "Import")
            } else if importedPDFs.count > 1 {
                // --- Layer 3: Post-import grouping prompt ---
                // Files disagree on series name or have none. Show the grouping sheet.
                for pdf in importedPDFs {
                    self.convertedPDFs.removeAll(where: { $0.url.lastPathComponent == pdf.url.lastPathComponent })
                    self.convertedPDFs.append(pdf)
                }
                self.saveLibrary()
                self.scanLibrary()
                Task {
                    for pdf in importedPDFs { await self.generateCoverThumbnail(for: pdf) }
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    await MainActor.run { self.pendingSeriesGroup = PendingSeriesGroup(pdfs: importedPDFs, suggestedName: dominantSeries) }
                }
            } else {
                // Single file — just add it normally
                Task { await self.finalizeSeriesImport(pdfs: importedPDFs, seriesName: dominantSeries) }
                for pdf in importedPDFs { Task { await self.generateCoverThumbnail(for: pdf) } }
            }
        }
    }
    
    /// Apply a confirmed series name to a batch of PDFs and save to the library.
    func finalizeSeriesImport(pdfs: [ConvertedPDF], seriesName: String) async {
        await MainActor.run {
            let targetCollection: PDFCollection
            if let existing = self.collections.first(where: { $0.name == seriesName }), !seriesName.isEmpty {
                targetCollection = existing
            } else if !seriesName.isEmpty {
                let newCol = PDFCollection(id: UUID(), name: seriesName, icon: "books.vertical", color: "orange", creationDate: Date())
                self.collections.append(newCol)
                targetCollection = newCol
            } else {
                // No series — just add all files without grouping
                for pdf in pdfs {
                    self.convertedPDFs.removeAll(where: { $0.url.lastPathComponent == pdf.url.lastPathComponent })
                    self.convertedPDFs.append(pdf)
                }
                self.saveLibrary()
                return
            }
            
            for var pdf in pdfs {
                pdf.collectionId = targetCollection.id
                pdf.metadata.series = seriesName
                self.convertedPDFs.removeAll(where: { $0.url.lastPathComponent == pdf.url.lastPathComponent })
                self.convertedPDFs.append(pdf)
            }
            self.saveLibrary()
            self.scanLibrary()
        }
        for pdf in pdfs { Task { await self.generateCoverThumbnail(for: pdf) } }
    }
    
    /// Assign an existing library item to an existing or new series collection.
    func assignToSeries(_ pdf: ConvertedPDF, seriesName: String) {
        let targetCollection: PDFCollection
        if let existing = self.collections.first(where: { $0.name == seriesName }) {
            targetCollection = existing
        } else {
            let newCol = PDFCollection(id: UUID(), name: seriesName, icon: "books.vertical", color: "orange", creationDate: Date())
            self.collections.append(newCol)
            targetCollection = newCol
        }
        
        if let index = self.convertedPDFs.firstIndex(where: { $0.id == pdf.id }) {
            self.convertedPDFs[index].collectionId = targetCollection.id
            self.convertedPDFs[index].metadata.series = seriesName
        }
        self.saveLibrary()
        Logger.shared.log("Layer 4: Manually assigned '\(pdf.name)' to series '\(seriesName)'", category: "Import")
    }
    
    func syncWatchedFolders() async {
        let localFolders = await MainActor.run { self.watchedFolders }
        guard !localFolders.isEmpty else { return }
        
        await MainActor.run { self.isConverting = true; self.processingStatus = "Background Folder Sync..." }
        defer { Task { await MainActor.run { self.isConverting = false; self.processingStatus = "" } } }
        
        let existingNames = await MainActor.run { Set(self.convertedPDFs.map { $0.name }) }
        
        let newPDFs: [ConvertedPDF] = await Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            let documentsDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            var newlyImported: [ConvertedPDF] = []
            var staleBookmarkIndices: [Int] = []
            
            for (index, folder) in localFolders.enumerated() {
                var isStale = false
                do {
                    await MainActor.run { self.processingStatus = "Resolving \(folder.name)..." }
                    let resolvedURL = try URL(resolvingBookmarkData: folder.bookmarkData, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &isStale)
                    
                    if isStale {
                        staleBookmarkIndices.append(index)
                        continue
                    }
                    
                    let accessing = resolvedURL.startAccessingSecurityScopedResource()
                    defer { if accessing { resolvedURL.stopAccessingSecurityScopedResource() } }
                    
                    let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
                    guard let enumerator = fileManager.enumerator(at: resolvedURL, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
                        continue
                    }
                    
                    var fileCount = 0
                    
                    while let fileURL = enumerator.nextObject() as? URL {
                        fileCount += 1
                        if fileCount % 10 == 0 {
                            let currentCount = fileCount
                            await MainActor.run { self.processingStatus = "Scanning \(folder.name) (\(currentCount) items)..." }
                            await Task.yield()
                        }
                        
                        guard let resourceValues = try? fileURL.resourceValues(forKeys: Set(keys)),
                              let isDirectory = resourceValues.isDirectory, !isDirectory else { continue }
                        
                        let ext = fileURL.pathExtension.lowercased()
                        guard ["cbz", "zip", "epub"].contains(ext) else { continue }
                        
                        let fileName = fileURL.lastPathComponent
                        let destURL = documentsDir.appendingPathComponent(fileName)
                        
                        if existingNames.contains(fileName) || newlyImported.contains(where: { $0.name == fileName }) {
                            continue
                        }
                        
                        do {
                            await MainActor.run { self.processingStatus = "Syncing \(fileName)..." }
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
                let indicesToRemove = staleBookmarkIndices
                await MainActor.run {
                    for i in indicesToRemove.sorted(by: >) { self.watchedFolders.remove(at: i) }
                    self.saveLibrary()
                }
            }
            
            return newlyImported
        }.value
        
        await completeFolderImport(newPDFs)
    }

    private func completeFolderImport(_ newPDFs: [ConvertedPDF]) async {
        if newPDFs.isEmpty { return }
        
        await MainActor.run {
            for var newPdf in newPDFs {
                // Map series metadata to actual UI Collections for smart grouping
                if let seriesName = newPdf.metadata.series, !seriesName.isEmpty {
                    if let existingCol = self.collections.first(where: { $0.name == seriesName }) {
                        newPdf.collectionId = existingCol.id
                    } else {
                        let newCol = PDFCollection(id: UUID(), name: seriesName, icon: "folder", color: "blue", creationDate: Date())
                        self.collections.append(newCol)
                        newPdf.collectionId = newCol.id
                    }
                }
                
                self.convertedPDFs.removeAll(where: { $0.url.lastPathComponent == newPdf.url.lastPathComponent })
                self.convertedPDFs.append(newPdf)
            }
            self.saveLibrary()
            self.scanLibrary()
        }
        
        for pdf in newPDFs {
            Task { await self.generateCoverThumbnail(for: pdf) }
        }
    }
    
    // MARK: - \u2705 PDF Import Support
    
    /// Detect content type from file extension and content analysis
    func detectContentType(from url: URL) -> ContentType {
        let ext = url.pathExtension.lowercased()
        let filename = url.deletingPathExtension().lastPathComponent.lowercased()
        
        // 1. Strong Keyword Check for Manga
        let mangaKeywords = ["manga", "tankobon", "volume", "chapter", "inuyasha", "shonen", "shoujo", "seinen", "josei"]
        if mangaKeywords.contains(where: { filename.contains($0) }) {
             return .manga
        }
        
        switch ext {
        case "cbz", "zip":
            // Check if manga mode is enabled globally
            return conversionSettings.mangaMode ? .manga : .comic
            
        case "pdf":
            // Analyze PDF to determine if it's a book or comic
            let importer = PDFImporter()
            let hasText = importer.hasTextContent(url: url)
            return hasText ? .book : .hybrid
            
        case "epub":
            // Smart Sniffing: Check if it is a pre-paginated comic or a text book
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
                                return .hybrid // It's an image-based comic EPUB
                            }
                        }
                    }
                }
            } catch {
                Logger.shared.log("EPUB Content Type Sniffing failed for \(filename): \(error.localizedDescription)", category: "Import", type: .warning)
                return .book
            }
            return .book
            
        default:
            return .hybrid
        }
    }
    
    /// Import PDF by extracting pages as images and creating CBZ
    func importPDF(url: URL) async {
        let fileName = url.deletingPathExtension().lastPathComponent
        await MainActor.run { processingStatus = "Importing \(fileName)..." }
        
        do {
            // \u2705 CRITICAL FIX: Copy PDF to temp to avoid Security Scope loss during long import
            let tempPDFURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
            try FileManager.default.copyItem(at: url, to: tempPDFURL)
            defer { try? FileManager.default.removeItem(at: tempPDFURL) }
            
            let importer = PDFImporter()
            // \u2705 Capture settings MainActor-side to pass to background task
            let settings = conversionSettings
            // \u2705 Capture self (weakly or just rely on class instance if we need)
            // Ideally we need to access MainActor properties via await MainActor.run or capture them before.
            // We pass 'settings' into the closure context clearly.
            let conversionManager = self 
            
            // 3. Offload Heavy Lifting to Background Thread (Detached Task)
            let (extractedCount, newCoverData) = try await Task.detached(priority: .userInitiated) { () -> (Int, Data?) in
                let pageCount = importer.getPageCount(url: tempPDFURL)
                guard pageCount > 0 else { throw PDFImporter.ImportError.emptyPDF }
                
                // Create temp directory for images
                let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: tempDir) }
                
                // Enterprise Parallel Processing (Bounded Concurrency)
                // iPhone 14 Pro Max has 6 cores. We refrain from maxing out to avoid thermal throttling/OOM.
                let maxConcurrent = 4 
                
                return try await withThrowingTaskGroup(of: (Int, Data?).self) { group in
                    var processedCount = 0
                    var firstPageData: Data? = nil
                    
                    for index in 0..<pageCount {
                        // Rate Limiter
                        if index >= maxConcurrent {
                           if let result = try await group.next() {
                               if result.0 == 0 { firstPageData = result.1 }
                               processedCount += 1
                               
                               // Update Progress on Main Actor
                               let currentCount = processedCount
                               let progress = Double(currentCount) / Double(pageCount)
                               await MainActor.run {
                                   conversionManager.processingStatus = "Importing Page \(currentCount) of \(pageCount)"
                                   conversionManager.conversionProgress = progress
                               }
                           }
                        }
                        
                        group.addTask {
                             // Autoreleasepool essential for image ops
                             try autoreleasepool {
                                let image = try importer.extractPage(url: tempPDFURL, pageIndex: index, dpi: 300)
                                let imageName = String(format: "page_%04d.jpg", index + 1)
                                let imageURL = tempDir.appendingPathComponent(imageName)
                                
                                if let data = image.jpegData(compressionQuality: settings.compressionQuality.value) {
                                    try data.write(to: imageURL)
                                    // Return cover data if first page
                                    return (index, index == 0 ? data : nil)
                                }
                                return (index, nil)
                             }
                        }
                    }
                    
                    // Harvest remaining tasks
                    for try await result in group {
                        if result.0 == 0 { firstPageData = result.1 }
                        processedCount += 1
                        let currentCount = processedCount
                        let progress = Double(currentCount) / Double(pageCount)
                        await MainActor.run {
                            conversionManager.processingStatus = "Importing Page \(currentCount) of \(pageCount)"
                            conversionManager.conversionProgress = progress
                        }
                    }
                    
                    // Zip temp directory into CBZ (Back on background thread)
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
            
            // Detect content type
            let contentType = detectContentType(from: url)
            
            // Get file size
            let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let cbzName = fileName + ".cbz"
            let cbzURL = docDir.appendingPathComponent(cbzName)
            let attributes = try FileManager.default.attributesOfItem(atPath: cbzURL.path)
            let fileSize = attributes[.size] as? Int64 ?? 0
            
            // Create ConvertedPDF entry
            let newPDF = ConvertedPDF(
                id: UUID(),
                name: fileName,
                url: cbzURL,
                pageCount: extractedCount,
                fileSize: fileSize,
                metadata: PDFMetadata(title: fileName),
                contentType: contentType
            )
            
            // Save Cover using Helper
            if let coverData = newCoverData {
                saveCoverImage(coverData, for: newPDF)
            }
            
            await MainActor.run {
                convertedPDFs.append(newPDF)
                saveLibrary()
                processingStatus = ""
                Logger.shared.log("Imported PDF: \(fileName) (\(extractedCount) pages) as \(contentType.rawValue)", category: "Import")
            }
            
        } catch {
            await MainActor.run {
                processingStatus = "PDF import failed: \(error.localizedDescription)"
                Logger.shared.log("PDF import error: \(error)", category: "Import")
                self.appAlert = AppAlert(title: "Import Failed", message: "Could not import PDF: \(error.localizedDescription)")
            }
            // Clear error after 3 seconds
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await MainActor.run { processingStatus = "" }
        }
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
        
        // 1. Check if we already have this session active (Smart Cache)
        if let cache = editorCache, cache.pdfID == pdf.id {
            // Already unzipped! Instant load.
            guard index < cache.files.count else { return nil }
            return ConversionManager.loadDownsampledImageStatic(at: cache.files[index], maxDimension: 1920)
        }
        
        // 2. If it's a NEW session (ID mismatch), we must clean up the old one first
        if let oldCache = editorCache, oldCache.pdfID != pdf.id {

            endSession() // Clean up old files immediately
        }
        
        // 3. Concurrency Lock: If extraction is already running for THIS file, wait for it
        if let existingTask = activeExtractionTask {
            // Wait for existing task
             let result = try await existingTask.value
             // Double check ID match after await
             if result.workingDir.lastPathComponent.contains(pdf.id.uuidString) || true { // Simplified check
                 self.editorCache = (pdf.id, result.workingDir, result.files)
                 guard index < result.files.count else { return nil }
                 return ConversionManager.loadDownsampledImageStatic(at: result.files[index], maxDimension: 1920)
             }
        }
        
        // 4. Start New Extraction Task

        let newTask = Task.detached(priority: .userInitiated) {
            let result = try await ZipUtilities.extractComic(from: pdf.url)
            return (workingDir: result.workingDir, files: result.imageURLs)
        }
        
        self.activeExtractionTask = newTask
        
        let result = try await newTask.value
        
        // 5. Update Cache
        self.editorCache = (pdf.id, result.workingDir, result.files)
        self.activeExtractionTask = nil
        
        guard index < result.files.count else { return nil }
        return ConversionManager.loadDownsampledImageStatic(at: result.files[index], maxDimension: 1920)
    }
    
    func endSession() {

        
        // 1. Cancel the background unzipping IMMEDIATELY
        activeExtractionTask?.cancel()
        activeExtractionTask = nil
        
        // 2. Clear UI
        // We use MainActor.run just in case, though this class is @MainActor already.
        Task { @MainActor in
            self.editorCache = nil
            // Don't reset isConverting/progress here as that might be for other tasks? 
            // Actually, Editor Session is distinct from Conversion. 
            // Let's keep status clean.
            if self.processingStatus.contains("Importing") == false {
                 self.statusMessage = "Ready"
            }
        }
        
        // 3. Clean up disk (Add a slight delay to ensure the Task actually stopped writing)
        let cacheToDelete = self.editorCache
        
        // We delay the file deletion slightly to let the Task catch the cancellation error
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 1.0) {
            if let cache = cacheToDelete {
                 try? FileManager.default.removeItem(at: cache.folder)

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
        isConverting = true; conversionProgress = 0.0; processingStatus = "Converting..."; statusMessage = "Starting..."
        let isMangaMode = mangaMode ?? pdf.metadata.isManga ?? conversionSettings.mangaMode
        var jobSettings = conversionSettings
        jobSettings.mangaMode = isMangaMode
        
        // Smart Content Type Handling: books are always Standard pipeline
        if pdf.contentType == .book {
            jobSettings.mangaMode = false
            jobSettings.enablePanelSplit = false
            jobSettings.outputPipeline = .standard
            jobSettings.splitWebtoon = false
        }
        
        // Webtoon Handling
        if let isWebtoon = pdf.metadata.isWebtoon, isWebtoon {
            jobSettings.splitWebtoon = true
            jobSettings.enablePanelSplit = false
            jobSettings.outputPipeline = .standard
        }
        
        do {
            if jobSettings.outputFormat == .pdf {
                // PDF export (always Standard, no panel metadata)
                let fileManager = FileManager.default
                let pName = pdf.name.replacingOccurrences(of: ".cbz", with: "").replacingOccurrences(of: ".zip", with: "") + "_Converted.pdf"
                let outputURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(pName)
                let imageURLs = try await extractImageURLs(from: pdf.url)
                try PDFGenerator.generate(from: imageURLs, to: outputURL, mangaMode: jobSettings.mangaMode, chapters: pdf.chapters, settings: jobSettings) { progress in
                    Task { @MainActor in self.conversionProgress = progress; self.processingStatus = "Converting \(Int(progress * 100))%" }
                }
                isConverting = false; conversionProgress = 1.0; statusMessage = "✅ Conversion Complete!"; scanLibrary()
                Logger.shared.log("Conversion Successful: \(pdf.name) -> PDF", category: "Converter")
            } else if jobSettings.outputFormat == .cbz {
                // CBZ export
                let fileManager = FileManager.default
                let pName = pdf.name.replacingOccurrences(of: ".cbz", with: "").replacingOccurrences(of: ".pdf", with: "").replacingOccurrences(of: ".zip", with: "") + "_Converted.cbz"
                let outputURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(pName)
                
                await MainActor.run { processingStatus = "Extracting Images..." }
                let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
                
                let imageURLs = try await extractImageURLs(from: pdf.url)
                for (idx, url) in imageURLs.enumerated() {
                    let ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
                    let dest = tempDir.appendingPathComponent(String(format: "page_%04d.%@", idx, ext))
                    try fileManager.copyItem(at: url, to: dest)
                    
                    let p = Double(idx) / Double(imageURLs.count)
                    await MainActor.run { self.conversionProgress = p; self.processingStatus = "Packaging CBZ..." }
                }
                
                if fileManager.fileExists(atPath: outputURL.path) { try fileManager.removeItem(at: outputURL) }
                try await ZipUtilities.zipDirectory(tempDir, to: outputURL)
                try fileManager.removeItem(at: tempDir)
                
                isConverting = false; conversionProgress = 1.0; statusMessage = "✅ Conversion Complete!"; scanLibrary()
                Logger.shared.log("Conversion Successful: \(pdf.name) -> CBZ", category: "Converter")
            } else if jobSettings.outputPipeline == .proPanel {
                // Primary panel path: PanelViewEPUBConverter (Amazon-compliant, px tap-targets, 150% magnify)
                await MainActor.run { processingStatus = "Loading Panel Data..." }
                let combinedManifest = await getCombinedManifest(for: pdf)
                let panelsByPage: [Int: [PanelExtractor.Panel]] = combinedManifest
                let pvConverter = PanelViewEPUBConverter()
                let newURLs = try await pvConverter.convert(
                    sourceURL: pdf.url,
                    settings: jobSettings,
                    panels: panelsByPage
                ) { progress in Task { @MainActor in self.conversionProgress = progress; self.processingStatus = "Converting \(Int(progress * 100))%" } }
                
                for epubURL in newURLs {
                    try? await injectMetadata(into: epubURL, panels: panelsByPage, metadata: pdf.metadata)
                }
                
                isConverting = false; conversionProgress = 1.0
                statusMessage = "✅ Panel View EPUB Ready! (\(newURLs.count) file\(newURLs.count == 1 ? "" : "s"))"
                scanLibrary()
                Logger.shared.log("PanelView Conversion Successful: \(pdf.name) -> \(newURLs.count) EPUB files", category: "Converter")
                // Removed Legacy AZW3 & EPUB Paths
            } else {
                // SVG-Viewport EPUB (cloud-safe) — no panel metadata injected
                let converter = CBZToEPUBConverter()
                let newURLs = try await converter.convert(
                    sourceURL: pdf.url,
                    settings: jobSettings,
                    manualManifest: nil
                ) { progress in Task { @MainActor in self.conversionProgress = progress; self.processingStatus = "Converting \(Int(progress * 100))%" } }
                
                for epubURL in newURLs {
                    try? await injectMetadata(into: epubURL, panels: [:], metadata: pdf.metadata)
                }
                
                isConverting = false; conversionProgress = 1.0
                statusMessage = "✅ Conversion Complete! (\(newURLs.count) files)"; scanLibrary()
                Logger.shared.log("Conversion Successful: \(pdf.name) -> \(newURLs.count) EPUB files", category: "Converter")
            }
            try? await Task.sleep(nanoseconds: 3 * 1_000_000_000); self.statusMessage = nil
        } catch {
            Logger.shared.log("Conversion Failed: \(error)", category: "Converter", type: .error)
            isConverting = false; statusMessage = "Error: \(error.localizedDescription)"
        }
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
            
            var jobSettings = conversionSettings
            if pdf.contentType == .book {
                jobSettings.mangaMode = false
                jobSettings.enablePanelSplit = false
                jobSettings.outputPipeline = .standard
                jobSettings.splitWebtoon = false
            }
            
            if let isWebtoon = pdf.metadata.isWebtoon, isWebtoon {
                jobSettings.splitWebtoon = true
                jobSettings.enablePanelSplit = false
                jobSettings.outputPipeline = .standard
            }
            
            do {
                if jobSettings.outputFormat == .pdf {
                    let fileManager = FileManager.default
                    let pName = pdf.name
                        .replacingOccurrences(of: ".cbz", with: "")
                        .replacingOccurrences(of: ".zip", with: "") + "_Converted.pdf"
                    let outputURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(pName)
                    let imageURLs = try await extractImageURLs(from: pdf.url)
                    try PDFGenerator.generate(from: imageURLs, to: outputURL, mangaMode: jobSettings.mangaMode, chapters: pdf.chapters, settings: jobSettings) { p in
                        Task { @MainActor in
                            self.conversionProgress = p
                            self.processingStatus = "Converting \(currentNum) of \(total) (\(Int(p * 100))%)"
                        }
                    }
                    await MainActor.run { self.scanLibrary() }
                    Logger.shared.log("Batch Conversion successful: \(pdf.name) -> PDF", category: "Converter")
                } else if jobSettings.outputFormat == .cbz {
                    let fileManager = FileManager.default
                    let pName = pdf.name.replacingOccurrences(of: ".cbz", with: "").replacingOccurrences(of: ".pdf", with: "").replacingOccurrences(of: ".zip", with: "") + "_Converted.cbz"
                    let outputURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(pName)
                    let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
                    
                    let imageURLs = try await extractImageURLs(from: pdf.url)
                    for (idx, url) in imageURLs.enumerated() {
                        let ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
                        let dest = tempDir.appendingPathComponent(String(format: "page_%04d.%@", idx, ext))
                        try fileManager.copyItem(at: url, to: dest)
                        
                        let p = Double(idx) / Double(imageURLs.count)
                        await MainActor.run {
                            self.conversionProgress = p
                            self.processingStatus = "Converting \(currentNum) of \(total) (\(Int(p * 100))%)"
                        }
                    }
                    
                    if fileManager.fileExists(atPath: outputURL.path) { try fileManager.removeItem(at: outputURL) }
                    try await ZipUtilities.zipDirectory(tempDir, to: outputURL)
                    try fileManager.removeItem(at: tempDir)
                    
                    await MainActor.run { self.scanLibrary() }
                    Logger.shared.log("Batch Conversion successful: \(pdf.name) -> CBZ", category: "Converter")
                } else if jobSettings.outputPipeline == .proPanel {
                    await MainActor.run { processingStatus = "Reading panels for \(pdf.name)..." }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    let combinedManifest = await getCombinedManifest(for: pdf)
                    let pvConverter = PanelViewEPUBConverter()
                    let newURLs = try await pvConverter.convert(
                        sourceURL: pdf.url,
                        settings: jobSettings,
                        panels: combinedManifest
                    ) { p in
                        Task { @MainActor in
                            self.conversionProgress = p
                            self.processingStatus = "Converting \(currentNum) of \(total) (\(Int(p * 100))%)"
                        }
                    }
                    for epubURL in newURLs {
                        try? await injectMetadata(into: epubURL, panels: combinedManifest, metadata: pdf.metadata)
                    }
                    await MainActor.run { self.scanLibrary() }
                    Logger.shared.log("Batch KF8 Conversion successful: \(pdf.name)", category: "Converter")
                } else {
                    // SVG-Viewport EPUB — no panel metadata
                    let converter = CBZToEPUBConverter()
                    let newURLs = try await converter.convert(
                        sourceURL: pdf.url,
                        settings: jobSettings,
                        manualManifest: nil
                    ) { p in
                        Task { @MainActor in
                            self.conversionProgress = p
                            self.processingStatus = "Converting \(currentNum) of \(total) (\(Int(p * 100))%)"
                        }
                    }
                    for epubURL in newURLs {
                        try? await injectMetadata(into: epubURL, panels: [:], metadata: pdf.metadata)
                    }
                    await MainActor.run { self.scanLibrary() }
                    Logger.shared.log("Batch Conversion successful: \(pdf.name)", category: "Converter")
                }
            } catch {
                Logger.shared.log("Batch Error for \(pdf.name): \(error)", category: "Converter")
                await MainActor.run { self.statusMessage = "Error on \(pdf.name)" }
                try? await Task.sleep(nanoseconds: 1 * 1_000_000_000)
            }
        }
        
        isConverting = false
    }
    func convertAndMerge(sourceFiles: [ConvertedPDF], outputName: String, mangaMode: Bool) async {
        guard !sourceFiles.isEmpty else { return }
        isConverting = true
        
        let fileManager = FileManager.default
        let documentsDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var jobSettings = conversionSettings
        jobSettings.mangaMode = mangaMode
        
        do {
            if jobSettings.outputFormat == .pdf || jobSettings.outputFormat == .cbz {
                // Image-based Bulk Extraction & Merge
                var batches: [[(url: URL, chapter: Chapter)]] = []
                var currentBatch: [(url: URL, chapter: Chapter)] = []
                var currentBatchSize: Int64 = 0
                let sizeLimit = jobSettings.splitMode.limit
                
                var firstCoverImageData: Data? = nil
                
                for (index, file) in sourceFiles.enumerated() {
                    if Task.isCancelled { break }
                    await MainActor.run {
                        self.processingStatus = "Step 1/2: Extracting \(index + 1) of \(sourceFiles.count)"
                        self.statusMessage = "Extracting \(file.name)..."
                        self.conversionProgress = Double(index) / Double(sourceFiles.count)
                    }
                    
                    let fileSize = file.fileSize
                    // Split boundary trigger: We only split if the batch has items AND adding this new file exceeds limit.
                    if sizeLimit != Int64.max && !currentBatch.isEmpty && (currentBatchSize + fileSize) > sizeLimit {
                        batches.append(currentBatch)
                        currentBatch = []
                        currentBatchSize = 0
                    }
                    
                    var images = try await extractImageURLs(from: file.url)
                    
                    // If the source file is ALREADY a Manga PDF resulting from a previous conversion, 
                    // its physical pages are extracted backwards. We must revert them to logical LTR 
                    // order here so the global batch merge doesn't scramble the books.
                    if file.url.pathExtension.lowercased() == "pdf", let isManga = file.metadata.isManga, isManga {
                        images.reverse()
                    }
                    
                    // The starting index for this chapter relative to the CURRENT batch
                    let chapterStartIndex = currentBatch.count
                    let chapterTitle = file.name.replacingOccurrences(of: ".cbz", with: "")
                                                .replacingOccurrences(of: ".zip", with: "")
                                                .replacingOccurrences(of: ".pdf", with: "")
                                                .replacingOccurrences(of: ".epub", with: "")
                    
                    let chapter = Chapter(title: chapterTitle, pageIndex: chapterStartIndex)
                    
                    if firstCoverImageData == nil, let firstImageURL = images.first {
                        firstCoverImageData = try? Data(contentsOf: firstImageURL)
                    }
                    
                    for imageURL in images {
                        currentBatch.append((url: imageURL, chapter: chapter))
                    }
                    currentBatchSize += fileSize
                }
                
                if !currentBatch.isEmpty {
                    batches.append(currentBatch)
                }
                
                guard !batches.isEmpty && !batches[0].isEmpty else {
                    isConverting = false; return
                }
                
                await MainActor.run {
                    self.processingStatus = "Step 2/2: Merging..."
                    self.statusMessage = "Merging \(batches.count) parts..."
                    self.conversionProgress = 0.5
                }
                
                let ext = jobSettings.outputFormat == .cbz ? ".cbz" : ".pdf"
                
                for (batchIndex, batch) in batches.enumerated() {
                    let partSuffix = batches.count > 1 ? " (pt \(batchIndex + 1))" : ""
                    let outputFilename = (outputName.isEmpty ? "Merged Collection" : outputName) + partSuffix + ext
                    let finalOutputURL = documentsDir.appendingPathComponent(outputFilename)
                    if fileManager.fileExists(atPath: finalOutputURL.path) { try fileManager.removeItem(at: finalOutputURL) }
                    
                    var batchImages = batch.map { $0.url }
                    
                    // Deduplicate chapters
                    var mergedChapters: [Chapter] = []
                    var seenChapters = Set<String>()
                    for item in batch {
                        if !seenChapters.contains(item.chapter.title) {
                            mergedChapters.append(item.chapter)
                            seenChapters.insert(item.chapter.title)
                        }
                    }
                    
                    // Generate Badged Cover for split parts
                    if let coverData = firstCoverImageData, batches.count > 1 {
                        let badgedCoverData = CoverGenerator.generateCover(from: coverData, partNumber: batchIndex + 1, totalParts: batches.count)
                        let tempCoverURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
                        try? badgedCoverData.write(to: tempCoverURL)
                        
                        // Replace the first image in the batch with the branded cover
                        if !batchImages.isEmpty {
                            batchImages[0] = tempCoverURL
                        }
                    }
                    
                    if jobSettings.outputFormat == .pdf {
                        let totalBatches = batches.count
                        try await Task.detached {
                            try PDFGenerator.generate(from: batchImages, to: finalOutputURL, mangaMode: jobSettings.mangaMode, chapters: mergedChapters, settings: jobSettings) { progress in
                                let baseProgress = Double(batchIndex) / Double(totalBatches)
                                let currentPartProgress = progress / Double(totalBatches)
                                Task { @MainActor [weak self] in self?.conversionProgress = 0.5 + (0.5 * (baseProgress + currentPartProgress)) }
                            }
                        }.value
                    } else {
                        try await Task.detached {
                            let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                            try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
                            for (idx, url) in batchImages.enumerated() {
                                let pathExt = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
                                let dest = tempDir.appendingPathComponent(String(format: "page_%04d.%@", idx, pathExt))
                                try fileManager.copyItem(at: url, to: dest)
                            }
                            try await ZipUtilities.zipDirectory(tempDir, to: finalOutputURL)
                            try fileManager.removeItem(at: tempDir)
                        }.value
                    }
                    
                    // ✅ Pre-register the file with its known page count (batch.count)
                    let finalFileSize = (try? finalOutputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                    let outputPDF = ConvertedPDF(name: outputFilename, url: finalOutputURL, pageCount: batch.count, fileSize: finalFileSize, metadata: PDFMetadata(title: outputFilename))
                    await MainActor.run { self.convertedPDFs.append(outputPDF) }
                }
                
                await MainActor.run {
                    self.scanLibrary()
                    self.statusMessage = "✅ Merge Complete!"
                    self.processingStatus = ""
                    self.conversionProgress = 1.0
                    self.isConverting = false
                }
                try? await Task.sleep(nanoseconds: 3 * 1_000_000_000)
                await MainActor.run { self.statusMessage = nil }
                return
            }
            
            // EPUB Bulk Merge (Existing Pipeline)
            // EPUB Bulk Merge (Existing Pipeline but with limits)
            var generatedBatches: [[URL]] = []
            var currentEPUBBatch: [URL] = []
            var currentEPUBBatchSize: Int64 = 0
            let epubSizeLimit = jobSettings.splitMode.limit
            
            var firstEPUBFileCoverData: Data? = nil
            
            for (index, file) in sourceFiles.enumerated() {
                if Task.isCancelled { break }
                let currentNum = index + 1
                await MainActor.run {
                    self.processingStatus = "Step 1/2: Converting \(currentNum) of \(sourceFiles.count)"
                    self.statusMessage = "Converting \(file.name)..."
                    self.conversionProgress = 0.0
                }
                
                let fileSize = file.fileSize
                if epubSizeLimit != Int64.max && !currentEPUBBatch.isEmpty && (currentEPUBBatchSize + fileSize) > epubSizeLimit {
                    generatedBatches.append(currentEPUBBatch)
                    currentEPUBBatch = []
                    currentEPUBBatchSize = 0
                }
                
                if firstEPUBFileCoverData == nil {
                    // Quick extract first image for cover badging later
                    if var images = try? await extractImageURLs(from: file.url) {
                        if file.url.pathExtension.lowercased() == "pdf" && (file.metadata.isManga == true) {
                            images.reverse()
                        }
                        if let firstImage = images.first {
                            firstEPUBFileCoverData = try? Data(contentsOf: firstImage)
                        }
                    }
                }
                
                await MainActor.run { processingStatus = "Reading Source Panels..." }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                let combinedManifest = await getCombinedManifest(for: file)
                
                Logger.shared.log("Starting Conversion for '\(file.name)'", category: "Converter")
                
                let isMangaPDF = file.url.pathExtension.lowercased() == "pdf" && (file.metadata.isManga == true)
                let resultingURLs: [URL]
                if jobSettings.outputPipeline == .proPanel {
                    let converter = PanelViewEPUBConverter()
                    resultingURLs = try await converter.convert(sourceURL: file.url, settings: jobSettings, panels: combinedManifest, sourceIsMangaPDF: isMangaPDF) { progress in
                        Task { @MainActor in self.conversionProgress = progress }
                    }
                } else {
                    let converter = CBZToEPUBConverter()
                    resultingURLs = try await converter.convert(sourceURL: file.url, settings: jobSettings, manualManifest: nil, sourceIsMangaPDF: isMangaPDF) { progress in
                        // We are doing N files, so this progress needs to be relative, but for now we just show it directly
                        Task { @MainActor in self.conversionProgress = progress }
                    }
                }
                
                currentEPUBBatch.append(contentsOf: resultingURLs)
                currentEPUBBatchSize += fileSize
                
                for epubURL in resultingURLs {
                    try? await injectMetadata(into: epubURL, panels: combinedManifest, metadata: file.metadata)
                }
            }
            
            if !currentEPUBBatch.isEmpty {
                generatedBatches.append(currentEPUBBatch)
            }
            
            guard !generatedBatches.isEmpty && !generatedBatches[0].isEmpty else {
                isConverting = false; return
            }
            
            await MainActor.run {
                self.processingStatus = "Step 2/2: Merging..."
                self.statusMessage = "Merging \(generatedBatches.count) EPUB parts..."
                self.conversionProgress = 0.5
            }
            
            let merger = EPUBMerger()
            
            for (batchIndex, batch) in generatedBatches.enumerated() {
                let partSuffix = generatedBatches.count > 1 ? " (pt \(batchIndex + 1))" : ""
                let outputFilename = (outputName.isEmpty ? "Merged Collection" : outputName) + partSuffix + ".epub"
                let finalOutputURL = documentsDir.appendingPathComponent(outputFilename)
                
                var overrideCover: Data? = nil
                if let baseCover = firstEPUBFileCoverData, generatedBatches.count > 1 {
                    overrideCover = CoverGenerator.generateCover(from: baseCover, partNumber: batchIndex + 1, totalParts: generatedBatches.count)
                }
                
                try await merger.mergeEPUBs(sourceURLs: batch, outputURL: finalOutputURL, settings: jobSettings, overrideCoverData: overrideCover)
                
                // ✅ Pre-register newly generated EPUB with known page count from detached calculation
                let finalFileSize = (try? finalOutputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                let totalPages = await Task.detached(priority: .background) { return ConversionManager.getPageCountStatic(from: finalOutputURL) }.value
                let outputPDF = ConvertedPDF(name: outputFilename, url: finalOutputURL, pageCount: totalPages, fileSize: finalFileSize, metadata: PDFMetadata(title: outputFilename))
                await MainActor.run { self.convertedPDFs.append(outputPDF) }
            }

            await MainActor.run { self.statusMessage = "Cleaning up..." }
            for batch in generatedBatches {
                for url in batch { try? fileManager.removeItem(at: url) }
            }
            
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
            await MainActor.run {
                self.statusMessage = "Merge Failed: \(error.localizedDescription)"
                self.isConverting = false
            }
        }
    }

    // MARK: - Thumbnails & Helpers
    func generateCoverThumbnail(for pdf: ConvertedPDF) async {
        // Check if we already have a cover on disk
        if let coverURL = getCoverURL(for: pdf),
           FileManager.default.fileExists(atPath: coverURL.path) { return }
        
        let url = pdf.url
        let image = await Task.detached(priority: .background) {
            return ConversionManager.extractCoverImageStatic(from: url)
        }.value
        
        guard let image = image,
              let jpegData = image.jpegData(compressionQuality: 0.7) else { return }
        
        // Use saveCoverImage which writes to disk AND caches with the correct UUID key
        saveCoverImage(jpegData, for: pdf)
        objectWillChange.send()
    }
    
    /// Generate covers for all imported files that are missing one. Called on app launch
    /// and after bulk imports to backfill any items imported before this fix.
    func backfillMissingThumbnails() {
        let pdfsNeedingCovers = convertedPDFs.filter { pdf in
            guard let coverURL = getCoverURL(for: pdf) else { return true }
            return !FileManager.default.fileExists(atPath: coverURL.path)
        }
        guard !pdfsNeedingCovers.isEmpty else { return }
        Logger.shared.log("Backfilling thumbnails for \(pdfsNeedingCovers.count) files.", category: "System")
        for pdf in pdfsNeedingCovers {
            Task(priority: .background) { await generateCoverThumbnail(for: pdf) }
        }
    }
    
    func getThumbnail(for pdf: ConvertedPDF) -> UIImage? {
        if let cached = thumbnailCache.object(forKey: pdf.id.uuidString as NSString) { return cached }
        
        Task.detached(priority: .userInitiated) {
            // Check disk cache first to avoid extracting the archive again
            if let coverURL = await self.getCoverURL(for: pdf),
               let data = try? Data(contentsOf: coverURL),
               let image = UIImage(data: data) {
                
                await MainActor.run {
                    self.thumbnailCache.setObject(image, forKey: pdf.id.uuidString as NSString)
                    self.objectWillChange.send()
                }
            } else {
                // Generate from scratch if it doesn't exist
                await self.generateCoverThumbnail(for: pdf)
            }
        }
        
        return nil
    }
    
    nonisolated static func extractCoverImageStatic(from url: URL) -> UIImage? {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" {
            guard let document = PDFDocument(url: url), let page = document.page(at: 0) else { return nil }
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

                        }
                    }
                }
            } catch {

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
        if self.editorCache?.pdfID == pdf.id {
             self.editorCache = nil
             // We don't force endSession because that might close the UI, but we clear the cache so next page load re-unzips.
        }
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
                                panelsToInject[index] = detected
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
    
    // ✅ NEW: Reusable Metadata Injection with Strict Re-Zip
    func injectMetadata(into archiveURL: URL, panels: [Int: [PanelExtractor.Panel]], metadata: PDFMetadata) async throws {
        Logger.shared.log("Starting Injection: \(archiveURL.lastPathComponent) with \(panels.count) pages", category: "Injection")
        
        // ---------------------------------------------------------
        // PHASE 1: PREPARE DATA (In Memory)
        // ---------------------------------------------------------
        
        // 1. Generate ComicInfo.xml
        var smartPanelsDict: [String: [SmartPanel]] = [:]
        for (index, pagePanels) in panels {
            let smartPanels = pagePanels.map { SmartPanel(x: $0.boundingBox.minX, y: $0.boundingBox.minY, width: $0.boundingBox.width, height: $0.boundingBox.height) }
            smartPanelsDict["\(index)"] = smartPanels
        }
        
        var xmlContent = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        xmlContent += "<ComicInfo>\n"
        xmlContent += "  <Title>\(metadata.title.xmlEscaped())</Title>\n"
        if let series = metadata.series { xmlContent += "  <Series>\(series.xmlEscaped())</Series>\n" }
        xmlContent += generatePagesXML(from: smartPanelsDict)
        xmlContent += "\n</ComicInfo>"
        
        guard let comicInfoData = xmlContent.data(using: .utf8) else { return }
        
        // 2. Prepare Updates (OPF & XHTML)
        let fileManager = FileManager.default
        var opfData: Data? = nil
        var opfPath: String? = nil
        var xhtmlUpdates: [String: Data] = [:]
        
        // We need to read the OLD archive first to prepare these updates
        // We scope this so we close the file handle before writing the new one (Windows safe)
        try {
            guard let sourceArchive = try? Archive(url: archiveURL, accessMode: .read, pathEncoding: .utf8) else { return }
            
            // A. Prepare OPF Update
            if let entry = sourceArchive.makeIterator().first(where: { $0.path.hasSuffix(".opf") }) {
                opfPath = entry.path
                var rawOpf = Data()
                _ = try sourceArchive.extract(entry) { rawOpf.append($0) }
                
                if var opfString = String(data: rawOpf, encoding: .utf8) {
                    var modified = false
                    
                    // 1. Kindle ASIN/UUID (Required for Guided View)
                    if !opfString.contains("urn:amazon:asin") && !opfString.contains("urn:uuid:") {
                        if let range = opfString.range(of: "<metadata"),
                           let endOfOpen = opfString[range.upperBound...].range(of: ">") {
                             let insertIndex = endOfOpen.upperBound
                             // Use a consistent ID or new one? New one is fine for export.
                             let asinUUID = UUID().uuidString
                             let tag = "\n    <dc:identifier id=\"uid\">urn:uuid:\(asinUUID)</dc:identifier>"
                             opfString.insert(contentsOf: tag, at: insertIndex)
                             modified = true
                        }
                    }
                    
                    // 1b. Ensure 'rendition' AND 'dcterms' prefixes are declared in <package>
                    // If we use rendition:layout or dcterms:modified, the prefixes must be defined in the root element.
                    if !opfString.contains("http://www.idpf.org/vocab/rendition/#") || !opfString.contains("http://purl.org/dc/terms/") {
                        if let range = opfString.range(of: "<package") {
                            if let endOfOpen = opfString[range.upperBound...].range(of: ">") {
                                // We need to check if 'prefix' attribute already exists
                                let tagContent = opfString[range.upperBound..<endOfOpen.lowerBound]
                                
                                if tagContent.contains("prefix=\"") {
                                    // Append to existing prefix attribute
                                    if let prefixRange = opfString.range(of: "prefix=\"") {
                                        let insertionPoint = prefixRange.upperBound
                                        var newPrefixes = ""
                                        if !opfString.contains("http://www.idpf.org/vocab/rendition/#") {
                                            newPrefixes += "rendition: http://www.idpf.org/vocab/rendition/# "
                                        }
                                        if !opfString.contains("http://purl.org/dc/terms/") {
                                            newPrefixes += "dcterms: http://purl.org/dc/terms/ "
                                        }
                                        opfString.insert(contentsOf: newPrefixes, at: insertionPoint)
                                        modified = true
                                    }
                                } else {
                                    // Insert new prefix attribute
                                    let prefixDef = " prefix=\"rendition: http://www.idpf.org/vocab/rendition/# dcterms: http://purl.org/dc/terms/\""
                                    opfString.insert(contentsOf: prefixDef, at: endOfOpen.lowerBound)
                                    modified = true
                                }
                            }
                        }
                    }
                    
                    // 2. Original Resolution Check (Removed Fixed-Layout requirements)
                    // We only inject the detected resolution to help kindle scale natively without letterbox framing.
                    if !opfString.contains("<meta name=\"original-resolution\"") {
                         if let range = opfString.range(of: "</metadata>") {
                             
                             // ✅ RESOLUTION EXTRACTION: Find first image to set correct original-resolution
                             var resolutionTag = ""
                             if let imageEntry = sourceArchive.makeIterator().first(where: { 
                                 $0.path.contains("images") && 
                                 ($0.path.hasSuffix(".jpg") || $0.path.hasSuffix(".jpeg") || $0.path.hasSuffix(".png")) 
                             }) {
                                 var imageData = Data()
                                 _ = try? sourceArchive.extract(imageEntry) { imageData.append($0) }
                                 if let image = UIImage(data: imageData) {
                                     let w = Int(image.size.width)
                                     let h = Int(image.size.height)
                                     resolutionTag = "\n    <meta name=\"original-resolution\" content=\"\(w)x\(h)\"/>"
                                     Logger.shared.log("Detected Key Resolution: \(w)x\(h)", category: "Injection")
                                 }
                             }
                             
                             let tag = """
\(resolutionTag)
"""
                             opfString.insert(contentsOf: tag, at: range.lowerBound)
                             modified = true
                             Logger.shared.log("Injected Fallback Resolution", category: "Injection")
                         }
                    }
                    
                    // 3. Embed ComicInfo as Base64 (Zero Footprint)
                    // Kindle rejects valid XML files if they aren't in the Manifest, and rejects them IN the manifest if they aren't core types.
                    // Solution: Embed as Base64 metadata in OPF.
                    
                    let base64 = comicInfoData.base64EncodedString()
                    
                    // A. Remove existing tag if present (prevent duplication)
                    // We remove both 'property' (legacy/error) and 'name' (correct) versions to ensure a clean state
                    let pattern = "<meta (property=\"inksync:comicinfo\"|name=\"inksync-comicinfo\")[^>]*>.*?</meta>\\s*|<meta name=\"inksync-comicinfo\" content=\".*?\"/>\\s*"
                    let originalOPF = opfString
                    if let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) {
                        let range = NSRange(opfString.startIndex..<opfString.endIndex, in: opfString)
                        opfString = regex.stringByReplacingMatches(in: opfString, options: [], range: range, withTemplate: "")
                        if opfString != originalOPF {
                            modified = true
                            Logger.shared.log("Removed legacy inksync-comicinfo tag", category: "Injection")
                        }
                    }
                    
                    // B. Insert New Tag (CONDITIONAL - Only for Guided View)
                    if conversionSettings.isGuidedView {
                        if let range = opfString.range(of: "</metadata>") {
                             let metaTag = "\n    <meta name=\"inksync-comicinfo\" content=\"\(base64)\"/>"
                             opfString.insert(contentsOf: metaTag, at: range.lowerBound)
                             modified = true
                             Logger.shared.log("Injected inksync-comicinfo metadata (Guided View)", category: "Injection")
                        }
                    } else {
                        Logger.shared.log("Skipping metadata injection (Standard Mode)", category: "Injection")
                    } 
                    
                    if modified {
                        opfData = opfString.data(using: .utf8)
                    } else {
                        opfData = rawOpf // No changes needed
                    }
                }
            }
            
            // B. Prepare XHTML Updates (EPUB Only)
            if archiveURL.pathExtension.lowercased() == "epub" {
                for (index, _) in panels {
                     let pageNum = index + 1
                     
                     // Try to find image
                     let imageBase = String(format: "image_%04d", pageNum)
                     var imageName: String? = nil
                     var entryPath: String? = nil
                     
                     for ext in ["jpg", "jpeg", "png", "webp"] {
                         let p = "OEBPS/images/\(imageBase).\(ext)"
                         if sourceArchive[p] != nil {
                             imageName = "\(imageBase).\(ext)"
                             entryPath = p
                             break
                         }
                     }
                     
                     if let img = imageName, let path = entryPath, let entry = sourceArchive[path] {
                         var imgData = Data()
                         _ = try sourceArchive.extract(entry) { imgData.append($0) }
                         
                         var w = 1000
                         var h = 1500
                         if let sz = UIImage(data: imgData)?.size {
                             w = Int(sz.width)
                             h = Int(sz.height)
                         }
                         
                         let xhtmlContent = CBZToEPUBConverter.generateChunkXHTML(
                            chunkIndex: pageNum,
                            images: [img],
                            title: "Page \(pageNum)",
                            width: w,
                            height: h
                         )
                         
                         if let data = xhtmlContent.data(using: .utf8) {
                             let savePath = String(format: "OEBPS/text/page_%04d.xhtml", pageNum)
                             xhtmlUpdates[savePath] = data
                         }
                     }
                }
            }
        }()
        
        // ---------------------------------------------------------
        // PHASE 2: STRICT RE-ZIP (Write New File)
        // ---------------------------------------------------------
        
        let tempID = UUID().uuidString
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(tempID)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }
        
        let newArchiveURL = tempDir.appendingPathComponent("temp.epub")
        
        // Scope to ensure archive closes (deinit) before move
        do {
            guard let newArchive = try? Archive(url: newArchiveURL, accessMode: .create, pathEncoding: .utf8) else {
                Logger.shared.log("Failed to create temporary archive", category: "Injection")
                return 
            }
            
            // 1. MIMETYPE (Must be First & Stored & NO EXTRA FIELDS)
            // Writing to disk and adding as file avoids explicit metadata passed in the closure-based API
            // which likely triggers ZIPFoundation to write extended timestamps.
            let mimePath = tempDir.appendingPathComponent("mimetype")
            try "application/epub+zip".write(to: mimePath, atomically: true, encoding: .ascii)
            
            try newArchive.addEntry(with: "mimetype", fileURL: mimePath, compressionMethod: .none)
            try? fileManager.removeItem(at: mimePath)
            
            // 2. META-INF/container.xml (Must be Second for strict compliance)
            var processedPaths: Set<String> = ["mimetype"]
            
            if let oldArchive = try? Archive(url: archiveURL, accessMode: .read, pathEncoding: .utf8) {
                if let containerEntry = oldArchive["META-INF/container.xml"] {
                    let tempContainer = tempDir.appendingPathComponent("container.xml")
                    _ = try oldArchive.extract(containerEntry, to: tempContainer)
                    try newArchive.addEntry(with: "META-INF/container.xml", fileURL: tempContainer, compressionMethod: .deflate)
                    try? fileManager.removeItem(at: tempContainer)
                    processedPaths.insert("META-INF/container.xml")
                }
            
                // 3. MIGRATE REMAINDER (Copy from Old -> New)
                for entry in oldArchive {
                    if processedPaths.contains(entry.path) { continue }
                    
                    // Skip Special Files (We inject/update these manually)
                    // We need to calculate comicInfoPath here too or just skip strictly by suffix if we want to be safe?
                    // Safe approach: Skip if it ends in ComicInfo.xml AND is in the same dir as OPF.
                    // But simpler: We calculated `opfPath` earlier.
                    
                    let targetComicInfoPath: String
                    if let opf = opfPath, let lastSlash = opf.lastIndex(of: "/") {
                         let dir = opf[..<lastSlash]
                         targetComicInfoPath = "\(dir)/ComicInfo.xml"
                    } else {
                         targetComicInfoPath = "ComicInfo.xml"
                    }
                    
                    if entry.path == targetComicInfoPath { continue }
                    if entry.path == "ComicInfo.xml" { continue } 
                    if entry.path == "META-INF/ComicInfo.xml" { continue } // ✅ Skip new location too
                    if entry.path == opfPath { continue }
                    if xhtmlUpdates.keys.contains(entry.path) { continue }
                    
                    let tempExtract = tempDir.appendingPathComponent("transfer.tmp")
                    _ = try oldArchive.extract(entry, to: tempExtract)
                    
                    try newArchive.addEntry(with: entry.path, type: .file, uncompressedSize: Int64(entry.uncompressedSize), modificationDate: entry.fileAttributes[.modificationDate] as? Date ?? Date(), permissions: entry.fileAttributes[.posixPermissions] as? UInt16 ?? 0o644, compressionMethod: .deflate, bufferSize: 8192, progress: nil) { pos, size in
                        let handle = try? FileHandle(forReadingFrom: tempExtract)
                        try? handle?.seek(toOffset: UInt64(pos))
                        return handle?.readData(ofLength: size) ?? Data()
                    }
                    try? fileManager.removeItem(at: tempExtract)
                }
            }
            
            // 4. INJECT NEW/UPDATED FILES
            
            // ComicInfo check: Ensure it lives next to OPF
            // ComicInfo check: Ensure it lives in META-INF (Best Practice for ignoring files in Manifest)
            // If it was in OEBPS, we arguably should MOVE it, but for now let's just write to META-INF if that's where we target.
            
            // ComicInfo File Injection (REMOVED)
            // We now embed this in the OPF metadata above.
            // keeping this comment for context.
            // let comicInfoPath = "META-INF/ComicInfo.xml"
            // try newArchive.addEntry(...)
            
            // OPF
            if let data = opfData, let path = opfPath {
                // Log OPF for debugging
                if String(data: data, encoding: .utf8) != nil {

                }
                
                try newArchive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), modificationDate: Date(), permissions: 0o644, compressionMethod: .deflate, bufferSize: 8192, progress: nil) { pos, size in
                    return data.subdata(in: Int(pos)..<min(Int(pos)+size, data.count))
                }
            }
            
            // XHTML Updates
            for (path, data) in xhtmlUpdates {
                try newArchive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), modificationDate: Date(), permissions: 0o644, compressionMethod: .deflate, bufferSize: 8192, progress: nil) { pos, size in
                    return data.subdata(in: Int(pos)..<min(Int(pos)+size, data.count))
                }
            }
            
        } // DEINIT: newArchive closed here
        
        // 5. ATOMIC SWAP
        try finalizeSwap(source: newArchiveURL, dest: archiveURL)
        Logger.shared.log("Successfully rebuilt EPUB structure", category: "Injection")
        
        // 6. LOG STRUCTURE (Flight Recorder)
        Logger.shared.logEPUBStructure(at: archiveURL)
    }
    

    
    // Helper to finish the swap (Split out to ensure deinit)
    private func finalizeSwap(source: URL, dest: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        try fm.moveItem(at: source, to: dest)
    }
    
    // MARK: - Kindle OPF Injection
    // Ensures ASIN and Fixed-Layout Metadata exist for Guided View support.
    private func ensureKindleOPF(at url: URL) async throws {
        // Re-implements the Hot-Fix logic to ensure ASIN and Fixed-Layout tags exist in the OPF.
        // This is critical for activating Guided View on Kindle devices.
        
        let fileManager = FileManager.default
        _ = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        
        // Optimize: We don't need to unzip everything, just the OPF. 
        // But ZIPFoundation update requires re-archiving or careful manipulation.
        // Simplest consistent way: Read Entry -> Modify -> Remove -> Add.
        
        guard let archive = try? Archive(url: url, accessMode: .update, pathEncoding: .utf8) else { return }
        
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

            }
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

// MARK: - Pre-Flight Validation & Export
extension ConversionManager {
    enum ValidationResult {
        case success
        case warning(String)
        case failure(String)
    }
    
    func validateForExport(_ pdf: ConvertedPDF) -> ValidationResult {
        Logger.shared.log("Running Pre-Flight Check for: \(pdf.name)", category: "Validation")
        
        // 1. Check for Panels (if Guided View is active)
        if conversionSettings.isGuidedView {
            let panels = panelOverrides[pdf.id] ?? [:]
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
                    self.convertedPDFs = self.convertedPDFs
                }
            }
        }
    }
}
