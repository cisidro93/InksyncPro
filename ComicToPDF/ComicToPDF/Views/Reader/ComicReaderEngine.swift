import SwiftUI
import ZIPFoundation
import PDFKit
import ImageIO
import AVFoundation
import Vision
import UIKit

extension Notification.Name {
    static let comicImageCacheImageLoaded = Notification.Name("InksyncPro.ComicImageCache.imageLoaded")
    static let readerZoomStateChanged = Notification.Name("InksyncPro.ComicReader.zoomStateChanged")
}

enum ComicReadingMode: String, CaseIterable, Codable {
    case pageHorizontal   // Single page, horizontal swipe (default)
    case panelNavigation  // Panel-by-panel using pageModels Vision data
    case webtoonScroll    // Continuous vertical scroll
    case mangaRTL         // Single page, horizontal swipe, right-to-left
}

@MainActor
final class ComicImageCache: ObservableObject {
    private var cache = NSCache<NSNumber, UIImage>()
    private var thumbnailCache: NSCache<NSNumber, UIImage> = {
        let cache = NSCache<NSNumber, UIImage>()
        cache.countLimit = ReaderCacheLimits.thumbnailScrubBar
        cache.name = "com.inksyncpro.comicthumbnails"
        return cache
    }()
    private var accessQueue: [Int] = []
    private let fetchingQueueLock = NSLock()
    private var fetchingQueue: Set<Int> = [] // Track pending extractions
    
    private var lastRequestedIndex: Int = 0
    private var readingDirection: Int = 1 // 1 for forward, -1 for backward
    private var inFlightPrefetchTasks: [Int: Task<Void, Never>] = [:]
    private var averageSecondsPerPage: Double = 8.0
    private var isPrefetching = false
    private nonisolated(unsafe) var notificationObservers: [NSObjectProtocol] = []
    
    func cancelAllPrefetchTasks() {
        inFlightPrefetchTasks.values.forEach { $0.cancel() }
        inFlightPrefetchTasks.removeAll()
    }
    
    private func storePrefetchTask(_ task: Task<Void, Never>, for index: Int) {
        inFlightPrefetchTasks[index] = task
    }
    
    private func removePrefetchTask(_ index: Int) {
        inFlightPrefetchTasks.removeValue(forKey: index)
    }
    
    func updateReadingVelocity(secondsPerPage: Double) {
        self.averageSecondsPerPage = secondsPerPage
    }
    
    private func isFetching(_ index: Int) -> Bool {
        fetchingQueueLock.lock()
        defer { fetchingQueueLock.unlock() }
        return fetchingQueue.contains(index)
    }
    
    private func startFetching(_ index: Int) {
        fetchingQueueLock.lock()
        fetchingQueue.insert(index)
        fetchingQueueLock.unlock()
    }
    
    private func stopFetching(_ index: Int) {
        fetchingQueueLock.lock()
        fetchingQueue.remove(index)
        fetchingQueueLock.unlock()
    }
    
    private var maxCacheSize: Int {
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        let usage = MemoryMonitor.reportMemoryUsage()
        if usage > 600.0 { return 8 }
        if usage > 400.0 { return isPad ? 12 : 6 }
        return isPad ? 20 : 12 // Rich page buffer for iPad Pro dual spreads & 120Hz scrubbing
    }
    private let prefetchLimit: Int // Configurable read-ahead page buffer
    
    // For CBZ extraction — store URL, NOT a shared Archive.
    private var cbzURL: URL?
    private var entries: [ZIPFoundation.Entry] = []

    // ── Pre-extracted archive path (CBR/RAR/CBT/TAR) ──────────────────────────
    private var extractedImageURLs: [URL] = []
    private var extractedTempDir: URL? = nil
    let isPreExtracted: Bool
    
    // Cache for composite/virtual omnibus pre-extracted source files
    private var lastExtractedVirtualURL: URL? = nil
    private var lastExtractedVirtualTempDir: URL? = nil
    private var lastExtractedVirtualImageURLs: [URL] = []
    
    // ✅ OPDS-style cloud page streaming
    private var cloudPageSource: CloudPageSource?
    
    // Virtual omnibus page mapping
    private var virtualCoordinator: VirtualPageCoordinator?
    
    @Published var isLoading = true
    @Published var loadError: String? = nil   // Non-nil = show error view with exit button
    @Published var loadDiagnosticReport: DocumentDiagnosticReport? = nil
    @Published var isLandscapeArray: [Bool] = []
    var pageCount: Int = 0
    let pdfID: UUID
    let isPDF: Bool
    let isStream: Bool
    let sourceMode: SourceMode
    var activelyAccessedURL: URL?
    
