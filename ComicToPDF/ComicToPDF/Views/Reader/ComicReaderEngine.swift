import SwiftUI
import ZIPFoundation
import PDFKit
import ImageIO

extension Notification.Name {
    static let comicImageCacheImageLoaded = Notification.Name("InksyncPro.ComicImageCache.imageLoaded")
}

extension View {
    @ViewBuilder
    func applyFilterPreset(_ preset: ReadingFilterPreset) -> some View {
        switch preset {
        case .original:
            self
        case .vintage:
            self
                .contrast(0.9)
                .saturation(0.7)
                .colorMultiply(Color(red: 1.0, green: 0.95, blue: 0.9)) // Warm tone
        case .eink:
            self
                .contrast(1.4)
                .saturation(0.0) // Grayscale
        case .vibrant:
            self
                .contrast(1.1)
                .saturation(1.4)
        case .dark:
            self
                .colorInvert()
                .hueRotation(.degrees(180)) // Invert colors preserving hue
        case .amber:
            self
                .colorMultiply(Color(red: 1.0, green: 0.86, blue: 0.65))
        case .sepia:
            self
                .colorMultiply(Color(red: 0.95, green: 0.89, blue: 0.78))
        }
    }
}

enum ComicReadingMode: String, CaseIterable, Codable {
    case pageHorizontal   // Single page, horizontal swipe (default)
    case pageTwoUp        // Two-page spread, landscape
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
    private var fetchingQueue: Set<Int> = [] // Track pending extractions
    private var maxCacheSize: Int {
        let usage = MemoryMonitor.reportMemoryUsage()
        return usage > 300.0 ? 3 : 7 // Dynamic Memory Cache scaling
    }
    private let prefetchLimit: Int // Configurable read-ahead page buffer
    
    // For CBZ extraction — store URL, NOT a shared Archive.
    private var cbzURL: URL?
    private var entries: [ZIPFoundation.Entry] = []

    // ── CBR/RAR path ──────────────────────────────────────────────────────────
    private var extractedCBRImageURLs: [URL] = []
    private var extractedCBRTempDir: URL? = nil
    let isCBR: Bool
    
    // ✅ OPDS-style cloud page streaming
    private var cloudPageSource: CloudPageSource?
    
    @Published var isLoading = true
    @Published var loadError: String? = nil   // Non-nil = show error view with exit button
    var pageCount: Int = 0
    let isPDF: Bool
    let isStream: Bool
    var activelyAccessedURL: URL?
    
