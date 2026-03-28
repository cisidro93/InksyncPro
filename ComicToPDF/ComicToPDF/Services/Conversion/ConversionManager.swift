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
    
    private var progressSubscription: AnyCancellable?
    
    init() {
        loadLibrary()
        scanLibrary()
        createWelcomeFile()
        performStartupOptimization()
        Task { await MainActor.run { self.migrateCoversToDisk() } }
        
        NotificationCenter.default.addObserver(forName: NSNotification.Name("LibraryNeedsRescan"), object: nil, queue: .main) { [weak self] notification in
            let modeRaw = notification.userInfo?["mode"] as? String
            let mode: AppUIMode = (modeRaw == AppUIMode.go.rawValue) ? .go : .pro
            Task { @MainActor [weak self] in
                self?.scanLibrary(addedByMode: mode)
            }
        }
        
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
            self.scanLibrary()
        case .failed(let url, let error):
            self.isConverting = false
            Logger.shared.log("Conversion Failed [\(url.lastPathComponent)]: \(error.localizedDescription)", category: "Engine", type: .error)
            self.appAlert = AppAlert(title: "Conversion Failed", message: error.localizedDescription)
        }
    }
    
    private func performStartupOptimization() {
        let key = "hasRunStartupOptimization"
        if UserDefaults.standard.bool(forKey: key) { return }
        
        let memory = ProcessInfo.processInfo.physicalMemory
        let ramGB = Double(memory) / 1024.0 / 1024.0 / 1024.0
        
        if ramGB > 5.5 {
            conversionSettings.compressionQuality = .high
        } else if ramGB < 3.5 {
            conversionSettings.compressionQuality = .compact
        } else {
            conversionSettings.compressionQuality = .balanced
        }
        
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
            try? await Task.sleep(nanoseconds: 500_000_000) 
            guard !Task.isCancelled else { return }
            LibraryPersistenceManager.shared.save(manager: self)
        }
    }
    
    func savePDFs() { saveLibrary() }
    
    func loadLibrary() {
        LibraryPersistenceManager.shared.load(manager: self)
    }
    
    func savePanelOverrides(for pdfID: UUID, pageIndex: Int, panels: [PanelExtractor.Panel]) async {
        if WorkspaceSessionManager.shared.panelOverrides[pdfID] == nil { WorkspaceSessionManager.shared.panelOverrides[pdfID] = [:] }
        WorkspaceSessionManager.shared.panelOverrides[pdfID]?[pageIndex] = panels
        saveLibrary() 
    }
    
    func savePanelOverrides(for pdfID: UUID, panels: [Int: [PanelExtractor.Panel]]) {
        WorkspaceSessionManager.shared.panelOverrides[pdfID] = panels
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
}