    init(pdf: ConvertedPDF, prefetchLimit: Int = 2) {
        self.pdfID = pdf.id
        self.prefetchLimit = prefetchLimit
        self.sourceMode = pdf.sourceMode
        self.cache.totalCostLimit = 150 * 1024 * 1024 // 150 MB absolute RAM cap
        let perfClass = ProcessInfo.processInfo.performanceClass
        switch perfClass {
        case .low:
            self.cache.countLimit = ReaderCacheLimits.comicBufferLowDevice
        case .medium:
            self.cache.countLimit = ReaderCacheLimits.comicBufferStandardDevice
        case .high:
            self.cache.countLimit = ReaderCacheLimits.comicBufferProDevice
        }
        let scheme = pdf.url.scheme?.lowercased() ?? ""
        
        if scheme == "virtual-omnibus" {
            isStream = false
            isPDF = false
            isPreExtracted = false
            
            let omnibusID = UUID(uuidString: pdf.url.host ?? "") ?? UUID()
            let omni = LibraryService.shared.virtualOmnibuses.first(where: { $0.id == omnibusID })
                ?? ConversionManager.shared.virtualOmnibuses.first(where: { $0.id == omnibusID })
            if let omni {
                let resolvedFiles = omni.fileIDs.compactMap { id in
                    LibraryService.shared.items.first(where: { $0.id == id })
                        ?? ConversionManager.shared.convertedPDFs.first(where: { $0.id == id })
                }
                let coord = VirtualPageCoordinator(files: resolvedFiles)
                self.virtualCoordinator = coord
                self.pageCount = coord.totalPageCount
                self.isLoading = false
                self.scanPageOrientations(resolvedURL: nil)
            } else {
                self.virtualCoordinator = nil
                self.pageCount = 0
                self.isLoading = false
                let report = DocumentOpenDiagnostics.logFailure(url: pdf.url, pdf: pdf, error: nil, context: "ComicReaderEngine")
                self.loadDiagnosticReport = report
                self.loadError = report.rootCauseDescription
            }
        } else {
            isStream = (scheme == "http" || scheme == "https")
            let ext = pdf.url.pathExtension.lowercased()
            isPDF = (ext == "pdf")
            let isCBRFile = (ext == "cbr" || ext == "rar")
            let isCBTFile = (ext == "cbt" || ext == "tar")
            self.isPreExtracted = isCBRFile || isCBTFile
            self.virtualCoordinator = nil
        }
        
        let memObs = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.cancelAllPrefetchTasks()
                self.cache.removeAllObjects()
                self.thumbnailCache.removeAllObjects()
                Logger.shared.log("ComicImageCache: Memory warning received. Cleared image & thumbnail cache and cancelled pending prefetch.", category: "Memory", type: .warning)
            }
        }
        self.notificationObservers.append(memObs)
        
        let renameObs = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("InksyncPro.fileDidRename"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let pdfID = notification.userInfo?["pdfID"] as? UUID
            let newURL = notification.userInfo?["newURL"] as? URL
            
            Task { @MainActor in
                guard let self = self else { return }
                guard let pdfID = pdfID,
                      let newURL = newURL,
                      pdfID == pdf.id else { return }
                
                Logger.shared.log("ComicImageCache: Active file renamed to \(newURL.lastPathComponent). Updating handles.", category: "Engine", type: .success)
                
                if let oldAccess = self.activelyAccessedURL {
                    oldAccess.stopAccessingSecurityScopedResource()
                    self.activelyAccessedURL = nil
                }
                
                if case .linked = pdf.sourceMode {
                    let didAccess = newURL.startAccessingSecurityScopedResource()
                    if didAccess {
                        self.activelyAccessedURL = newURL
                    }
                }
                
                self.cbzURL = newURL
                
                if self.isPDF {
                    Task {
                        await PDFRenderActor.shared.clear()
                        _ = await PDFRenderActor.shared.loadDocument(at: newURL)
                    }
                }
            }
        }
        self.notificationObservers.append(renameObs)
        
        if scheme == "virtual-omnibus" {
            // Already initialized, no background archive extraction needed!
        } else if isStream {
            self.pageCount = 0
            self.isLoading = true
        } else if isPDF {
            let targetURL = LibraryFileRecord.resolveSandboxURL(pdf.url.absoluteString)
            Task.detached(priority: .userInitiated) { [weak self] in
                let resolvedURL: URL
                var accessedURL: URL? = nil
                if case .linked(let bm) = pdf.sourceMode,
                   let url = try? BookmarkResolver.shared.resolve(bm) {
                    let didAccess = url.startAccessingSecurityScopedResource()
                    resolvedURL = url
                    if didAccess { accessedURL = url }
                } else {
                    resolvedURL = targetURL
                }
                
                let count = await PDFRenderActor.shared.loadDocument(at: resolvedURL)
                
                if let accessed = accessedURL {
                    if let self = self {
                        await MainActor.run { self.activelyAccessedURL = accessed }
                    } else {
                        accessed.stopAccessingSecurityScopedResource()
                    }
                }
                if count == 0 {
                    let report = DocumentOpenDiagnostics.logFailure(url: resolvedURL, pdf: pdf, error: nil, context: "ComicReaderEngine")
                    await MainActor.run { [weak self] in
                        guard let self = self else { return }
                        self.loadDiagnosticReport = report
                        self.loadError = report.rootCauseDescription
                        self.pageCount = 0
                        self.isLoading = false
                    }
                } else {
                    await MainActor.run { [weak self] in
                        guard let self = self else { return }
                        self.pageCount = count
                        self.isLoading = false
                        self.scanPageOrientations(resolvedURL: resolvedURL)
                    }
                }
            }
        } else if isPreExtracted {
            let targetURL = LibraryFileRecord.resolveSandboxURL(pdf.url.absoluteString)
            Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else { return }
                let resolvedURL: URL
                var accessedURL: URL? = nil
                if case .linked(let bm) = pdf.sourceMode,
                   let url = try? BookmarkResolver.shared.resolve(bm) {
                    let didAccess = url.startAccessingSecurityScopedResource()
                    resolvedURL = url
                    if didAccess { accessedURL = url }
                } else {
                    resolvedURL = targetURL
                }
                do {
                    let ext = resolvedURL.pathExtension.lowercased()
                    let isCBT = ["cbt", "tar"].contains(ext)
                    
                    let (tempDir, imageURLs): (URL, [URL])
                    if isCBT {
                        (tempDir, imageURLs) = try await CBTExtractor.extract(from: resolvedURL)
                    } else {
                        (tempDir, imageURLs) = try await CBRExtractor.extract(from: resolvedURL)
                    }
                    
                    if let accessed = accessedURL {
                        await MainActor.run { self.activelyAccessedURL = accessed }
                    }
                    if imageURLs.isEmpty {
                        let report = DocumentOpenDiagnostics.logFailure(url: resolvedURL, pdf: pdf, error: nil, context: "ComicReaderEngine")
                        await MainActor.run {
                            self.loadDiagnosticReport = report
                            self.loadError = report.rootCauseDescription
                            self.isLoading = false
                        }
                    } else {
                        await MainActor.run {
                            self.extractedTempDir = tempDir
                            self.extractedImageURLs = imageURLs
                            self.pageCount = imageURLs.count
                            self.isLoading = false
                            self.scanPageOrientations(resolvedURL: resolvedURL)
                        }
                    }
                } catch {
                    if let accessed = accessedURL { accessed.stopAccessingSecurityScopedResource() }
                    let report = DocumentOpenDiagnostics.logFailure(url: resolvedURL, pdf: pdf, error: error, context: "ComicReaderEngine")
                    await MainActor.run {
                        self.loadDiagnosticReport = report
                        self.loadError = report.rootCauseDescription
                        self.isLoading = false
                    }
                }
            }
        } else {
            let targetURL = LibraryFileRecord.resolveSandboxURL(pdf.url.absoluteString)
            Task.detached(priority: .userInitiated) { [weak self] in
                let resolvedURL: URL
                var accessedURL: URL? = nil
                if case .linked(let bm) = pdf.sourceMode,
                   let url = try? BookmarkResolver.shared.resolve(bm) {
                    let didAccess = url.startAccessingSecurityScopedResource()
                    resolvedURL = url
                    if didAccess { accessedURL = url }
                } else {
                    resolvedURL = targetURL
                }
                guard let archive = try? Archive(url: resolvedURL, accessMode: .read, pathEncoding: .utf8) else {
                    if let accessed = accessedURL { accessed.stopAccessingSecurityScopedResource() }
                    let report = DocumentOpenDiagnostics.logFailure(url: resolvedURL, pdf: pdf, error: nil, context: "ComicReaderEngine")
                    await MainActor.run { [weak self] in
                        self?.loadDiagnosticReport = report
                        self?.loadError = report.rootCauseDescription
                        self?.isLoading = false
                    }
                    return
                }
                
                let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "gif", "heic"]
                let sortedEntries = archive.filter { entry in
                    let path = entry.path
                    let name = (path as NSString).lastPathComponent
                    guard !path.contains("__MACOSX"), !name.hasPrefix("._"), name != ".DS_Store", !path.hasSuffix("/") else { return false }
                    let ext = (name as NSString).pathExtension.lowercased()
                    return imageExtensions.contains(ext)
                }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                
                let isEPUB = resolvedURL.pathExtension.lowercased() == "epub" || pdf.name.lowercased().hasSuffix(".epub")
                if sortedEntries.isEmpty || isEPUB {
                    if let accessed = accessedURL { accessed.stopAccessingSecurityScopedResource() }
                    if isEPUB {
                        Logger.shared.log("ComicReaderEngine: EPUB document detected in comic archive loader. Auto-switching to BookReader.", category: "Reader", type: .warning)
                        await MainActor.run {
                            NotificationCenter.default.post(name: NSNotification.Name("SwitchToBookReader"), object: nil)
                        }
                        return
                    }
                    let report = DocumentOpenDiagnostics.logFailure(url: resolvedURL, pdf: pdf, error: nil, context: "ComicReaderEngine")
                    await MainActor.run { [weak self] in
                        self?.loadDiagnosticReport = report
                        self?.loadError = report.rootCauseDescription
                        self?.isLoading = false
                    }
                    return
                }
                
                if let accessed = accessedURL {
                    if let self = self {
                        await MainActor.run { self.activelyAccessedURL = accessed }
                    } else {
                        accessed.stopAccessingSecurityScopedResource()
                    }
                }
                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    self.cbzURL = resolvedURL
                    self.entries = sortedEntries
                    self.pageCount = sortedEntries.count
                    self.isLoading = false
                    self.scanPageOrientations(resolvedURL: resolvedURL)
                }
            }
        }
    }
    
    deinit {
        for obs in notificationObservers {
            NotificationCenter.default.removeObserver(obs)
        }
        activelyAccessedURL?.stopAccessingSecurityScopedResource()
        if isPDF {
            Task.detached(priority: .background) { await PDFRenderActor.shared.clear() }
        }
        if let tempDir = extractedTempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        if let vTempDir = lastExtractedVirtualTempDir {
            try? FileManager.default.removeItem(at: vTempDir)
        }
        if !isPDF && !isStream && !isPreExtracted {
            Task.detached(priority: .background) { await ArchiveManager.shared.clearCache() }
        }
    }
    
    private func scanPageOrientations(resolvedURL: URL?) {
        let total = self.pageCount
        guard total > 0 else { return }
        
        self.isLandscapeArray = Array(repeating: false, count: total)
        
        let isPDF = self.isPDF
        let isPreExtracted = self.isPreExtracted
        let imageURLs = self.extractedImageURLs
        let pdfSourceMode = self.sourceMode
        
        let entryPaths = self.entries.map { $0.path }
        
        var resolvedPages: [(url: URL, localIndex: Int, sourceMode: SourceMode)] = []
        if let coordinator = self.virtualCoordinator {
            for i in 0..<total {
                if let resolved = coordinator.resolvePage(at: i) {
                    resolvedPages.append((url: resolved.file.url, localIndex: resolved.localPageIndex, sourceMode: resolved.file.sourceMode))
                }
            }
        }
        
        Task.detached(priority: .utility) { [weak self] in
            var array = Array(repeating: false, count: total)
            
            if isPDF, let resolved = resolvedURL {
                let accessing = resolved.startAccessingSecurityScopedResource()
                defer { if accessing { resolved.stopAccessingSecurityScopedResource() } }
                
                if let doc = PDFDocument(url: resolved) {
                    for i in 0..<min(total, doc.pageCount) {
                        if let page = doc.page(at: i) {
                            let bounds = page.bounds(for: .mediaBox)
                            array[i] = bounds.width > bounds.height * 1.1
                        }
                    }
                }
            } else if isPreExtracted {
                await withTaskGroup(of: (Int, Bool).self) { group in
                    for i in 0..<min(total, imageURLs.count) {
                        let url = imageURLs[i]
                        group.addTask {
                            if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                               let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
                                let wVal = properties[kCGImagePropertyPixelWidth] as? NSNumber
                                let hVal = properties[kCGImagePropertyPixelHeight] as? NSNumber
                                let w = CGFloat(wVal?.doubleValue ?? 0)
                                let h = CGFloat(hVal?.doubleValue ?? 0)
                                return (i, w > h * 1.1)
                            }
                            return (i, false)
                        }
                    }
                    for await (index, isL) in group {
                        array[index] = isL
                    }
                }
            } else if !resolvedPages.isEmpty {
                await withTaskGroup(of: (Int, Bool).self) { group in
                    for i in 0..<resolvedPages.count {
                        let pageInfo = resolvedPages[i]
                        group.addTask {
                            let fileURL: URL
                            let isLinked: Bool
                            if case .linked(let bm) = pageInfo.sourceMode,
                               let url = try? BookmarkResolver.shared.resolve(bm) {
                                fileURL = url
                                isLinked = true
                            } else {
                                fileURL = pageInfo.url
                                isLinked = false
                            }
                            
                            let accessing = isLinked ? fileURL.startAccessingSecurityScopedResource() : false
                            defer { if accessing { fileURL.stopAccessingSecurityScopedResource() } }
                            
                            let fileExt = fileURL.pathExtension.lowercased()
                            
                            if fileExt == "pdf" {
                                if let doc = PDFDocument(url: fileURL), pageInfo.localIndex < doc.pageCount,
                                   let page = doc.page(at: pageInfo.localIndex) {
                                    let bounds = page.bounds(for: .mediaBox)
                                    return (i, bounds.width > bounds.height * 1.1)
                                }
                            } else {
                                if let sortedPaths = try? await ArchiveManager.shared.getSortedImagePaths(for: fileURL) {
                                    if pageInfo.localIndex < sortedPaths.count {
                                        let entryPath = sortedPaths[pageInfo.localIndex]
                                        if let data = try? await ArchiveManager.shared.extractEntry(from: fileURL, path: entryPath),
                                           let source = CGImageSourceCreateWithData(data as CFData, nil),
                                           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
                                            let wVal = properties[kCGImagePropertyPixelWidth] as? NSNumber
                                            let hVal = properties[kCGImagePropertyPixelHeight] as? NSNumber
                                            let w = CGFloat(wVal?.doubleValue ?? 0)
                                            let h = CGFloat(hVal?.doubleValue ?? 0)
                                            return (i, w > h * 1.1)
                                        }
                                    }
                                }
                            }
                            return (i, false)
                        }
                    }
                    for await (index, isL) in group {
                        array[index] = isL
                    }
                }
            } else if let resolved = resolvedURL {
                let isLinked: Bool
                if case .linked = pdfSourceMode {
                    isLinked = true
                } else {
                    isLinked = false
                }
                
                let accessing = isLinked ? resolved.startAccessingSecurityScopedResource() : false
                defer { if accessing { resolved.stopAccessingSecurityScopedResource() } }
                
                await withTaskGroup(of: (Int, Bool).self) { group in
                    for i in 0..<min(total, entryPaths.count) {
                        let entryPath = entryPaths[i]
                        group.addTask {
                            do {
                                let data = try await ArchiveManager.shared.extractEntry(from: resolved, path: entryPath)
                                if let source = CGImageSourceCreateWithData(data as CFData, nil),
                                   let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
                                    let wVal = properties[kCGImagePropertyPixelWidth] as? NSNumber
                                    let hVal = properties[kCGImagePropertyPixelHeight] as? NSNumber
                                    let w = CGFloat(wVal?.doubleValue ?? 0)
                                    let h = CGFloat(hVal?.doubleValue ?? 0)
                                    return (i, w > h * 1.1)
                                }
                            } catch {
                                Logger.shared.log("ComicImageCache: Failed to inspect orientation for \(entryPath): \(error.localizedDescription)", category: "ComicEngine", type: .warning)
                            }
                            return (i, false)
                        }
                    }
                    for await (index, isL) in group {
                        array[index] = isL
                    }
                }
            }
            
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                self.objectWillChange.send()
                self.isLandscapeArray = array
                NotificationCenter.default.post(
                    name: NSNotification.Name("ComicImageCache.OrientationsScanned"),
                    object: self
                )
                self.prewarmThumbnails()
            }
        }
    }
    
    func setupCloudSource(_ source: CloudPageSource) {
        self.cloudPageSource = source
        self.pageCount = source.pageCount
        self.isLoading = false
    }
    func getThumbnailImage(at index: Int) -> UIImage? {
        guard index >= 0 && index < pageCount else { return nil }
        
        if let cachedImage = thumbnailCache.object(forKey: NSNumber(value: index)) {
            return cachedImage
        }
        
        if let fullImage = cache.object(forKey: NSNumber(value: index)) {
            let thumb = fullImage.preparingThumbnail(of: CGSize(width: 100, height: 150)) ?? fullImage
            thumbnailCache.setObject(thumb, forKey: NSNumber(value: index))
            return thumb
        }
        
        if isFetching(index) { return nil }
        
        if virtualCoordinator != nil {
            fetchVirtualThumbnailImageAsync(at: index)
        } else if !isStream {
            fetchLocalThumbnailImageAsync(at: index)
        }
        
        return nil
    }
    
    private func fetchLocalThumbnailImageAsync(at index: Int) {
        startFetching(index)
        
        let isPDF = self.isPDF
        let isPreExtracted = self.isPreExtracted
        let cbzURL = self.cbzURL
        let extractedImageURLs = self.extractedImageURLs
        let entryPath: String? = (index < entries.count) ? entries[index].path : nil
        
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 150)
        let scale: CGFloat = isPDF ? 0.15 : 1.0
        
        let task = Task.detached(priority: .utility) { [weak self] in
            guard let self = self else { return }
            
            let img = await ComicImageCache.extractOrRenderImageBackground(
                at: index,
                isPDF: isPDF,
                isPreExtracted: isPreExtracted,
                cbzURL: cbzURL,
                extractedImageURLs: extractedImageURLs,
                entryPath: entryPath,
                bounds: bounds,
                scale: scale
            )
            
            guard !Task.isCancelled else {
                await MainActor.run { [weak self] in
                    self?.stopFetching(index)
                    self?.removePrefetchTask(index)
                }
                return
            }
            
            if let img {
                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    self.thumbnailCache.setObject(img, forKey: NSNumber(value: index))
                    self.stopFetching(index)
                    self.removePrefetchTask(index)
                    NotificationCenter.default.post(
                        name: .comicImageCacheImageLoaded,
                        object: self,
                        userInfo: ["index": index, "isThumbnail": true]
                    )
                }
            } else {
                await MainActor.run { [weak self] in
                    self?.stopFetching(index)
                    self?.removePrefetchTask(index)
                }
            }
        }
        
        storePrefetchTask(task, for: index)
    }
    
    private func fetchVirtualThumbnailImageAsync(at index: Int) {
        guard let coordinator = self.virtualCoordinator,
              let resolved = coordinator.resolvePage(at: index) else { return }
        
        startFetching(index)
        
        let pdf = resolved.file
        let localPageIndex = resolved.localPageIndex
        
        let ext = pdf.url.pathExtension.lowercased()
        let isPDF = (ext == "pdf")
        let isCBRFile = (ext == "cbr" || ext == "rar")
        let isCBTFile = (ext == "cbt" || ext == "tar")
        let isPreExtracted = isCBRFile || isCBTFile
        
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 150)
        let scale: CGFloat = isPDF ? 0.15 : 1.0
        
        var cachedURL: URL? = nil
        if isPreExtracted {
            if pdf.url == self.lastExtractedVirtualURL {
                if localPageIndex < self.lastExtractedVirtualImageURLs.count {
                    cachedURL = self.lastExtractedVirtualImageURLs[localPageIndex]
                }
            }
        }
        
        let task = Task.detached(priority: .utility) { [weak self] in
            guard let self = self else { return }
            
            let resolvedURL: URL
            var accessedURL: URL? = nil
            if case .linked(let bm) = pdf.sourceMode,
               let url = try? BookmarkResolver.shared.resolve(bm) {
                let didAccess = url.startAccessingSecurityScopedResource()
                resolvedURL = url
                if didAccess { accessedURL = url }
            } else {
                resolvedURL = pdf.url
            }
            
            defer {
                accessedURL?.stopAccessingSecurityScopedResource()
            }
            
            guard !Task.isCancelled else {
                await MainActor.run { [weak self] in
                    self?.stopFetching(index)
                    self?.removePrefetchTask(index)
                }
                return
            }
            
            let img: UIImage?
            if isPDF {
                _ = await PDFRenderActor.shared.loadDocument(at: resolvedURL)
                img = await PDFRenderActor.shared.renderPage(at: localPageIndex, scale: scale)
            } else if isPreExtracted {
                if let cached = cachedURL {
                    img = autoreleasepool {
                        let srcOpts: [CFString: Any] = [kCGImageSourceShouldCache: false]
                        guard let source = CGImageSourceCreateWithURL(cached as CFURL, srcOpts as CFDictionary) else {
                            return UIImage(data: (try? Data(contentsOf: cached)) ?? Data())
                        }
                        let maxPixelSize = max(bounds.width, bounds.height) * scale
                        let downOpts: [CFString: Any] = [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceShouldCacheImmediately: true,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
                        ]
                        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, downOpts as CFDictionary) else {
                            return UIImage(data: (try? Data(contentsOf: cached)) ?? Data())
                        }
                        return UIImage(cgImage: cgImage)
                    }
                } else {
                    let (tempDir, imageURLs): (URL, [URL])
                    if isCBTFile {
                        (tempDir, imageURLs) = (try? await CBTExtractor.extract(from: resolvedURL)) ?? (FileManager.default.temporaryDirectory, [])
                    } else {
                        (tempDir, imageURLs) = (try? await CBRExtractor.extract(from: resolvedURL)) ?? (FileManager.default.temporaryDirectory, [])
                    }
                    
                    await MainActor.run { [weak self] in
                        guard let self = self else {
                            try? FileManager.default.removeItem(at: tempDir)
                            return
                        }
                        if let oldTemp = self.lastExtractedVirtualTempDir {
                            try? FileManager.default.removeItem(at: oldTemp)
                        }
                        self.lastExtractedVirtualURL = pdf.url
                        self.lastExtractedVirtualTempDir = tempDir
                        self.lastExtractedVirtualImageURLs = imageURLs
                    }
                    
                    if localPageIndex < imageURLs.count {
                        let imageURL = imageURLs[localPageIndex]
                        img = autoreleasepool {
                            let srcOpts: [CFString: Any] = [kCGImageSourceShouldCache: false]
                            guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, srcOpts as CFDictionary) else {
                                return UIImage(data: (try? Data(contentsOf: imageURL)) ?? Data())
                            }
                            let maxPixelSize = max(bounds.width, bounds.height) * scale
                            let downOpts: [CFString: Any] = [
                                kCGImageSourceCreateThumbnailFromImageAlways: true,
                                kCGImageSourceShouldCacheImmediately: true,
                                kCGImageSourceCreateThumbnailWithTransform: true,
                                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
                            ]
                            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, downOpts as CFDictionary) else {
                                return UIImage(data: (try? Data(contentsOf: imageURL)) ?? Data())
                            }
                            return UIImage(cgImage: cgImage)
                        }
                    } else {
                        img = nil
                    }
                }
            } else {
                do {
                    let sortedPaths = try await ArchiveManager.shared.getSortedImagePaths(for: resolvedURL)
                    if localPageIndex < sortedPaths.count {
                        let entryPath = sortedPaths[localPageIndex]
                        let data = try await ArchiveManager.shared.extractEntry(from: resolvedURL, path: entryPath)
                        img = autoreleasepool {
                            let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
                            guard let imageSource = CGImageSourceCreateWithData(data as CFData, options as CFDictionary) else {
                                return UIImage(data: data)
                            }
                            let maxPixelSize = max(bounds.width, bounds.height) * scale
                            let downsampleOptions: [CFString: Any] = [
                                kCGImageSourceCreateThumbnailFromImageAlways: true,
                                kCGImageSourceShouldCacheImmediately: true,
                                kCGImageSourceCreateThumbnailWithTransform: true,
                                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
                            ]
                            guard let downsampledImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, downsampleOptions as CFDictionary) else {
                                return UIImage(data: data)
                            }
                            return UIImage(cgImage: downsampledImage)
                        }
                    } else {
                        img = nil
                    }
                } catch {
                    img = nil
                }
            }
            
            guard !Task.isCancelled else {
                await MainActor.run { [weak self] in
                    self?.stopFetching(index)
                    self?.removePrefetchTask(index)
                }
                return
            }
            
            if let img {
                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    self.thumbnailCache.setObject(img, forKey: NSNumber(value: index))
                    self.stopFetching(index)
                    self.removePrefetchTask(index)
                    NotificationCenter.default.post(
                        name: .comicImageCacheImageLoaded,
                        object: self,
                        userInfo: ["index": index, "isThumbnail": true]
                    )
                }
            } else {
                await MainActor.run { [weak self] in
                    self?.stopFetching(index)
                    self?.removePrefetchTask(index)
                }
            }
        }
        
        storePrefetchTask(task, for: index)
    }
    
    func prewarmThumbnails() {
        let total = pageCount
        Task {
            guard total > 0 else { return }
            for i in 0..<total {
                if Task.isCancelled { break }
                if self.thumbnailCache.object(forKey: NSNumber(value: i)) == nil {
                    _ = self.getThumbnailImage(at: i)
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
            }
        }
    }
    
    func getImage(at index: Int) -> UIImage? {
        guard index >= 0 && index < pageCount else { return nil }
        
        if index != lastRequestedIndex {
            let isSibling = getSiblingIndex(for: index) == lastRequestedIndex
            if !isSibling {
                readingDirection = index > lastRequestedIndex ? 1 : -1
            }
            lastRequestedIndex = index
        }
        
        if let cachedImage = cache.object(forKey: NSNumber(value: index)) {
            updateLRUOnMain(index)
            return cachedImage
        }
        
        if isFetching(index) { return nil }
        
        if virtualCoordinator != nil {
            fetchVirtualImageAsync(at: index, priority: .userInitiated)
        } else if isStream && cloudPageSource != nil {
            fetchCloudPageImage(at: index, priority: .userInitiated)
        } else if !isStream {
            fetchLocalImageAsync(at: index, priority: .userInitiated)
        }
        
        prefetchSurrounding(index: index)
        return nil
    }
    
    func peekImageSize(at index: Int) -> CGSize? {
        guard index >= 0 && index < pageCount else { return nil }
        return cache.object(forKey: NSNumber(value: index))?.size
    }

    /// Non-mutating read of the memory cache for SwiftUI render passes
    func cachedImage(at index: Int) -> UIImage? {
        guard index >= 0 && index < pageCount else { return nil }
        return cache.object(forKey: NSNumber(value: index))
    }
    
    private func fetchVirtualImageAsync(at index: Int, priority: TaskPriority = .userInitiated) {
        guard let coordinator = self.virtualCoordinator,
              let resolved = coordinator.resolvePage(at: index) else { return }
        
        startFetching(index)
        
        let pdf = resolved.file
        let localPageIndex = resolved.localPageIndex
        
        let ext = pdf.url.pathExtension.lowercased()
        let isPDF = (ext == "pdf")
        let isCBRFile = (ext == "cbr" || ext == "rar")
        let isCBTFile = (ext == "cbt" || ext == "tar")
        let isPreExtracted = isCBRFile || isCBTFile
        
        let bounds = UIScreen.main.bounds
        let scale = UIScreen.main.scale
        
        // Check if we already have the extracted image URLs cached for this virtual source file
        var cachedURL: URL? = nil
        if isPreExtracted {
            if pdf.url == self.lastExtractedVirtualURL {
                if localPageIndex < self.lastExtractedVirtualImageURLs.count {
                    cachedURL = self.lastExtractedVirtualImageURLs[localPageIndex]
                }
            }
        }
        
        let task = Task.detached(priority: priority) { [weak self] in
            guard let self = self else { return }
            
            // Resolve external bookmark for linked files if needed
            let resolvedURL: URL
            var accessedURL: URL? = nil
            if case .linked(let bm) = pdf.sourceMode,
               let url = try? BookmarkResolver.shared.resolve(bm) {
                let didAccess = url.startAccessingSecurityScopedResource()
                resolvedURL = url
                if didAccess { accessedURL = url }
            } else {
                resolvedURL = pdf.url
            }
            
            defer {
                accessedURL?.stopAccessingSecurityScopedResource()
            }
            
            guard !Task.isCancelled else {
                await MainActor.run { [weak self] in
                    self?.stopFetching(index)
                    self?.removePrefetchTask(index)
                }
                return
            }
            
            let img: UIImage?
            if isPDF {
                _ = await PDFRenderActor.shared.loadDocument(at: resolvedURL)
                img = await PDFRenderActor.shared.renderPage(at: localPageIndex, scale: scale)
            } else if isPreExtracted {
                if let cached = cachedURL {
                    // Cache hit: read directly from the cached path
                    img = autoreleasepool {
                        let srcOpts: [CFString: Any] = [kCGImageSourceShouldCache: false]
                        guard let source = CGImageSourceCreateWithURL(cached as CFURL, srcOpts as CFDictionary) else {
                            return UIImage(data: (try? Data(contentsOf: cached)) ?? Data())
                        }
                        let maxPixelSize = max(bounds.width, bounds.height) * scale
                        let downOpts: [CFString: Any] = [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceShouldCacheImmediately: true,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
                        ]
                        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, downOpts as CFDictionary) else {
                            return UIImage(data: (try? Data(contentsOf: cached)) ?? Data())
                        }
                        return UIImage(cgImage: cgImage)
                    }
                } else {
                    // Cache miss: extract the archive and cache the resulting files on MainActor
                    let (tempDir, imageURLs): (URL, [URL])
                    if isCBTFile {
                        (tempDir, imageURLs) = (try? await CBTExtractor.extract(from: resolvedURL)) ?? (FileManager.default.temporaryDirectory, [])
                    } else {
                        (tempDir, imageURLs) = (try? await CBRExtractor.extract(from: resolvedURL)) ?? (FileManager.default.temporaryDirectory, [])
                    }
                    
                    await MainActor.run { [weak self] in
                        guard let self = self else {
                            try? FileManager.default.removeItem(at: tempDir)
                            return
                        }
                        if let oldTemp = self.lastExtractedVirtualTempDir {
                            try? FileManager.default.removeItem(at: oldTemp)
                        }
                        self.lastExtractedVirtualURL = pdf.url
                        self.lastExtractedVirtualTempDir = tempDir
                        self.lastExtractedVirtualImageURLs = imageURLs
                    }
                    
                    if localPageIndex < imageURLs.count {
                        let imageURL = imageURLs[localPageIndex]
                        img = autoreleasepool {
                            let srcOpts: [CFString: Any] = [kCGImageSourceShouldCache: false]
                            guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, srcOpts as CFDictionary) else {
                                return UIImage(data: (try? Data(contentsOf: imageURL)) ?? Data())
                            }
                            let maxPixelSize = max(bounds.width, bounds.height) * scale
                            let downOpts: [CFString: Any] = [
                                kCGImageSourceCreateThumbnailFromImageAlways: true,
                                kCGImageSourceShouldCacheImmediately: true,
                                kCGImageSourceCreateThumbnailWithTransform: true,
                                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
                            ]
                            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, downOpts as CFDictionary) else {
                                return UIImage(data: (try? Data(contentsOf: imageURL)) ?? Data())
                            }
                            return UIImage(cgImage: cgImage)
                        }
                    } else {
                        img = nil
                    }
                }
            } else {
                do {
                    let sortedPaths = try await ArchiveManager.shared.getSortedImagePaths(for: resolvedURL)
                    if localPageIndex < sortedPaths.count {
                        let entryPath = sortedPaths[localPageIndex]
                        let data = try await ArchiveManager.shared.extractEntry(from: resolvedURL, path: entryPath)
                        img = autoreleasepool {
                            let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
                            guard let imageSource = CGImageSourceCreateWithData(data as CFData, options as CFDictionary) else {
                                return UIImage(data: data)
                            }
                            let maxPixelSize = max(bounds.width, bounds.height) * scale
                            let downsampleOptions: [CFString: Any] = [
                                kCGImageSourceCreateThumbnailFromImageAlways: true,
                                kCGImageSourceShouldCacheImmediately: true,
                                kCGImageSourceCreateThumbnailWithTransform: true,
                                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
                            ]
                            guard let downsampledImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, downsampleOptions as CFDictionary) else {
                                return UIImage(data: data)
                            }
                            return UIImage(cgImage: downsampledImage)
                        }
                    } else {
                        img = nil
                    }
                } catch {
                    img = nil
                }
            }
            
            guard !Task.isCancelled else {
                await MainActor.run { [weak self] in
                    self?.stopFetching(index)
                    self?.removePrefetchTask(index)
                }
                return
            }
            
            if let img {
                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    let bitsPerPixel = img.cgImage?.bitsPerPixel ?? 32
                    let cost = Int(img.size.width * img.size.height * CGFloat(bitsPerPixel) / 8)
                    self.cache.setObject(img, forKey: NSNumber(value: index), cost: cost)
                    self.registerLoadedImageOrientation(at: index, size: img.size)
                    self.stopFetching(index)
                    self.updateLRUOnMain(index)
                    self.removePrefetchTask(index)
                    NotificationCenter.default.post(
                        name: .comicImageCacheImageLoaded,
                        object: self,
                        userInfo: ["index": index]
                    )
                }
            } else {
                await MainActor.run { [weak self] in
                    self?.stopFetching(index)
                    self?.removePrefetchTask(index)
                }
            }
        }
        
        storePrefetchTask(task, for: index)
    }
    
    private func fetchLocalImageAsync(at index: Int, priority: TaskPriority = .userInitiated) {
        startFetching(index)
        
        let isPDF = self.isPDF
        let isPreExtracted = self.isPreExtracted
        let cbzURL = self.cbzURL
        let extractedImageURLs = self.extractedImageURLs
        let entryPath: String? = (index < entries.count) ? entries[index].path : nil
        let bounds = UIScreen.main.bounds
        let scale = UIScreen.main.scale
        
        let task = Task.detached(priority: priority) { [weak self] in
            guard let self = self else { return }
            
            let img = await ComicImageCache.extractOrRenderImageBackground(
                at: index,
                isPDF: isPDF,
                isPreExtracted: isPreExtracted,
                cbzURL: cbzURL,
                extractedImageURLs: extractedImageURLs,
                entryPath: entryPath,
                bounds: bounds,
                scale: scale
            )
            
            guard !Task.isCancelled else {
                await MainActor.run { [weak self] in
                    self?.stopFetching(index)
                    self?.removePrefetchTask(index)
                }
                return
            }
            
            if let img {
                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    let bitsPerPixel = img.cgImage?.bitsPerPixel ?? 32
                    let cost = Int(img.size.width * img.size.height * CGFloat(bitsPerPixel) / 8)
                    self.cache.setObject(img, forKey: NSNumber(value: index), cost: cost)
                    self.registerLoadedImageOrientation(at: index, size: img.size)
                    self.stopFetching(index)
                    self.updateLRUOnMain(index)
                    self.removePrefetchTask(index)
                    NotificationCenter.default.post(
                        name: .comicImageCacheImageLoaded,
                        object: self,
                        userInfo: ["index": index]
                    )
                }
            } else {
                await MainActor.run { [weak self] in
                    self?.stopFetching(index)
                    self?.removePrefetchTask(index)
                }
            }
        }
        
        storePrefetchTask(task, for: index)
    }
    
    private func updateLRUOnMain(_ index: Int) {
        if let pos = accessQueue.firstIndex(of: index) {
            accessQueue.remove(at: pos)
        }
        accessQueue.append(index)

        while accessQueue.count > maxCacheSize {
            let evictIndex = accessQueue.removeFirst()
            cache.removeObject(forKey: NSNumber(value: evictIndex))
        }
    }
    
    private static func extractOrRenderImageBackground(
        at index: Int,
        isPDF: Bool,
        isPreExtracted: Bool,
        cbzURL: URL?,
        extractedImageURLs: [URL],
        entryPath: String?,
        bounds: CGRect,
        scale: CGFloat
    ) async -> UIImage? {
        if isPDF {
            return await PDFRenderActor.shared.renderPage(at: index, scale: scale)
        } else if isPreExtracted {
            guard index < extractedImageURLs.count else { return nil }
            let imageURL = extractedImageURLs[index]
            return autoreleasepool {
                let srcOpts: [CFString: Any] = [kCGImageSourceShouldCache: false]
                guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, srcOpts as CFDictionary) else {
                    return UIImage(data: (try? Data(contentsOf: imageURL)) ?? Data())
                }
                let maxPixelSize = max(bounds.width, bounds.height) * scale
                let downOpts: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
                ]
                guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, downOpts as CFDictionary) else {
                    return UIImage(data: (try? Data(contentsOf: imageURL)) ?? Data())
                }
                return UIImage(cgImage: cgImage)
            }
        } else {
            guard let url = cbzURL, let path = entryPath else { return nil }
            do {
                let data = try await ArchiveManager.shared.extractEntry(from: url, path: path)
                return autoreleasepool {
                    let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
                    guard let imageSource = CGImageSourceCreateWithData(data as CFData, options as CFDictionary) else {
                        return UIImage(data: data)
                    }
                    
                    let maxPixelSize = max(bounds.width, bounds.height) * scale
                    let downsampleOptions: [CFString: Any] = [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceShouldCacheImmediately: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
                    ]
                    
                    guard let downsampledImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, downsampleOptions as CFDictionary) else {
                        return UIImage(data: data)
                    }
                    
                    return UIImage(cgImage: downsampledImage)
                }
            } catch {
                return nil
            }
        }
    }
    
        func registerLoadedImageOrientation(at index: Int, size: CGSize) {
            let isL = size.width > size.height * 1.1
            if index >= 0 && index < isLandscapeArray.count {
                if isLandscapeArray[index] != isL {
                    objectWillChange.send()
                    isLandscapeArray[index] = isL
                }
            }
        }

        private func isPageLandscape(_ idx: Int, landscapeArray: [Bool]) -> Bool {
            if idx >= 0 && idx < landscapeArray.count && landscapeArray[idx] {
                return true
            }
            if let size = peekImageSize(at: idx), size.width > size.height * 1.1 {
                return true
            }
            return false
        }

        func computeSpreads() -> [[Int]] {
            var allSpreads: [[Int]] = []
            let landscapeArray = self.isLandscapeArray
            let totalPages = self.pageCount
            guard totalPages > 0 else { return [] }

            var i = 0
            while i < totalPages {
                let isL = isPageLandscape(i, landscapeArray: landscapeArray)
                if isL {
                    allSpreads.append([i])
                    i += 1
                } else {
                    if i + 1 < totalPages {
                        let nextIsL = isPageLandscape(i + 1, landscapeArray: landscapeArray)
                        if nextIsL {
                            allSpreads.append([i])
                            i += 1
                        } else {
                            allSpreads.append([i, i + 1])
                            i += 2
                        }
                    } else {
                        allSpreads.append([i])
                        i += 1
                    }
                }
            }
            return allSpreads
        }
    
    private func getSiblingIndex(for index: Int) -> Int? {
        guard index >= 0 && index < pageCount else { return nil }
        
        let spreads = computeSpreads()
        for spread in spreads {
            if spread.contains(index) {
                if spread.count == 2 {
                    return spread[0] == index ? spread[1] : spread[0]
                }
                break
            }
        }
        return nil
    }
    
    private func prefetchSurrounding(index: Int) {
        guard !isPrefetching else { return }
        guard pageCount > 0 else { return }
        isPrefetching = true
        defer { isPrefetching = false }

        let direction = readingDirection
        let cacheCap = maxCacheSize
        
        // Dynamic look-ahead factor based on reading velocity
        let velocityAheadFactor: Int
        if averageSecondsPerPage < 4.0 {
            velocityAheadFactor = 2 // Skimming fast: prefetch 2 extra pages ahead
        } else if averageSecondsPerPage > 15.0 {
            velocityAheadFactor = -1 // Reading slow: prefetch 1 fewer page ahead
        } else {
            velocityAheadFactor = 0
        }
        
        // Base prefetch sizes based on memory capacity
        let baseAhead = cacheCap >= 7 ? 4 : (cacheCap >= 5 ? 3 : 2)
        let baseBehind = cacheCap >= 7 ? 2 : (cacheCap >= 5 ? 1 : 0)
        
        // Final bounds clamped safely
        let targetAhead = max(2, min(8, baseAhead + velocityAheadFactor))
        let targetBehind = max(0, baseBehind)
        
        var prefetchIndices: Set<Int> = []
        if direction >= 0 {
            // Forward movement: prefetch pages ahead, pages behind
            let aheadCount = max(1, targetAhead)
            for i in 1...aheadCount {
                prefetchIndices.insert(index + i)
            }
            if targetBehind > 0 {
                for i in 1...targetBehind {
                    if index - i >= 0 { prefetchIndices.insert(index - i) }
                }
            }
        } else {
            // Backward movement: prefetch pages behind (reverse), pages ahead
            for i in 1...5 {
                if index - i >= 0 { prefetchIndices.insert(index - i) }
            }
            for i in 1...2 {
                if index + i < pageCount { prefetchIndices.insert(index + i) }
            }
        }
        
        // Cancel tasks that are no longer in the active prefetch window safely by snapshotting keys
        let siblingIndex = getSiblingIndex(for: index)
        let keysToCheck = Array(inFlightPrefetchTasks.keys)
        for idx in keysToCheck {
            if !prefetchIndices.contains(idx) && idx != index && idx != siblingIndex {
                if let task = inFlightPrefetchTasks.removeValue(forKey: idx) {
                    task.cancel()
                    stopFetching(idx)
                }
            }
        }
        
        // Filter out of bounds and trigger prefetch
        for i in prefetchIndices {
            guard i >= 0 && i < pageCount else { continue }
            if self.cache.object(forKey: NSNumber(value: i)) == nil && !self.isFetching(i) {
                if isStream {
                    fetchCloudPageImage(at: i, priority: .utility)
                } else {
                    fetchLocalImageAsync(at: i, priority: .utility)
                }
            }
        }
    }

    private func fetchCloudPageImage(at index: Int, priority: TaskPriority = .userInitiated) {
        guard let source = cloudPageSource, index < source.pages.count else { return }
        startFetching(index)
        let entry = source.pages[index]
        let manifest = source.manifest

        let bounds = UIScreen.main.bounds
        let scale = UIScreen.main.scale
        let maxPixelSize = max(bounds.width, bounds.height) * scale

        let task = Task.detached(priority: priority) { [weak self] in
            guard let self else { return }
            do {
                let data = try await ZipCentralDirectory.fetchEntryData(entry: entry, manifest: manifest)
                
                guard !Task.isCancelled else {
                    await MainActor.run { [weak self] in
                        self?.stopFetching(index)
                        self?.removePrefetchTask(index)
                    }
                    return
                }
                
                guard let image = Self.decodeImageData(data, maxPixelSize: maxPixelSize) else {
                    await MainActor.run { [weak self] in
                        self?.stopFetching(index)
                        self?.removePrefetchTask(index)
                    }
                    return
                }
                
                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    let bitsPerPixel = image.cgImage?.bitsPerPixel ?? 32
                    let cost = Int(image.size.width * image.size.height * CGFloat(bitsPerPixel) / 8)
                    self.cache.setObject(image, forKey: NSNumber(value: index), cost: cost)
                    self.stopFetching(index)
                    self.updateLRUOnMain(index)
                    self.removePrefetchTask(index)
                    NotificationCenter.default.post(
                        name: .comicImageCacheImageLoaded,
                        object: self,
                        userInfo: ["index": index]
                    )
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.stopFetching(index)
                    self?.removePrefetchTask(index)
                }
            }
        }
        
        storePrefetchTask(task, for: index)
    }

    private static nonisolated func decodeImageData(_ data: Data, maxPixelSize: CGFloat) -> UIImage? {
        return autoreleasepool {
            let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
            guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else {
                return UIImage(data: data)
            }
            let downsampleOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions as CFDictionary) else {
                return UIImage(data: data)
            }
            return UIImage(cgImage: cgImage)
        }
    }
}

