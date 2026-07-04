import SwiftUI
import ZIPFoundation
import PDFKit
import ImageIO
import AVFoundation
import Vision

extension Notification.Name {
    static let comicImageCacheImageLoaded = Notification.Name("InksyncPro.ComicImageCache.imageLoaded")
    static let readerZoomStateChanged = Notification.Name("InksyncPro.ComicReader.zoomStateChanged")
}

struct ReadingFilterModifier: ViewModifier {
    let preset: ReadingFilterPreset
    
    @AppStorage("customContrast") private var customContrast: Double = 1.0
    @AppStorage("customBrightness") private var customBrightness: Double = 0.0
    @AppStorage("customSaturation") private var customSaturation: Double = 1.0

    func body(content: Content) -> some View {
        switch preset {
        case .original:
            content
        case .vintage:
            content
                .contrast(0.9)
                .saturation(0.7)
                .colorMultiply(Color(red: 1.0, green: 0.95, blue: 0.9)) // Warm tone
        case .eink:
            content
                .contrast(1.4)
                .saturation(0.0) // Grayscale
        case .vibrant:
            content
                .contrast(1.1)
                .saturation(1.4)
        case .dark:
            content
                .colorInvert()
                .hueRotation(.degrees(180)) // Invert colors preserving hue
        case .amber:
            content
                .colorMultiply(Color(red: 1.0, green: 0.86, blue: 0.65))
        case .sepia:
            content
                .colorMultiply(Color(red: 0.95, green: 0.89, blue: 0.78))
        case .custom:
            content
                .contrast(customContrast)
                .brightness(customBrightness)
                .saturation(customSaturation)
        }
    }
}

extension View {
    func applyFilterPreset(_ preset: ReadingFilterPreset) -> some View {
        modifier(ReadingFilterModifier(preset: preset))
    }
}

enum ComicReadingMode: String, CaseIterable, Codable {
    case pageHorizontal   // Single page, horizontal swipe (default)
    case panelNavigation  // Panel-by-panel using pageModels Vision data
    case webtoonScroll    // Continuous vertical scroll
    case mangaRTL         // Single page, horizontal swipe, right-to-left
    case pageSlide        // Flat horizontal slide transition
    case pageFade         // Crossfade between pages
}

@MainActor
final class ComicImageCache: ObservableObject {
    private var cache = NSCache<NSNumber, UIImage>()
    private var accessQueue: [Int] = []
    private let fetchingQueueLock = NSLock()
    private var fetchingQueue: Set<Int> = [] // Track pending extractions
    