    init(pdf: ConvertedPDF, prefetchLimit: Int = 2) {
        self.prefetchLimit = prefetchLimit
        let scheme = pdf.url.scheme?.lowercased() ?? ""
        isStream = (scheme == "http" || scheme == "https")
        
        let ext = pdf.url.pathExtension.lowercased()
        isPDF = (ext == "pdf")
        let isCBRFile = (ext == "cbr" || ext == "rar")
        self.isCBR = isCBRFile
        
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
            Task { @MainActor in
                guard let self = self else { return }
                guard let userInfo = notification.userInfo,
                      let pdfID = userInfo["pdfID"] as? UUID,
                      let newURL = userInfo["newURL"] as? URL,
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
        
        if isStream {
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
                    self?.pageCount = count
                    self?.isLoading = false
                }
            }
        } else if isCBRFile {
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
                    let (tempDir, imageURLs) = try await CBRExtractor.extract(from: resolvedURL)
                    if let accessed = accessedURL {
                        await MainActor.run { self.activelyAccessedURL = accessed }
                    }
                    await MainActor.run {
                        self.extractedCBRTempDir = tempDir
                        self.extractedCBRImageURLs = imageURLs
                        self.pageCount = imageURLs.count
                        self.isLoading = false
                        if imageURLs.isEmpty {
                            self.loadError = "The CBR/RAR archive contained no readable images."
                        }
                    }
                } catch {
                    if let accessed = accessedURL { accessed.stopAccessingSecurityScopedResource() }
                    await MainActor.run {
                        self.loadError = "Could not open this CBR/RAR file.\n\n\(error.localizedDescription)"
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
                    self?.cbzURL = resolvedURL
                    self?.entries = sortedEntries
                    self?.pageCount = sortedEntries.count
                    self?.isLoading = false
                }
            }
        }
    }
    
    deinit {
        activelyAccessedURL?.stopAccessingSecurityScopedResource()
        if isPDF {
            Task { await PDFRenderActor.shared.clear() }
        }
        if let tempDir = extractedCBRTempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        if !isPDF && !isStream && !isCBR {
            Task { await ArchiveManager.shared.clearCache() }
        }
    }
    
    func setupCloudSource(_ source: CloudPageSource) {
        self.cloudPageSource = source
        self.pageCount = source.pageCount
        self.isLoading = false
    }

    func getImage(at index: Int) -> UIImage? {
        guard index >= 0 && index < pageCount else { return nil }
        
        if let cachedImage = cache.object(forKey: NSNumber(value: index)) {
            updateLRUOnMain(index)
            return cachedImage
        }
        
        if fetchingQueue.contains(index) { return nil }
        
        if isStream && cloudPageSource != nil {
            fetchCloudPageImage(at: index)
        } else if !isStream {
            fetchLocalImageAsync(at: index)
        }
        
        prefetchSurrounding(index: index)
        return nil
    }
    
    func peekImageSize(at index: Int) -> CGSize? {
        guard index >= 0 && index < pageCount else { return nil }
        return cache.object(forKey: NSNumber(value: index))?.size
    }
    
    private func fetchLocalImageAsync(at index: Int) {
        fetchingQueue.insert(index)
        
        let isPDF = self.isPDF
        let isCBR = self.isCBR
        let cbzURL = self.cbzURL
        let extractedCBRImageURLs = self.extractedCBRImageURLs
        let entryPath: String? = (index < entries.count) ? entries[index].path : nil
        let bounds = UIScreen.main.bounds
        let scale = UIScreen.main.scale
        
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            
            let img = await ComicImageCache.extractOrRenderImageBackground(
                at: index,
                isPDF: isPDF,
                isCBR: isCBR,
                cbzURL: cbzURL,
                extractedCBRImageURLs: extractedCBRImageURLs,
                entryPath: entryPath,
                bounds: bounds,
                scale: scale
            )
            
            if let img {
                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    self.cache.setObject(img, forKey: NSNumber(value: index))
                    self.fetchingQueue.remove(index)
                    self.updateLRUOnMain(index)
                    NotificationCenter.default.post(
                        name: .comicImageCacheImageLoaded,
                        object: self,
                        userInfo: ["index": index]
                    )
                }
            } else {
                await MainActor.run { [weak self] in
                    _ = self?.fetchingQueue.remove(index)
                }
            }
        }
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
        isCBR: Bool,
        cbzURL: URL?,
        extractedCBRImageURLs: [URL],
        entryPath: String?,
        bounds: CGRect,
        scale: CGFloat
    ) async -> UIImage? {
        if isPDF {
            return await PDFRenderActor.shared.renderPage(at: index, scale: scale * 1.5)
        } else if isCBR {
            guard index < extractedCBRImageURLs.count else { return nil }
            let imageURL = extractedCBRImageURLs[index]
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
        let range = max(0, index - prefetchLimit)...min(pageCount - 1, index + prefetchLimit)
        for i in range {
            if i == index { continue }
            if self.cache.object(forKey: NSNumber(value: i)) == nil && !self.fetchingQueue.contains(i) {
                if isStream {
                    fetchCloudPageImage(at: i)
                } else {
                    fetchLocalImageAsync(at: i)
                }
            }
        }
    }

    private func fetchCloudPageImage(at index: Int) {
        guard let source = cloudPageSource, index < source.pages.count else { return }
        fetchingQueue.insert(index)
        let entry = source.pages[index]
        let manifest = source.manifest

        let bounds = UIScreen.main.bounds
        let scale = UIScreen.main.scale
        let maxPixelSize = max(bounds.width, bounds.height) * scale

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let data = try await ZipCentralDirectory.fetchEntryData(entry: entry, manifest: manifest)
                guard let image = Self.decodeImageData(data, maxPixelSize: maxPixelSize) else {
                    await MainActor.run { [weak self] in _ = self?.fetchingQueue.remove(index) }
                    return
                }
                
                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    self.cache.setObject(image, forKey: NSNumber(value: index))
                    self.fetchingQueue.remove(index)
                    self.updateLRUOnMain(index)
                    NotificationCenter.default.post(
                        name: .comicImageCacheImageLoaded,
                        object: self,
                        userInfo: ["index": index]
                    )
                }
            } catch {
                await MainActor.run { [weak self] in
                    _ = self?.fetchingQueue.remove(index)
                }
            }
        }
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
    @State private var chromeVisible = false
    @State private var currentIndex: Int = 0
    @State private var readingMode: ComicReadingMode = .pageHorizontal
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
    /// Debounce task — prevents rapid mode flips when the notification fires
    /// multiple times during the iPhone rotation animation (portrait→landscape).
    @State private var orientationTask: Task<Void, Never>? = nil
    /// AI Narration Engine — connects to the image cache on appear
    @StateObject private var narrationEngine = NarrationEngine()
    /// Phase 3: Live Reading Room — MultipeerConnectivity co-reading session.
    @StateObject private var readingRoom = ReadingRoomSession()
    /// Phase 4A: Auto-hide chrome — cancellable idle timer.
    @State private var chromeIdleTask: Task<Void, Never>? = nil
    @FocusState private var isReaderFocused: Bool
    
    init(pdf: ConvertedPDF, onDismiss: @escaping () -> Void, allBooks: [ConvertedPDF] = []) {
        self.pdf = pdf
        self.onDismiss = onDismiss
        self.allBooks = allBooks
        self._cache = StateObject(wrappedValue: ComicImageCache(
            pdf: pdf,
            prefetchLimit: AppSettingsManager.shared.conversionSettings.readingPrefetchLimit
        ))
        let isMangaComic = pdf.metadata.isManga == true || pdf.contentType == .manga
        let isiPad = UIDevice.current.userInterfaceIdiom == .pad
        // Phase 4B: iPad defaults to two-page spread; manga always opens RTL regardless of device.
        let defaultMode: ComicReadingMode = isMangaComic ? .mangaRTL : (isiPad ? .pageTwoUp : .pageHorizontal)
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
                    } else if readingMode == .pageTwoUp {
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
                            onChromeTap: {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                    chromeVisible.toggle()
                                }
                                // Phase 4A: start / reset 4-second auto-hide timer
                                if chromeVisible { startChromeIdleTimer() }
                            },
                            onFlipPastEnd: { attemptComicSeriesContinuation() }
                        )
                    }
                }
                .ignoresSafeArea()
            }

            brightnessZones
            readerChromeView
            filterHUDView
            settingsHUDView
            achievementToastView
            // Phase 3: Live Reading Room overlay (peer avatars + reactions + HUD pill)
            if readingRoom.isHosting {
                ReadingRoomOverlay(
                    session: readingRoom,
                    currentPage: currentIndex,
                    totalPages: cache.pageCount
                )
                .zIndex(15)
            }
        }
        .onAppear {
            if let saved = ReaderProgressTracker.shared.progress(for: pdf.id) {
                currentIndex = saved.currentPageIndex
                if let filterString = saved.colorFilter,
                   let filterPreset = ReadingFilterPreset(rawValue: filterString) {
                    activeFilterPreset = filterPreset
                }
                if let prefersManga = saved.prefersMangaMode, prefersManga {
                    readingMode = .mangaRTL
                } else if let wasDual = saved.wasInDualPageMode, wasDual {
                    readingMode = .pageTwoUp
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
            // On appear, honour the current physical orientation immediately
            // so opening in landscape already shows two pages.
            syncReadingModeToOrientation()
            if essentialReaderMode {
                if readingMode == .pageHorizontal || readingMode == .mangaRTL {
                    readingMode = .pageSlide
                }
                ambientPageColor = .clear
            }
            isReaderFocused = true
            BackTapManager.shared.isEnabled = backTapEnabled
        }
        // Auto two-up: rotate device → automatically flip reading mode so the
        // user doesn't need to discover the mode-toggle button in the chrome.
        // Webtoon and panel-navigation are intentional choices; never override them.
        // Debounced orientation sync — the notification fires 2-3× per rotation
        // on iPhone. Without debounce, readingMode flips rapidly which destroys
        // and recreates TwoUpBookPager while BookFlipGesture Tasks are in flight.
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            orientationTask?.cancel()
            orientationTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000) // 300 ms — lets rotation settle
                guard !Task.isCancelled else { return }
                syncReadingModeToOrientation()
            }
        }
        .onChange(of: currentIndex) { _, newIndex in
            // Panels-style ambient colour — sample edge pixels on page change
            extractAmbientColor(for: newIndex)
            // Notify narration engine of manual page changes (distinct from narration-driven advances)
            if narrationEngine.isNarrating {
                narrationEngine.didManuallyChangePage(to: newIndex)
            }
            // Phase 3: broadcast page change to any connected reading room peers
            readingRoom.broadcastPage(newIndex, totalPages: cache.pageCount)
        }
        // Once the archive finishes loading, honour the current orientation.
        // syncReadingModeToOrientation() is a no-op while isLoading == true,
        // so this catch-up call is needed for comics opened in landscape.
        // IMPORTANT: Only fire in landscape — in portrait the user's saved
        // readingMode preference (e.g. pageTwoUp restored from progress) is
        // authoritative and must not be overridden.
        .onChange(of: cache.isLoading) { _, isLoading in
            guard !isLoading, UIDevice.current.orientation.isLandscape else { return }
            syncReadingModeToOrientation()
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
            let isManga = (newMode == .mangaRTL)
            if let idx = conversionManager.convertedPDFs.firstIndex(where: { $0.id == pdf.id }) {
                conversionManager.convertedPDFs[idx].metadata.isManga = isManga
                conversionManager.saveLibrary()
            }
        }
        .sheet(isPresented: $showingCharacterMap) {
            CharacterOverlayView(
                seriesName: pdf.metadata.series ?? pdf.name,
                issueNumber: Int(pdf.metadata.issueNumber ?? "") ?? 1,
                pageIndex: currentIndex
            )
        }
        .focusable()
        .focused($isReaderFocused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) {
            if readingMode == .mangaRTL {
                nextPage()
            } else {
                prevPage()
            }
            return .handled
        }
        .onKeyPress(.rightArrow) {
            if readingMode == .mangaRTL {
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
        if currentIndex < cache.pageCount - 1 {
            currentIndex += 1
        } else {
            attemptComicSeriesContinuation()
        }
    }

    private func prevPage() {
        if currentIndex > 0 {
            currentIndex -= 1
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

    // MARK: - Orientation Helper

    /// Switches between single-page and two-up based on physical device orientation.
    /// Intentional modes (webtoon, panel navigation) are never auto-overridden.
    private func syncReadingModeToOrientation() {
        // Do not switch mode while the archive is still being indexed: creating
        // TwoUpBookPager with pageCount == 0 produces an empty TabView that
        // never recovers because spreadIdx.onChange fires before entries are loaded.
        guard !cache.isLoading else { return }

        let orientation = UIDevice.current.orientation
        let isLandscape = orientation.isLandscape

        // Respect modes the user deliberately chose — don't hijack them.
        guard readingMode != .webtoonScroll, readingMode != .panelNavigation else { return }

        withAnimation(.easeInOut(duration: 0.2)) {
            if isLandscape {
                // Landscape → two-page spread
                if readingMode != .pageTwoUp {
                    readingMode = .pageTwoUp
                }
            } else if orientation.isPortrait {
                // Portrait → restore single-page (manga keeps RTL)
                if readingMode == .pageTwoUp {
                    let isMangaComic = pdf.metadata.isManga == true || pdf.contentType == .manga
                    readingMode = isMangaComic ? .mangaRTL : .pageHorizontal
                }
            }
            // .faceUp / .faceDown / .unknown → leave mode unchanged
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
            pageText: "\(currentIndex + 1) / \(cache.pageCount)",
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
        progress.wasInDualPageMode = (readingMode == .pageTwoUp)
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
    @State private var currentScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var shareItem: UIImage? = nil
    @State private var showShareSheet = false

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

    var body: some View {
        Group {
            if let image = image {
                GeometryReader { geo in
                    let rendered = renderSize(for: image, in: geo.size)

                    ZStack {
                        Color.black.ignoresSafeArea()

                        Image(uiImage: image)
                            .resizable()
                            .frame(width: rendered.width, height: rendered.height)
                            .scaleEffect(currentScale)
                            .offset(offset)
                            .position(x: geo.size.width / 2, y: geo.size.height / 2)
                            .gesture(
                                SimultaneousGesture(
                                    MagnificationGesture()
                                        .onChanged { val in currentScale = max(1.0, val) }
                                        .onEnded   { _ in
                                            withAnimation(.spring()) {
                                                currentScale = 1.0
                                                offset = .zero
                                            }
                                        },
                                    DragGesture()
                                        .onChanged { val in
                                            if currentScale > 1.0 { offset = val.translation }
                                        }
                                        .onEnded { _ in
                                            if currentScale <= 1.0 {
                                                withAnimation(.spring()) { offset = .zero }
                                            }
                                        }
                                )
                            )
                            .onTapGesture(count: 2) { loc in
                                withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                                    if currentScale > 1.0 {
                                        currentScale = 1.0
                                        offset = .zero
                                    } else {
                                        currentScale = 2.5
                                        let centerX = geo.size.width / 2
                                        let centerY = geo.size.height / 2
                                        // Calculate offset to bring the tapped point to the center of the screen
                                        let dx = (centerX - loc.x) * (currentScale - 1)
                                        let dy = (centerY - loc.y) * (currentScale - 1)
                                        offset = CGSize(width: dx, height: dy)
                                    }
                                }
                            }
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
                            shareItem = image
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
                        Image(uiImage: image)
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
                .onAppear {
                    image = cache.getImage(at: index)
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