struct ComicReaderEngine: View {
    @EnvironmentObject var manager: ConversionManager
    let pdf: ConvertedPDF
    var onDismiss: () -> Void
    /// All library books — used to auto-advance to the next volume at series end.
    var allBooks: [ConvertedPDF] = []
    
    @Environment(\.horizontalSizeClass) private var hSizeClass
    private var brightnessZoneWidth: CGFloat {
        hSizeClass == .regular ? 60 : 20
    }
    
    @EnvironmentObject var conversionManager: ConversionManager
    @ObservedObject private var prefs = EBookPreferences.shared
    
    @StateObject private var cache: ComicImageCache
    @StateObject private var velocityEngine = ReaderVelocityEngine()
    @State private var pageEntryTime = Date()
    @State private var maxPageIndexVisited = 0
    @AppStorage("isAutoCropEnabled") private var isAutoCropEnabled = false
    @AppStorage("hasSeenReaderOnboarding") private var hasSeenReaderOnboarding = false
    @State private var chromeVisible = false
    @State private var currentIndex: Int = 0
    @State private var showJumpToPage = false
    @State private var jumpToPageText = ""
    @State private var sessionStartTime: Date? = nil
    @State private var readingMode: ComicReadingMode = .pageHorizontal
    @State private var lastPageTurnReadingMode: ComicReadingMode = .pageHorizontal
    @AppStorage("prefersTwoUpSpreads") private var prefersTwoUpSpreads = true
    @State private var activeFilterPreset: ReadingFilterPreset = .original
    @State private var showingFilterHUD = false
    @State private var showingSettingsHUD = false
    @AppStorage("essentialReaderMode") private var essentialReaderMode = false
    @AppStorage("backTapEnabled") private var backTapEnabled = false
    @State private var lastBrightnessDragValue: CGFloat = 0
    /// Panels-style ambient chrome tint — sampled from the current page edges
    @State private var ambientPageColor: Color = .clear
    /// Tracks in-flight ambient colour extraction so it can be cancelled on rapid page swipes.
    @State private var ambientColorTask: Task<Void, Never>? = nil
    /// AI Dialogue Lens Layout-aware OCR Engine
    @StateObject private var narrationEngine = PageOCREngine()
    /// On-device Comic Dialogue Speech Narration Engine
    @StateObject private var speechEngine = ComicDialogueSpeechEngine.shared
    /// Cooldown timer to prevent double-tap bouncing when toggling panel navigation
    @State private var lastGuidedToggleTime: Date = .distantPast
    