    private var lastRequestedIndex: Int = 0
    private var readingDirection: Int = 1 // 1 for forward, -1 for backward
    private var inFlightPrefetchTasks: [Int: Task<Void, Never>] = [:]
    private var averageSecondsPerPage: Double = 8.0
    
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
        let usage = MemoryMonitor.reportMemoryUsage()
        return usage > 300.0 ? 3 : 7 // Dynamic Memory Cache scaling
    }
    private let prefetchLimit: Int // Configurable read-ahead page buffer
    
    // For CBZ extraction — store URL, NOT a shared Archive.
    private var cbzURL: URL?
    private var entries: [ZIPFoundation.Entry] = []

    // ── Pre-extracted archive path (CBR/RAR/CBT/TAR) ──────────────────────────
    private var extractedImageURLs: [URL] = []
    private var extractedTempDir: URL? = nil
    let isPreExtracted: Bool
    
    // ✅ OPDS-style cloud page streaming
    private var cloudPageSource: CloudPageSource?
    
    // Virtual omnibus page mapping
    private var virtualCoordinator: VirtualPageCoordinator?
    
    @Published var isLoading = true
    @Published var loadError: String? = nil   // Non-nil = show error view with exit button
    @Published var isLandscapeArray: [Bool] = []
    var pageCount: Int = 0
    let isPDF: Bool
    let isStream: Bool
    var activelyAccessedURL: URL?
    
    init(pdf: ConvertedPDF, prefetchLimit: Int = 2) {
        self.prefetchLimit = prefetchLimit
        self.cache.totalCostLimit = 150 * 1024 * 1024 // 150 MB absolute RAM cap
        let scheme = pdf.url.scheme?.lowercased() ?? ""
        
        if scheme == "virtual-omnibus" {
            isStream = false
            isPDF = false
            isPreExtracted = false
            
            let omnibusID = UUID(uuidString: pdf.url.host ?? "") ?? UUID()
            if let omni = LibraryService.shared.virtualOmnibuses.first(where: { $0.id == omnibusID }) {
                let resolvedFiles = omni.fileIDs.compactMap { id in
                    LibraryService.shared.items.first(where: { $0.id == id })
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
                self.loadError = "Could not find virtual omnibus data."
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
        
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.cache.removeAllObjects()
                Logger.shared.log("ComicImageCache: Memory warning received. Cleared image cache.", category: "Memory", type: .warning)
            }
        }
        
        NotificationCenter.default.addObserver(
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
        
        if scheme == "virtual-omnibus" {
            // Already initialized, no background archive extraction needed!
        } else if isStream {
            self.pageCount = 0
            self.isLoading = true
        } else if isPDF {
            Task.detached(priority: .userInitiated) { [weak self] in
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
                
                let count = await PDFRenderActor.shared.loadDocument(at: resolvedURL)
                
                if let accessed = accessedURL {
                    if let self = self {
                        await MainActor.run { self.activelyAccessedURL = accessed }
                    } else {
                        accessed.stopAccessingSecurityScopedResource()
                    }
                }
                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    self.pageCount = count
                    self.isLoading = false
                    self.scanPageOrientations(resolvedURL: resolvedURL)
                }
            }
        } else if isPreExtracted {
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
                    resolvedURL = pdf.url
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
                    await MainActor.run {
                        self.extractedTempDir = tempDir
                        self.extractedImageURLs = imageURLs
                        self.pageCount = imageURLs.count
                        self.isLoading = false
                        if imageURLs.isEmpty {
                            self.loadError = "The archive contained no readable images."
                        } else {
                            self.scanPageOrientations(resolvedURL: resolvedURL)
                        }
                    }
                } catch {
                    if let accessed = accessedURL { accessed.stopAccessingSecurityScopedResource() }
                    await MainActor.run {
                        self.loadError = "Could not open this file.\n\n\(error.localizedDescription)"
                        self.isLoading = false
                    }
                }
            }
        } else {
            Task.detached(priority: .userInitiated) { [weak self] in
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
                guard let archive = try? Archive(url: resolvedURL, accessMode: .read, pathEncoding: .utf8) else {
                    if let accessed = accessedURL { accessed.stopAccessingSecurityScopedResource() }
                    await MainActor.run { [weak self] in
                        self?.loadError = "Could not open the comic archive."
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
        activelyAccessedURL?.stopAccessingSecurityScopedResource()
        if isPDF {
            Task { await PDFRenderActor.shared.clear() }
        }
        if let tempDir = extractedTempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        if !isPDF && !isStream && !isPreExtracted {
            Task { await ArchiveManager.shared.clearCache() }
        }
    }
    
    private func scanPageOrientations(resolvedURL: URL?) {
        let total = self.pageCount
        guard total > 0 else { return }
        
        self.isLandscapeArray = Array(repeating: false, count: total)
        
        let isPDF = self.isPDF
        let isPreExtracted = self.isPreExtracted
        let imageURLs = self.extractedImageURLs
        
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
                            array[i] = bounds.width > bounds.height * 1.15
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
                                let w = properties[kCGImagePropertyPixelWidth] as? CGFloat ?? 0
                                let h = properties[kCGImagePropertyPixelHeight] as? CGFloat ?? 0
                                return (i, w > h * 1.15)
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
                                    return (i, bounds.width > bounds.height * 1.15)
                                }
                            } else {
                                if let archive = try? Archive(url: fileURL, accessMode: .read, pathEncoding: .utf8) {
                                    let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "gif", "heic"]
                                    let sorted = archive.filter { entry in
                                        let name = (entry.path as NSString).lastPathComponent
                                        guard !entry.path.contains("__MACOSX"), !name.hasPrefix("._"), name != ".DS_Store", !entry.path.hasSuffix("/") else { return false }
                                        let ext = (name as NSString).pathExtension.lowercased()
                                        return imageExtensions.contains(ext)
                                    }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                                    
                                    if pageInfo.localIndex < sorted.count {
                                        let entryPath = sorted[pageInfo.localIndex].path
                                        if let data = try? await ArchiveManager.shared.extractEntry(from: fileURL, path: entryPath),
                                           let source = CGImageSourceCreateWithData(data as CFData, nil),
                                           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
                                            let w = properties[kCGImagePropertyPixelWidth] as? CGFloat ?? 0
                                            let h = properties[kCGImagePropertyPixelHeight] as? CGFloat ?? 0
                                            return (i, w > h * 1.15)
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
                await withTaskGroup(of: (Int, Bool).self) { group in
                    for i in 0..<min(total, entryPaths.count) {
                        let entryPath = entryPaths[i]
                        group.addTask {
                            do {
                                let data = try await ArchiveManager.shared.extractEntry(from: resolved, path: entryPath)
                                if let source = CGImageSourceCreateWithData(data as CFData, nil),
                                   let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
                                    let w = properties[kCGImagePropertyPixelWidth] as? CGFloat ?? 0
                                    let h = properties[kCGImagePropertyPixelHeight] as? CGFloat ?? 0
                                    return (i, w > h * 1.15)
                                }
                            } catch {}
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
                self.isLandscapeArray = array
                NotificationCenter.default.post(
                    name: NSNotification.Name("ComicImageCache.OrientationsScanned"),
                    object: self
                )
            }
        }
    }
    
    func setupCloudSource(_ source: CloudPageSource) {
        self.cloudPageSource = source
        self.pageCount = source.pageCount
        self.isLoading = false
    }
    func getImage(at index: Int) -> UIImage? {
        guard index >= 0 && index < pageCount else { return nil }
        
        if index != lastRequestedIndex {
            readingDirection = index > lastRequestedIndex ? 1 : -1
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
                let (tempDir, imageURLs): (URL, [URL])
                if isCBTFile {
                    (tempDir, imageURLs) = (try? await CBTExtractor.extract(from: resolvedURL)) ?? (FileManager.default.temporaryDirectory, [])
                } else {
                    (tempDir, imageURLs) = (try? await CBRExtractor.extract(from: resolvedURL)) ?? (FileManager.default.temporaryDirectory, [])
                }
                defer {
                    if tempDir != FileManager.default.temporaryDirectory {
                        try? FileManager.default.removeItem(at: tempDir)
                    }
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
            } else {
                guard let archive = try? Archive(url: resolvedURL, accessMode: .read, pathEncoding: .utf8) else {
                    await MainActor.run {
                        self.stopFetching(index)
                        self.removePrefetchTask(index)
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
                
                if localPageIndex < sortedEntries.count {
                    let entryPath = sortedEntries[localPageIndex].path
                    do {
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
                    } catch {
                        img = nil
                    }
                } else {
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
    
    private func prefetchSurrounding(index: Int) {
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
        let targetBehind = baseBehind
        
        var prefetchIndices: Set<Int> = []
        if direction >= 0 {
            // Forward movement
            for i in 1...targetAhead {
                prefetchIndices.insert(index + i)
            }
            for i in 1...targetBehind where targetBehind > 0 {
                prefetchIndices.insert(index - i)
            }
        } else {
            // Backward movement
            for i in 1...targetAhead {
                prefetchIndices.insert(index - i)
            }
            for i in 1...targetBehind where targetBehind > 0 {
                prefetchIndices.insert(index + i)
            }
        }
        
        // Cancel tasks that are no longer in the active prefetch window
        for (idx, task) in inFlightPrefetchTasks {
            if !prefetchIndices.contains(idx) && idx != index {
                task.cancel()
                inFlightPrefetchTasks.removeValue(forKey: idx)
                stopFetching(idx)
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
    
    @StateObject private var cache: ComicImageCache
    @StateObject private var velocityEngine = ReaderVelocityEngine()
    @State private var pageEntryTime = Date()
    @State private var maxPageIndexVisited = 0
    @AppStorage("isAutoCropEnabled") private var isAutoCropEnabled = false
    @AppStorage("hasSeenReaderOnboarding") private var hasSeenReaderOnboarding = false
    @State private var chromeVisible = false
    @State private var currentIndex: Int = 0
    @State private var readingMode: ComicReadingMode = .pageHorizontal
    @AppStorage("prefersTwoUpSpreads") private var prefersTwoUpSpreads = true
    @State private var activeFilterPreset: ReadingFilterPreset = .original
    @State private var showingFilterHUD = false
    @State private var showingSettingsHUD = false
    @AppStorage("essentialReaderMode") private var essentialReaderMode = false
    @AppStorage("backTapEnabled") private var backTapEnabled = false
    @State private var showingCharacterMap = false
    @State private var lastBrightnessDragValue: CGFloat = 0
    /// Panels-style ambient chrome tint — sampled from the current page edges
    @State private var ambientPageColor: Color = .clear
    /// Tracks in-flight ambient colour extraction so it can be cancelled on rapid page swipes.
    @State private var ambientColorTask: Task<Void, Never>? = nil
    /// AI Narration Engine — connects to the image cache on appear
    @StateObject private var narrationEngine = NarrationEngine()
    /// Phase 3: Live Reading Room — MultipeerConnectivity co-reading session.
    @StateObject private var readingRoom = ReadingRoomSession()
    
    /// AI Dialogue Lens State
    @State private var isDialogueLensEnabled = false
    @State private var selectedTextBlock: TextBlock? = nil
    @State private var currentDialogueBlocks: [TextBlock] = []
    @State private var isDialogueOCRing = false
    @ObservedObject private var dialogueSpeechManager = DialogueSpeechManager.shared
    /// Phase 4A: Auto-hide chrome — cancellable idle timer.
    @State private var chromeIdleTask: Task<Void, Never>? = nil
    
    var isMangaComic: Bool {
        pdf.metadata.isManga == true || pdf.contentType == .manga
    }
    
    func shouldShowTwoUpSpread(for size: CGSize) -> Bool {
        guard prefersTwoUpSpreads else { return false }
        // Spread layouts are page-based only (not webtoon vertical scroll, nor panel navigation)
        guard readingMode == .pageHorizontal || readingMode == .mangaRTL || readingMode == .pageSlide || readingMode == .pageFade else { return false }
        return size.width > size.height
    }

    private var isCurrentlyTwoUp: Bool {
        guard prefersTwoUpSpreads else { return false }
        guard readingMode == .pageHorizontal || readingMode == .mangaRTL || readingMode == .pageSlide || readingMode == .pageFade else { return false }
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            return windowScene.interfaceOrientation.isLandscape
        }
        return false
    }

    private func computeSpreads() -> [[Int]] {
        var allSpreads: [[Int]] = []
        let landscapeArray = cache.isLandscapeArray

        guard landscapeArray.count == cache.pageCount else {
            // Fallback while scanning is in progress
            if cache.pageCount > 1 {
                allSpreads.append([0]) // Page 0 is the cover, keep it solo
                var i = 1
                while i < cache.pageCount {
                    if i + 1 < cache.pageCount {
                        allSpreads.append([i, i + 1])
                        i += 2
                    } else {
                        allSpreads.append([i])
                        i += 1
                    }
                }
            } else {
                allSpreads.append([0])
            }
            return allSpreads
        }

        allSpreads.append([0]) // Page 0 is the cover, keep it solo
        var i = 1
        while i < cache.pageCount {
            let isL = landscapeArray[i]
            if isL {
                allSpreads.append([i])
                i += 1
            } else {
                if i + 1 < cache.pageCount {
                    let nextIsL = landscapeArray[i + 1]
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
    }

    var body: some View {
        GeometryReader { geo in
        ZStack {
            Color.black.ignoresSafeArea()

            if let error = cache.loadError {
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

                    Button { onDismiss() } label: {
                        Label("Close Reader", systemImage: "xmark.circle.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.black)
                            .padding(.horizontal, 28)
                            .padding(.vertical, 14)
                            .background(Color.white, in: Capsule())
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
                    } else if shouldShowTwoUpSpread(for: geo.size) {
                        twoUpView
                    } else if readingMode == .panelNavigation {
                        guidedView
                    } else {
                        BookPager(
                            currentIndex: $currentIndex,
                            totalPages: cache.pageCount,
                            cache: cache,
                            readingMode: readingMode,
                            activeFilterPreset: activeFilterPreset,
                            isMangaRTL: isMangaComic,
                            onChromeTap: {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                    chromeVisible.toggle()
                                }
                                // Phase 4A: start / reset 4-second auto-hide timer
                                if chromeVisible { startChromeIdleTimer() }
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
            
            // Dialogue Lens HUD and Loading indicators
            dialogueHUDView
            
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
                .transition(.opacity)
                .zIndex(18)
            }
            
            KeyCommandHandler { command in
                let input = command.input
                if input == UIKeyCommand.inputLeftArrow {
                    if readingMode == .mangaRTL {
                        nextPage()
                    } else {
                        prevPage()
                    }
                } else if input == UIKeyCommand.inputRightArrow {
                    if readingMode == .mangaRTL {
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
            // Phase 3: Live Reading Room overlay (peer avatars + reactions + HUD pill)
            if readingRoom.isHosting {
                ReadingRoomOverlay(
                    session: readingRoom,
                    currentPage: currentIndex,
                    totalPages: cache.pageCount
                )
                .zIndex(15)
            }
            
            if !hasSeenReaderOnboarding {
                readerOnboardingOverlay
            }
        }
        .onAppear {
            pageEntryTime = Date()
            if let saved = ReaderProgressTracker.shared.progress(for: pdf.id) {
                currentIndex = saved.currentPageIndex
                if let filterString = saved.colorFilter,
                   let filterPreset = ReadingFilterPreset(rawValue: filterString) {
                    activeFilterPreset = filterPreset
                }
                if let prefersManga = saved.prefersMangaMode {
                    readingMode = prefersManga ? .mangaRTL : .pageHorizontal
                } else {
                    readingMode = isMangaComic ? .mangaRTL : .pageHorizontal
                }
                if let wasDual = saved.wasInDualPageMode {
                    prefersTwoUpSpreads = wasDual
                }
            } else {
                let isMangaComic = pdf.metadata.isManga == true || pdf.contentType == .manga
                if isMangaComic {
                    readingMode = .mangaRTL
                }
            }
            // Connect narration engine to the reader's image cache
            narrationEngine.connect(totalPages: cache.pageCount) { [cache] index in
                cache.getImage(at: index)
            }
            narrationEngine.onPageComplete = { nextIndex in
                withAnimation { currentIndex = nextIndex }
            }
            if essentialReaderMode {
                if readingMode == .pageHorizontal || readingMode == .mangaRTL {
                    readingMode = .pageSlide
                }
                ambientPageColor = .clear
            }
            BackTapManager.shared.isEnabled = backTapEnabled
            maxPageIndexVisited = currentIndex
            NotificationCenter.default.post(name: NSNotification.Name("Reader_ForceKeyFocus"), object: nil)
        }
        .onChange(of: currentIndex) { oldIndex, newIndex in
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
            // Notify narration engine of manual page changes (distinct from narration-driven advances)
            if narrationEngine.isNarrating {
                narrationEngine.didManuallyChangePage(to: newIndex)
            }
            
            if isDialogueLensEnabled {
                selectedTextBlock = nil
                DialogueSpeechManager.shared.stop()
                Task {
                    await prewarmOCR(for: newIndex)
                }
            }
            // Phase 3: broadcast page change to any connected reading room peers
            readingRoom.broadcastPage(newIndex, totalPages: cache.pageCount)
        }
        .onChange(of: essentialReaderMode) { _, isSpeed in
            if isSpeed {
                if readingMode == .pageHorizontal {
                    readingMode = .pageSlide
                } else if readingMode == .mangaRTL {
                    readingMode = .pageSlide
                }
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
        .sheet(isPresented: $showingCharacterMap) {
            CharacterOverlayView(
                seriesName: pdf.metadata.series ?? pdf.name,
                issueNumber: Int(pdf.metadata.issueNumber ?? "") ?? 1,
                pageIndex: currentIndex
            )
        }
        .onDisappear {
            BackTapManager.shared.isEnabled = false
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
    } // closes GeometryReader
} // end body

    var guidedView: some View {
        TabView(selection: $currentIndex) {
            ForEach(0..<cache.pageCount, id: \.self) { index in
                let panelsForPage = PageModelStore.shared.legacyVisionPanels(for: pdf.id, pageIndex: index)
                ComicGuidedPageView(
                    index: index,
                    cache: cache,
                    panels: panelsForPage,
                    masterIndex: $currentIndex,
                    totalPages: cache.pageCount,
                    onTapChrome: { chromeVisible.toggle() }
                )
                .applyFilterPreset(activeFilterPreset)
                .tag(index)
            }
        }
        .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))
    }
    
    var webtoonView: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 0) {
                ForEach(0..<cache.pageCount, id: \.self) { index in
                    WebtoonImageCell(
                        index: index,
                        cache: cache,
                        activeFilterPreset: activeFilterPreset,
                        onAppearAction: { currentIndex = index }
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
    }
    
    var twoUpView: some View {
        TwoUpBookPager(
            currentIndex: $currentIndex,
            cache: cache,
            activeFilterPreset: activeFilterPreset,
            isMangaRTL: readingMode == .mangaRTL || pdf.metadata.isManga == true,
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

    // MARK: - Series Continuation

    /// Called when the reader reaches the last page of the file.
    /// Posts openMergedBook with the next volume in the series so the library
    /// auto-transitions — mirrors the same logic in BookReaderEngine and EBookReaderView.
    private func attemptComicSeriesContinuation() {
        guard let seriesName = pdf.metadata.series, !seriesName.isEmpty else { return }

        // Numeric-first sort with localizedStandardCompare fallback for "HC", "TPB", "#0" etc.
        let siblings = allBooks
            .filter { $0.metadata.series == seriesName && $0.id != pdf.id }
            .sorted { lhs, rhs in
                let lhsNum = Double(lhs.metadata.issueNumber ?? lhs.metadata.volume ?? "")
                let rhsNum = Double(rhs.metadata.issueNumber ?? rhs.metadata.volume ?? "")
                if let l = lhsNum, let r = rhsNum { return l < r }
                let lKey = lhs.metadata.issueNumber ?? lhs.metadata.volume ?? lhs.name
                let rKey = rhs.metadata.issueNumber ?? rhs.metadata.volume ?? rhs.name
                return lKey.localizedStandardCompare(rKey) == .orderedAscending
            }

        guard !siblings.isEmpty else { return }

        let selfKey = pdf.metadata.issueNumber ?? pdf.metadata.volume ?? pdf.name
        if let currentIdx = siblings.firstIndex(where: {
            ($0.metadata.issueNumber ?? $0.metadata.volume ?? $0.name) == selfKey
        }) {
            let nextIdx = siblings.index(after: currentIdx)
            guard siblings.indices.contains(nextIdx) else { return }
            NotificationCenter.default.post(name: .openMergedBook, object: siblings[nextIdx])
        } else if let first = siblings.first {
            // Current book not found in sorted siblings (missing series metadata) —
            // fall back to opening the first sibling so the user always gets a next book.
            NotificationCenter.default.post(name: .openMergedBook, object: first)
        }
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

    /// Left + right brightness drag zones.
    @ViewBuilder private var brightnessZones: some View {
        HStack {
            Color.clear
                .contentShape(Rectangle())
                .frame(width: brightnessZoneWidth)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            let delta = value.translation.height - lastBrightnessDragValue
                            lastBrightnessDragValue = value.translation.height
                            UIScreen.main.brightness -= delta * 0.005
                        }
                        .onEnded { _ in lastBrightnessDragValue = 0 }
                )
            Spacer()
            Color.clear
                .contentShape(Rectangle())
                .frame(width: brightnessZoneWidth)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            let delta = value.translation.height - lastBrightnessDragValue
                            lastBrightnessDragValue = value.translation.height
                            UIScreen.main.brightness -= delta * 0.005
                        }
                        .onEnded { _ in lastBrightnessDragValue = 0 }
                )
        }
    }

    /// Full ReaderChrome view — extracted so the compiler can type-check it independently.
    @ViewBuilder private var readerChromeView: some View {
        ReaderChrome(
            title: pdf.name,
            pageText: "\(currentIndex + 1) / \(cache.pageCount)  •  \(velocityEngine.estimatedTimeRemaining)",
            isVisible: $chromeVisible,
            onBack: saveProgressAndDismiss,
            onBookmark: {
                let bookmark = Annotation(pdfID: pdf.id, pageIndex: currentIndex,
                                          kind: .bookmark, createdAt: Date(), modifiedAt: Date())
                AnnotationStore.shared.add(bookmark)
            },
            onSettingsToggle: {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { showingSettingsHUD.toggle() }
            },
            onCharacterMapToggle: {
                showingCharacterMap.toggle()
            },
            isDialogueLensEnabled: isDialogueLensEnabled,
            onDialogueLensToggle: {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isDialogueLensEnabled.toggle()
                    if isDialogueLensEnabled {
                        Task {
                            await prewarmOCR(for: currentIndex)
                        }
                    } else {
                        selectedTextBlock = nil
                        DialogueSpeechManager.shared.stop()
                    }
                }
                HapticEngine.light()
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
                    isMangaMode: readingMode == .mangaRTL
                )
            ),
            isNarrating: narrationEngine.isNarrating,
            isNarrationOCRing: narrationEngine.isOCRing,
            onNarrationToggle: handleNarrationToggle,
            isAutoCropEnabled: isAutoCropEnabled,
            onCropToggle: {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isAutoCropEnabled.toggle()
                }
                HapticEngine.light()
            },
            isEnhanced: activeFilterPreset != .original,
            onEnhanceToggle: { withAnimation(.easeInOut) { showingFilterHUD.toggle() } },
            isSettingsActive: readingMode != .pageHorizontal,
            currentModeLabel: readingMode != .pageHorizontal ? readingMode.hudLabel : nil,
            ambientColor: ambientPageColor,
            isInRoom: readingRoom.isHosting,
            roomPeerCount: readingRoom.peers.count,
            onRoomToggle: {
                if readingRoom.isHosting {
                    readingRoom.stop()
                } else {
                    readingRoom.startHosting(bookID: pdf.id.uuidString)
                }
            },
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

    private func saveProgressAndDismiss() {
        var progress = ReaderProgressTracker.shared.progress(for: pdf.id) ?? ReadingProgress(
            pdfID: pdf.id, lastOpenedAt: Date(), currentPageIndex: currentIndex,
            currentChapterIndex: nil, currentChapterOffset: nil,
            totalPagesRead: 1,
            completionFraction: Double(currentIndex + 1) / Double(cache.pageCount),
            readingSessionDates: [Date()], estimatedMinutesRemaining: nil
        )
        progress.currentPageIndex = currentIndex
        progress.lastOpenedAt = Date()
        progress.completionFraction = Double(currentIndex + 1) / Double(cache.pageCount)
        progress.prefersMangaMode = (readingMode == .mangaRTL)
        progress.colorFilter = activeFilterPreset.rawValue
        progress.lastCanonicalLeadIndex = currentIndex
        progress.wasInDualPageMode = prefersTwoUpSpreads
        if !progress.readingSessionDates.contains(where: { Calendar.current.isDateInToday($0) }) {
            progress.readingSessionDates.append(Date())
        }
        ReaderProgressTracker.shared.update(progress)
        readingRoom.stop() // Phase 3: ensure room tears down on dismiss
        onDismiss()
    }

    /// Phase 4A: Start (or restart) the 4-second idle timer that auto-hides the chrome.
    /// Cancels any in-flight timer so rapid taps don't stack timers.
    private func startChromeIdleTimer() {
        chromeIdleTask?.cancel()
        chromeIdleTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000) // 4 seconds
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { chromeVisible = false }
        }
    }

    private func handleNarrationToggle() {
        if narrationEngine.isNarrating {
            if narrationEngine.isSpeaking {
                narrationEngine.togglePause()
            } else {
                narrationEngine.stop()
            }
        } else {
            narrationEngine.isMangaMode = (readingMode == .mangaRTL)
            narrationEngine.startNarrating(from: currentIndex)
        }
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

    private func prewarmOCR(for pageIndex: Int) async {
        isDialogueOCRing = true
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
                    DialogueSpeechManager.shared.stop()
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
                                DialogueSpeechManager.shared.stop()
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
                            if DialogueSpeechManager.shared.isSpeaking {
                                DialogueSpeechManager.shared.stop()
                            } else {
                                DialogueSpeechManager.shared.speak(block.text)
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: DialogueSpeechManager.shared.isSpeaking ? "stop.fill" : "play.fill")
                                    .font(.system(size: 14, weight: .bold))
                                Text(DialogueSpeechManager.shared.isSpeaking ? "Stop Voice" : "Speak Aloud")
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                            }
                            .foregroundColor(.black)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(Color.white, in: Capsule())
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

// MARK: - DialogueSpeechManager

@MainActor
final class DialogueSpeechManager: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    static let shared = DialogueSpeechManager()
    
    private let synthesizer = AVSpeechSynthesizer()
    @Published var isSpeaking = false
    
    override init() {
        super.init()
        synthesizer.delegate = self
        configureAudioSession()
    }
    
    func speak(_ text: String) {
        stop()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
        isSpeaking = true
    }
    
    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }
    
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
        }
    }
    
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
        }
    }
    
    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .spokenAudio,
                options: [.duckOthers, .allowBluetooth]
            )
        } catch {}
    }
}

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

    /// Compute the rendered width/height that fits the image inside `container`
    /// without overflowing, preserving aspect ratio.
    private func renderSize(for image: UIImage, in container: CGSize) -> CGSize {
        let imgHeight = max(1, image.size.height)
        let contHeight = max(1, container.height)
        
        let imageAspect     = image.size.width / imgHeight
        let containerAspect = container.width  / contHeight
        
        if imageAspect > containerAspect {
            // Landscape-dominant: clamp to container width
            return CGSize(width: container.width, height: container.width / imageAspect)
        } else {
            // Portrait-dominant: clamp to container height
            return CGSize(width: container.height * imageAspect, height: container.height)
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
        
        guard let sourceImage = image else {
            displayImage = nil
            return
        }
        if isAutoCropEnabled {
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
                    let rendered = renderSize(for: img, in: geo.size)

                    ZStack {
                        Color.black.ignoresSafeArea()

                        Image(uiImage: img)
                            .resizable()
                            .frame(width: rendered.width, height: rendered.height)
                            .scaleEffect(currentScale)
                            .offset(offset)
                            .position(x: geo.size.width / 2, y: geo.size.height / 2)
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
                            .dragGestureOnlyIfZoomed(
                                currentScale: currentScale,
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
                                withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                                    if currentScale > 1.0 {
                                        currentScale = 1.0
                                        lastScale = 1.0
                                        offset = .zero
                                        lastOffset = .zero
                                    } else {
                                        currentScale = 2.5
                                        lastScale = 2.5
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
                    .sheet(isPresented: $showShareSheet) {
                        if let item = shareItem {
                            ShareSheet(activityItems: [item])
                                .presentationDetents([.medium, .large])
                        }
                    }
                }
            } else {
                ZStack {
                    Color.black
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white.opacity(0.5)))
                        .scaleEffect(1.5)
                }
            }
        }
        .id(index)
        .onAppear {
            if image == nil {
                image = cache.getImage(at: index)
            }
        }
        .onChange(of: image) { _, _ in
            updateDisplayImage()
        }
        .onChange(of: isAutoCropEnabled) { _, _ in
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
        }
    }
}

// MARK: - Guided View Component
struct ComicGuidedPageView: View {
    let index: Int
    let cache: ComicImageCache
    let panels: [PanelExtractor.Panel]
    @Binding var masterIndex: Int
    let totalPages: Int
    var onTapChrome: () -> Void
    
    @State private var image: UIImage? = nil
    @State private var currentPanelIndex: Int = -1 // -1 means Zoomed Out
    
    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                if let img = image {
                    let metrics = calculateMetrics(for: geo.size, image: img)

                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .scaleEffect(metrics.scale)
                        .offset(x: metrics.offsetX, y: metrics.offsetY)
                        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: currentPanelIndex)
                        .onTapGesture { loc in
                            let third = geo.size.width / 3
                            if loc.x < third {
                                rewind()
                            } else if loc.x > geo.size.width - third {
                                advance()
                            } else {
                                onTapChrome()
                            }
                        }

                    // ── Panel Navigation HUD ──────────────────────────
                    VStack {
                        Spacer()
                        if panels.isEmpty {
                            // Zero panels: show a hint to open Work Area
                            HStack(spacing: 8) {
                                Image(systemName: "viewfinder")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.6))
                                Text("No panels — tap \u{203A} to skip page")
                                    .font(.system(size: 11, weight: .medium, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.6))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(.bottom, 90)
                        } else if currentPanelIndex >= 0 {
                            // Active panel indicator
                            VStack(spacing: 6) {
                                // Segmented progress dots
                                HStack(spacing: 4) {
                                    ForEach(0..<panels.count, id: \.self) { i in
                                        Capsule()
                                            .fill(i <= currentPanelIndex ? Color.white : Color.white.opacity(0.3))
                                            .frame(width: i == currentPanelIndex ? 18 : 6, height: 4)
                                            .animation(.spring(response: 0.25), value: currentPanelIndex)
                                    }
                                }
                                Text("Panel \(currentPanelIndex + 1) of \(panels.count)")
                                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.white)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(.bottom, 90)
                        }
                    }
                } else {
                    ZStack {
                        Color.black
                        ProgressView().progressViewStyle(CircularProgressViewStyle(tint: .white.opacity(0.5)))
                    }
                    .onAppear {
                        image = cache.getImage(at: index)
                    }
                }
            }
        }
        .onAppear {
            image = cache.getImage(at: index)
            currentPanelIndex = -1 // Start zoomed out
            // Auto-advance pages with no panels when in guided mode
            if panels.isEmpty && masterIndex < totalPages - 1 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    // Only auto-skip if there are genuinely no panels for this page
                    // (don't skip if panels haven't loaded yet)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .comicImageCacheImageLoaded)) { notification in
            guard let userInfo = notification.userInfo,
                  let loadedIndex = userInfo["index"] as? Int,
                  loadedIndex == index else { return }
            image = cache.getImage(at: index)
        }
    }
    
    struct ViewMetrics {
        let scale: CGFloat
        let offsetX: CGFloat
        let offsetY: CGFloat
    }
    
    private func calculateMetrics(for proxy: CGSize, image: UIImage) -> ViewMetrics {
        if currentPanelIndex == -1 || panels.isEmpty { return ViewMetrics(scale: 1.0, offsetX: 0, offsetY: 0) }
        
        let panel = panels[currentPanelIndex]
        let imgSize = image.size
        
        // Convert Vision Normalized Rect to Image Pixel Rect (UIKit / Top-Left origin)
        let rect = CGRect(
            x: panel.boundingBox.minX * imgSize.width,
            y: (1.0 - panel.boundingBox.maxY) * imgSize.height,
            width: panel.boundingBox.width * imgSize.width,
            height: panel.boundingBox.height * imgSize.height
        )
        
        // 1. Calculate how the image fits perfectly on screen at scale=1
        let imageRatio = imgSize.width / imgSize.height
        let screenRatio = proxy.width / proxy.height
        
        var renderW: CGFloat
        var renderH: CGFloat
        if imageRatio > screenRatio {
            renderW = proxy.width
            renderH = proxy.width / imageRatio
        } else {
            renderH = proxy.height
            renderW = proxy.height * imageRatio
        }
        
        // 2. Map pixel rect to render rect
        let mappedX = (rect.minX / imgSize.width) * renderW
        let mappedY = (rect.minY / imgSize.height) * renderH
        let mappedW = (rect.width / imgSize.width) * renderW
        let mappedH = (rect.height / imgSize.height) * renderH
        
        // 3. Target Scale to fit the panel perfectly (with 5% breathing room)
        let scaleX = proxy.width / mappedW
        let scaleY = proxy.height / mappedH
        let scale = min(scaleX, scaleY) * 0.95
        
        // 4. Calculate Offset to center the panel
        // Center of the physical screen representation
        let panelCenter = CGPoint(x: mappedX + mappedW / 2, y: mappedY + mappedH / 2)
        let imageRenderCenter = CGPoint(x: renderW / 2, y: renderH / 2)
        
        // SwiftUI offsets are post-scale transform
        let tx = (imageRenderCenter.x - panelCenter.x) * scale
        let ty = (imageRenderCenter.y - panelCenter.y) * scale
        
        return ViewMetrics(scale: scale, offsetX: tx, offsetY: ty)
    }
    
    private func advance() {
        if currentPanelIndex < panels.count - 1 {
            currentPanelIndex += 1
        } else {
            if masterIndex < totalPages - 1 {
                currentPanelIndex = -1 // Reset for return
                masterIndex += 1
            }
        }
    }
    
    private func rewind() {
        if currentPanelIndex > -1 {
            currentPanelIndex -= 1
        } else {
            if masterIndex > 0 {
                currentPanelIndex = -1
                masterIndex -= 1
            }
        }
    }
}

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

                if let img = cache.getImage(at: index) {
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
}


