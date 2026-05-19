import SwiftUI
import UIKit
import WebKit
import PDFKit
import ZIPFoundation
import PencilKit

// MARK: - Reader Color Filter
enum ReaderColorFilter: String, CaseIterable, Codable {
    case none     = "none"
    case sepia    = "sepia"
    case grayscale = "grayscale"
    case warm     = "warm"   // reduce blue light
    
    var label: String {
        switch self {
        case .none:      return "Standard"
        case .sepia:     return "Sepia"
        case .grayscale: return "Grayscale"
        case .warm:      return "Night Warm"
        }
    }
    var icon: String {
        switch self {
        case .none:      return "photo"
        case .sepia:     return "cup.and.saucer.fill"
        case .grayscale: return "moon.circle"
        case .warm:      return "flame.fill"
        }
    }
}

struct ReaderView: View {
    @State var fileURL: URL
    let contentType: ContentType
    @State var pdf: ConvertedPDF? // Added to support Bookmarking
    var onExit: (() -> Void)? = nil
    
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var conversionManager: ConversionManager
    
    @AppStorage("isMangaMode") private var isMangaMode = false
    @State private var isPanelViewEnabled = true
    @State private var isToolbarVisible = true
    @Environment(\.horizontalSizeClass) private var hSizeClass

    // Image Enhancements
    @AppStorage("comic_autoContrastLevel") private var autoContrastLevel: Double = 1.0
    @AppStorage("comic_smartSharpen") private var smartSharpen: Bool = false
    @AppStorage("isAutoCropEnabled") private var isAutoCropEnabled: Bool = false

    // Advanced Reader Features
    @AppStorage("isVerticalScroll") private var isVerticalScroll = false
    @AppStorage("isDoublePageMode") private var isDoublePageMode = false
    @AppStorage("autoLandscapeDualPage") private var autoLandscapeDualPage = true
    @State private var isDrawingMode = false
    @State private var canvasView = PKCanvasView()
    @State private var deviceOrientation: UIDeviceOrientation = UIDevice.current.orientation
    @State private var rotationDebounceTask: Task<Void, Never>? = nil
    
    // Color Filter
    @State private var colorFilter: ReaderColorFilter = .none

    // Settings sheet
    @State private var showReaderSettings = false

    // Bookmark toast
    @State private var showBookmarkToast = false
    @State private var bookmarkToastMessage = ""

    // Ambient page color (wired to ReaderChrome)
    @State private var ambientPageColor: Color = .clear

    // Jump to Page
    @State private var showJumpToPage = false
    @State private var jumpToPageText = ""
    
    // Unzip State
    @State private var unzippedDir: URL?
    @State private var pages: [URL] = []
    @State private var currentPageIndex = 0
    @State private var isLoading = true
    @State private var errorMessage: String?
    
    // Binge Mode State
    @State private var showBingePrompt = false
    @State private var nextVolumeToRead: ConvertedPDF? = nil
    
    // Casual Comforts State
    @State private var brightnessLevel: CGFloat = UIScreen.main.brightness
    @State private var warmthLevel: Double = 0.0 // 0.0 to 0.4
    @State private var showSwipeHUD = false
    @State private var hudMessage = ""
    @State private var swipeStartBrightness: CGFloat = 0
    @State private var swipeStartWarmth: Double = 0
    
    // ✅ Orientation Lock
    @ObservedObject private var orientationLock = OrientationLockManager.shared
    
    // ✅ Sleep Timer
    @ObservedObject private var sleepTimer = SleepTimerManager.shared
    @State private var showSleepTimerPicker = false
    
    // ✅ Table of Contents
    @State private var showTOC = false
    @State private var toc: CBZTableOfContents = CBZTableOfContents(chapters: [])
    
    // ✅ Share Page
    @State private var shareImage: UIImage? = nil
    @State private var showShareSheet = false
    
    // PDF document reference (for share + TOC)
    @State private var loadedPDFDocument: PDFDocument? = nil
    @State private var pdfViewRef: PDFView? = nil

    // PDF Search
    @State private var showSearch = false

    // Webtoon auto-scroll
    @State private var isWebtoonAutoScrolling = false
    @State private var webtoonScrollSpeed: Double = 60.0

    // Typography Settings
    @State private var showTypographyHUD = false
    @ObservedObject private var prefs = EBookPreferences.shared

    // Ambient brightness (time-of-day night mode)
    @ObservedObject private var ambientBrightness = AmbientBrightnessManager.shared
    @State private var userHasManuallyAdjustedWarmth = false

    // Cloud streaming phase-aware loading
    @ObservedObject private var streamCoordinator = CloudStreamCoordinator.shared

    // Reading velocity tracking
    @State private var sessionStartTime: Date = Date()
    @State private var pagesReadThisSession: Int = 0
    
