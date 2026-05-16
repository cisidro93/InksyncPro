import SwiftUI
import PDFKit
import ZIPFoundation
import Combine

@MainActor
class ConversionManager: ObservableObject {
    @Published var convertedPDFs: [ConvertedPDF] = []
    @Published var collections: [PDFCollection] = []
    // MARK: - App Config Shifted to AppSettingsManager
    
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
        // 80MB: ~160 × 360px covers @ ~500KB each — fits comfortably without memory pressure
        cache.totalCostLimit = 1024 * 1024 * 80
        return cache
    }()
    
    // UI State (Forwarded to TaskEngine)
    var isConverting: Bool { get { TaskEngine.shared.isConverting } set { TaskEngine.shared.isConverting = newValue } }
    var conversionProgress: Double { get { TaskEngine.shared.conversionProgress } set { TaskEngine.shared.conversionProgress = newValue } }
    var processingStatus: String { get { TaskEngine.shared.processingStatus } set { TaskEngine.shared.processingStatus = newValue } }
    var statusMessage: String? { get { TaskEngine.shared.statusMessage } set { TaskEngine.shared.statusMessage = newValue } }
    var appAlert: AppAlert? { get { TaskEngine.shared.appAlert } set { TaskEngine.shared.appAlert = newValue } }
    var activeTasks: [AppBackgroundTask] { get { TaskEngine.shared.activeTasks } set { TaskEngine.shared.activeTasks = newValue } }
    
    // Vault State now in AppSettingsManager
    
    // ✅ NEW: Background Metadata State
    @Published var failedMetadataPDFs: [ConvertedPDF] = []
    
    // MARK: - Panel Editor State
    @Published var isPresentingPanelEditor: Bool = false
    @Published var currentEditorImage: UIImage? = nil
    @Published var currentEditorPanels: [CGRect] = []
    
    // Non-published continuation for async waiting
    private var panelEditorContinuation: CheckedContinuation<[CGRect], Never>?
    
    func setPanelEditorContinuation(_ continuation: CheckedContinuation<[CGRect], Never>) {
        self.panelEditorContinuation = continuation
    }
    
    func submitPanelEdits(_ rects: [CGRect]) {
        isPresentingPanelEditor = false
        currentEditorImage = nil
        currentEditorPanels = []
        panelEditorContinuation?.resume(returning: rects)
        panelEditorContinuation = nil
    }
    
    var visiblePDFs: [ConvertedPDF] {
        convertedPDFs.filter { AppSettingsManager.shared.isVaultUnlocked ? true : !$0.isPrivate }
    }
    
    /// Only Pro-mode files — used by the Pro Library to exclude Go conversions.
    var proLibraryPDFs: [ConvertedPDF] {
        convertedPDFs.filter { (AppSettingsManager.shared.isVaultUnlocked ? true : !$0.isPrivate) && $0.addedByMode == .pro }
    }
    
    private var taskEngineRelay: AnyCancellable?
    private var importMonitorRelay: AnyCancellable?

    init() {
        loadLibrary()
        
        createWelcomeFile()
        performStartupOptimization()
        Task { await MainActor.run { self.migrateCoversToDisk() } }
        
        NotificationCenter.default.addObserver(forName: .libraryNeedsRescan, object: nil, queue: .main) { [weak self] notification in
            let modeRaw = notification.userInfo?["mode"] as? String
            let mode: AppUIMode = (modeRaw == AppUIMode.go.rawValue) ? .go : .pro
            Task { @MainActor [weak self] in
                self?.scanLibrary(addedByMode: mode)
            }
        }
        
        NotificationCenter.default.addObserver(forName: .libraryNeedsSave, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.saveLibrary()
            }
        }

        // ✅ ISSUE 11 FIX: Relay TaskEngine state changes through ConversionManager.
        // TaskEngine owns @Published properties (isConverting, conversionProgress, etc.)
        // that ConversionManager exposes as computed forwarding properties.
        // Without this subscription, changes to TaskEngine do NOT trigger
        // ConversionManager.objectWillChange, so observing SwiftUI views never
        // re-render (e.g. InkTabBar progress bar, processingStatus text).
        taskEngineRelay = TaskEngine.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }

        // Relay ImportMonitorManager changes so both iPhone InkTabBar and iPad sidebar
        // progress panels re-render when import progress ticks forward.
        importMonitorRelay = ImportMonitorManager.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }

        // ── Cloud Cover Ready: wire CloudCoverExtractor → thumbnailCache ──────
        // CloudCoverExtractor writes covers to disk but has no reference to
        // ConversionManager. We observe its notification to load the new image
        // into NSCache and trigger a SwiftUI redraw — otherwise cells stay on
        // the cloud placeholder indefinitely.
        NotificationCenter.default.addObserver(
            forName: .cloudCoverReady,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let pdfID = notification.userInfo?["pdfID"] as? UUID,
                  let image  = notification.userInfo?["image"]  as? UIImage else { return }
            self.thumbnailCache.setObject(image, forKey: pdfID.uuidString as NSString)
            self.objectWillChange.send()
        }
    }
    
    
    
    private func performStartupOptimization() {
        let key = "hasRunStartupOptimization"
        if UserDefaults.standard.bool(forKey: key) { return }
        
        let memory = ProcessInfo.processInfo.physicalMemory
        let ramGB = Double(memory) / 1024.0 / 1024.0 / 1024.0
        
        if ramGB > 5.5 {
            AppSettingsManager.shared.conversionSettings.compressionQuality = .high
        } else if ramGB < 3.5 {
            AppSettingsManager.shared.conversionSettings.compressionQuality = .compact
        } else {
            AppSettingsManager.shared.conversionSettings.compressionQuality = .balanced
        }
        
        UserDefaults.standard.set(true, forKey: key)
        AppSettingsManager.shared.save()
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
            // 300ms debounce — collapses burst saves (e.g. per-file metadata loops) into one disk write.
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            LibraryPersistenceManager.shared.save(manager: self)
            // Keep Spotlight index in sync with the library
            SpotlightIndexer.shared.indexLibrary(pdfs: self.convertedPDFs)
        }
    }
    
    func savePDFs() { saveLibrary() }
    
    func loadLibrary() {
        LibraryPersistenceManager.shared.load(manager: self)
    }
    
    func savePanelOverrides(for pdfID: UUID, pageIndex: Int, panels: [PanelExtractor.Panel]) async {
        PageModelStore.shared.saveLegacyVisionPanels(panels, for: pdfID, pageIndex: pageIndex)
        saveLibrary() 
    }
    
    func savePanelOverrides(for pdfID: UUID, panels: [Int: [PanelExtractor.Panel]]) {
        PageModelStore.shared.saveAllLegacyVisionPanels(panels, for: pdfID)
        self.saveLibrary()
    }
    
    // MARK: - Cover Image Management
    
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
        PhysicalFileSystemRouter.shared.getCoverURL(for: pdf)
    }

    func getOriginalCoverURL(for pdf: ConvertedPDF) -> URL {
        PhysicalFileSystemRouter.shared.getOriginalCoverURL(for: pdf)
    }
    
    func migrateCoversToDisk() {
        PhysicalFileSystemRouter.shared.migrateCoversToDisk(manager: self)
    }
    
    func loadCoverThumbnail(for pdf: ConvertedPDF) async -> UIImage? {
        await PhysicalFileSystemRouter.shared.loadCoverThumbnail(for: pdf, manager: self)
    }
    
    func saveCoverImage(_ data: Data, for pdf: ConvertedPDF) {
        PhysicalFileSystemRouter.shared.saveCoverImage(data, for: pdf, manager: self)
    }
    
    // MARK: - Advanced Metadata Update
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
        var combined = PageModelStore.shared.getAllLegacyVisionPanels(for: pdf.id)
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
    
    func scanLibrary(addedByMode: AppUIMode? = nil) {
        Task {
            // ✅ Delegated O(N) file enumeration to strictly concurrent Actor
            await LibraryScanner.shared.scanLibrary(addedByMode: addedByMode, manager: self)
        }
    }
    
    func deletePDF(_ pdf: ConvertedPDF) {
        SpotlightIndexer.shared.deindexBook(pdf.id)
        PhysicalFileSystemRouter.shared.deletePDF(pdf, manager: self)
    }
    
    func removeFromLibrary(_ pdf: ConvertedPDF) { deletePDF(pdf) }
}