    /// SwiftData context
    @Environment(\.modelContext) private var modelContext
    

    
    /// Custom Toast messages
    @State private var showToast = false
    @State private var toastMessage = ""
    
    /// Study Notebook and Highlights State
    @State private var showAnnotations = false
    @State private var activeHighlightToEdit: SDAnnotation? = nil
    @State private var showCropAdjustmentSheet = false
    
    /// Focus state for Magic Keyboard navigation
    @FocusState private var isReaderFocused: Bool
    
    /// AI Dialogue Lens State
    @State private var isDialogueLensEnabled = false
    @State private var selectedTextBlock: TextBlock? = nil
    @State private var currentDialogueBlocks: [TextBlock] = []
    @State private var isDialogueOCRing = false
    @State private var dialogueOCRTask: Task<Void, Never>? = nil
    /// Phase 4A: Auto-hide chrome — cancellable idle timer.
    @State private var chromeIdleTask: Task<Void, Never>? = nil
    
    var isMangaComic: Bool {
        pdf.metadata.isManga == true || pdf.contentType == .manga
    }

    var isMangaActive: Bool {
        isMangaComic || readingMode == .mangaRTL || lastPageTurnReadingMode == .mangaRTL
    }
    
    func shouldShowTwoUpSpread(for size: CGSize) -> Bool {
        let isLandscape = size.width > size.height
        if UIDevice.current.userInterfaceIdiom == .phone && !isLandscape {
            return false
        }
        let pdfDual = EBookPreferences.shared.pdfDualPage || (EBookPreferences.shared.autoLandscapeDualPage && isLandscape)
        let isDual = prefersTwoUpSpreads || pdfDual
        guard isDual else { return false }
        guard readingMode == .pageHorizontal || readingMode == .mangaRTL || readingMode == .panelNavigation else { return false }
        return true
    }