    var body: some View {
        GeometryReader { geo in
            ZStack {
                // ✅ Route: text-based EPUB → EBookReaderView, image formats (CBZ/CBR/PDF) → comicReaderBody
                if fileURL.pathExtension.lowercased() == "epub" && contentType == .book {
                    EBookReaderView(
                        fileURL: fileURL,
                        title: fileURL.deletingPathExtension().lastPathComponent,
                        pdf: pdf,
                        onExit: onExit ?? { dismiss() }
                    )
                } else {
                    comicReaderBody(in: geo)
                }
                
                // KOReader Casual Comforts Overlay
                edgeSwipeOverlay(in: geo)
                
                // Manga Binge-Mode HUD
                if showBingePrompt, let nextVol = nextVolumeToRead {
                    bingeModeOverlay(nextVol: nextVol)
                }
            }
        }
        .sheet(isPresented: $showTypographyHUD) {
            TypographySettingsHUD(prefs: prefs, webView: nil, isFixedLayout: true)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }
    
    // MARK: - Comic / Manga Reader
    private func comicReaderBody(in geo: GeometryProxy) -> some View {
        ZStack {
            if isLoading {
                CloudAwareLoadingView(pdf: pdf)
            } else if let error = errorMessage {
                    VStack {
                        Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundColor(.red)
                        Text("Error: \(error)").padding()
                    }
                } else {
                    // ✅ READER CONTENT
                    if isVerticalScroll {
                        // ✅ WEBTOON MODE: UIScrollView-backed with auto-scroll + position memory
                        ZStack {
                            WebtoonScrollView(
                                pages: pages,
                                currentPageIndex: $currentPageIndex,
                                pdfID: pdf?.id,
                                isAutoScrolling: isWebtoonAutoScrolling,
                                scrollSpeed: webtoonScrollSpeed,
                                onCenterTap: {
                                    withAnimation(.easeInOut(duration: 0.2)) { isToolbarVisible.toggle() }
                                },
                                onEndReached: {
                                    if let nextVol = getNextVolume() {
                                        self.nextVolumeToRead = nextVol
                                        withAnimation(.spring()) { self.showBingePrompt = true }
                                    }
                                }
                            )
                            WebtoonControlBar(isAutoScrolling: $isWebtoonAutoScrolling, scrollSpeed: $webtoonScrollSpeed)
                        }
                    } else {
                        // ✅ ZERO-LATENCY METAL PPL READER
                        if fileURL.pathExtension.lowercased() != "pdf" {
                            if !pages.isEmpty {
                                let effectiveDoublePage = isDoublePageMode || (autoLandscapeDualPage && geo.size.width > geo.size.height)
                                PPLReaderView(pages: pages, currentPageIndex: $currentPageIndex, pdfID: pdf?.id, isMangaMode: isMangaMode, isDoublePageOverride: effectiveDoublePage, isDrawingMode: isDrawingMode) {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        isToolbarVisible.toggle()
                                    }
                                }
                                .ignoresSafeArea()
                            }
                        } else {
                            PDFKitView(
                                url: fileURL,
                                currentPageIndex: $currentPageIndex,
                                totalPages: $pages,
                                isVerticalScroll: isVerticalScroll,
                                isMangaMode: isMangaMode,
                                isDoublePageMode: isDoublePageMode || (autoLandscapeDualPage && geo.size.width > geo.size.height),
                                loadedDocument: $loadedPDFDocument,
                                onSingleTap: {
                                    withAnimation(.easeInOut(duration: 0.2)) { isToolbarVisible.toggle() }
                                },
                                onViewCreated: { ref in pdfViewRef = ref }
                            )
                            .colorMultiply(.white)
                            .colorInvertIfDark(theme: EBookPreferences.shared.activeTheme)
                            
                            // ✅ PHASE 30: PencilKit Overlay (GoodNotes Parity)
                            if isDrawingMode {
                                CanvasInkBearingView(
                                    canvasView: $canvasView,
                                    isDrawingMode: isDrawingMode,
                                    onDrawingSaved: { drawing in
                                        // Cache flattened representation here to disk/memory
                                    }
                                )
                                // Allows native PDF panning with 2 fingers while drawing with Pencil/1 finger
                                .allowsHitTesting(true)
                            }
                        }
                    }
                }
                
                // Apply overlays in a Group so modifiers chain cleanly
                Group {
                    colorFilterOverlay
                    // Ambient warmth overlay (time-of-day) — only if user hasn't manually adjusted
                    if !userHasManuallyAdjustedWarmth && ambientBrightness.recommendedWarmth > 0 {
                        Rectangle()
                            .fill(Color.orange.opacity(ambientBrightness.recommendedWarmth * 0.6))
                            .ignoresSafeArea()
                            .allowsHitTesting(false)
                    }
                }
                .animation(.easeInOut(duration: 1.0), value: warmthLevel)
                .animation(.easeInOut(duration: 1.5), value: ambientBrightness.recommendedWarmth)

                // Hardware Button Binding (dual-page aware)
                VolumeHook(onUp: {
                    if isMangaMode { nextPage() } else { prevPage() }
                }, onDown: {
                    if isMangaMode { prevPage() } else { nextPage() }
                })
                .frame(width: 0, height: 0)
                
                // ✅ Immersive UI OSD — bottom micro-pill while toolbar is hidden
                if !isVerticalScroll && !pages.isEmpty && !isLoading && !isToolbarVisible {
                    VStack {
                        Spacer()
                        let isDual = (isDoublePageMode || autoLandscapeDualPage) && geo.size.width > geo.size.height
                        let pillText: String = {
                            if isDual && currentPageIndex > 0 {
                                let lead = PageBufferManager.canonicalLeadIndex(for: currentPageIndex, isMangaMode: isMangaMode)
                                let right = min(lead + 1, pages.count - 1)
                                return "\(lead + 1)–\(right + 1) / \(pages.count)"
                            }
                            return "\(currentPageIndex + 1) / \(pages.count)"
                        }()
                        Text(pillText)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white.opacity(0.7))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.black.opacity(0.5))
                            .clipShape(Capsule())
                            .padding(.bottom, 10)
                            .opacity(0.3)
                    }
                }
            }
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(.leftArrow) {
                if isMangaMode { nextPage() } else { prevPage() }
                return .handled
            }
            .onKeyPress(.rightArrow) {
                if isMangaMode { prevPage() } else { nextPage() }
                return .handled
            }
            .onKeyPress(.space) {
                nextPage()
                return .handled
            }
            .navigationBarHidden(true)
            .statusBarHidden(!isToolbarVisible)
            // ── Bookmark toast HUD ──────────────────────────────────────────
            .overlay(alignment: .bottom) {
                if showBookmarkToast {
                    Text(bookmarkToastMessage)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
                        .padding(.bottom, 110)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            // ── ReaderChrome (unified top + bottom chrome) ─────────────────
            .overlay {
                if !isLoading && errorMessage == nil {
                    let pageText: String = {
                        if pages.isEmpty { return "" }
                        let isDual = (isDoublePageMode || autoLandscapeDualPage) && geo.size.width > geo.size.height
                        if isDual && currentPageIndex > 0 {
                            let lead = PageBufferManager.canonicalLeadIndex(for: currentPageIndex, isMangaMode: isMangaMode)
                            let right = min(lead + 1, pages.count - 1)
                            return "\(lead + 1)–\(right + 1) / \(pages.count)"
                        }
                        return "\(currentPageIndex + 1) / \(pages.count)"
                    }()

                    ReaderChrome(
                        title: fileURL.deletingPathExtension().lastPathComponent,
                        pageText: pageText,
                        isVisible: $isToolbarVisible,
                        onBack: { if let onExit = onExit { onExit() } else { dismiss() } },
                        onBookmark: toggleBookmarkWithToast,
                        onBookmarkActive: isBookmarked,
                        onSettingsToggle: { showReaderSettings = true },
                        onTOCToggle: toc.chapters.count > 1 ? { showTOC = true } : nil,
                        currentProgress: Binding(
                            get: { pages.isEmpty ? 0 : Double(currentPageIndex) / Double(max(1, pages.count - 1)) },
                            set: { val in
                                let raw = Int((val * Double(max(1, pages.count - 1))).rounded())
                                let isDual = isDoublePageMode || (autoLandscapeDualPage && geo.size.width > geo.size.height)
                                let snapped = isDual
                                    ? PageBufferManager.canonicalLeadIndex(for: raw, isMangaMode: isMangaMode)
                                    : raw
                                currentPageIndex = max(0, min(snapped, pages.count - 1))
                            }
                        ),
                        totalPages: pages.count,
                        customScrubber: pages.isEmpty || isVerticalScroll ? nil : AnyView(
                            ReaderScrubber(
                                currentPageIndex: $currentPageIndex,
                                totalPages: pages.count,
                                isMangaMode: isMangaMode,
                                pages: pages
                            )
                        ),
                        isPDF: fileURL.pathExtension.lowercased() == "pdf",
                        isEnhanced: autoContrastLevel > 1.0 || smartSharpen,
                        onEnhanceToggle: {
                            if autoContrastLevel > 1.0 || smartSharpen {
                                autoContrastLevel = 1.0; smartSharpen = false
                            } else {
                                autoContrastLevel = 1.5; smartSharpen = true
                            }
                            PageBufferManager.shared.render(pageIndex: currentPageIndex, bounds: .zero)
                        },
                        isSettingsActive: showReaderSettings,
                        currentModeLabel: isMangaMode ? "MANGA" : (isVerticalScroll ? "WEBTOON" : nil),
                        ambientColor: ambientPageColor
                    )
                }
            }
            .task {
                await prepareArchive()
                restorePerBookPreferences()
                trackProgress(isPageTurn: false)
                // Build TOC from extracted pages
                let extracted = pages
                toc = CBZTableOfContents.build(from: extracted)
            }
            .onChange(of: pages) {
                // If we're a PDF and we have a loaded document, don't overwrite TOC with the empty file URLs
                if fileURL.pathExtension.lowercased() != "pdf" {
                    toc = CBZTableOfContents.build(from: pages)
                }
            }
            .onChange(of: loadedPDFDocument) {
                if let doc = loadedPDFDocument {
                    toc = buildPDFTOC(from: doc)
                }
            }
            .onChange(of: currentPageIndex) { _, _ in
                trackProgress(isPageTurn: true)
                pagesReadThisSession += 1
                // Periodic velocity flush every 10 page turns
                if pagesReadThisSession % 10 == 0, let id = pdf?.id {
                    let elapsed = Date().timeIntervalSince(sessionStartTime)
                    ReaderProgressTracker.shared.logPageTurn(pdfID: id, pages: 10, seconds: elapsed)
                    sessionStartTime = Date()
                    pagesReadThisSession = 0
                }
            }
            .onChange(of: isMangaMode) { savePerBookPreferences() }
            .onChange(of: colorFilter) { savePerBookPreferences() }
            .onChange(of: sleepTimer.didFire) { _, fired in
                if fired { if let onExit = onExit { onExit() } else { dismiss() } }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("Reader_EndOfBookReached"))) { _ in
                nextPage()
            }
            // Context menu bridge from PPLReaderView
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("Reader_BookmarkCurrentPage"))) { note in
                if let idx = note.userInfo?["pageIndex"] as? Int {
                    Logger.shared.log("Bookmarking page \(idx + 1)", category: "ReaderView")
                    // Delegate to the bookmark engine
                    NotificationCenter.default.post(name: NSNotification.Name("BookmarkAdded"),
                                                    object: nil,
                                                    userInfo: ["pdfID": pdf?.id as Any, "pageIndex": idx])
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("Reader_ShareCurrentPage"))) { note in
                if let idx = note.userInfo?["pageIndex"] as? Int, idx < pages.count {
                    Task.detached(priority: .userInitiated) {
                        if let data = try? Data(contentsOf: pages[idx]),
                           let img  = UIImage(data: data) {
                            await MainActor.run { shareImage = img; showShareSheet = true }
                        }
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
                let newOrientation = UIDevice.current.orientation
                guard newOrientation.isValidInterfaceOrientation else { return }
                
                rotationDebounceTask?.cancel()
                rotationDebounceTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 200_000_000) // 200ms debounce
                    guard !Task.isCancelled else { return }
                    withAnimation {
                        deviceOrientation = newOrientation
                    }
                }
            }
            .onDisappear {
                // Flush final velocity event
                if let id = pdf?.id, pagesReadThisSession > 0 {
                    let elapsed = Date().timeIntervalSince(sessionStartTime)
                    ReaderProgressTracker.shared.logPageTurn(pdfID: id, pages: pagesReadThisSession, seconds: elapsed)
                }
                if let dir = unzippedDir {
                    try? FileManager.default.removeItem(at: dir)
                }
                orientationLock.unlock()
                sleepTimer.stop()
            }
            .alert("Jump to Page", isPresented: $showJumpToPage) {
                TextField("Page number (1–\(pages.count))", text: $jumpToPageText)
                    .keyboardType(.numberPad)
                Button("Go") {
                    if let n = Int(jumpToPageText), n >= 1, n <= pages.count {
                        let rawIndex = n - 1
                        let isDual = (isDoublePageMode || autoLandscapeDualPage) && geo.size.width > geo.size.height
                        // Snap to canonical spread lead so parity is maintained
                        currentPageIndex = isDual
                            ? PageBufferManager.canonicalLeadIndex(for: rawIndex, isMangaMode: isMangaMode)
                            : rawIndex
                    }
                    jumpToPageText = ""
                }
                Button("Cancel", role: .cancel) { jumpToPageText = "" }
            } message: {
                Text("Enter a page number between 1 and \(pages.count).")
            }
            .sheet(isPresented: $showTOC) {
                ReaderTOCSheet(toc: toc, currentPageIndex: $currentPageIndex)
            }
            .sheet(isPresented: $showShareSheet) {
                if let img = shareImage {
                    ShareSheet(activityItems: [img])
                }
            }
            .sheet(isPresented: $showSleepTimerPicker) { SleepTimerPickerSheet() }
            .sheet(isPresented: $showSearch) {
                if let doc = loadedPDFDocument, let pdfV = pdfViewRef {
                    ReaderSearchView(document: doc, pdfView: pdfV)
                        .presentationDetents([.medium, .large])
                }
            }
            .sheet(isPresented: $showReaderSettings) {
                ReaderSettingsSheet(
                    isMangaMode: $isMangaMode,
                    isVerticalScroll: $isVerticalScroll,
                    isDoublePageMode: $isDoublePageMode,
                    autoLandscapeDualPage: $autoLandscapeDualPage,
                    autoContrastLevel: $autoContrastLevel,
                    smartSharpen: $smartSharpen,
                    isAutoCropEnabled: $isAutoCropEnabled,
                    colorFilter: $colorFilter,
                    ambientBrightness: ambientBrightness,
                    isWebtoonAutoScrolling: $isWebtoonAutoScrolling,
                    onJumpToPage: { jumpToPageText = ""; showJumpToPage = true },
                    onTOC: { showTOC = true },
                    onSleepTimer: { showSleepTimerPicker = true },
                    onSharePage: { shareCurrentPage() },
                    onDone: {}
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
    }
    
    // MARK: - Top Bar removed — now rendered by ReaderChrome overlay above
    // All chrome logic lives in ReaderChrome.swift (top capsule + bottom card).

    // MARK: - Share Current Page (format-aware)
    private func shareCurrentPage() {
        if fileURL.pathExtension.lowercased() == "pdf" {
            let pageIdx = currentPageIndex
            let docURL = fileURL
            Task.detached(priority: .userInitiated) {
                if let doc = PDFDocument(url: docURL),
                   let page = doc.page(at: pageIdx) {
                    let size = CGSize(width: 1024, height: 1408)
                    let thumb = page.thumbnail(of: size, for: .mediaBox)
                    await MainActor.run {
                        self.shareImage = thumb
                        self.showShareSheet = true
                    }
                }
            }
        } else {
            guard currentPageIndex < pages.count else { return }
            let url = pages[currentPageIndex]
            Task.detached(priority: .userInitiated) {
                if let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
                    await MainActor.run {
                        self.shareImage = image
                        self.showShareSheet = true
                    }
                }
            }
        }
    }

    // MARK: - PDF Table of Contents Parser
    private func buildPDFTOC(from doc: PDFDocument) -> CBZTableOfContents {
        guard let root = doc.outlineRoot, root.numberOfChildren > 0 else {
            return CBZTableOfContents(chapters: [])
        }
        var chapters: [(title: String, pageIndex: Int)] = []
        for i in 0..<root.numberOfChildren {
            guard let node = root.child(at: i),
                  let dest = node.destination,
                  let page = dest.page,
                  let label = node.label, !label.isEmpty else { continue }
            chapters.append((title: label, pageIndex: doc.index(for: page)))
        }
        guard !chapters.isEmpty else { return CBZTableOfContents(chapters: []) }
        let total = doc.pageCount
        let built = chapters.enumerated().map { idx, ch -> CBZTableOfContents.Chapter in
            let end = idx + 1 < chapters.count ? chapters[idx + 1].pageIndex : total
            return CBZTableOfContents.Chapter(title: ch.title, firstPageIndex: ch.pageIndex, pageCount: max(1, end - ch.pageIndex))
        }
        return CBZTableOfContents(chapters: built)
    }


    // MARK: - Archive Preparation
    private func prepareArchive() async {
        var activeFileURL = fileURL

        // ── LINKED EXTERNAL DRIVE ─────────────────────────────────────────────
        // Security-scoped bookmarks expire between app launches and after drive
        // reconnect. We must resolve fresh from bookmark data and acquire scope
        // before any file I/O, or every read silently fails with EPERM / ENOENT.
        if let pdfItem = pdf, case .linked(let bookmarkData) = pdfItem.sourceMode {
            await MainActor.run {
                self.isLoading = true
                self.errorMessage = nil
            }
            do {
                let resolvedURL = try BookmarkResolver.shared.resolve(bookmarkData)
                let didAccess = resolvedURL.startAccessingSecurityScopedResource()

                // Validate the drive is actually readable right now
                var coordError: NSError?
                var isAccessible = false
                let coordinator = NSFileCoordinator()
                coordinator.coordinate(
                    readingItemAt: resolvedURL,
                    options: .immediatelyAvailableMetadataOnly,
                    error: &coordError
                ) { safeURL in
                    isAccessible = FileManager.default.fileExists(atPath: safeURL.path)
                }

                guard coordError == nil, isAccessible else {
                    if didAccess { resolvedURL.stopAccessingSecurityScopedResource() }
                    await MainActor.run {
                        self.errorMessage = "External drive is not connected or the file is no longer accessible. Please reconnect the drive and try again."
                        self.isLoading = false
                    }
                    return
                }

                // Hand off to the shared extraction pipeline using the live, scoped URL.
                // Keep the security scope alive until extraction is complete by
                // stopping it only after the pipeline finishes.
                await MainActor.run { self.fileURL = resolvedURL }
                activeFileURL = resolvedURL

                // Run extraction (see shared pipeline below), then release scope.
                defer { if didAccess { resolvedURL.stopAccessingSecurityScopedResource() } }
                await extractAndOpen(activeFileURL: resolvedURL)
                return

            } catch {
                await MainActor.run {
                    Logger.shared.log("ReaderView: Linked drive bookmark resolution failed: \(error.localizedDescription)", category: "ReaderView", type: .error)
                    self.errorMessage = "Could not access external drive file: \(error.localizedDescription)"
                    self.isLoading = false
                }
                return
            }
        }

        // ── CLOUD STREAMING ───────────────────────────────────────────────────
        if let pdf = pdf, case .cloud = pdf.sourceMode {
            await MainActor.run {
                self.isLoading = true
                self.errorMessage = nil
            }
            do {
                let readyState = try await CloudStreamCoordinator.shared.prepare(pdf: pdf)
                switch readyState {

                case .pageStream(let source):
                    let tempDir = FileManager.default.temporaryDirectory
                        .appendingPathComponent("stream_\(pdf.id.uuidString.prefix(8))")
                    try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

                    var fetchedPages: [URL?] = Array(repeating: nil, count: source.pageCount)

                    await withTaskGroup(of: (Int, URL?).self) { group in
                        for (i, entry) in source.pages.enumerated() {
                            group.addTask {
                                do {
                                    let data = try await ZipCentralDirectory.fetchEntryData(
                                        entry: entry, manifest: source.manifest
                                    )
                                    let ext = (entry.name as NSString).pathExtension.lowercased()
                                    let pageFile = tempDir.appendingPathComponent(
                                        String(format: "page_%05d.\(ext.isEmpty ? "jpg" : ext)", i)
                                    )
                                    try data.write(to: pageFile, options: .atomic)
                                    return (i, pageFile)
                                } catch {
                                    Logger.shared.log(
                                        "CloudStream: Page \(i) fetch failed: \(error.localizedDescription)",
                                        category: "ReaderView", type: .error
                                    )
                                    return (i, nil)
                                }
                            }
                        }
                        for await (index, pageURL) in group {
                            fetchedPages[index] = pageURL
                        }
                    }

                    let resolvedPages = fetchedPages.compactMap { $0 }
                    await MainActor.run {
                        self.unzippedDir = tempDir
                        self.pages = resolvedPages
                        self.isLoading = false
                        if resolvedPages.isEmpty {
                            self.errorMessage = "Could not load any pages from the cloud archive."
                        }
                    }

                    if let firstPage = resolvedPages.first,
                       let convManager = await MainActor.run(body: { [weak conversionManager] in conversionManager }) {
                        Task(priority: .background) {
                            await PhysicalFileSystemRouter.shared
                                .generateCoverThumbnailFromLocalURL(for: pdf, localURL: firstPage, manager: convManager)
                        }
                    }
                    return

                case .extractedPages(let workingDir, let pages):
                    await MainActor.run {
                        self.unzippedDir = workingDir
                        self.pages = pages
                        self.isLoading = false
                        if pages.isEmpty { self.errorMessage = "No images found in archive." }
                    }

                    if let firstPage = pages.first,
                       let convManager = await MainActor.run(body: { [weak conversionManager] in conversionManager }) {
                        Task(priority: .background) {
                            await PhysicalFileSystemRouter.shared
                                .generateCoverThumbnailFromLocalURL(for: pdf, localURL: firstPage, manager: convManager)
                        }
                    }
                    return

                case .localTemp(let url):
                    await MainActor.run { self.fileURL = url }
                    activeFileURL = url

                    if let convManager = await MainActor.run(body: { [weak conversionManager] in conversionManager }) {
                        Task(priority: .background) {
                            await PhysicalFileSystemRouter.shared
                                .generateCoverThumbnailFromLocalURL(for: pdf, localURL: url, manager: convManager)
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    Logger.shared.log("Reader cloud stream failed: \(error.localizedDescription)", category: "ReaderView", type: .error)
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
                return
            }
        }

        await extractAndOpen(activeFileURL: activeFileURL)
    }

    /// Shared extraction pipeline — used by both the local and linked drive paths.
    private func extractAndOpen(activeFileURL: URL) async {
        let ext = activeFileURL.pathExtension.lowercased()

        // PDFs are handled directly by PDFKitView without extraction
        if ext == "pdf" {
            await MainActor.run { self.isLoading = false }
            return
        }

        do {
            if ext == "epub" {
                let fileManager = FileManager.default
                let tempID = UUID().uuidString
                let dest = fileManager.temporaryDirectory.appendingPathComponent("Reader_\(tempID)")

                try fileManager.createDirectory(at: dest, withIntermediateDirectories: true)
                try fileManager.unzipItem(at: activeFileURL, to: dest)
                await MainActor.run { self.unzippedDir = dest }

                if let enumerator = fileManager.enumerator(at: dest, includingPropertiesForKeys: nil) {
                    var foundPages: [URL] = []
                    while let file = enumerator.nextObject() as? URL {
                        if file.lastPathComponent.hasPrefix("._") || file.lastPathComponent == ".DS_Store" { continue }
                        if ["jpg", "jpeg", "png", "webp", "heic"].contains(file.pathExtension.lowercased()) {
                            foundPages.append(file)
                        }
                    }
                    foundPages.sort { $0.lastPathComponent < $1.lastPathComponent }

                    await MainActor.run {
                        self.pages = foundPages
                        self.isLoading = false
                        if foundPages.isEmpty { self.errorMessage = "No pages found in EPUB." }
                    }
                }
            } else {
                // CBZ / ZIP
                let result = try await ZipUtilities.extractComic(from: activeFileURL)
                await MainActor.run {
                    self.unzippedDir = result.workingDir
                    self.pages = result.imageURLs
                    self.isLoading = false
                    if result.imageURLs.isEmpty { self.errorMessage = "No images found in comic archive." }
                }
            }
        } catch {
            await MainActor.run {
                Logger.shared.log("Reader extraction failed: \(error.localizedDescription)", category: "ReaderView")
                self.errorMessage = "Failed to open comic: \(error.localizedDescription)"
                self.isLoading = false
            }
        }
    }

    // MARK: - Navigation
    // These are used by volume hardware buttons, keyboard, and the Binge Mode bridge.
    // PPLReaderView handles its own gesture-driven navigation internally.
    private func nextPage() {
        if currentPageIndex < pages.count - 1 {
            currentPageIndex += 1
        } else {
            // Trigger Manga Binge-Mode auto-continuation
            if let nextVol = getNextVolume() {
                self.nextVolumeToRead = nextVol
                withAnimation(.spring()) { self.showBingePrompt = true }
            }
        }
    }

    private func prevPage() {
        if currentPageIndex > 0 {
            currentPageIndex -= 1
        }
    }
    
    // MARK: - Manga Binge-Mode Pipeline
    
    private func getNextVolume() -> ConvertedPDF? {
        guard let current = pdf, let series = current.metadata.series else { return nil }
        let seriesItems = conversionManager.convertedPDFs.filter { $0.metadata.series == series && $0.id != current.id && !$0.isPrivate }
        
        let sorted = seriesItems.sorted { a, b in
            let aNum = Double(a.metadata.issueNumber ?? a.metadata.volume ?? "0") ?? 0
            let bNum = Double(b.metadata.issueNumber ?? b.metadata.volume ?? "0") ?? 0
            return aNum < bNum
        }
        
        let currentNum = Double(current.metadata.issueNumber ?? current.metadata.volume ?? "0") ?? 0
        return sorted.first { (Double($0.metadata.issueNumber ?? $0.metadata.volume ?? "0") ?? 0) > currentNum }
    }
    
    @ViewBuilder
    private func bingeModeOverlay(nextVol: ConvertedPDF) -> some View {
        ZStack {
            Color.black.opacity(0.8).ignoresSafeArea()
                .onTapGesture {
                    withAnimation { showBingePrompt = false }
                }
            
            VStack(spacing: 24) {
                Image(systemName: "books.vertical.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Theme.orange, Theme.red],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )

                VStack(spacing: 8) {
                    Text("Volume Complete!")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    Text("Continue reading the next issue in the series?")
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                VStack(spacing: 6) {
                    Text(nextVol.name)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)

                    if let issue = nextVol.metadata.issueNumber {
                        Text("Issue #\(issue)")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.orange)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity)
                .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, 32)

                HStack(spacing: 16) {
                    Button {
                        withAnimation { showBingePrompt = false }
                    } label: {
                        Text("Later")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    Button { launchBingeJump(to: nextVol) } label: {
                        Text("Read Now")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Theme.orange, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .shadow(color: Theme.orange.opacity(0.4), radius: 10, y: 4)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 32)
                .padding(.top, 8)
            }
            .padding(32)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .shadow(color: .black.opacity(0.4), radius: 30, y: 10)
            .padding(32)
        }
        .zIndex(1000)
    }
    
    private func launchBingeJump(to nextPDF: ConvertedPDF) {
        withAnimation { showBingePrompt = false }
        dismiss()
        // Wait for the modal dismissal animation to complete before triggering the router
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NotificationCenter.default.post(name: NSNotification.Name("OpenMergedBook"), object: nextPDF)
        }
    }
    
    // MARK: - KOReader Casual Comforts (Edge Swipes)
    
    @ViewBuilder
    private func edgeSwipeOverlay(in geo: GeometryProxy) -> some View {
        ZStack {
            Color.orange
                .opacity(warmthLevel)
                .allowsHitTesting(false)
                .ignoresSafeArea()
            
            HStack(spacing: 0) {
                Color.clear.contentShape(Rectangle())
                    .frame(width: max(30, geo.size.width * 0.08))
                    .gesture(
                        DragGesture(minimumDistance: 15)
                            .onChanged { val in handleEdgeSwipe(val: val, geo: geo, isLeft: true) }
                            .onEnded { _ in finishEdgeSwipe() }
                    )
                    .onTapGesture {
                        if !isMangaMode { prevPage() } else { nextPage() }
                    }
                
                Spacer()
                
                Color.clear.contentShape(Rectangle())
                    .frame(width: max(30, geo.size.width * 0.08))
                    .gesture(
                        DragGesture(minimumDistance: 15)
                            .onChanged { val in handleEdgeSwipe(val: val, geo: geo, isLeft: false) }
                            .onEnded { _ in finishEdgeSwipe() }
                    )
                    .onTapGesture {
                        if !isMangaMode { nextPage() } else { prevPage() }
                    }
            }
            .padding(.top, 100)
            .padding(.bottom, 120)
            
            if showSwipeHUD {
                VStack {
                    Spacer()
                    Text(hudMessage)
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(Color.black.opacity(0.8))
                        .cornerRadius(16)
                        .padding(.bottom, 120)
                }
                .transition(.opacity)
                .zIndex(100)
            }
        }
        .onAppear {
            swipeStartBrightness = UIScreen.main.brightness
        }
    }
    
    private func handleEdgeSwipe(val: DragGesture.Value, geo: GeometryProxy, isLeft: Bool) {
        if !showSwipeHUD {
            swipeStartBrightness = UIScreen.main.brightness
            swipeStartWarmth = warmthLevel
            withAnimation { showSwipeHUD = true }
        }
        guard geo.size.height > 0 else { return }
        let deltaY = val.translation.height / geo.size.height
        
        if isLeft {
            let newBright = max(0.0, min(1.0, swipeStartBrightness - deltaY))
            UIScreen.main.brightness = newBright
            self.brightnessLevel = newBright
            self.hudMessage = "Brightness: \(Int(newBright * 100))%"
        } else {
            let newWarmth = max(0.0, min(0.4, swipeStartWarmth - deltaY))
            self.warmthLevel = newWarmth
            self.userHasManuallyAdjustedWarmth = true  // suppress ambient auto-warmth
            self.hudMessage = "Warmth: \(Int((newWarmth / 0.4) * 100))%"
        }
    }
    
    private func finishEdgeSwipe() {
        swipeStartBrightness = UIScreen.main.brightness
        swipeStartWarmth = warmthLevel
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000) // 1.2 s
            withAnimation { self.showSwipeHUD = false }
        }
    }
    
    // MARK: - Bookmarks
    private var isBookmarked: Bool {
        guard let pdf = pdf else { return false }
        return pdf.metadata.bookmarkedPages.contains(currentPageIndex)
    }
    
    private func toggleBookmark() {
        guard let p = pdf, let idx = conversionManager.convertedPDFs.firstIndex(where: { $0.id == p.id }) else { return }
        
        var updated = conversionManager.convertedPDFs[idx]
        if isBookmarked {
            updated.metadata.bookmarkedPages.removeAll(where: { $0 == currentPageIndex })
        } else {
            updated.metadata.bookmarkedPages.append(currentPageIndex)
        }
        
        conversionManager.convertedPDFs[idx] = updated
        conversionManager.saveLibrary()
        
        // Haptic feedback
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
    }

    private func toggleBookmarkWithToast() {
        let wasBookmarked = isBookmarked
        toggleBookmark()
        bookmarkToastMessage = wasBookmarked
            ? "Bookmark removed"
            : "Page \(currentPageIndex + 1) bookmarked"
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            showBookmarkToast = true
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation(.easeOut(duration: 0.3)) { showBookmarkToast = false }
        }
    }

    // MARK: - Color Filter Overlay
    @ViewBuilder
    private var colorFilterOverlay: some View {
        if colorFilter != .none {
            Group {
                switch colorFilter {
                case .sepia:
                    Color(red: 0.44, green: 0.26, blue: 0.08)
                        .blendMode(.multiply)
                        .opacity(0.28)
                case .grayscale:
                    Color.white
                        .opacity(0)
                        .overlay(Color.black.opacity(0)) // handled via .saturation modifier below
                case .warm:
                    Color(red: 1.0, green: 0.75, blue: 0.4)
                        .blendMode(.multiply)
                        .opacity(0.15)
                case .none:
                    EmptyView()
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
    }
    
    // MARK: - Per-Book Preference Persistence
    private func restorePerBookPreferences() {
        guard let p = pdf,
              let saved = ReaderProgressTracker.shared.progress(for: p.id) else { return }
        
        self.currentPageIndex = saved.currentPageIndex
        
        if let mangaMode = saved.prefersMangaMode {
            isMangaMode = mangaMode
        }
        if let savedFilter = saved.colorFilter,
           let filter = ReaderColorFilter(rawValue: savedFilter) {
            colorFilter = filter
        }
    }
    
    private func savePerBookPreferences() {
        guard let p = pdf else { return }
        var progress = ReaderProgressTracker.shared.progress(for: p.id)
            ?? ReadingProgress(pdfID: p.id, lastOpenedAt: Date(), currentPageIndex: currentPageIndex,
                               totalPagesRead: 1, completionFraction: 0, readingSessionDates: [])
        progress.prefersMangaMode = isMangaMode
        progress.colorFilter = colorFilter.rawValue
        ReaderProgressTracker.shared.update(progress)
    }

    // MARK: - Progress Tracking Integration
    private func trackProgress(isPageTurn: Bool) {
        guard let p = pdf else { return }
        var progress = ReaderProgressTracker.shared.progress(for: p.id) ?? ReadingProgress(pdfID: p.id, lastOpenedAt: Date(), currentPageIndex: currentPageIndex, totalPagesRead: 1, completionFraction: 0, readingSessionDates: [])
        progress.lastOpenedAt = Date()
        progress.currentPageIndex = currentPageIndex
        if isPageTurn {
            progress.totalPagesRead += 1
            GamificationManager.shared.logPageRead()
        }
        if !pages.isEmpty {
           progress.completionFraction = Double(currentPageIndex) / Double(max(1, pages.count - 1))
        }
        if !progress.readingSessionDates.contains(where: { Calendar.current.isDateInToday($0) }) {
            progress.readingSessionDates.append(Date())
        }
        ReaderProgressTracker.shared.update(progress)
    }
}

// ✅ EPUBSmartReader completely removed and renovated into the PPL Metal Engine.

// MARK: - Standard PDF Component
struct PDFKitView: UIViewRepresentable {
    let url: URL
    @Binding var currentPageIndex: Int
    @Binding var totalPages: [URL]
    let isVerticalScroll: Bool
    let isMangaMode: Bool
    let isDoublePageMode: Bool
    @Binding var loadedDocument: PDFDocument?
    let onSingleTap: () -> Void
    var onViewCreated: ((PDFView) -> Void)? = nil  // surfaces the UIKit view reference

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        // 🚨 PANEL PARITY: True Dual Spread Engine
        pdfView.displayMode = isDoublePageMode ? .twoUpContinuous : .singlePage
        pdfView.displayDirection = isVerticalScroll ? .vertical : .horizontal
        pdfView.displaysPageBreaks = false

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.delegate = context.coordinator
        
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.delegate = context.coordinator
        
        tap.require(toFail: doubleTap)
        
        pdfView.addGestureRecognizer(doubleTap)
        pdfView.addGestureRecognizer(tap)

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.pageChanged(_:)),
            name: .PDFViewPageChanged,
            object: pdfView
        )

        context.coordinator.loadTask = Task.detached(priority: .userInitiated) {
            if let document = PDFDocument(url: url) {
                if Task.isCancelled { return }
                await MainActor.run {
                    if Task.isCancelled { return }
                    pdfView.document = document
                    self.totalPages = Array(repeating: url, count: document.pageCount)
                    self.loadedDocument = document
                }
            }
        }
        // Surface the live PDFView back to the parent (search, share, TOC).
        // Deferred one runloop to avoid mutating state during SwiftUI layout.
        let cb = onViewCreated
        DispatchQueue.main.async { cb?(pdfView) }
        return pdfView
    }

    func updateUIView(_ pdfView: PDFView, context: Context) {
        pdfView.displayDirection = isVerticalScroll ? .vertical : .horizontal
        pdfView.displayMode = isDoublePageMode ? .twoUpContinuous : .singlePage
        pdfView.displaysAsBook = isDoublePageMode
        pdfView.displaysRTL = isMangaMode
        
        if let doc = pdfView.document,
           currentPageIndex >= 0 && currentPageIndex < doc.pageCount,
           let currentVisible = pdfView.currentPage,
           doc.index(for: currentVisible) != currentPageIndex {
            if let targetPage = doc.page(at: currentPageIndex) {
                pdfView.go(to: targetPage)
            }
        }
    }
    
    // ✅ PHASE 24: CoreGraphics Memory Severance
    // Explicitly destroys the CGPDFDocument bridge when SwiftUI collapses the representable,
    // permanently ending the dreaded iPadOS backend Memory leak.
    static func dismantleUIView(_ uiView: PDFView, coordinator: Coordinator) {
        coordinator.loadTask?.cancel()
        uiView.document = nil
        uiView.removeFromSuperview()
    }

    class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: PDFKitView
        var loadTask: Task<Void, Never>?
        
        init(_ parent: PDFKitView) { self.parent = parent }
        
        @objc func handleTap(_ gesture: UITapGestureRecognizer) { parent.onSingleTap() }
        
        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let pdfView = gesture.view as? PDFView,
                  let currentPage = pdfView.currentPage else { return }
            
            let point = gesture.location(in: pdfView)
            let pagePoint = pdfView.convert(point, to: currentPage)
            
            // Toggle Zoom Out if currently zoomed in
            let autoScale = pdfView.scaleFactorForSizeToFit
            if pdfView.scaleFactor > autoScale * 1.05 {
                UIView.animate(withDuration: 0.3) {
                    pdfView.autoScales = true
                }
                return
            }
            
            // Smart Crop text isolation heuristics
            // Sweep a large vertical rectangle intersecting the text column
            let sweepRect = CGRect(x: pagePoint.x - 50, y: pagePoint.y - 400, width: 100, height: 800)
            if let selection = currentPage.selection(for: sweepRect) {
                let bounds = selection.bounds(for: currentPage) // Represents the column bounds natively
                
                // If it successfully grabbed a real column
                if bounds.width > 50 && bounds.height > 50 {
                    let targetScale = (pdfView.bounds.width / bounds.width) * 0.95 // Lock column width to screen + 5% margin
                    UIView.animate(withDuration: 0.3) {
                        pdfView.scaleFactor = targetScale
                        // Auto-scroll to the top of the selected block so the user can start reading down
                        let topOfColumn = CGRect(x: bounds.minX, y: bounds.maxY, width: bounds.width, height: 1)
                        pdfView.go(to: topOfColumn, on: currentPage)
                    }
                    return
                }
            }
            
            // Fallback: 2x Zoom on Tap Center
            UIView.animate(withDuration: 0.3) {
                pdfView.scaleFactor = pdfView.scaleFactor * 2.0
                pdfView.go(to: CGRect(x: pagePoint.x, y: pagePoint.y, width: 1, height: 1), on: currentPage)
            }
        }
        
        @objc func pageChanged(_ notification: Notification) {
            guard let pdfView = notification.object as? PDFView,
                  let currentPage = pdfView.currentPage,
                  let document = pdfView.document else { return }
            
            let index = document.index(for: currentPage)
            if index != parent.currentPageIndex {
                DispatchQueue.main.async { self.parent.currentPageIndex = index }
            }
        }
        
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            return true
        }
    }
}

