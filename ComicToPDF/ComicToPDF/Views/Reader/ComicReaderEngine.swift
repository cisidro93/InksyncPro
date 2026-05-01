import SwiftUI
import ZIPFoundation
import PDFKit
import ImageIO

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
        }
    }
}

enum ComicReadingMode: String, CaseIterable, Codable {
    case pageHorizontal   // Single page, horizontal swipe (default)
    case pageTwoUp        // Two-page spread, landscape
    case panelNavigation  // Panel-by-panel using pageModels Vision data
    case webtoonScroll    // Continuous vertical scroll
    case mangaRTL         // Single page, horizontal swipe, right-to-left
}

class ComicImageCache: ObservableObject {
    private var cache = NSCache<NSNumber, UIImage>()
    private var accessQueue: [Int] = []
    private var fetchingQueue: Set<Int> = [] // Track pending extractions
    private let maxCacheSize = 7 // Can hold about ~15MB of images in memory depending on screen size
    
    // For CBZ extraction
    private var cbzArchive: Archive?
    private var entries: [Entry] = []
    
    @Published var isLoading = true
    @Published var cacheUpdatedTick = 0 // Triggers SwiftUI redraw for async streams
    var pageCount: Int = 0
    let isPDF: Bool
    let isStream: Bool
    private var pdfDocument: PDFDocument?
    /// Holds the URL whose security scope is currently active for linked CBZ files.
    /// Released in `deinit` when the reader is dismissed.
    var activelyAccessedURL: URL?
    
    init(pdf: ConvertedPDF) {
        let scheme = pdf.url.scheme?.lowercased() ?? ""
        isStream = (scheme == "http" || scheme == "https")
        
        let ext = pdf.url.pathExtension.lowercased()
        isPDF = (ext == "pdf")
        
        if isStream {
            self.pdfDocument = nil
            self.pageCount = 100
            self.isLoading = false
        } else if isPDF {
            self.pdfDocument = nil
            Task.detached(priority: .userInitiated) { [weak self] in
                // Linked Library: resolve and access the security-scoped URL.
                // PDFDocument copies data on open, so we can stop access immediately after init.
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
                let doc = PDFDocument(url: resolvedURL)
                // PDFDocument has loaded its data — release the security scope.
                if let accessed = accessedURL { accessed.stopAccessingSecurityScopedResource() }
                let count = doc?.pageCount ?? 0
                await MainActor.run { [weak self] in
                    self?.pdfDocument = doc
                    self?.pageCount = count
                    self?.isLoading = false
                }
            }
        } else {
            self.pdfDocument = nil
            Task.detached(priority: .userInitiated) { [weak self] in
                // Linked Library: for CBZ, we need the security scope live for the entire
                // reader session since images are extracted lazily page-by-page on demand.
                // Store the URL so we can stop access in deinit.
                let resolvedURL: URL
                if case .linked(let bm) = pdf.sourceMode,
                   let url = try? BookmarkResolver.shared.resolve(bm) {
                    let didAccess = url.startAccessingSecurityScopedResource()
                    resolvedURL = url
                    // Store reference so deinit can call stopAccessingSecurityScopedResource.
                    // Set synchronously to avoid leaks if dismissed quickly.
                    if didAccess {
                        if let self = self {
                            self.activelyAccessedURL = url
                        } else {
                            url.stopAccessingSecurityScopedResource()
                        }
                    }
                } else {
                    resolvedURL = pdf.url
                }
                guard let archive = try? Archive(url: resolvedURL, accessMode: .read, pathEncoding: .utf8) else {
                    await MainActor.run { [weak self] in self?.isLoading = false }
                    return
                }
                
                let sortedEntries = archive.filter { entry in
                    let name = entry.path.lowercased()
                    return name.hasSuffix(".jpg") || name.hasSuffix(".jpeg") || name.hasSuffix(".png") || name.hasSuffix(".webp")
                }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                
                await MainActor.run { [weak self] in
                    self?.cbzArchive = archive
                    self?.entries = sortedEntries
                    self?.pageCount = sortedEntries.count
                    self?.isLoading = false
                }
            }
        }
    }
    