    private var isCurrentlyTwoUp: Bool {
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            let isLandscape = windowScene.interfaceOrientation.isLandscape
            if UIDevice.current.userInterfaceIdiom == .phone && !isLandscape {
                return false
            }
            let pdfDual = EBookPreferences.shared.pdfDualPage || (EBookPreferences.shared.autoLandscapeDualPage && isLandscape)
            let isDual = prefersTwoUpSpreads || pdfDual
            guard isDual else { return false }
            guard readingMode == .pageHorizontal || readingMode == .mangaRTL || readingMode == .panelNavigation else { return false }
            return true
        }
        return false
    }

    private func isPageLandscape(_ idx: Int, landscapeArray: [Bool]) -> Bool {
        if idx >= 0 && idx < landscapeArray.count && landscapeArray[idx] {
            return true
        }
        if let size = cache.peekImageSize(at: idx), size.width > size.height * 1.1 {
            return true
        }
        return false
    }

    private func computeSpreads() -> [[Int]] {
        var allSpreads: [[Int]] = []
        let landscapeArray = cache.isLandscapeArray
        let pageCount = cache.pageCount

        var i = 0
        while i < pageCount {
            let isL = isPageLandscape(i, landscapeArray: landscapeArray)
            if isL {
                allSpreads.append([i])
                i += 1
            } else {
                if i + 1 < pageCount {
                    let nextIsL = isPageLandscape(i + 1, landscapeArray: landscapeArray)
                    if nextIsL {
                        allSpreads.append([i])
                        i += 1
                    } else {
                        allSpreads.append([i, i + 1])
                        i += 2
                    }
                } else {
                    allSpreads.append([i])
                    i += 1
                }
            }
        }
        return allSpreads
    }
    
    init(pdf: ConvertedPDF, onDismiss: @escaping () -> Void, allBooks: [ConvertedPDF] = []) {
        self.pdf = pdf
        self.onDismiss = onDismiss
        self.allBooks = allBooks
        self._cache = StateObject(wrappedValue: ComicImageCache(
            pdf: pdf,
            prefetchLimit: AppSettingsManager.shared.conversionSettings.readingPrefetchLimit
        ))
        let isMangaComic = pdf.metadata.isManga == true || pdf.contentType == .manga
        let defaultMode: ComicReadingMode = isMangaComic ? .mangaRTL : .pageHorizontal
        self._readingMode = State(initialValue: defaultMode)
        self._lastPageTurnReadingMode = State(initialValue: defaultMode)
    }

    var body: some View {
        GeometryReader { geo in
        ZStack {
            Color.black.ignoresSafeArea()

            if let report = cache.loadDiagnosticReport {
                DocumentOpenErrorView(
                    report: report,
                    onRetry: nil,
                    onDismiss: { onDismiss() }
                )
            } else if let error = cache.loadError {
                // ── Failed file: show error + escape hatch ─────────────────────
                VStack(spacing: 24) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(.orange)

                    Text("Couldn't Open File")
                        .font(.title2.bold())
                        .foregroundColor(.white)

                    Text(error)
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.65))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)

                    HStack(spacing: 12) {
                        let isEPUB = pdf.url.pathExtension.lowercased() == "epub" || pdf.name.lowercased().hasSuffix(".epub")
                        if isEPUB {
                            Button {
                                NotificationCenter.default.post(name: NSNotification.Name("SwitchToBookReader"), object: nil)
                            } label: {
                                Label("Open in Book Reader", systemImage: "book.fill")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(.black)
                                    .padding(.horizontal, 22)
                                    .padding(.vertical, 12)
                                    .background(Color.inkGreen, in: Capsule())
                            }
                        }
                        
                        Button { onDismiss() } label: {
                            Label("Close Reader", systemImage: "xmark.circle.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(isEPUB ? .white : .black)
                                .padding(.horizontal, 22)
                                .padding(.vertical, 12)
                                .background(isEPUB ? Color.white.opacity(0.15) : Color.white, in: Capsule())
                        }
                    }
                    .padding(.top, 8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            } else if cache.isLoading {
                ProgressView("Loading Comic...")
                    .foregroundColor(.white)
            } else {
                Group {
                    if readingMode == .webtoonScroll {
                        webtoonView
                    } else if readingMode == .panelNavigation {
                        guidedView(for: geo.size)
                    } else if shouldShowTwoUpSpread(for: geo.size) {
                        twoUpView
                    } else {
                        BookPager(
                            currentIndex: $currentIndex,
                            totalPages: cache.pageCount,
                            cache: cache,
                            readingMode: readingMode,
                            activeFilterPreset: activeFilterPreset,
                            isMangaRTL: isMangaActive,
                            onChromeTap: {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                    chromeVisible.toggle()
                                }
                                chromeIdleTask?.cancel()
                                NotificationCenter.default.post(name: NSNotification.Name("Reader_ForceKeyFocus"), object: nil)
                            },
                            onFlipPastEnd: { attemptComicSeriesContinuation() }
                        )
                    }
                }
                .ignoresSafeArea()
                .overlay {
                    if isDialogueLensEnabled {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { location in
                                handleDialogueLensTap(at: location, in: geo.size)
                            }
                            .ignoresSafeArea()
                    }
                }
            }

            brightnessZones
            readerChromeView
            filterHUDView
            settingsHUDView
            achievementToastView
            
            if !chromeVisible {
                KindleProgressFooterView(
                    currentPage: currentIndex + 1,
                    totalPages: max(1, cache.pageCount),
                    estimatedMinutesLeft: ReaderProgressTracker.shared.progress(for: pdf.id)?.estimatedMinutesRemaining
                )
                .transition(.opacity)
            }
            
            // Dialogue Lens HUD and Loading indicators
            dialogueHUDView
            
            // Spatial Speech Bubble Tracker Highlight
            if let activeBlock = speechEngine.activeBlock, let image = cache.getImage(at: currentIndex) {
                let rect = screenRect(for: activeBlock.boundingBox, in: geo.size, imageSize: image.size)
                if rect.width > 0 && rect.height > 0 {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [Color.purple, Color.cyan],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 3
                        )
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.purple.opacity(0.12))
                        )
                        .shadow(color: Color.purple.opacity(0.7), radius: 10)
                        .frame(width: max(24, rect.width + 12), height: max(24, rect.height + 12))
                        .position(x: rect.midX, y: rect.midY)
                        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: activeBlock.id)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                        .zIndex(15)
                }
            }

            // Floating Non-Blocking Speech Narration HUD
            if speechEngine.isActive {
                VStack {
                    Spacer()
                    ComicSpeechHUDView(engine: speechEngine) {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            speechEngine.stop()
                        }
                    }
                    .padding(.bottom, chromeVisible ? 140 : 44)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(30)
            }
            
            if showToast {
                Text(toastMessage)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
                    .padding(.bottom, 110)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(100)
            }
            
            if isDialogueLensEnabled && isDialogueOCRing {
                VStack {
                    HStack(spacing: 8) {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .purple))
                            .scaleEffect(0.8)
                        Text("Scanning text...")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundColor(.purple)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 0.5))
                    .padding(.top, 70)
                    Spacer()
                }
                .allowsHitTesting(false)
                .transition(.opacity)
                .zIndex(18)
            }
            
            KeyCommandHandler { command in
                let input = command.input
                if input == UIKeyCommand.inputLeftArrow {
                    if isMangaActive {
                        nextPage()
                    } else {
                        prevPage()
                    }
                } else if input == UIKeyCommand.inputRightArrow {
                    if isMangaActive {
                        prevPage()
                    } else {
                        nextPage()
                    }
                } else if input == " " {
                    nextPage()
                } else if input == "\u{1B}" {
                    saveProgressAndDismiss()
                }
            }
            .frame(width: 1, height: 1)
            .opacity(0.01)
            
            if !hasSeenReaderOnboarding {
                readerOnboardingOverlay
            }

            ReadingJumpToastOverlay()
        }
        .overlay { if prefs.showReadingRuler { ReadingRulerOverlay() } }
        .onAppear {
            pageEntryTime = Date()
            if sessionStartTime == nil {
                sessionStartTime = Date()
            }
            if let saved = ReaderProgressTracker.shared.progress(for: pdf.id) {
                currentIndex = saved.currentPageIndex
                if let filterString = saved.colorFilter,
                   let filterPreset = ReadingFilterPreset(rawValue: filterString) {
                    activeFilterPreset = filterPreset
                }
                if let prefersManga = saved.prefersMangaMode {
                    readingMode = prefersManga ? .mangaRTL : .pageHorizontal
                    lastPageTurnReadingMode = readingMode
                } else {
                    readingMode = isMangaComic ? .mangaRTL : .pageHorizontal
                    lastPageTurnReadingMode = readingMode
                }
                if let wasDual = saved.wasInDualPageMode {
                    prefersTwoUpSpreads = wasDual
                }
            } else {
                let isMangaComic = pdf.metadata.isManga == true || pdf.contentType == .manga
                if isMangaComic {
                    readingMode = .mangaRTL
                    lastPageTurnReadingMode = .mangaRTL
                }
            }
            // Connect OCR engine to the reader's image cache
            narrationEngine.connect(totalPages: cache.pageCount) { [cache] index in
                cache.getImage(at: index)
            }
            if essentialReaderMode {
                ambientPageColor = .clear
            }
            BackTapManager.shared.isEnabled = backTapEnabled
            maxPageIndexVisited = currentIndex
            NotificationCenter.default.post(name: NSNotification.Name("Reader_ForceKeyFocus"), object: nil)
            isReaderFocused = true
        }
        .onDisappear {
            speechEngine.stop()
        }
        .onChange(of: currentIndex) { oldIndex, newIndex in
            if speechEngine.isActive && speechEngine.activePageIndex != newIndex {
                speechEngine.stop()
            }
            let elapsed = Date().timeIntervalSince(pageEntryTime)
            pageEntryTime = Date()
            if newIndex > maxPageIndexVisited {
                maxPageIndexVisited = newIndex
                let remainingPages = max(0, cache.pageCount - 1 - newIndex)
                velocityEngine.recordPageDuration(elapsed, remainingPages: remainingPages)
            }
            if let avgSpeed = velocityEngine.averageDuration {
                cache.updateReadingVelocity(secondsPerPage: avgSpeed)
            }
            NotificationCenter.default.post(name: NSNotification.Name("Reader_ForceKeyFocus"), object: nil)

            // Panels-style ambient colour — sample edge pixels on page change
            extractAmbientColor(for: newIndex)
            if isDialogueLensEnabled {
                selectedTextBlock = nil
                dialogueOCRTask?.cancel()
                dialogueOCRTask = Task {
                    // Debounce by 250ms to allow fast swiping without triggering heavy OCR tasks
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    guard !Task.isCancelled else { return }
                    await prewarmOCR(for: newIndex)
                }
            }
        }
        .onChange(of: essentialReaderMode) { _, isSpeed in
            if isSpeed {
                ambientPageColor = .clear
            } else {
                let isMangaComic = pdf.metadata.isManga == true || pdf.contentType == .manga
                readingMode = isMangaComic ? .mangaRTL : .pageHorizontal
                extractAmbientColor(for: currentIndex)
            }
        }

        // ✅ Phase 5: Apple Handoff (Reader State Sync)
        .userActivity("com.inksync.read", isActive: true) { activity in
            activity.title = "Reading \(pdf.name)"
            activity.isEligibleForHandoff = true
            activity.addUserInfoEntries(from: [
                "pdfID": pdf.id.uuidString,
                "pageIndex": currentIndex
            ])
            // Also notify local Watch/Mac companion apps if built in the future
            activity.becomeCurrent()
        }
        .onChange(of: readingMode) { _, newMode in
            if newMode == .mangaRTL || newMode == .pageHorizontal {
                lastPageTurnReadingMode = newMode
            }
            if newMode == .mangaRTL {
                if let idx = conversionManager.convertedPDFs.firstIndex(where: { $0.id == pdf.id }) {
                    conversionManager.convertedPDFs[idx].metadata.isManga = true
                    conversionManager.saveLibrary()
                }
            } else if newMode == .pageHorizontal {
                if let idx = conversionManager.convertedPDFs.firstIndex(where: { $0.id == pdf.id }) {
                    conversionManager.convertedPDFs[idx].metadata.isManga = false
                    conversionManager.saveLibrary()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ComicReader_ToggleGuidedInspection"))) { _ in
            let now = Date()
            guard now.timeIntervalSince(lastGuidedToggleTime) > 0.35 else { return }
            lastGuidedToggleTime = now
            HapticEngine.medium()
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                if readingMode == .panelNavigation {
                    let targetMode: ComicReadingMode
                    if lastPageTurnReadingMode != .panelNavigation && lastPageTurnReadingMode != .webtoonScroll {
                        targetMode = lastPageTurnReadingMode
                    } else {
                        targetMode = isMangaActive ? .mangaRTL : .pageHorizontal
                    }
                    readingMode = targetMode
                } else {
                    if readingMode == .mangaRTL || readingMode == .pageHorizontal {
                        lastPageTurnReadingMode = readingMode
                    }
                    readingMode = .panelNavigation
                }
            }
        }

        .sheet(item: $activeHighlightToEdit) { annotation in
            AnnotationEditSheet(annotation: annotation)
                .presentationDetents([.height(180), .medium])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showCropAdjustmentSheet) {
            ProCropAdjustmentSheet(
                pdfID: pdf.id,
                pdfDocument: (cache.isPDF ? PDFDocument(url: pdf.url) : nil),
                sourceImage: cache.getImage(at: currentIndex),
                currentPageIndex: currentIndex,
                onApplyCrop: { insets in
                    NotificationCenter.default.post(
                        name: NSNotification.Name("Reader_CropInsetsChanged"),
                        object: insets
                    )
                },
                onDismiss: { showCropAdjustmentSheet = false }
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .openManualCropEditor)) { _ in
            showCropAdjustmentSheet = true
        }
        .onDisappear {
            BackTapManager.shared.isEnabled = false
            cache.cancelAllPrefetchTasks()
            saveCurrentProgress()
        }
        .onReceive(NotificationCenter.default.publisher(for: .readerJumpToPage)) { notification in
            if let pageIndex = notification.userInfo?["pageIndex"] as? Int, pageIndex >= 0, pageIndex < cache.pageCount {
                let fromPage = currentIndex
                if abs(pageIndex - fromPage) > 1 {
                    ReadingJumpTracker.shared.recordJump(fromPage: fromPage, toPage: pageIndex) {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            currentIndex = fromPage
                        }
                    }
                }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    currentIndex = pageIndex
                }
            }
        }
        .onChange(of: backTapEnabled) { _, newValue in
            BackTapManager.shared.isEnabled = newValue
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("Reader_NextPage"))) { _ in
            nextPage()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("Reader_PrevPage"))) { _ in
            prevPage()
        }
        .onReceive(NotificationCenter.default.publisher(for: .comicImageCacheImageLoaded)) { notification in
            guard let userInfo = notification.userInfo,
                  let loadedIndex = userInfo["index"] as? Int,
                  loadedIndex == currentIndex else { return }
            extractAmbientColor(for: currentIndex)
        }
        .preferredColorScheme(.dark)
        .focusable()
        .focused($isReaderFocused)
        .focusEffectDisabled()
        .alert("Go to Page", isPresented: $showJumpToPage) {
            TextField("Page number (1-\(cache.pageCount))", text: $jumpToPageText)
                .keyboardType(.numberPad)
            Button("Cancel", role: .cancel) { }
            Button("Go") {
                if let pageNum = Int(jumpToPageText), pageNum >= 1 && pageNum <= cache.pageCount {
                    let targetIdx = pageNum - 1
                    let fromPage = currentIndex
                    if abs(targetIdx - fromPage) > 1 {
                        ReadingJumpTracker.shared.recordJump(fromPage: fromPage, toPage: targetIdx) {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                currentIndex = fromPage
                            }
                        }
                    }
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        currentIndex = targetIdx
                    }
                }
            }
        } message: {
            Text("Enter a page number between 1 and \(cache.pageCount).")
        }
        .onKeyPress(.leftArrow) {
            if isMangaComic || readingMode == .mangaRTL {
                nextPage()
            } else {
                prevPage()
            }
            return .handled
        }
        .onKeyPress(.rightArrow) {
            if isMangaComic || readingMode == .mangaRTL {
                prevPage()
            } else {
                nextPage()
            }
            return .handled
        }
        .onKeyPress(.space) {
            nextPage()
            return .handled
        }
        .onKeyPress(.escape) {
            saveProgressAndDismiss()
            return .handled
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ReaderAdvancePageForward"))) { _ in
            if isMangaComic || readingMode == .mangaRTL {
                prevPage()
            } else {
                nextPage()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ReaderAdvancePageBackward"))) { _ in
            if isMangaComic || readingMode == .mangaRTL {
                nextPage()
            } else {
                prevPage()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ReaderToggleMarkupMode"))) { _ in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                isDialogueLensEnabled.toggle()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ReaderToggleSidebar"))) { _ in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                showAnnotations.toggle()
            }
        }
        .ignoresSafeArea()
    } // closes GeometryReader
} // end body

    @ViewBuilder
    private func guidedView(for size: CGSize) -> some View {
        let isTwoUp = shouldShowTwoUpSpread(for: size)
        let spreads = isTwoUp ? computeSpreads() : (0..<cache.pageCount).map { [$0] }
        let activeSpreadIndex = spreads.firstIndex(where: { $0.contains(currentIndex) }) ?? 0
        let currentSpread = (activeSpreadIndex < spreads.count) ? spreads[activeSpreadIndex] : [currentIndex]

        ComicSpreadGuidedView(
            spread: currentSpread,
            cache: cache,
            pdf: pdf,
            masterIndex: $currentIndex,
            spreads: spreads,
            activeFilterPreset: activeFilterPreset,
            isMangaMode: isMangaActive,
            isChromeVisible: chromeVisible,
            onTapChrome: { chromeVisible.toggle() },
            onToggleReadingMode: {
                let now = Date()
                guard now.timeIntervalSince(lastGuidedToggleTime) > 0.35 else { return }
                lastGuidedToggleTime = now
                HapticEngine.medium()
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    let targetMode: ComicReadingMode
                    if lastPageTurnReadingMode != .panelNavigation && lastPageTurnReadingMode != .webtoonScroll {
                        targetMode = lastPageTurnReadingMode
                    } else {
                        targetMode = isMangaActive ? .mangaRTL : .pageHorizontal
                    }
                    readingMode = targetMode
                }
            }
        )
        .id("guided_spread_\(activeSpreadIndex)")
    }
    
    var webtoonView: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 0) {
                ForEach(0..<cache.pageCount, id: \.self) { index in
                    WebtoonImageCell(
                        index: index,
                        cache: cache,
                        activeFilterPreset: activeFilterPreset,
                        onAppearAction: {
                            currentIndex = index
                            // Keep chrome active while scrolling / navigating through Webtoon mode
                        }
                    )
                }
                
                // Add an explicit button to load the next volume in the series
                Button(action: {
                    attemptComicSeriesContinuation()
                }) {
                    HStack {
                        Text("Next Volume in Series")
                            .font(.system(size: 16, weight: .semibold))
                        Image(systemName: "chevron.right")
                    }
                    .foregroundColor(.white)
                    .padding(.vertical, 16)
                    .padding(.horizontal, 32)
                    .background(Color.white.opacity(0.15))
                    .cornerRadius(12)
                }
                .padding(.vertical, 40)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                chromeVisible.toggle()
            }
            chromeIdleTask?.cancel()
        }
        .ignoresSafeArea()
    }
    
    var twoUpView: some View {
        TwoUpBookPager(
            currentIndex: $currentIndex,
            cache: cache,
            activeFilterPreset: activeFilterPreset,
            readingMode: readingMode,
            isMangaRTL: isMangaActive,
            onChromeTap: { chromeVisible.toggle() },
            onFlipPastEnd: { attemptComicSeriesContinuation() }
        )
    }


    // MARK: - Navigation helpers
    
    private func nextPage() {
        if isCurrentlyTwoUp {
            let spreads = computeSpreads()
            if let currentSpreadIdx = spreads.firstIndex(where: { $0.contains(currentIndex) }) {
                let nextSpreadIdx = currentSpreadIdx + 1
                if nextSpreadIdx < spreads.count {
                    currentIndex = spreads[nextSpreadIdx].first ?? currentIndex
                } else {
                    attemptComicSeriesContinuation()
                }
            } else {
                if currentIndex < cache.pageCount - 1 {
                    currentIndex += 1
                } else {
                    attemptComicSeriesContinuation()
                }
            }
        } else {
            if currentIndex < cache.pageCount - 1 {
                currentIndex += 1
            } else {
                attemptComicSeriesContinuation()
            }
        }
    }

    private func prevPage() {
        if isCurrentlyTwoUp {
            let spreads = computeSpreads()
            if let currentSpreadIdx = spreads.firstIndex(where: { $0.contains(currentIndex) }) {
                let prevSpreadIdx = currentSpreadIdx - 1
                if prevSpreadIdx >= 0 {
                    currentIndex = spreads[prevSpreadIdx].first ?? currentIndex
                }
            } else {
                if currentIndex > 0 {
                    currentIndex -= 1
                }
            }
        } else {
            if currentIndex > 0 {
                currentIndex -= 1
            }
        }
    }

    // MARK: - Series & Collection Continuation

    /// Called when the reader reaches the last page of the file or flips past the end.
    /// Delegates to ReadingContinuationResolver to auto-transition to the next issue
    /// in the user's custom collection (story arc), virtual omnibus, or publisher series.
    private func attemptComicSeriesContinuation() {
        saveCurrentProgress()
        _ = ReadingContinuationResolver.shared.continueReading(after: pdf, in: allBooks)
    }



    // MARK: - Ambient Colour Extraction

    /// Extracts the average edge colour of the current page for Panels-style chrome tinting.
    /// Uses a SINGLE 32×32 downscale of the full page, then samples the edge pixels from
    /// the tiny bitmap. This avoids the OOM crash that occurred when drawing a full 4K+
    /// CGImage into a 1×1 context 20 times per page change.
    private func extractAmbientColor(for index: Int) {
        guard !essentialReaderMode else {
            ambientPageColor = .clear
            return
        }
        guard let image = cache.getImage(at: index),
              let cgImage = image.cgImage else { return }

        // Cancel any in-flight task so rapid page swipes don’t stack up allocations.
        ambientColorTask?.cancel()
        ambientColorTask = Task.detached(priority: .utility) {
            guard !Task.isCancelled else { return }

            // ── Step 1: Scale the full page down to 32×32 once ──────────────────
            // Drawing a large CGImage into a tiny context is inexpensive; the GPU
            // driver bilinear-scales it. Doing it once costs ~50–200µs on M2.
            let thumbSize = 32
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let bytesPerRow = thumbSize * 4
            var pixelBuffer = [UInt8](repeating: 0, count: thumbSize * bytesPerRow)

            guard let ctx = CGContext(
                data: &pixelBuffer,
                width: thumbSize,
                height: thumbSize,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }

            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: thumbSize, height: thumbSize))

            guard !Task.isCancelled else { return }

            // ── Step 2: Sample edge pixels from the 32×32 bitmap ─────────────────
            // pixelBuffer layout: RGBA, row-major, top-to-bottom (CoreGraphics default).
            func pixel(x: Int, y: Int) -> (CGFloat, CGFloat, CGFloat) {
                let offset = (y * bytesPerRow) + (x * 4)
                let r = CGFloat(pixelBuffer[offset])     / 255
                let g = CGFloat(pixelBuffer[offset + 1]) / 255
                let b = CGFloat(pixelBuffer[offset + 2]) / 255
                return (r, g, b)
            }

            var rSum: CGFloat = 0
            var gSum: CGFloat = 0
            var bSum: CGFloat = 0
            var count: CGFloat = 0

            // Sample 4 pixels per edge (left, right, top, bottom)
            let sampleSteps = 4
            for s in 0..<sampleSteps {
                let t = Int(Double(s + 1) / Double(sampleSteps + 1) * Double(thumbSize))
                for (x, y) in [(0, t), (thumbSize - 1, t), (t, 0), (t, thumbSize - 1)] {
                    let (r, g, b) = pixel(x: x, y: y)
                    rSum += r; gSum += g; bSum += b; count += 1
                }
            }

            guard count > 0, !Task.isCancelled else { return }

            let avgR = rSum / count
            let avgG = gSum / count
            let avgB = bSum / count

            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.6)) {
                    ambientPageColor = Color(red: avgR, green: avgG, blue: avgB)
                }
            }
        }
    }

    // MARK: - Extracted sub-views

    /// Left brightness drag zone.
    @ViewBuilder private var brightnessZones: some View {
        EdgeBrightnessGestureZone()
    }

    /// Full ReaderChrome view — extracted so the compiler can type-check it independently.
    @ViewBuilder private var readerChromeView: some View {
        ReaderChrome(
            title: pdf.name,
            pageText: "\(currentIndex + 1) / \(cache.pageCount)  •  \(velocityEngine.estimatedTimeRemaining)",
            isVisible: $chromeVisible,
            onBack: saveProgressAndDismiss,
            onBookmark: {
                toggleBookmark()
            },
            onBookmarkActive: isCurrentPageBookmarked,
            onSettingsToggle: {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { showingSettingsHUD.toggle() }
            },
            onAnnotationsToggle: {
                NotificationCenter.default.post(name: .toggleStudyNotebook, object: nil)
            },
            isDialogueLensEnabled: isDialogueLensEnabled,
            onDialogueLensToggle: {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isDialogueLensEnabled.toggle()
                    if isDialogueLensEnabled {
                        dialogueOCRTask?.cancel()
                        dialogueOCRTask = Task {
                            await prewarmOCR(for: currentIndex)
                        }
                    } else {
                        dialogueOCRTask?.cancel()
                        dialogueOCRTask = nil
                        selectedTextBlock = nil
                    }
                }
                HapticEngine.light()
            },
            onReadAloudToggle: {
                startPageNarration()
            },
            currentProgress: Binding(
                get: { Double(currentIndex) / Double(max(1, cache.pageCount - 1)) },
                set: { currentIndex = Int($0 * Double(max(1, cache.pageCount - 1))) }
            ),
            totalPages: cache.pageCount,
            customScrubber: AnyView(
                VisualComicScrubber(
                    currentIndex: $currentIndex,
                    totalPages: cache.pageCount,
                    cache: cache,
                    isMangaMode: isMangaComic || readingMode == .mangaRTL
                )
            ),
            onJumpToPage: {
                jumpToPageText = ""
                showJumpToPage = true
            },
            isPDF: cache.isPDF,
            isAutoCropEnabled: isAutoCropEnabled,
            onCropToggle: {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isAutoCropEnabled.toggle()
                }
                HapticEngine.light()
            },
            onManualCropToggle: {
                showCropAdjustmentSheet = true
            },
            onReflowToggle: cache.isPDF ? {
                HapticEngine.medium()
                NotificationCenter.default.post(
                    name: NSNotification.Name("InksyncPro.switchReaderEngine"),
                    object: nil,
                    userInfo: ["engine": "proPDF"]
                )
            } : nil,
            isEnhanced: activeFilterPreset != .original,
            onEnhanceToggle: { withAnimation(.easeInOut) { showingFilterHUD.toggle() } },
            isSettingsActive: readingMode != .pageHorizontal,
            currentModeLabel: readingMode != .pageHorizontal ? readingMode.hudLabel : nil,
            ambientColor: ambientPageColor,
            sessionStartTime: sessionStartTime,
            onSwipeDown: saveProgressAndDismiss
        )
    }

    /// Filter preset HUD (eink / vintage / etc).
    @ViewBuilder private var filterHUDView: some View {
        if showingFilterHUD {
            VStack {
                Spacer()
                FilterHUDView(activePreset: $activeFilterPreset, onDismiss: {
                    withAnimation(.easeInOut) { showingFilterHUD = false }
                })
                .padding(.bottom, 80)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .zIndex(10)
        }
    }

    /// Reading mode settings sheet (page-turn style, filter, etc).
    @ViewBuilder private var settingsHUDView: some View {
        if showingSettingsHUD {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { showingSettingsHUD = false }
                }
                .zIndex(11)
            VStack {
                Spacer()
                ReaderSettingsHUD(
                    readingMode: $readingMode,
                    activeFilterPreset: $activeFilterPreset,
                    prefersTwoUpSpreads: $prefersTwoUpSpreads,
                    onOpenVisualCrop: {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            showingSettingsHUD = false
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            showCropAdjustmentSheet = true
                        }
                    },
                    isPDF: cache.isPDF,
                    onSwitchToProPDF: {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            showingSettingsHUD = false
                        }
                    },
                    onDismiss: {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { showingSettingsHUD = false }
                    }
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .zIndex(12)
        }
    }

    @ViewBuilder private var achievementToastView: some View {
        EmptyView()
    }

    // MARK: - Private Helpers

    private func saveCurrentProgress() {
        let total = max(cache.pageCount, 1)
        var progress = ReaderProgressTracker.shared.progress(for: pdf.id) ?? ReadingProgress(
            pdfID: pdf.id, lastOpenedAt: Date(), currentPageIndex: currentIndex,
            currentChapterIndex: nil, currentChapterOffset: nil,
            totalPagesRead: 1,
            completionFraction: Double(currentIndex + 1) / Double(total),
            readingSessionDates: [Date()], estimatedMinutesRemaining: nil
        )
        progress.currentPageIndex = currentIndex
        progress.lastOpenedAt = Date()
        progress.completionFraction = Double(currentIndex + 1) / Double(total)
        progress.prefersMangaMode = isMangaActive
        progress.colorFilter = activeFilterPreset.rawValue
        progress.lastCanonicalLeadIndex = currentIndex
        progress.wasInDualPageMode = prefersTwoUpSpreads
        if !progress.readingSessionDates.contains(where: { Calendar.current.isDateInToday($0) }) {
            progress.readingSessionDates.append(Date())
        }
        ReaderProgressTracker.shared.update(progress)
    }

    private var isCurrentPageBookmarked: Bool {
        let inStore = AnnotationStore.shared.annotations(for: pdf.id).contains(where: { $0.pageIndex == currentIndex && $0.kind == .bookmark })
        let inMetadata = pdf.metadata.bookmarkedPages.contains(currentIndex)
        return inStore || inMetadata
    }

    private func toggleBookmark() {
        let wasBookmarked = isCurrentPageBookmarked
        if wasBookmarked {
            let existing = AnnotationStore.shared.annotations(for: pdf.id).filter { $0.pageIndex == currentIndex && $0.kind == .bookmark }
            for b in existing {
                AnnotationStore.shared.delete(id: b.id, pdfID: pdf.id)
            }
            if let idx = ConversionManager.shared.convertedPDFs.firstIndex(where: { $0.id == pdf.id }) {
                ConversionManager.shared.convertedPDFs[idx].metadata.bookmarkedPages.removeAll(where: { $0 == currentIndex })
                ConversionManager.shared.saveProgressOnly()
            }
            showToastMessage("Bookmark Removed")
            HapticEngine.light()
        } else {
            let bookmark = Annotation(
                pdfID: pdf.id,
                pageIndex: currentIndex,
                chapterTitle: "Page \(currentIndex + 1)",
                kind: .bookmark,
                createdAt: Date(),
                modifiedAt: Date()
            )
            AnnotationStore.shared.add(bookmark)
            if let idx = ConversionManager.shared.convertedPDFs.firstIndex(where: { $0.id == pdf.id }) {
                if !ConversionManager.shared.convertedPDFs[idx].metadata.bookmarkedPages.contains(currentIndex) {
                    ConversionManager.shared.convertedPDFs[idx].metadata.bookmarkedPages.append(currentIndex)
                    ConversionManager.shared.saveProgressOnly()
                }
            }
            showToastMessage("Bookmark Added")
            HapticEngine.medium()
        }
    }

    private func saveProgressAndDismiss() {
        saveCurrentProgress()
        onDismiss()
    }

    /// Phase 4A: Start (or restart) the 4-second idle timer that auto-hides the chrome.
    /// Keep chrome active while navigating; dismissal is explicit by tapping reading canvas.
    private func startChromeIdleTimer() {
        chromeIdleTask?.cancel()
    }



    @ViewBuilder
    private var readerOnboardingOverlay: some View {
        ZStack {
            // Dark glassmorphism background overlay
            Color.black.opacity(0.85)
                .ignoresSafeArea()
                .onTapGesture {
                    // Prevent dismiss on random background tap unless desired
                }
            
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                
                ZStack {
                    // Tap Zone Outlines
                    HStack(spacing: 0) {
                        // Left Zone (Page Back)
                        VStack {
                            Spacer()
                            Image(systemName: "arrow.left.circle")
                                .font(.system(size: 32))
                                .foregroundColor(.white.opacity(0.6))
                                .padding(.bottom, 8)
                            Text("Page Back")
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                                .foregroundColor(.white)
                            Text("Tap left 20% of screen")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.5))
                            Spacer()
                        }
                        .frame(width: w * 0.2)
                        .background(Color.white.opacity(0.03))
                        .overlay(
                            Rectangle()
                                .strokeBorder(style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round, miterLimit: 10, dash: [4, 4], dashPhase: 0))
                                .foregroundColor(.white.opacity(0.2))
                        )
                        
                        // Center Zone (Menu Chrome)
                        VStack {
                            Spacer()
                            Image(systemName: "hand.tap")
                                .font(.system(size: 32))
                                .foregroundColor(.white.opacity(0.6))
                                .padding(.bottom, 8)
                            Text("Reader Controls")
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                                .foregroundColor(.white)
                            Text("Tap center zone to toggle controls")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.5))
                            Spacer()
                        }
                        .frame(width: w * 0.6)
                        .background(Color.white.opacity(0.01))
                        
                        // Right Zone (Page Forward)
                        VStack {
                            Spacer()
                            Image(systemName: "arrow.right.circle")
                                .font(.system(size: 32))
                                .foregroundColor(.white.opacity(0.6))
                                .padding(.bottom, 8)
                            Text("Page Forward")
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                                .foregroundColor(.white)
                            Text("Tap right 20% of screen")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.5))
                            Spacer()
                        }
                        .frame(width: w * 0.2)
                        .background(Color.white.opacity(0.03))
                        .overlay(
                            Rectangle()
                                .strokeBorder(style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round, miterLimit: 10, dash: [4, 4], dashPhase: 0))
                                .foregroundColor(.white.opacity(0.2))
                        )
                    }
                    
                    // Gesture Annotations overlay in the middle
                    VStack(spacing: 24) {
                        Spacer()
                        
                        VStack(spacing: 6) {
                            Text("QUICK GESTURES")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundColor(.yellow)
                                .tracking(1.5)
                            
                            HStack(spacing: 20) {
                                Label("Double-Tap to Zoom", systemImage: "magnifyingglass.circle")
                                Label("Drag left edge for Brightness", systemImage: "sun.max.circle")
                            }
                            .font(.system(size: 13))
                            .foregroundColor(.white.opacity(0.8))
                        }
                        .padding(.vertical, 16)
                        .padding(.horizontal, 24)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .shadow(radius: 10)
                        
                        // "Got It" Button
                        Button {
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                hasSeenReaderOnboarding = true
                            }
                            HapticEngine.success()
                        } label: {
                            Text("Got It")
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .foregroundColor(.black)
                                .padding(.horizontal, 48)
                                .padding(.vertical, 14)
                                .background(Color.white)
                                .clipShape(Capsule())
                                .shadow(radius: 8)
                        }
                        .padding(.bottom, h * 0.1)
                    }
                }
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
        .zIndex(100)
    }

    // MARK: - AI Dialogue Lens Helpers

    private func showToastMessage(_ message: String) {
        toastMessage = message
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            showToast = true
        }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation(.easeOut(duration: 0.3)) {
                if toastMessage == message {
                    showToast = false
                }
            }
        }
    }

    private func prewarmOCR(for pageIndex: Int) async {
        isDialogueOCRing = true
        narrationEngine.connect(totalPages: cache.pageCount, imageProvider: { [weak cache] idx in
            cache?.getImage(at: idx)
        })
        narrationEngine.isMangaMode = isMangaActive
        narrationEngine.prewarmOCR(for: pageIndex)
        let blocks = await narrationEngine.fetchTextBlocks(for: pageIndex)
        currentDialogueBlocks = blocks
        isDialogueOCRing = false
    }

    private func handleDialogueLensTap(at location: CGPoint, in viewSize: CGSize) {
        guard let image = cache.getImage(at: currentIndex) else { return }
        
        let block = textBlock(at: location, in: viewSize, imageSize: image.size, blocks: currentDialogueBlocks)
        
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            if let block = block {
                selectedTextBlock = block
                HapticEngine.medium()
            } else {
                // Tapped outside any text block
                if selectedTextBlock != nil {
                    selectedTextBlock = nil
                } else {
                    chromeVisible.toggle()
                }
            }
        }
    }

    private func textBlock(at tapPoint: CGPoint, in viewSize: CGSize, imageSize: CGSize, blocks: [TextBlock]) -> TextBlock? {
        guard imageSize.width > 0, imageSize.height > 0 else { return nil }
        
        let imageRatio = imageSize.width / imageSize.height
        let viewRatio = viewSize.width / viewSize.height
        
        var renderWidth: CGFloat
        var renderHeight: CGFloat
        var offsetX: CGFloat = 0
        var offsetY: CGFloat = 0
        
        if imageRatio > viewRatio {
            renderWidth = viewSize.width
            renderHeight = viewSize.width / imageRatio
            offsetY = (viewSize.height - renderHeight) / 2
        } else {
            renderHeight = viewSize.height
            renderWidth = viewSize.height * imageRatio
            offsetX = (viewSize.width - renderWidth) / 2
        }
        
        let relativeX = tapPoint.x - offsetX
        let relativeY = tapPoint.y - offsetY
        
        guard relativeX >= 0, relativeX <= renderWidth,
              relativeY >= 0, relativeY <= renderHeight else {
            return nil
        }
        
        let normalizedX = relativeX / renderWidth
        let normalizedY = 1.0 - (relativeY / renderHeight) // Vision bottom-origin
        
        for block in blocks {
            let paddedBox = block.boundingBox.insetBy(dx: -0.015, dy: -0.015)
            if paddedBox.contains(CGPoint(x: normalizedX, y: normalizedY)) {
                return block
            }
        }
        return nil
    }

    private func screenRect(for boundingBox: CGRect, in viewSize: CGSize, imageSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let imageRatio = imageSize.width / imageSize.height
        let viewRatio = viewSize.width / viewSize.height
        
        var renderWidth: CGFloat
        var renderHeight: CGFloat
        var offsetX: CGFloat = 0
        var offsetY: CGFloat = 0
        
        if imageRatio > viewRatio {
            renderWidth = viewSize.width
            renderHeight = viewSize.width / imageRatio
            offsetY = (viewSize.height - renderHeight) / 2
        } else {
            renderHeight = viewSize.height
            renderWidth = viewSize.height * imageRatio
            offsetX = (viewSize.width - renderWidth) / 2
        }
        
        let x = offsetX + (boundingBox.minX * renderWidth)
        let y = offsetY + ((1.0 - boundingBox.maxY) * renderHeight)
        let w = boundingBox.width * renderWidth
        let h = boundingBox.height * renderHeight
        
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private func startPageNarration() {
        dialogueOCRTask?.cancel()
        dialogueOCRTask = Task {
            if currentDialogueBlocks.isEmpty {
                await prewarmOCR(for: currentIndex)
            }
            guard !currentDialogueBlocks.isEmpty else {
                showToastMessage("No dialogue detected on page")
                return
            }
            speechEngine.startReading(
                blocks: currentDialogueBlocks,
                startIndex: 0,
                pageIndex: currentIndex,
                title: pdf.name,
                onPageAdvanceRequested: {
                    if currentIndex + 1 < cache.pageCount {
                        nextPage()
                        Task {
                            try? await Task.sleep(nanoseconds: 300_000_000)
                            startPageNarration()
                        }
                    }
                }
            )
            HapticEngine.medium()
        }
    }

    @ViewBuilder
    private var dialogueHUDView: some View {
        if let block = selectedTextBlock {
            VStack {
                Spacer()
                
                VStack(spacing: 16) {
                    HStack {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkles")
                                .foregroundColor(.purple)
                            Text("AI Dialogue HUD")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundColor(.purple)
                                .tracking(1.0)
                        }
                        
                        Spacer()
                        
                        Button {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                selectedTextBlock = nil
                            }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 18))
                                .foregroundColor(.white.opacity(0.4))
                        }
                    }
                    
                    ScrollView {
                        Text(block.text)
                            .font(.system(size: 18, weight: .medium, design: .rounded))
                            .foregroundColor(.white)
                            .lineSpacing(6)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                    }
                    .frame(maxHeight: 120)
                    
                    HStack(spacing: 12) {
                        Button {
                            HapticEngine.medium()
                            let startIndex = currentDialogueBlocks.firstIndex(of: block) ?? 0
                            speechEngine.startReading(
                                blocks: currentDialogueBlocks.isEmpty ? [block] : currentDialogueBlocks,
                                startIndex: startIndex,
                                pageIndex: currentIndex,
                                title: pdf.name,
                                onPageAdvanceRequested: {
                                    if currentIndex + 1 < cache.pageCount {
                                        nextPage()
                                        Task {
                                            try? await Task.sleep(nanoseconds: 300_000_000)
                                            startPageNarration()
                                        }
                                    }
                                }
                            )
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "speaker.wave.2.fill")
                                    .font(.system(size: 13, weight: .bold))
                                Text("Speak")
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(LinearGradient(colors: [.blue, .purple], startPoint: .leading, endPoint: .trailing), in: Capsule())
                        }

                        Button {
                            UIPasteboard.general.string = block.text
                            showToastMessage("Copied to clipboard")
                            HapticEngine.light()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "doc.on.doc.fill")
                                    .font(.system(size: 13, weight: .bold))
                                Text("Copy Text")
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                            }
                            .foregroundColor(.black)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(Color.white, in: Capsule())
                        }
                        
                        Button {
                            let newHighlight = SDAnnotation(
                                id: UUID(),
                                pdfID: pdf.id.uuidString,
                                pageIndex: currentIndex,
                                text: block.text,
                                note: nil,
                                isReadwiseImport: false,
                                readwiseBookTitle: pdf.name,
                                readwiseAuthor: nil,
                                createdAt: Date()
                            )
                            newHighlight.kindRaw = "highlight"
                            modelContext.insert(newHighlight)
                            try? modelContext.save()
                            showToastMessage("Saved to Notebook")
                            HapticEngine.light()
                            
                            // Immediately open the annotation editor for notes and tags
                            withAnimation {
                                selectedTextBlock = nil
                                activeHighlightToEdit = newHighlight
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "notebook.fill")
                                    .font(.system(size: 13, weight: .bold))
                                Text("Save to Notes")
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(Color.purple.opacity(0.6), in: Capsule())
                            .overlay(Capsule().stroke(Color.purple, lineWidth: 1))
                        }
                        
                        Spacer()
                        
                        Text("Page \(currentIndex + 1)")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundColor(.white.opacity(0.4))
                    }
                }
                .padding(20)
                .background(
                    ZStack {
                        Color.clear.background(.ultraThinMaterial)
                        Color.purple.opacity(0.08)
                    }
                )
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.4), radius: 24, y: 12)
                .frame(maxWidth: hSizeClass == .regular ? 560 : .infinity)
                .padding(.horizontal, 20)
                .padding(.bottom, 90)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .zIndex(20)
        }
    }

} // end ComicReaderEngine