extension View {
    @ViewBuilder func colorInvertIfDark(theme: EBookTheme) -> some View {
        if theme.isDark {
            self.colorInvert().hueRotation(.degrees(180))
        } else { self }
    }
}

// MARK: - Premium UI Components

struct ReaderScrubber: View {
    @Binding var currentPageIndex: Int
    let totalPages: Int
    let isMangaMode: Bool
    let pages: [URL]
    
    @Environment(\.colorScheme) private var colorScheme
    @State private var isDragging: Bool = false
    @State private var dragIndex: Int? = nil
    
    // Precomputed colours that are always legible in both modes
    private var trackBg: Color {
        colorScheme == .dark ? Color.white.opacity(0.25) : Color.black.opacity(0.18)
    }
    private var trackFill: Color { Theme.orange }
    private var thumbColor: Color {
        colorScheme == .dark ? Color(white: 0.9) : Color.white
    }
    private var panelBg: Material { .regularMaterial }
    
    var body: some View {
        VStack(spacing: 0) {
            // ── 5-page filmstrip thumbnail strip (shown while scrubbing) ──
            if isDragging, let activeIndex = dragIndex {
                filmstrip(centeredAt: activeIndex)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, 8)
            } else {
                // Idle: compact page pill only
                Text("\(currentPageIndex + 1) / \(totalPages)")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, 8)
            }
            
