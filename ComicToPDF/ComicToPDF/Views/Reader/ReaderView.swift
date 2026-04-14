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
    
    // ✅ Phase 30: Advanced Reader Features
    @AppStorage("isVerticalScroll") private var isVerticalScroll = false
    @AppStorage("isDoublePageMode") private var isDoublePageMode = false
    @AppStorage("autoLandscapeDualPage") private var autoLandscapeDualPage = true
    @State private var isDrawingMode = false
    @State private var canvasView = PKCanvasView()
    @State private var deviceOrientation: UIDeviceOrientation = UIDevice.current.orientation
    
    // ✅ Color Filter
    @State private var colorFilter: ReaderColorFilter = .none
    
    // ✅ Jump to Page
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
    
    // ✅ CBR warning
    @State private var showCBRWarning = false
    
    var body: some View {
        GeometryReader { geo in
            ZStack {
                // ✅ CBR Guard: surface helpful message early
                if CBRSupportChecker.isCBR(fileURL) {
                    VStack(spacing: 20) {
                        Image(systemName: "doc.badge.exclamationmark")
                            .font(.system(size: 60))
                            .foregroundStyle(Color.orange)
                        Text("CBR Not Supported")
                            .font(.title2.bold())
                        Text(CBRSupportChecker.unsupportedMessage)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                        Button("Go Back") { if let onExit = onExit { onExit() } else { dismiss() } }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.orange)
                    }
                // ✅ Route: text-based EPUB → EBookReaderView, everything else → image reader
                } else if fileURL.pathExtension.lowercased() == "epub" && contentType == .book {
                    EBookReaderView(
                        fileURL: fileURL,
                        title: fileURL.deletingPathExtension().lastPathComponent,
                        onExit: onExit ?? { dismiss() }
                    )
                } else {
                    comicReaderBody
                }
                
                // KOReader Casual Comforts Overlay
                edgeSwipeOverlay(in: geo)
                
                // Manga Binge-Mode HUD
                if showBingePrompt, let nextVol = nextVolumeToRead {
                    bingeModeOverlay(nextVol: nextVol)
                }
            }
        }
    }
    
    // MARK: - Comic / Manga Reader
    private var comicReaderBody: some View {
        ZStack {
            if isLoading {
                ProgressView("Opening Book...").scaleEffect(1.2)
            } else if let error = errorMessage {
                    VStack {
                        Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundColor(.red)
                        Text("Error: \(error)").padding()
                    }
                } else {
                    // ✅ READER CONTENT
                    if isVerticalScroll {
                        // VERTICAL WEBTOON MODE
                        // 🚨 COMPETITOR FIX: Native SwiftUI AsyncImage poisons Jetsam thresholds over 300 pages.
                        // Replacing with custom mapping bounds using LocalFileImage
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(pages, id: \.self) { pageURL in
                                    LocalFileImage(url: pageURL)
                                }
                            }
                        }
                    } else {
                        // ✅ ZERO-LATENCY METAL PPL READER
                        if fileURL.pathExtension.lowercased() != "pdf" {
                            if !pages.isEmpty {
                                let effectiveDoublePage = isDoublePageMode || (autoLandscapeDualPage && deviceOrientation.isLandscape)
                                PPLReaderView(pages: pages, currentPageIndex: $currentPageIndex, isMangaMode: isMangaMode, isDoublePageOverride: effectiveDoublePage) {
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
                                isDoublePageMode: isDoublePageMode,
                                onSingleTap: {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        isToolbarVisible.toggle()
                                    }
                                }
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
                
                // Apply color filter overlay
                colorFilterOverlay
                
                // Hardware Hardware Binding
                VolumeHook(onUp: {
                    isMangaMode ? nextPage() : prevPage()
                }, onDown: {
                    isMangaMode ? prevPage() : nextPage()
                })
                .frame(width: 0, height: 0)
                
                // ✅ Immersive UI OSD
                if !isVerticalScroll && !pages.isEmpty && !isLoading {
                    VStack {
                        Spacer()
                        if isToolbarVisible {
                            ReaderScrubber(
                                currentPageIndex: $currentPageIndex,
                                totalPages: pages.count,
                                isMangaMode: isMangaMode,
                                pages: pages
                            )
                            .padding(.bottom, 20)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        } else {
                            // Micro-pill that fades out the visual pollution
                            Text("\(currentPageIndex + 1) / \(pages.count)")
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
            }
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(.leftArrow) {
                isMangaMode ? nextPage() : prevPage()
                return .handled
            }
            .onKeyPress(.rightArrow) {
                isMangaMode ? prevPage() : nextPage()
                return .handled
            }
            .navigationBarHidden(true)
            .statusBarHidden(!isToolbarVisible)
            .overlay(alignment: .top) {
                if isToolbarVisible && !isLoading && errorMessage == nil {
                    topBar
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .task {
                await prepareArchive()
                restorePerBookPreferences()
                trackProgress()
                // Build TOC from extracted pages
                let extracted = pages
                toc = CBZTableOfContents.build(from: extracted)
            }
            .onChange(of: pages) {
                toc = CBZTableOfContents.build(from: pages)
            }
            .onChange(of: currentPageIndex) { trackProgress() }
            .onChange(of: isMangaMode) { savePerBookPreferences() }
            .onChange(of: colorFilter) { savePerBookPreferences() }
            .onChange(of: sleepTimer.didFire) { fired in
                if fired { if let onExit = onExit { onExit() } else { dismiss() } }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
                deviceOrientation = UIDevice.current.orientation
            }
            .onDisappear {
                if let dir = unzippedDir {
                    try? FileManager.default.removeItem(at: dir)
                }
                orientationLock.unlock() // Always restore free rotation on exit
                sleepTimer.stop()
            }
            .alert("Jump to Page", isPresented: $showJumpToPage) {
                TextField("Page number (1–\(pages.count))", text: $jumpToPageText)
                    .keyboardType(.numberPad)
                Button("Go") {
                    if let n = Int(jumpToPageText), n >= 1, n <= pages.count {
                        currentPageIndex = n - 1
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
            .sheet(isPresented: $showSleepTimerPicker) {
                SleepTimerPickerSheet()
            }
    }
    
    // MARK: - Top Bar (Minimal Glass HUD)
    @ViewBuilder private var topBar: some View {
        HStack(spacing: 10) {
            // Back
            Button { if let onExit = onExit { onExit() } else { dismiss() } } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: Circle())
            }

            Text(fileURL.deletingPathExtension().lastPathComponent)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .shadow(color: .black.opacity(0.6), radius: 3)

            Spacer()

            // Page + reading time pill
            if !pages.isEmpty {
                VStack(spacing: 1) {
                    Text("\(currentPageIndex + 1) / \(pages.count)")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))
                    if let mins = ReaderProgressTracker.shared.progress(for: pdf?.id ?? UUID())?.estimatedMinutesRemaining, mins > 0 {
                        Text("\(mins)m left")
                            .font(.system(size: 9, weight: .regular, design: .rounded))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.ultraThinMaterial, in: Capsule())
            }

            Spacer()

            // Sleep timer badge
            if sleepTimer.isActive {
                Button { showSleepTimerPicker = true } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "moon.zzz.fill").font(.system(size: 10))
                        Text(sleepTimer.formattedRemaining).font(.system(size: 11, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(Color.orange)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
                }
            }

            // Orientation lock
            Button { orientationLock.toggleLock(current: deviceOrientation) } label: {
                Image(systemName: orientationLock.isLocked ? "lock.rotation" : "lock.rotation.open")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(orientationLock.isLocked ? Color.orange : .white)
                    .frame(width: 34, height: 34)
                    .background(.ultraThinMaterial, in: Circle())
            }

            // Bookmark
            if pdf != nil {
                Button(action: toggleBookmark) {
                    Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(isBookmarked ? Theme.orange : .white)
                        .frame(width: 34, height: 34)
                        .background(.ultraThinMaterial, in: Circle())
                }
            }

            // Settings + all tools
            Menu {
                Section("Reading Mode") {
                    Toggle("Manga (Right-to-Left)", isOn: $isMangaMode)
                    Toggle("Vertical Webtoon Scroll", isOn: $isVerticalScroll)
                }
                Section("Layout") {
                    Toggle("Dual Page (Manual)", isOn: $isDoublePageMode)
                    Toggle("Auto Dual Page in Landscape", isOn: $autoLandscapeDualPage)
                }
                Section("Color Filter") {
                    ForEach(ReaderColorFilter.allCases, id: \.self) { filter in
                        Button { withAnimation { colorFilter = filter } } label: {
                            Label(filter.label, systemImage: filter.icon)
                        }
                        .foregroundStyle(colorFilter == filter ? Color.orange : Color.primary)
                    }
                }
                Section("Navigate") {
                    Button { jumpToPageText = ""; showJumpToPage = true } label: {
                        Label("Jump to Page…", systemImage: "arrow.right.circle")
                    }
                    .disabled(pages.isEmpty)
                    Button { showTOC = true } label: {
                        Label("Table of Contents", systemImage: "list.bullet.rectangle")
                    }
                    .disabled(toc.chapters.count <= 1)
                }
                Section("Tools") {
                    Button { shareCurrentPage() } label: {
                        Label("Share This Page", systemImage: "square.and.arrow.up")
                    }
                    .disabled(pages.isEmpty)
                    Button { showSleepTimerPicker = true } label: {
                        Label(
                            sleepTimer.isActive ? "Sleep Timer (\(sleepTimer.formattedRemaining))" : "Sleep Timer…",
                            systemImage: "moon.zzz"
                        )
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(.ultraThinMaterial, in: Circle())
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 52)
        .padding(.bottom, 10)
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0.55), Color.clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .top)
        )
    }

    // MARK: - Share Current Page
    private func shareCurrentPage() {
        guard currentPageIndex < pages.count else { return }
        let url = pages[currentPageIndex]
        DispatchQueue.global(qos: .userInitiated).async {
            if let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
                DispatchQueue.main.async {
                    self.shareImage = image
                    self.showShareSheet = true
                }
            }
        }
    }

    
    // MARK: - Archive Preparation
    private func prepareArchive() async {
        let ext = fileURL.pathExtension.lowercased()
        
        // PDFs are handled directly by PDFKitView without extraction
        if ext == "pdf" {
            await MainActor.run { isLoading = false }
            return
        }
        
        do {
            if ext == "epub" {
                let fileManager = FileManager.default
                let tempID = UUID().uuidString
                let dest = fileManager.temporaryDirectory.appendingPathComponent("Reader_\(tempID)")
                
                try fileManager.createDirectory(at: dest, withIntermediateDirectories: true)
                try fileManager.unzipItem(at: fileURL, to: dest)
                await MainActor.run { self.unzippedDir = dest }
                
                if let enumerator = fileManager.enumerator(at: dest, includingPropertiesForKeys: nil) {
                    var foundPages: [URL] = []
                    while let file = enumerator.nextObject() as? URL {
                        // ✅ RENOVATED: Extract Raw Images for Metal PPL Engine (Bypassing slow HTML WKWebViews)
                        if ["jpg", "jpeg", "png", "webp", "heic"].contains(file.pathExtension.lowercased()) {
                            // Filter out standard EPUB structural assets (like cover thumbnails or tiny icons)
                            if !file.lastPathComponent.lowercased().contains("thumbnail") && !file.lastPathComponent.lowercased().contains("cover") {
                                foundPages.append(file)
                            } else if file.lastPathComponent.lowercased() == "cover.jpg" {
                                foundPages.insert(file, at: 0) // Ensure explicit cover is page 0
                            }
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
                let result = try await ZipUtilities.extractComic(from: fileURL)
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
                    .foregroundColor(Theme.orange)
                
                Text("Volume Complete!")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                
                Text("Continue reading the next issue in the series?")
                    .font(.headline)
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                
                VStack(spacing: 12) {
                    Text(nextVol.name)
                        .font(.title3)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                    
                    if let issue = nextVol.metadata.issueNumber {
                        Text("Issue #\(issue)")
                            .font(.subheadline)
                            .foregroundColor(Theme.orange)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.white.opacity(0.1))
                .cornerRadius(12)
                .padding(.horizontal, 32)
                
                HStack(spacing: 16) {
                    Button(action: {
                        withAnimation { showBingePrompt = false }
                    }) {
                        Text("Later")
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.white.opacity(0.2))
                            .cornerRadius(12)
                    }
                    
                    Button(action: {
                        launchBingeJump(to: nextVol)
                    }) {
                        Text("Read Now")
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Theme.orange)
                            .cornerRadius(12)
                    }
                }
                .padding(.horizontal, 32)
                .padding(.top, 16)
            }
            .padding(32)
            .background(BlurView(style: .systemMaterialDark))
            .cornerRadius(24)
            .shadow(radius: 20)
            .padding(40)
        }
        .zIndex(1000)
    }
    
    private func launchBingeJump(to nextPDF: ConvertedPDF) {
        withAnimation { showBingePrompt = false }
        isLoading = true
        fileURL = nextPDF.url
        pdf = nextPDF
        
        // Cleanup old
        if let dir = unzippedDir { try? FileManager.default.removeItem(at: dir) }
        unzippedDir = nil
        pages = []
        currentPageIndex = 0
        
        Task { await prepareArchive() }
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
        
        let deltaY = val.translation.height / geo.size.height
        
        if isLeft {
            let newBright = max(0.0, min(1.0, swipeStartBrightness - deltaY))
            UIScreen.main.brightness = newBright
            self.brightnessLevel = newBright
            self.hudMessage = "Brightness: \(Int(newBright * 100))%"
        } else {
            let newWarmth = max(0.0, min(0.4, swipeStartWarmth - deltaY))
            self.warmthLevel = newWarmth
            self.hudMessage = "Warmth: \(Int((newWarmth / 0.4) * 100))%"
        }
    }
    
    private func finishEdgeSwipe() {
        swipeStartBrightness = UIScreen.main.brightness
        swipeStartWarmth = warmthLevel
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
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
    private func trackProgress() {
        guard let p = pdf else { return }
        var progress = ReaderProgressTracker.shared.progress(for: p.id) ?? ReadingProgress(pdfID: p.id, lastOpenedAt: Date(), currentPageIndex: currentPageIndex, totalPagesRead: 1, completionFraction: 0, readingSessionDates: [])
        progress.lastOpenedAt = Date()
        progress.currentPageIndex = currentPageIndex
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
    let onSingleTap: () -> Void

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
                }
            }
        }
        return pdfView
    }

    func updateUIView(_ pdfView: PDFView, context: Context) {
        pdfView.displayDirection = isVerticalScroll ? .vertical : .horizontal
        pdfView.displayMode = isDoublePageMode ? .twoUpContinuous : .singlePage
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
        if theme == .dark || theme == .obsidian {
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