struct WebtoonImageCell: View {
    let index: Int
    let cache: ComicImageCache
    let activeFilterPreset: ReadingFilterPreset
    let onAppearAction: () -> Void

    @State private var image: UIImage? = nil

    var body: some View {
        Group {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .applyFilterPreset(activeFilterPreset)
                    // .fit ensures the full panel width is never clipped — critical for
                    // webtoon panels that are taller than the screen width.
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .onAppear { onAppearAction() }
            } else {
                ZStack {
                    Color.black.frame(height: 500)
                    ProgressView().progressViewStyle(CircularProgressViewStyle(tint: .white.opacity(0.5)))
                }
                .onAppear {
                    image = cache.getImage(at: index) // Force trigger fetch
                    onAppearAction()
                }
            }
        }
        .onDisappear {
            image = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .comicImageCacheImageLoaded)) { notification in
            guard let userInfo = notification.userInfo,
                  let loadedIndex = userInfo["index"] as? Int,
                  loadedIndex == index else { return }
            image = cache.getImage(at: index)
        }
    }
}

// Wrap Image to support pinch-to-zoom (Basic implementation)
struct ComicPageView: View {
    let index: Int
    let cache: ComicImageCache
    /// Callbacks wired from BookFlipGesture / BookPager for context menu actions.
    var onSaveToPhotos: (() -> Void)? = nil
    var onShare: (() -> Void)? = nil
    var onBookmark: (() -> Void)? = nil
    
    @ObservedObject private var prefs = EBookPreferences.shared
    @State private var image: UIImage? = nil
    @State private var displayImage: UIImage? = nil
    @AppStorage("isAutoCropEnabled") private var isAutoCropEnabled = false
    @State private var currentScale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var shareItem: UIImage? = nil
    @State private var showShareSheet = false
    @State private var cropTask: Task<Void, Never>? = nil

    /// Compute the rendered width/height according to the user's active ComicPageFitMode.
    private func renderSize(for image: UIImage, in container: CGSize, fitMode: ComicPageFitMode) -> CGSize {
        let imgWidth  = max(1, image.size.width)
        let imgHeight = max(1, image.size.height)
        let contWidth  = max(1, container.width)
        let contHeight = max(1, container.height)
        
        let imageAspect     = imgWidth / imgHeight
        let containerAspect = contWidth / contHeight
        
        switch fitMode {
        case .fitWidth:
            // Matches screen width 100% — panel expands horizontally edge-to-edge
            return CGSize(width: contWidth, height: contWidth / imageAspect)
            
        case .fillScreen:
            // True Edge-to-Edge full bleed: fills 100% of container so zero letterboxing occurs
            let scale = max(contWidth / imgWidth, contHeight / imgHeight)
            return CGSize(width: imgWidth * scale, height: imgHeight * scale)
            
        case .smartFit, .fitPage:
            // Traditional aspect-fit within bounds (smartFit trims borders first)
            if imageAspect > containerAspect {
                return CGSize(width: contWidth, height: contWidth / imageAspect)
            } else {
                return CGSize(width: contHeight * imageAspect, height: contHeight)
            }
        }
    }

    private func validateAndClampOffset(containerSize: CGSize, renderedSize: CGSize) {
        let maxW = max(0, (renderedSize.width * currentScale - containerSize.width) / 2)
        let maxH = max(0, (renderedSize.height * currentScale - containerSize.height) / 2)
        
        var newW = offset.width
        var newH = offset.height
        
        if newW > maxW { newW = maxW }
        if newW < -maxW { newW = -maxW }
        if newH > maxH { newH = maxH }
        if newH < -maxH { newH = -maxH }
        
        withAnimation(.easeOut(duration: 0.15)) {
            offset = CGSize(width: newW, height: newH)
            lastOffset = offset
        }
    }