            // ── Scrubber track ──
            GeometryReader { geo in
                let displayIndex = dragIndex ?? currentPageIndex
                let normalized = isMangaMode
                    ? CGFloat(totalPages - 1 - displayIndex)
                    : CGFloat(displayIndex)
                let ratio = totalPages > 1 ? normalized / CGFloat(totalPages - 1) : 0
                let thumbDiameter: CGFloat = isDragging ? 22 : 18
                let trackWidth = geo.size.width - thumbDiameter
                let thumbX = ratio * trackWidth
                
                ZStack(alignment: .leading) {
                    // Background track
                    Capsule()
                        .fill(trackBg)
                        .frame(height: isDragging ? 5 : 4)
                    
                    // Filled portion
                    Capsule()
                        .fill(trackFill)
                        .frame(width: thumbX + thumbDiameter, height: isDragging ? 5 : 4)
                    
                    // Thumb
                    Circle()
                        .fill(thumbColor)
                        .shadow(color: .black.opacity(isDragging ? 0.35 : 0.2), radius: isDragging ? 6 : 3, y: 1)
                        .frame(width: thumbDiameter, height: thumbDiameter)
                        .offset(x: thumbX)
                        .animation(.interactiveSpring(response: 0.18, dampingFraction: 0.8), value: displayIndex)
                }
                .frame(height: 36) // Generous hit-target height
                .contentShape(Rectangle()) // Full bar is draggable
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onChanged { val in
                            isDragging = true
                            guard geo.size.width > 0 else { return }
                            let percentage = min(max(val.location.x / geo.size.width, 0), 1)
                            let rawIndex = Int(round(percentage * CGFloat(totalPages - 1)))
                            let targeted = isMangaMode ? (totalPages - 1 - rawIndex) : rawIndex
                            if dragIndex != targeted {
                                let g = UISelectionFeedbackGenerator()
                                g.selectionChanged()
                                dragIndex = targeted
                            }
                        }
                        .onEnded { _ in
                            if let final = dragIndex {
                                currentPageIndex = final
                            }
                            withAnimation(.easeOut(duration: 0.2)) {
                                isDragging = false
                            }
                            dragIndex = nil
                        }
                )
            }
            .frame(height: 36)
            .padding(.horizontal, 20)
        }
        .padding(.top, 12)
        .padding(.bottom, 16)
        .padding(.horizontal, 4)
        .background(panelBg, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.18), radius: 16, y: 4)
        .padding(.horizontal, 16)
        .animation(.interactiveSpring(response: 0.22, dampingFraction: 0.85), value: isDragging)
    }
    
    // MARK: - Filmstrip
    @ViewBuilder
    private func filmstrip(centeredAt center: Int) -> some View {
        let halfCount = 2
        let indices = (center - halfCount ... center + halfCount).map { $0 }
        
        HStack(spacing: 6) {
            ForEach(indices, id: \.self) { idx in
                let isCenter = idx == center
                if idx >= 0 && idx < pages.count {
                    VStack(spacing: 3) {
                        LocalFileImage(url: pages[idx])
                            .frame(
                                width: isCenter ? 70 : 52,
                                height: isCenter ? 100 : 74
                            )
                            .cornerRadius(isCenter ? 7 : 5)
                            .overlay(
                                RoundedRectangle(cornerRadius: isCenter ? 7 : 5)
                                    .strokeBorder(
                                        isCenter ? Theme.orange : Color.primary.opacity(0.15),
                                        lineWidth: isCenter ? 2 : 0.5
                                    )
                            )
                            .shadow(color: .black.opacity(isCenter ? 0.4 : 0.15), radius: isCenter ? 8 : 3)
                            .scaleEffect(isCenter ? 1.0 : 0.92)
                        
                        Text("\(idx + 1)")
                            .font(.system(size: isCenter ? 11 : 9, weight: .semibold, design: .rounded))
                            .foregroundStyle(isCenter ? Theme.orange : .secondary)
                    }
                    .animation(.interactiveSpring(response: 0.2, dampingFraction: 0.75), value: center)
                } else {
                    Color.clear
                        .frame(width: isCenter ? 70 : 52, height: isCenter ? 100 : 74)
                }
            }
        }
    }
}