    /// Stop security-scoped access when the cache is released (reader dismissed).
    deinit {
        activelyAccessedURL?.stopAccessingSecurityScopedResource()
    }
    
    func getImage(at index: Int) -> UIImage? {
        guard index >= 0 && index < pageCount else { return nil }
        
        // 1. Check Memory Cache
        if let cachedImage = cache.object(forKey: NSNumber(value: index)) {
            updateLRU(index)
            return cachedImage
        }
        
        // 2. Prevent redundant fetching
        if fetchingQueue.contains(index) { return nil }
        
        if isStream {
            fetchStreamImage(at: index)
        } else {
            // ✅ PROFESSIONAL ASYNC STREAMING (Eliminates UI Stutter/Main Thread lockups)
            fetchLocalImageAsync(at: index)
        }
        
        // Prefetch surrounding pages (Prefetch window ±2)
        prefetchSurrounding(index: index)
        
        return nil // Always return heavily operations asynchronously. UI uses a ProgressView block.
    }
    
    private func fetchLocalImageAsync(at index: Int) {
        fetchingQueue.insert(index)
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            // Capture archive state needed on background context
            let img = self.extractOrRenderImage(at: index)
            if let img {
                self.cache.setObject(img, forKey: NSNumber(value: index))
                await MainActor.run { [weak self] in
                    self?.fetchingQueue.remove(index)
                    self?.updateLRUOnMain(index)
                    self?.cacheUpdatedTick += 1 // Force UI redraw to pop the newly loaded image
                }
            } else {
                _ = await MainActor.run { [weak self] in
                    self?.fetchingQueue.remove(index)
                }
            }
        }
    }
    
    /// Must be called only from the main actor. Renamed from updateLRU to make isolation explicit.
    private func updateLRUOnMain(_ index: Int) {
        if let pos = accessQueue.firstIndex(of: index) {
            accessQueue.remove(at: pos)
        }
        accessQueue.append(index)
        
        // Evict if over maxCacheSize
        while accessQueue.count > maxCacheSize {
            let evictIndex = accessQueue.removeFirst()
            cache.removeObject(forKey: NSNumber(value: evictIndex))
        }
    }

    /// Legacy call-site bridge — ensures LRU updates always reach the main actor.
    private func updateLRU(_ index: Int) {
        Task { @MainActor [weak self] in self?.updateLRUOnMain(index) }
    }
    
    private func extractOrRenderImage(at index: Int) -> UIImage? {
        if isPDF {
            guard let page = pdfDocument?.page(at: index) else { return nil }
            let pageRect = page.bounds(for: .mediaBox)
            // Retina scale × 1.5
            let scale = UIScreen.main.scale * 1.5
            let size = CGSize(width: pageRect.width * scale, height: pageRect.height * scale)
            
            UIGraphicsBeginImageContextWithOptions(size, false, 1.0)
            guard let context = UIGraphicsGetCurrentContext() else { return nil }
            context.setFillColor(UIColor.white.cgColor)
            context.fill(CGRect(origin: .zero, size: size))
            
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: scale, y: -scale)
            page.draw(with: .mediaBox, to: context)
            
            let image = UIGraphicsGetImageFromCurrentImageContext()
            UIGraphicsEndImageContext()
            return image
        } else {
            guard let archive = cbzArchive, index < entries.count else { return nil }
            let entry = entries[index]
            var data = Data()
            do {
                _ = try archive.extract(entry, bufferSize: 32768) { chunk in
                    data.append(chunk)
                }
                
                // Extremely safe downsampling to prevent OOM on 4K CBZ images (ImageIO trick)
                let options: [CFString: Any] = [
                    kCGImageSourceShouldCache: false
                ]
                guard let imageSource = CGImageSourceCreateWithData(data as CFData, options as CFDictionary) else {
                    return UIImage(data: data) // Fallback
                }
                
                let maxPixelSize = max(UIScreen.main.bounds.width, UIScreen.main.bounds.height) * UIScreen.main.scale
                let downsampleOptions: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
                ]
                
                guard let downsampledImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, downsampleOptions as CFDictionary) else {
                    return UIImage(data: data) // Fallback
                }
                
                return UIImage(cgImage: downsampledImage)
            } catch {
                return nil
            }
        }
    }
    
    private func prefetchSurrounding(index: Int) {
        let range = max(0, index - 2)...min(pageCount - 1, index + 2)
        for i in range {
            if i == index { continue }
            if self.cache.object(forKey: NSNumber(value: i)) == nil && !self.fetchingQueue.contains(i) {
                if isStream {
                    fetchStreamImage(at: i)
                } else {
                    fetchLocalImageAsync(at: i)
                }
            }
        }
    }

    private func fetchStreamImage(at index: Int) {
        // Prevent duplicate network calls for same index
        if accessQueue.contains(index) { return }
        
        guard let url = URL(string: "\(pdfDocument == nil ? "http://prototype-stream" : .init())/\(index)") else { return } // Replace with actual pdf.url in production
        
        accessQueue.append(index) // Mark as fetching before the Task starts
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            // Use URLSession async/await — no GCD dataTask callback needed
            if let (data, _) = try? await URLSession.shared.data(from: url),
               let image = UIImage(data: data) {
                self.cache.setObject(image, forKey: NSNumber(value: index))
                await MainActor.run { [weak self] in
                    self?.cacheUpdatedTick += 1
                }
            }
        }
    }
}