    private func updateDisplayImage() {
        cropTask?.cancel()
        cropTask = nil
        
        guard let sourceImage = image ?? cache.getImage(at: index) else {
            displayImage = nil
            return
        }
        
        // 1. Manual Pro Crop Insets (Precision Top/Bottom/Left/Right trim)
        let manualInsets = ReaderProgressTracker.shared.cropInsets(for: cache.pdfID)
        if let insets = manualInsets, insets.modeRaw == "custom" {
            let minX = insets.left
            let cropW = max(0.05, 1.0 - insets.left - insets.right)
            let cropH = max(0.05, 1.0 - insets.top - insets.bottom)
            // ImageProcessor.crop expects CoreGraphics coordinates (y: (1.0 - rect.maxY) * height)
            // To start insets.top from the top of the image, rect.maxY must be 1.0 - insets.top
            let minY = insets.bottom
            let normalizedRect = CGRect(x: minX, y: minY, width: cropW, height: cropH)
            if let cropped = ImageProcessor.crop(image: sourceImage, to: normalizedRect) {
                self.displayImage = cropped
                return
            }
        } else if let insets = manualInsets, insets.modeRaw == "none" {
            self.displayImage = sourceImage
            return
        }
        
        // 2. Smart Auto Crop (Document-specific smartAuto, global auto-crop fallback, or smartFit mode)
        let isSmartFit = (prefs.comicPageFitMode == .smartFit)
        let shouldAutoCrop = isSmartFit || (manualInsets?.modeRaw == "smartAuto") || (manualInsets == nil && (isAutoCropEnabled || prefs.isSmartCropEnabled))
        if shouldAutoCrop {
            cropTask = Task.detached(priority: .userInitiated) {
                let cropRect = SmartCropper.suggestCrop(for: sourceImage)
                guard !Task.isCancelled else { return }
                
                let cropped = cropRect.flatMap { ImageProcessor.crop(image: sourceImage, to: $0) }
                guard !Task.isCancelled else { return }
                
                await MainActor.run {
                    self.displayImage = cropped ?? sourceImage
                }
            }
        } else {
            displayImage = sourceImage
        }
    }

    var body: some View {
        let currentImage = image ?? cache.getImage(at: index)
        Group {
            if let img = displayImage ?? currentImage {
                GeometryReader { geo in
                    let fitMode = prefs.comicPageFitMode
                    let rendered = renderSize(for: img, in: geo.size, fitMode: fitMode)
                    let isPannable = (currentScale > 1.01) || (rendered.height > geo.size.height + 2) || (rendered.width > geo.size.width + 2)

                    ZStack {
                        Color.black.ignoresSafeArea()

                        Image(uiImage: img)
                            .resizable()
                            .aspectRatio(contentMode: (fitMode == .fillScreen) ? .fill : .fit)
                            .frame(
                                width: (fitMode == .fillScreen || fitMode == .fitWidth) ? rendered.width : nil,
                                height: (fitMode == .fillScreen || fitMode == .fitWidth) ? rendered.height : nil
                            )
                            .frame(maxWidth: (fitMode == .fitPage) ? geo.size.width : nil, maxHeight: (fitMode == .fitPage) ? geo.size.height : nil)
                            .scaleEffect(currentScale)
                            .offset(offset)
                            .gesture(
                                MagnificationGesture()
                                    .onChanged { val in
                                        let nextScale = lastScale * val
                                        currentScale = min(max(1.0, nextScale), 6.0)
                                    }
                                    .onEnded { _ in
                                        lastScale = currentScale
                                        validateAndClampOffset(containerSize: geo.size, renderedSize: rendered)
                                    }
                            )
                            .dragGestureIfPannable(
                                isPannable: isPannable,
                                onChanged: { val in
                                    offset = CGSize(
                                        width: lastOffset.width + val.translation.width,
                                        height: lastOffset.height + val.translation.height
                                    )
                                },
                                onEnded: { _ in
                                    lastOffset = offset
                                    validateAndClampOffset(containerSize: geo.size, renderedSize: rendered)
                                }
                            )
                            .onTapGesture(count: 2) { loc in
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                    if currentScale > 1.05 {
                                        currentScale = 1.0
                                        lastScale = 1.0
                                        offset = .zero
                                        lastOffset = .zero
                                    } else {
                                        if prefs.comicPageFitMode == .fitPage {
                                            prefs.comicPageFitMode = .fillScreen
                                        } else {
                                            currentScale = 2.0
                                            lastScale = 2.0
                                            let centerX = geo.size.width / 2
                                            let centerY = geo.size.height / 2
                                            let dx = (centerX - loc.x) * (currentScale - 1)
                                            let dy = (centerY - loc.y) * (currentScale - 1)
                                            
                                            let maxW = max(0, (rendered.width * currentScale - geo.size.width) / 2)
                                            let maxH = max(0, (rendered.height * currentScale - geo.size.height) / 2)
                                            offset = CGSize(
                                                width: min(maxW, max(-maxW, dx)),
                                                height: min(maxH, max(-maxH, dy))
                                            )
                                            lastOffset = offset
                                        }
                                    }
                                }
                            }
                    }
                    .onDisappear {
                        cropTask?.cancel()
                        cropTask = nil
                        currentScale = 1.0
                        lastScale = 1.0
                        offset = .zero
                        lastOffset = .zero
                    }
                    // Phase 4A: long-press context menu (Save / Share / Bookmark)
                    .contextMenu {
                        if let onSaveToPhotos {
                            Button {
                                onSaveToPhotos()
                            } label: {
                                Label("Save to Photos", systemImage: "photo.badge.arrow.down")
                            }
                        }
                        Button {
                            shareItem = displayImage ?? image
                            showShareSheet = true
                        } label: {
                            Label("Share Page", systemImage: "square.and.arrow.up")
                        }
                        if let onBookmark {
                            Button {
                                HapticEngine.success()
                                onBookmark()
                            } label: {
                                Label("Add Bookmark", systemImage: "bookmark.fill")
                            }
                        }
                    } preview: {
                        // System shows a scaled preview of the page in the context menu blur
                        Image(uiImage: displayImage ?? image ?? UIImage())
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 280)
                    }
                    .clipped()
                    .sheet(isPresented: $showShareSheet) {
                        if let item = shareItem {
                            ShareSheet(activityItems: [item])
                                .presentationDetents([.medium, .large])
                        }
                    }
                }
                .clipped()
                .ignoresSafeArea()
            } else {
                Color.black
            }
        }
        .id(index)
        .onAppear {
            image = cache.getImage(at: index)
            updateDisplayImage()
        }
        .onChange(of: index) { _, newIndex in
            image = cache.getImage(at: newIndex)
            updateDisplayImage()
        }
        .onChange(of: image) { _, _ in
            updateDisplayImage()
        }
        .onChange(of: isAutoCropEnabled) { _, _ in
            updateDisplayImage()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("Reader_CropInsetsChanged"))) { _ in
            updateDisplayImage()
        }
        .onChange(of: prefs.comicPageFitMode) { _, _ in
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                offset = .zero
                lastOffset = .zero
                currentScale = 1.0
                lastScale = 1.0
            }
            updateDisplayImage()
        }
        .onChange(of: currentScale) { oldScale, newScale in
            let wasZoomed = oldScale > 1.0
            let isZoomed = newScale > 1.0
            if wasZoomed != isZoomed {
                NotificationCenter.default.post(
                    name: .readerZoomStateChanged,
                    object: nil,
                    userInfo: ["isZoomed": isZoomed]
                )
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .comicImageCacheImageLoaded)) { notification in
            guard let userInfo = notification.userInfo,
                  let loadedIndex = userInfo["index"] as? Int,
                  loadedIndex == index else { return }
            image = cache.getImage(at: index)
            updateDisplayImage()
        }
    }
}

// MARK: - Guided View Component (Dual-Page Spread & Single-Page Support)
struct ComicSpreadGuidedView: View {
    let spread: [Int] // [pageIndex] for single, or [leftIndex, rightIndex] for dual spread
    let cache: ComicImageCache
    let pdf: ConvertedPDF
    @Binding var masterIndex: Int
    let spreads: [[Int]]
    let activeFilterPreset: ReadingFilterPreset
    var isMangaMode: Bool = false
    var isChromeVisible: Bool = false
    var onTapChrome: () -> Void
    var onToggleReadingMode: (() -> Void)? = nil

    private var pdfID: UUID { pdf.id }

    @State private var image0: UIImage? = nil
    @State private var image1: UIImage? = nil
    @State private var currentStrideIndex: Int = 0 // 0 = Focused Inspection View (first panel/section)
    @State private var strides: [SpreadStride] = []
    @State private var isAnalyzing: Bool = false
    @State private var isAdjustingInWorkspace: Bool = false
    @State private var lastTapTime: Date = .distantPast
    @State private var pendingSingleTapWorkItem: DispatchWorkItem? = nil
    @State private var dragOffset: CGSize = .zero
    @State private var showPanelBadge: Bool = false
    @State private var badgeDismissTask: Task<Void, Never>? = nil

    @ObservedObject private var prefs = EBookPreferences.shared

    private var tapZoneStyle: TapZoneStyle {
        TapZoneStyle(rawValue: UserDefaults.standard.string(forKey: "tapZoneStyle") ?? "") ?? .classic
    }

    struct SpreadStride: Identifiable, Equatable {
        let id = UUID()
        let pageIndex: Int
        let panel: PanelExtractor.Panel
        let label: String
        let subIndex: Int
        let totalForPage: Int
    }