import MediaPlayer
import AVFoundation

struct VolumeHook: UIViewControllerRepresentable {
    var onUp: () -> Void
    var onDown: () -> Void
    
    func makeUIViewController(context: Context) -> VolumeObserverController {
        return VolumeObserverController(onUp: onUp, onDown: onDown)
    }
    func updateUIViewController(_ uiViewController: VolumeObserverController, context: Context) {}
}

class VolumeObserverController: UIViewController {
    var onUp: () -> Void
    var onDown: () -> Void
    private var baseVolume: Float = 0.5
    private var audioSession = AVAudioSession.sharedInstance()
    private var observation: NSKeyValueObservation?
    private let volumeView = MPVolumeView() // Native iOS 17 trick to perfectly hide the Volume HUD
    
    init(onUp: @escaping () -> Void, onDown: @escaping () -> Void) {
        self.onUp = onUp
        self.onDown = onDown
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) { fatalError() }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.addSubview(volumeView)
        volumeView.frame = CGRect(x: -1000, y: -1000, width: 1, height: 1)
        volumeView.isHidden = false
        
        try? audioSession.setCategory(.ambient) // Extremely important! Allows background music to keep playing while reading comic
        try? audioSession.setActive(true)
        baseVolume = audioSession.outputVolume
        
        observation = audioSession.observe(\.outputVolume, options: [.new]) { [weak self] session, change in
            guard let self = self, let newVolume = change.newValue else { return }
            if newVolume > self.baseVolume || newVolume == 1.0 {
                self.onUp()
            } else if newVolume < self.baseVolume || newVolume == 0.0 {
                self.onDown()
            }
            self.baseVolume = newVolume
        }
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        observation?.invalidate()
        try? audioSession.setActive(false)
    }
}