struct ComicReaderEngine: View {
    @EnvironmentObject var manager: ConversionManager
    let pdf: ConvertedPDF
    var onDismiss: () -> Void
    
    @StateObject private var cache: ComicImageCache
    @State private var chromeVisible = false
    @State private var currentIndex: Int = 0
    @State private var readingMode: ComicReadingMode = .pageHorizontal
    @State private var activeFilterPreset: ReadingFilterPreset = .original
    @State private var showingFilterHUD = false
    @State private var lastBrightnessDragValue: CGFloat = 0
    
    init(pdf: ConvertedPDF, onDismiss: @escaping () -> Void) {
        self.pdf = pdf
        self.onDismiss = onDismiss
        self._cache = StateObject(wrappedValue: ComicImageCache(pdf: pdf))
    }
    
    var body: some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)
            
            if cache.isLoading {
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
                    // Book-style page flip (single or RTL)
                    BookPager(
                        currentIndex: $currentIndex,
                        totalPages: cache.pageCount,
                        cache: cache,
                        readingMode: readingMode,
                        activeFilterPreset: activeFilterPreset,
                        onChromeTap: { chromeVisible.toggle() }
                    )
                    }
                }
            }
            
            // Edge Brightness Gesture Zones
            HStack {
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: 30)
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
                    .frame(width: 30)
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
            
            ReaderChrome(
                pdf: pdf,
                title: pdf.name,
                pageText: "\(currentIndex + 1) / \(cache.pageCount)",
                isVisible: $chromeVisible,
                onBack: {
                    ReaderProgressTracker.shared.update(ReadingProgress(
                        pdfID: pdf.id, lastOpenedAt: Date(), currentPageIndex: currentIndex,
                        currentChapterIndex: nil, currentChapterOffset: nil,
                        totalPagesRead: 1, completionFraction: Double(currentIndex + 1) / Double(cache.pageCount),
                        readingSessionDates: [Date()], estimatedMinutesRemaining: nil
                    ))
                    onDismiss()
                },
                onEInkSend: {},
                onBookmark: {
                    let bookmark = Annotation(pdfID: pdf.id, pageIndex: currentIndex, kind: .bookmark, createdAt: Date(), modifiedAt: Date())
                    AnnotationStore.shared.add(bookmark)
                },
                onAnnotationsToggle: {},
                onSettingsToggle: {
                    // Quick toggle reading mode
                    if readingMode == .pageHorizontal { readingMode = .panelNavigation }
                    else if readingMode == .panelNavigation { readingMode = .mangaRTL }
                    else if readingMode == .mangaRTL { readingMode = .webtoonScroll }
                    else if readingMode == .webtoonScroll { readingMode = .pageTwoUp }
                    else { readingMode = .pageHorizontal }
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
                isEnhanced: activeFilterPreset != .original,
                onEnhanceToggle: { withAnimation(.easeInOut) { showingFilterHUD.toggle() } }
            )
            
            if showingFilterHUD {
                VStack {
                    Spacer()
                    FilterHUDView(activePreset: $activeFilterPreset, onDismiss: {
                        withAnimation(.easeInOut) { showingFilterHUD = false }
                    })
                    .padding(.bottom, 80) // Stay above the scrub bar
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(10)
            }
        }
        .onAppear {
            if let saved = ReaderProgressTracker.shared.progress(for: pdf.id) {
                currentIndex = saved.currentPageIndex
            }
            // On appear, honour the current physical orientation immediately
            // so opening in landscape already shows two pages.
            syncReadingModeToOrientation()
        }
        // Auto two-up: rotate device → automatically flip reading mode so the
        // user doesn't need to discover the mode-toggle button in the chrome.
        // Webtoon and panel-navigation are intentional choices; never override them.
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            syncReadingModeToOrientation()
        }
        .onChange(of: currentIndex) { _, _ in
            GamificationManager.shared.logPageRead()
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
    }
    
    var guidedView: some View {
        TabView(selection: $currentIndex) {
            ForEach(0..<cache.pageCount, id: \.self) { index in
                let panelsForPage = PageModelStore.shared.legacyVisionPanels(for: pdf.id, pageIndex: index)
                ComicGuidedPageView(
                    image: cache.getImage(at: index),
                    panels: panelsForPage,
                    masterIndex: $currentIndex,
                    totalPages: cache.pageCount,
                    forceRedrawTick: cache.cacheUpdatedTick,
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
                    if let image = cache.getImage(at: index) {
                        Image(uiImage: image)
                            .resizable()
                            .applyFilterPreset(activeFilterPreset)
                            .aspectRatio(contentMode: .fill)
                            .padding(.bottom, 2)
                            .onAppear { currentIndex = index }
                            .id("webtoon_img_\(index)_\(cache.cacheUpdatedTick)") // Async trigger
                    } else {
                        ZStack {
                            Color.black.frame(height: 500)
                            ProgressView().progressViewStyle(CircularProgressViewStyle(tint: .white.opacity(0.5)))
                        }
                        .id("webtoon_place_\(index)_\(cache.cacheUpdatedTick)") // Async trigger
                    }
                }
            }
        }
    }
    
    var twoUpView: some View {
        TwoUpBookPager(
            currentIndex: $currentIndex,
            cache: cache,
            activeFilterPreset: activeFilterPreset,
            onChromeTap: { chromeVisible.toggle() }
        )
    }

    // MARK: - Orientation Helper

    /// Switches between single-page and two-up based on physical device orientation.
    /// Intentional modes (webtoon, panel navigation) are never auto-overridden.
    private func syncReadingModeToOrientation() {
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
                    let isMangaComic = pdf.metadata.isManga == true
                    readingMode = isMangaComic ? .mangaRTL : .pageHorizontal
                }
            }
            // .faceUp / .faceDown / .unknown → leave mode unchanged
        }
    }
}