    struct ViewMetrics {
        let scale: CGFloat
        let offsetX: CGFloat
        let offsetY: CGFloat
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                if currentStrideIndex >= 0 && currentStrideIndex < strides.count {
                    // ── Focused Inspection View (Smart Gutter / Panel Zoom) ──
                    inspectionStrideView(for: geo.size)

                    // ── Discreet Panel / Tier Index HUD Indicator ──
                    if showPanelBadge || isChromeVisible {
                        VStack {
                            panelBadgeView(for: strides[currentStrideIndex])
                                .padding(.top, 18)
                                .transition(.asymmetric(
                                    insertion: .opacity.combined(with: .scale(scale: 0.92)),
                                    removal: .opacity
                                ))
                            Spacer()
                        }
                    }
                } else {
                    // ── Macro Physical Spread Overview (Feels like holding a comic) ──
                    macroSpreadView(for: geo.size)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 15)
                    .onChanged { value in
                        pendingSingleTapWorkItem?.cancel()
                        pendingSingleTapWorkItem = nil
                        lastTapTime = .distantPast
                        dragOffset = value.translation
                    }
                    .onEnded { value in
                        pendingSingleTapWorkItem?.cancel()
                        pendingSingleTapWorkItem = nil
                        lastTapTime = .distantPast
                        let horizontalSwipe = value.predictedEndTranslation.width
                        let threshold: CGFloat = 80
                        if horizontalSwipe < -threshold {
                            dragOffset = .zero
                            if isMangaMode { rewind() } else { advance() }
                        } else if horizontalSwipe > threshold {
                            dragOffset = .zero
                            if isMangaMode { advance() } else { rewind() }
                        } else {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                dragOffset = .zero
                            }
                        }
                    }
            )
            .onTapGesture(count: 1) { loc in
                handleTapWithDebounce(loc: loc, width: geo.size.width)
            }
        }
        .onAppear {
            loadImagesAndAnalyze()
            flashPanelBadge()
        }
        .onChange(of: currentStrideIndex) { _, _ in
            dragOffset = .zero
            flashPanelBadge()
        }
        .onChange(of: prefs.panelInspectionStyle) { _, _ in
            strides.removeAll()
            isAnalyzing = false
            currentStrideIndex = 0
            loadImagesAndAnalyze()
        }
        .onDisappear {
            pendingSingleTapWorkItem?.cancel()
            pendingSingleTapWorkItem = nil
            badgeDismissTask?.cancel()
            badgeDismissTask = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ComicReader_OpenPanelWorkspace"))) { _ in
            isAdjustingInWorkspace = true
        }
        .sheet(isPresented: $isAdjustingInWorkspace, onDismiss: {
            loadImagesAndAnalyze()
        }) {
            let activePage = (currentStrideIndex >= 0 && currentStrideIndex < strides.count) ? strides[currentStrideIndex].pageIndex : (spread.first ?? masterIndex)
            NavigationStack {
                PrecisionCanvasView(
                    pdf: pdf,
                    pageIndex: .constant(activePage),
                    totalCount: max(1, cache.pageCount),
                    conversionManager: ConversionManager.shared,
                    shouldEndSessionOnDisappear: false
                )
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .comicImageCacheImageLoaded)) { notification in
            guard let userInfo = notification.userInfo,
                  let loadedIndex = userInfo["index"] as? Int else { return }
            if loadedIndex == spread.first || (spread.count > 1 && loadedIndex == spread[1]) {
                loadImagesAndAnalyze()
            }
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private func macroSpreadView(for size: CGSize) -> some View {
        if spread.count == 2 {
            let leftImg = isMangaMode ? image1 : image0
            let rightImg = isMangaMode ? image0 : image1
            HStack(spacing: 4) {
                if let l = leftImg {
                    Image(uiImage: l)
                        .resizable()
                        .applyFilterPreset(activeFilterPreset)
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: (size.width - 4) / 2, maxHeight: size.height)
                }
                if let r = rightImg {
                    Image(uiImage: r)
                        .resizable()
                        .applyFilterPreset(activeFilterPreset)
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: (size.width - 4) / 2, maxHeight: size.height)
                }
            }
            .frame(width: size.width, height: size.height)
        } else {
            if let img0 = image0 {
                Image(uiImage: img0)
                    .resizable()
                    .applyFilterPreset(activeFilterPreset)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size.width, height: size.height)
            }
        }
    }

    @ViewBuilder
    private func inspectionStrideView(for size: CGSize) -> some View {
        let activeStride = strides[currentStrideIndex]
        let activeImg = (activeStride.pageIndex == spread[0]) ? image0 : image1

        if let img = activeImg {
            let metrics = calculateMetrics(for: size, image: img, panel: activeStride.panel)

            Image(uiImage: img)
                .resizable()
                .applyFilterPreset(activeFilterPreset)
                .aspectRatio(contentMode: .fit)
                .frame(width: size.width, height: size.height)
                .scaleEffect(metrics.scale)
                .offset(x: metrics.offsetX + dragOffset.width, y: metrics.offsetY + dragOffset.height)
                .clipped()
                .animation(.spring(response: 0.38, dampingFraction: 0.82), value: currentStrideIndex)
        }
    }

    @ViewBuilder
    private func panelBadgeView(for stride: SpreadStride) -> some View {
        HStack(spacing: 8) {
            Image(systemName: prefs.panelInspectionStyle.icon)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.inkGreen)
            Text(stride.label)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(.white)

            Rectangle()
                .fill(Color.white.opacity(0.25))
                .frame(width: 1, height: 12)

            Button {
                HapticEngine.selection()
                isAdjustingInWorkspace = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "slider.horizontal.2.square")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Adjust")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                }
                .foregroundColor(Color.inkViolet)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 0.8))
        .shadow(color: .black.opacity(0.45), radius: 10, y: 3)
    }

    private func flashPanelBadge() {
        badgeDismissTask?.cancel()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
            showPanelBadge = true
        }
        badgeDismissTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if !Task.isCancelled {
                await MainActor.run {
                    withAnimation(.easeOut(duration: 0.4)) {
                        showPanelBadge = false
                    }
                }
            }
        }
    }

    // MARK: - Gesture Handling

    private func handleTapWithDebounce(loc: CGPoint, width: CGFloat) {
        let now = Date()
        if now.timeIntervalSince(lastTapTime) < 0.35 {
            // ✅ Double-tap detected! Cancel pending single-tap to prevent unwanted panel advancement or chrome toggle
            pendingSingleTapWorkItem?.cancel()
            pendingSingleTapWorkItem = nil
            lastTapTime = .distantPast
            HapticEngine.medium()
            onToggleReadingMode?()
        } else {
            lastTapTime = now
            pendingSingleTapWorkItem?.cancel()
            let workItem = DispatchWorkItem { [loc, width] in
                handleTap(loc: loc, width: width)
            }
            pendingSingleTapWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.26, execute: workItem)
        }
    }

    private func handleTap(loc: CGPoint, width: CGFloat) {
        let zones = tapZoneStyle.zones
        if loc.x < width * zones.leftEdge {
            if isMangaMode { advance() } else { rewind() }
        } else if loc.x > width * zones.rightEdge {
            if isMangaMode { rewind() } else { advance() }
        } else {
            onTapChrome()
        }
    }

    private func advance() {
        HapticEngine.light()
        dragOffset = .zero
        if strides.isEmpty {
            goToNextSpread()
            return
        }
        if currentStrideIndex < strides.count - 1 {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                currentStrideIndex += 1
            }
        } else {
            goToNextSpread()
        }
    }

    private func rewind() {
        HapticEngine.light()
        dragOffset = .zero
        if currentStrideIndex > 0 {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                currentStrideIndex -= 1
            }
        } else {
            goToPrevSpread()
        }
    }

    private func goToNextSpread() {
        guard let currentSpreadIdx = spreads.firstIndex(where: { $0 == spread }) else { return }
        let nextSpreadIdx = currentSpreadIdx + 1
        if nextSpreadIdx < spreads.count {
            masterIndex = spreads[nextSpreadIdx].first ?? masterIndex
            currentStrideIndex = 0
        }
    }

    private func goToPrevSpread() {
        guard let currentSpreadIdx = spreads.firstIndex(where: { $0 == spread }) else { return }
        let prevSpreadIdx = currentSpreadIdx - 1
        if prevSpreadIdx >= 0 {
            masterIndex = spreads[prevSpreadIdx].first ?? masterIndex
            currentStrideIndex = 0
        }
    }

    // MARK: - Logic & Analysis

    private func loadImagesAndAnalyze() {
        let idx0 = spread[0]
        if image0 == nil {
            image0 = cache.cachedImage(at: idx0) ?? cache.getImage(at: idx0)
        }
        if spread.count > 1 {
            let idx1 = spread[1]
            if image1 == nil {
                image1 = cache.cachedImage(at: idx1) ?? cache.getImage(at: idx1)
            }
        }
        analyzeStrides()
    }

    private func analyzeStrides() {
        guard !isAnalyzing else { return }
        guard let img0 = image0 else { return }
        if spread.count == 2 && image1 == nil { return }
        isAnalyzing = true

        let idx0 = spread[0]
        let idx1 = spread.count > 1 ? spread[1] : nil
        let img1 = image1
        let manga = isMangaMode
        let docID = pdfID

        Task.detached(priority: .userInitiated) {
            let isDualSpread = (spread.count == 2)
            let saved0 = await PageModelStore.shared.legacyVisionPanels(for: docID, pageIndex: idx0)
            let p0: [PanelExtractor.Panel]
            if !saved0.isEmpty {
                p0 = saved0
            } else {
                p0 = await PanelExtractor.detectPanelsOrSmartStrides(in: img0, isDualPage: isDualSpread, mangaMode: manga)
            }

            let p1: [PanelExtractor.Panel]
            if let idx1 = idx1, let img1 = img1 {
                let saved1 = await PageModelStore.shared.legacyVisionPanels(for: docID, pageIndex: idx1)
                if !saved1.isEmpty {
                    p1 = saved1
                } else {
                    p1 = await PanelExtractor.detectPanelsOrSmartStrides(in: img1, isDualPage: isDualSpread, mangaMode: manga)
                }
            } else {
                p1 = []
            }

            func panelLabel(for panel: PanelExtractor.Panel, index: Int, total: Int) -> String {
                let isFullWidthTier = panel.boundingBox.width >= 0.88
                if isFullWidthTier {
                    if total == 3 {
                        return index == 0 ? "Top Tier" : (index == 1 ? "Middle Tier" : "Bottom Tier")
                    } else if total == 2 {
                        return index == 0 ? "Top Half" : "Bottom Half"
                    }
                }
                return "Panel \(index + 1) of \(total)"
            }

            var builtStrides: [SpreadStride] = []
            if spread.count == 2, let idx1 = idx1 {
                // In both Western and Manga, idx0 (the lower page number) is read first:
                // Western: idx0 is left page, idx1 is right page -> read left (idx0) then right (idx1)
                // Manga: idx0 is right page, idx1 is left page -> read right (idx0) then left (idx1)
                let firstIdx = idx0
                let firstPanels = p0
                let secondIdx = idx1
                let secondPanels = p1

                for (i, panel) in firstPanels.enumerated() {
                    let lbl = panelLabel(for: panel, index: i, total: firstPanels.count)
                    builtStrides.append(SpreadStride(pageIndex: firstIdx, panel: panel, label: lbl, subIndex: i, totalForPage: firstPanels.count))
                }
                for (i, panel) in secondPanels.enumerated() {
                    let lbl = panelLabel(for: panel, index: i, total: secondPanels.count)
                    builtStrides.append(SpreadStride(pageIndex: secondIdx, panel: panel, label: lbl, subIndex: i, totalForPage: secondPanels.count))
                }
            } else {
                for (i, panel) in p0.enumerated() {
                    let lbl = panelLabel(for: panel, index: i, total: p0.count)
                    builtStrides.append(SpreadStride(pageIndex: idx0, panel: panel, label: lbl, subIndex: i, totalForPage: p0.count))
                }
            }

            await MainActor.run {
                self.strides = builtStrides
                self.isAnalyzing = false
                if self.currentStrideIndex < 0 && !builtStrides.isEmpty {
                    self.currentStrideIndex = 0
                }
            }
        }
    }

    private func calculateMetrics(for proxy: CGSize, image: UIImage, panel: PanelExtractor.Panel) -> ViewMetrics {
        guard proxy.width > 0, proxy.height > 0, proxy.width.isFinite, proxy.height.isFinite else {
            return ViewMetrics(scale: 1.0, offsetX: 0, offsetY: 0)
        }
        let imgSize = image.size
        guard imgSize.width > 0, imgSize.height > 0, imgSize.width.isFinite, imgSize.height.isFinite else {
            return ViewMetrics(scale: 1.0, offsetX: 0, offsetY: 0)
        }

        // Clamp normalized bounding box to valid [0..1] range defensively
        let b = panel.boundingBox
        let rawMinX = max(0.0, min(1.0, b.minX.isFinite ? b.minX : 0.0))
        let rawMinY = max(0.0, min(1.0, b.minY.isFinite ? b.minY : 0.0))
        let rawMaxX = max(rawMinX, min(1.0, b.maxX.isFinite ? b.maxX : 1.0))
        let rawMaxY = max(rawMinY, min(1.0, b.maxY.isFinite ? b.maxY : 1.0))
        let normW = max(0.02, rawMaxX - rawMinX)
        let normH = max(0.02, rawMaxY - rawMinY)

        let rect = CGRect(
            x: rawMinX * imgSize.width,
            y: (1.0 - rawMaxY) * imgSize.height,
            width: normW * imgSize.width,
            height: normH * imgSize.height
        )

        let imageRatio = imgSize.width / imgSize.height
        let screenRatio = proxy.width / proxy.height
        guard imageRatio > 0, imageRatio.isFinite, screenRatio > 0, screenRatio.isFinite else {
            return ViewMetrics(scale: 1.0, offsetX: 0, offsetY: 0)
        }

        var renderW: CGFloat
        var renderH: CGFloat
        if imageRatio > screenRatio {
            renderW = proxy.width
            renderH = proxy.width / imageRatio
        } else {
            renderH = proxy.height
            renderW = proxy.height * imageRatio
        }

        guard renderW > 0, renderH > 0, renderW.isFinite, renderH.isFinite else {
            return ViewMetrics(scale: 1.0, offsetX: 0, offsetY: 0)
        }

        let mappedX = (rect.minX / imgSize.width) * renderW
        let mappedY = (rect.minY / imgSize.height) * renderH
        let mappedW = (rect.width / imgSize.width) * renderW
        let mappedH = (rect.height / imgSize.height) * renderH
        guard mappedW > 1.0, mappedH > 1.0, mappedW.isFinite, mappedH.isFinite else {
            return ViewMetrics(scale: 1.0, offsetX: 0, offsetY: 0)
        }

        let scaleX = proxy.width / mappedW
        let scaleY = proxy.height / mappedH
        guard scaleX > 0, scaleY > 0, scaleX.isFinite, scaleY.isFinite else {
            return ViewMetrics(scale: 1.0, offsetX: 0, offsetY: 0)
        }

        let fitMode = EBookPreferences.shared.comicPageFitMode

        let targetScale: CGFloat
        switch fitMode {
        case .fitWidth:
            // Matches screen width edge-to-edge for maximum text clarity & immersion.
            // If the panel is unusually tall, allow it to scale up to 1.35x screen height
            // so it fills available space without losing the top/bottom captions.
            let maxAllowedScale = scaleY * 1.35
            targetScale = min(scaleX, max(scaleY, maxAllowedScale))
        case .fillScreen:
            // True edge-to-edge full bleed filling 100% of display
            targetScale = max(scaleX, scaleY)
        case .fitPage:
            // Clean aspect fit with zero arbitrary 0.96 downscale penalty
            targetScale = min(scaleX, scaleY)
        case .smartFit:
            // Smart fit: dynamically expand into available screen space up to 35% beyond base fit,
            // or match width if wide, filling available space while preventing excessive off-screen overflow
            let base = min(scaleX, scaleY)
            let fill = max(scaleX, scaleY)
            targetScale = min(fill, base * 1.35)
        }

        // Cap scale safely between 0.5x and 5.0x
        let scale = max(0.5, min(targetScale, 5.0))

        let panelCenter = CGPoint(x: mappedX + mappedW / 2, y: mappedY + mappedH / 2)
        let imageRenderCenter = CGPoint(x: renderW / 2, y: renderH / 2)

        let tx = (imageRenderCenter.x - panelCenter.x) * scale
        var ty = (imageRenderCenter.y - panelCenter.y) * scale

        // ── Smart Vertical Framing Safeguard ──
        // When a tier or panel is displayed, centering it vertically causes
        // the top edge to overflow the screen whenever mappedH * scale > proxy.height.
        // For top tiers / top-of-page panels (and in landscape mode), speech bubbles
        // and captions sit right at the top. We shift the tier DOWN so its top sits safely
        // within the screen with comfortable breathing room.
        let scaledPanelH = mappedH * scale
        let screenPanelTop = (proxy.height - scaledPanelH) / 2
        let screenPanelBottom = (proxy.height + scaledPanelH) / 2

        let isTopEdge = (rawMaxY >= 0.88) || (rect.minY <= 0.03 * imgSize.height)
        let isBottomEdge = (rawMinY <= 0.12) || (rect.maxY >= 0.97 * imgSize.height)
        let isLandscape = proxy.width > proxy.height
        let safeTop: CGFloat = isLandscape ? 12 : 16
        let safeBottom: CGFloat = isLandscape ? 12 : 16

        if isTopEdge {
            // Shift down so the top of the comic page / speech bubbles are 100% visible
            if screenPanelTop < safeTop {
                let shiftDown = safeTop - screenPanelTop
                ty += shiftDown
            }
        } else if isBottomEdge {
            // Shift up so bottom panels / credits aren't cut off
            if screenPanelBottom > (proxy.height - safeBottom) {
                let shiftUp = screenPanelBottom - (proxy.height - safeBottom)
                ty -= shiftUp
            }
        } else if screenPanelTop < safeTop {
            // General safety: if an inner panel still overflows top, prioritize top dialogue
            let shiftDown = safeTop - screenPanelTop
            ty += shiftDown
        }

        guard tx.isFinite, ty.isFinite else {
            return ViewMetrics(scale: scale, offsetX: 0, offsetY: 0)
        }

        return ViewMetrics(scale: scale, offsetX: tx, offsetY: ty)
    }
}

/// Backward compatibility alias
typealias ComicGuidedPageView = ComicSpreadGuidedView

// MARK: - Visual Scrubber (Premium redesign)
struct VisualComicScrubber: View {
    @Binding var currentIndex: Int
    let totalPages: Int
    @ObservedObject var cache: ComicImageCache
    var isMangaMode: Bool

    @State private var dragIndex: Int? = nil
    @State private var thumbXOffset: CGFloat = 0

    private let trackHeight: CGFloat = 10
    private let thumbSize: CGFloat = 26

    var body: some View {
        VStack(spacing: 0) {
            // ── Thumbnail preview card (shown while scrubbing) ─────────────────
            if let activeIndex = dragIndex, activeIndex >= 0 && activeIndex < totalPages {
                thumbnailCard(for: activeIndex)
                    .offset(x: clampedThumbOffset)
                    .padding(.bottom, 8)
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottom)))
                    .animation(.spring(response: 0.25, dampingFraction: 0.7), value: dragIndex)
            }

            // ── Track ─────────────────────────────────────────────────────────
            GeometryReader { geo in
                let trackWidth = geo.size.width - thumbSize
                let displayIndex = dragIndex ?? currentIndex
                let normalized = isMangaMode
                    ? CGFloat(totalPages - 1 - displayIndex)
                    : CGFloat(displayIndex)
                let ratio = totalPages > 1 ? min(max(normalized / CGFloat(totalPages - 1), 0), 1) : 0
                let thumbX = ratio * trackWidth

                ZStack(alignment: .leading) {
                    // Track background
                    Capsule()
                        .fill(Color.white.opacity(0.15))
                        .frame(height: trackHeight)

                    // Progress fill — white gradient
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.9), Color.white.opacity(0.6)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: thumbX + thumbSize, height: trackHeight)

                    // Thumb
                    Circle()
                        .fill(Color.white)
                        .frame(width: thumbSize, height: thumbSize)
                        .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                        .overlay(
                            Circle()
                                .stroke(Color.white.opacity(0.4), lineWidth: 1)
                                .scaleEffect(dragIndex != nil ? 1.25 : 1.0)
                                .opacity(dragIndex != nil ? 0 : 0)
                        )
                        // Glow when dragging
                        .shadow(
                            color: dragIndex != nil ? Color.white.opacity(0.35) : .clear,
                            radius: 10
                        )
                        .scaleEffect(dragIndex != nil ? 1.15 : 1.0)
                        .animation(.spring(response: 0.2, dampingFraction: 0.65), value: dragIndex != nil)
                        .offset(x: thumbX)
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { val in
                                    let percentage = min(max(val.location.x / geo.size.width, 0), 1)
                                    let rawIndex = Int(round(percentage * CGFloat(totalPages - 1)))
                                    let targeted = isMangaMode ? (totalPages - 1 - rawIndex) : rawIndex
                                    thumbXOffset = val.location.x - geo.size.width / 2
                                    if dragIndex != targeted {
                                        UISelectionFeedbackGenerator().selectionChanged()
                                        dragIndex = targeted
                                    }
                                }
                                .onEnded { _ in
                                    if let final = dragIndex {
                                        HapticEngine.light()
                                        currentIndex = final
                                    }
                                    dragIndex = nil
                                }
                        )
                }
                .frame(height: thumbSize)
            }
            .frame(height: thumbSize)
        }
    }

    // Clamp thumbnail card so it never goes off-screen edges
    private var clampedThumbOffset: CGFloat {
        max(-80, min(80, thumbXOffset))
    }

    @ViewBuilder
    private func thumbnailCard(for index: Int) -> some View {
        VStack(spacing: 6) {
            ZStack {
                // Frosted background
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .frame(width: 72, height: 104)

                if let img = cache.getThumbnailImage(at: index) {
                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 72, height: 104)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .transition(.opacity)
                } else {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white.opacity(0.5)))
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.5), radius: 14, y: 6)

            // Page number pill
            Text("\(index + 1) / \(totalPages)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 0.5))
        }
    }
}

// MARK: - Transparent UIKeyCommand Responder
struct KeyCommandHandler: UIViewControllerRepresentable {
    let onKeyPress: (UIKeyCommand) -> Void
    
    class Coordinator: NSObject {
        var onKeyPress: ((UIKeyCommand) -> Void)?
        
        @objc func handleKeyCommand(_ sender: UIKeyCommand) {
            onKeyPress?(sender)
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    func makeUIViewController(context: Context) -> UIKeyCommandViewController {
        let vc = UIKeyCommandViewController()
        context.coordinator.onKeyPress = onKeyPress
        vc.coordinator = context.coordinator
        return vc
    }
    
    func updateUIViewController(_ uiViewController: UIKeyCommandViewController, context: Context) {
        context.coordinator.onKeyPress = onKeyPress
        DispatchQueue.main.async {
            if !uiViewController.isFirstResponder {
                uiViewController.becomeFirstResponder()
            }
        }
    }
}

class UIKeyCommandViewController: UIViewController {
    weak var coordinator: KeyCommandHandler.Coordinator?
    
    override var canBecomeFirstResponder: Bool {
        true
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        becomeFirstResponder()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(forceBecomeFirstResponder),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(forceBecomeFirstResponder),
            name: NSNotification.Name("Reader_ForceKeyFocus"),
            object: nil
        )
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func forceBecomeFirstResponder() {
        becomeFirstResponder()
    }
    
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        becomeFirstResponder()
    }
    
    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [], action: #selector(keyTriggered)),
            UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [], action: #selector(keyTriggered)),
            UIKeyCommand(input: " ", modifierFlags: [], action: #selector(keyTriggered)),
            UIKeyCommand(input: "\u{1B}", modifierFlags: [], action: #selector(keyTriggered)) // Escape
        ]
    }
    
    @objc func keyTriggered(_ sender: UIKeyCommand) {
        coordinator?.handleKeyCommand(sender)
    }
}

extension View {
    @ViewBuilder
    func dragGestureOnlyIfZoomed(
        currentScale: CGFloat,
        onChanged: @escaping (DragGesture.Value) -> Void,
        onEnded: @escaping (DragGesture.Value) -> Void
    ) -> some View {
        if currentScale > 1.0 {
            self.gesture(
                DragGesture()
                    .onChanged(onChanged)
                    .onEnded(onEnded)
            )
        } else {
            self
        }
    }
    
    @ViewBuilder
    func dragGestureIfPannable(
        isPannable: Bool,
        onChanged: @escaping (DragGesture.Value) -> Void,
        onEnded: @escaping (DragGesture.Value) -> Void
    ) -> some View {
        if isPannable {
            self.gesture(
                DragGesture(minimumDistance: 10)
                    .onChanged(onChanged)
                    .onEnded(onEnded)
            )
        } else {
            self
        }
    }
}


