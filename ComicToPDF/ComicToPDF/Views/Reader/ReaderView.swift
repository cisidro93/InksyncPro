
import SwiftUI
import UIKit
import WebKit
import PDFKit
import ZIPFoundation

struct ReaderView: View {
    @State var fileURL: URL
    let contentType: ContentType
    @State var pdf: ConvertedPDF? // Added to support Bookmarking
    var onExit: (() -> Void)? = nil
    
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var conversionManager: ConversionManager
    
    @AppStorage("isMangaMode") private var isMangaMode = false
    @State private var isPanelViewEnabled = true
    @State private var isVerticalScroll = false
    @State private var isToolbarVisible = true
    
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
    
    var body: some View {
        GeometryReader { geo in
            ZStack {
                // ✅ Route: text-based EPUB → EBookReaderView, everything else → image reader
                if fileURL.pathExtension.lowercased() == "epub" && contentType == .book {
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
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(pages, id: \.self) { pageURL in
                                    AsyncImage(url: pageURL) { phase in
                                        if let image = phase.image {
                                            image.resizable().aspectRatio(contentMode: .fit)
                                        } else {
                                            Color.gray.opacity(0.1).frame(height: 300)
                                        }
                                    }
                                }
                            }
                        }
                    } else {
                        // ✅ ZERO-LATENCY METAL PPL READER
                        if fileURL.pathExtension.lowercased() != "pdf" {
                            if !pages.isEmpty {
                                PPLReaderView(pages: pages, currentPageIndex: $currentPageIndex, isMangaMode: isMangaMode) {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        isToolbarVisible.toggle()
                                    }
                                }
                                .ignoresSafeArea()
                            }
                        } else {
                            PDFKitView(url: fileURL)
                                .onTapGesture {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        isToolbarVisible.toggle()
                                    }
                                }
                        }
                    }
                }
                
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
            }
            .onDisappear {
                // Cleanup Temp Files
                if let dir = unzippedDir {
                    try? FileManager.default.removeItem(at: dir)
                }
            }
    }
    
    // MARK: - Top Bar
    @ViewBuilder private var topBar: some View {
        HStack(spacing: 16) {
            Button { if let onExit = onExit { onExit() } else { dismiss() } } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                    .padding(10)
                    .background(Color.primary.opacity(0.08))
                    .clipShape(Circle())
            }
            
            VStack(alignment: .leading, spacing: 1) {
                Text(fileURL.deletingPathExtension().lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
            }
            
            Spacer()
            
            if pdf != nil {
                Button(action: toggleBookmark) {
                    Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(isBookmarked ? Theme.orange : .primary)
                        .padding(10)
                        .background(Color.primary.opacity(0.08))
                        .clipShape(Circle())
                }
            }
            
            Menu {
                Section("Reading Direction") {
                    Toggle("Manga Mode (R-to-L)", isOn: $isMangaMode)
                    Toggle("Vertical Webtoon", isOn: $isVerticalScroll)
                }
                Section("Advanced") {
                    Toggle("Panel View", isOn: $isPanelViewEnabled)
                }
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.primary)
                    .padding(10)
                    .background(Color.primary.opacity(0.08))
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 50)
        .padding(.bottom, 12)
        .background(
            Color(UIColor.systemBackground).opacity(0.92)
                .background(.ultraThinMaterial.opacity(0.3))
                .ignoresSafeArea(edges: .top)
        )
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
                Color.black.opacity(0.001)
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
                
                Color.black.opacity(0.001)
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
}

// ✅ EPUBSmartReader completely removed and renovated into the PPL Metal Engine.

// MARK: - Standard PDF Component
struct PDFKitView: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        return pdfView
    }
    func updateUIView(_ pdfView: PDFView, context: Context) {
        if pdfView.document == nil { pdfView.document = PDFDocument(url: url) }
    }
}

// MARK: - Premium UI Components

struct ReaderScrubber: View {
    @Binding var currentPageIndex: Int
    let totalPages: Int
    let isMangaMode: Bool
    let pages: [URL]
    
    @State private var dragIndex: Int? = nil // Tracks the thumb while scrubbing
    
    var body: some View {
        VStack(spacing: 8) {
            // Floating Thumbnail Preview
            if let activeIndex = dragIndex, activeIndex >= 0 && activeIndex < pages.count {
                VStack(spacing: 4) {
                    AsyncImage(url: pages[activeIndex]) { phase in
                        if let image = phase.image {
                            image.resizable().aspectRatio(contentMode: .fit)
                        } else {
                            Color.black.opacity(0.8)
                        }
                    }
                    .frame(width: 90, height: 130)
                    .cornerRadius(8)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.2), lineWidth: 1))
                    .shadow(color: .black.opacity(0.5), radius: 10, y: 5)
                    
                    Text("Page \(activeIndex + 1)")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(uiColor: UIColor.systemBackground))
                        .clipShape(Capsule())
                        .shadow(radius: 3)
                }
                .transition(.opacity.combined(with: .scale))
            } else {
                Text("Page \(currentPageIndex + 1) of \(totalPages)")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color(uiColor: UIColor.systemBackground).opacity(0.8))
                    .clipShape(Capsule())
            }
            
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.15)).frame(height: 6)
                    
                    let displayIndex = dragIndex ?? currentPageIndex
                    let normalized = isMangaMode ? CGFloat(totalPages - 1 - displayIndex) : CGFloat(displayIndex)
                    let ratio = totalPages > 1 ? normalized / CGFloat(totalPages - 1) : 0
                    let thumbWidth: CGFloat = 20
                    let trackWidth = geo.size.width - thumbWidth
                    
                    Capsule()
                        .fill(Theme.orange)
                        .frame(width: ratio * trackWidth + thumbWidth, height: 6)
                    
                    Circle()
                        .fill(Color(uiColor: UIColor.systemBackground))
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
                                        currentPageIndex = final
                                    }
                                    dragIndex = nil
                                }
                        )
                }
                .frame(height: 24)
            }
            .frame(height: 24)
            .padding(.horizontal, 30)
        }
        .padding(.top, 10)
        .padding(.bottom, 20)
        .background(
            Color(uiColor: UIColor.systemBackground).opacity(0.92)
                .background(.ultraThinMaterial.opacity(0.3))
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: Color.black.opacity(0.15), radius: 10, y: 5)
        .padding(.horizontal, 20)
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