// Wrap Image to support pinch-to-zoom (Basic implementation)
struct ComicPageView: View {
    let image: UIImage?
    let forceRedrawTick: Int?
    @State private var currentScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero

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
        if let image = image {
            GeometryReader { geo in
                let rendered = renderSize(for: image, in: geo.size)

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
        } else {
            ZStack {
                Color.black
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white.opacity(0.5)))
                    .scaleEffect(1.5)
            }
        }
    }
}

// MARK: - Guided View Component
struct ComicGuidedPageView: View {
    let image: UIImage?
    let panels: [PanelExtractor.Panel]
    @Binding var masterIndex: Int
    let totalPages: Int
    let forceRedrawTick: Int?
    var onTapChrome: () -> Void
    
    @State private var currentPanelIndex: Int = -1 // -1 means Zoomed Out
    
    var body: some View {
        GeometryReader { geo in
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
            } else {
                ZStack {
                    Color.black
                    ProgressView().progressViewStyle(CircularProgressViewStyle(tint: .white.opacity(0.5)))
                }
            }
        }
        .onAppear {
            currentPanelIndex = -1 // Start zoomed out
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

// MARK: - Phase 4: Visual Scrubber Timeline
struct VisualComicScrubber: View {
    @Binding var currentIndex: Int
    let totalPages: Int
    @ObservedObject var cache: ComicImageCache
    var isMangaMode: Bool
    
    @State private var dragIndex: Int? = nil
    
    var body: some View {
        VStack(spacing: 8) {
            // Floating Visual Timeline
            if let activeIndex = dragIndex, activeIndex >= 0 && activeIndex < totalPages {
                VStack(spacing: 4) {
                    Group {
                        if let previewImg = cache.getImage(at: activeIndex) {
                            Image(uiImage: previewImg)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } else {
                            ZStack {
                                Color.gray.opacity(0.3)
                                ProgressView()
                            }
                        }
                    }
                    .frame(width: 90, height: 130)
                    .cornerRadius(8)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.2), lineWidth: 1))
                    .shadow(color: .black.opacity(0.8), radius: 15, y: 10)
                    .id("scrubber_thumb_\(activeIndex)_\(cache.cacheUpdatedTick)")
                    
                    Text("Page \(activeIndex + 1)")
                        .font(.system(size: 12, weight: .black))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.8))
                        .clipShape(Capsule())
                }
                .transition(.opacity.combined(with: .scale))
            }
            
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.2))
                        .frame(height: 8)
                    
                    let displayIndex = dragIndex ?? currentIndex
                    let normalized = isMangaMode ? CGFloat(totalPages - 1 - displayIndex) : CGFloat(displayIndex)
                    let ratio = totalPages > 1 ? normalized / CGFloat(totalPages - 1) : 0
                    let thumbWidth: CGFloat = 24
                    let trackWidth = geo.size.width - thumbWidth
                    
                    Capsule()
                        .fill(Theme.blue)
                        .frame(width: ratio * trackWidth + thumbWidth, height: 8)
                    
                    Circle()
                        .fill(Color.white)
                        .frame(width: thumbWidth, height: thumbWidth)
                        .shadow(radius: 4)
                        .offset(x: ratio * trackWidth)
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { val in
                                    let percentage = min(max(val.location.x / geo.size.width, 0), 1)
                                    let rawIndex = Int(round(percentage * CGFloat(totalPages - 1)))
                                    let targeted = isMangaMode ? (totalPages - 1 - rawIndex) : rawIndex
                                    
                                    if dragIndex != targeted {
                                        let generator = UISelectionFeedbackGenerator()
                                        generator.selectionChanged()
                                        dragIndex = targeted
                                    }
                                }
                                .onEnded { _ in
                                    if let final = dragIndex {
                                        Haptics.shared.playImpact(style: .medium)
                                        currentIndex = final
                                    }
                                    dragIndex = nil
                                }
                        )
                }
                .frame(height: 24)
            }
            .frame(height: 24)
        }
    }
}

