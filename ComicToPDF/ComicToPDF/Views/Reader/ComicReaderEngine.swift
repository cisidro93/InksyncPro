import SwiftUI
import ZIPFoundation
import PDFKit

extension View {
    @ViewBuilder
    func applyComicEnhancements(isEnhanced: Bool) -> some View {
        if isEnhanced {
            self
                .contrast(1.25)
                .saturation(1.35)
        } else {
            self
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
    private let maxCacheSize = 7
    private let queue = DispatchQueue(label: "com.inksync.ComicImageCache")
    
    // For CBZ extraction
    private var cbzArchive: Archive?
    private var entries: [Entry] = []
    
    @Published var isLoading = true
    var pageCount: Int = 0
    let isPDF: Bool
    private let pdfDocument: PDFDocument?
    
    init(pdf: ConvertedPDF) {
        let ext = pdf.url.pathExtension.lowercased()
        isPDF = (ext == "pdf")
        
        if isPDF {
            self.pdfDocument = PDFDocument(url: pdf.url)
            self.pageCount = pdfDocument?.pageCount ?? 0
            self.isLoading = false
        } else {
            self.pdfDocument = nil
            queue.async { [weak self] in
                guard let self = self else { return }
                guard let archive = try? Archive(url: pdf.url, accessMode: .read, pathEncoding: .utf8) else {
                    DispatchQueue.main.async { self.isLoading = false }
                    return
                }
                
                let sortedEntries = archive.filter { entry in
                    let name = entry.path.lowercased()
                    return name.hasSuffix(".jpg") || name.hasSuffix(".jpeg") || name.hasSuffix(".png") || name.hasSuffix(".webp")
                }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                
                DispatchQueue.main.async {
                    self.cbzArchive = archive
                    self.entries = sortedEntries
                    self.pageCount = sortedEntries.count
                    self.isLoading = false
                }
            }
        }
    }
    
    func getImage(at index: Int) -> UIImage? {
        guard index >= 0 && index < pageCount else { return nil }
        
        // 1. Check Memory Cache
        if let cachedImage = cache.object(forKey: NSNumber(value: index)) {
            updateLRU(index)
            return cachedImage
        }
        
        // 2. Not in memory, extract it synchronously to avoid SwiftUI layout thrashing on fast swiping
        // Wait, SwiftUI loves async for TabViews padding but TabView loads surrounding views.
        let image = extractOrRenderImage(at: index)
        if let img = image {
            cache.setObject(img, forKey: NSNumber(value: index))
            updateLRU(index)
        }
        
        // Background extraction of surrounding pages (Prefetch window ±3)
        prefetchSurrounding(index: index)
        
        return image
    }
    
    private func updateLRU(_ index: Int) {
        queue.async {
            if let pos = self.accessQueue.firstIndex(of: index) {
                self.accessQueue.remove(at: pos)
            }
            self.accessQueue.append(index)
            
            // Evict if over maxCacheSize (7)
            while self.accessQueue.count > self.maxCacheSize {
                let evictIndex = self.accessQueue.removeFirst()
                self.cache.removeObject(forKey: NSNumber(value: evictIndex))
            }
        }
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
                return UIImage(data: data)
            } catch {
                return nil
            }
        }
    }
    
    private func prefetchSurrounding(index: Int) {
        queue.async { [weak self] in
            guard let self = self else { return }
            let range = max(0, index - 2)...min(self.pageCount - 1, index + 3)
            for i in range {
                if i == index { continue }
                if self.cache.object(forKey: NSNumber(value: i)) == nil {
                    if let img = self.extractOrRenderImage(at: i) {
                        self.cache.setObject(img, forKey: NSNumber(value: i))
                        self.updateLRU(i)
                    }
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
    @State private var isEnhanced: Bool = false
    
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
                        // Standard Horizontal or RTL Mode
                        TabView(selection: $currentIndex) {
                            ForEach(0..<cache.pageCount, id: \.self) { index in
                                ComicPageView(image: cache.getImage(at: index))
                                    .applyComicEnhancements(isEnhanced: isEnhanced)
                                    .tag(index)
                                    .rotation3DEffect(.degrees(readingMode == .mangaRTL ? 180 : 0), axis: (x: 0, y: 1, z: 0))
                            }
                        }
                        .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))
                        // Reverse rendering context for RTL mode
                        .rotation3DEffect(.degrees(readingMode == .mangaRTL ? 180 : 0), axis: (x: 0, y: 1, z: 0))
                    }
                }
                .onTapGesture { chromeVisible.toggle() }
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
                isEnhanced: isEnhanced,
                onEnhanceToggle: { isEnhanced.toggle() }
            )
        }
        .onAppear {
            if let saved = ReaderProgressTracker.shared.progress(for: pdf.id) {
                currentIndex = saved.currentPageIndex
            }
        }
    }
    
    var guidedView: some View {
        TabView(selection: $currentIndex) {
            ForEach(0..<cache.pageCount, id: \.self) { index in
                let panelsForPage = manager.panelOverrides[pdf.id]?[index] ?? []
                ComicGuidedPageView(
                    image: cache.getImage(at: index),
                    panels: panelsForPage,
                    masterIndex: $currentIndex,
                    totalPages: cache.pageCount,
                    onTapChrome: { chromeVisible.toggle() }
                )
                .applyComicEnhancements(isEnhanced: isEnhanced)
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
                            .applyComicEnhancements(isEnhanced: isEnhanced)
                            .aspectRatio(contentMode: .fill)
                            .padding(.bottom, 2)
                            .onAppear { currentIndex = index }
                    } else {
                        Color.black.frame(height: 500)
                    }
                }
            }
        }
    }
    
    var twoUpView: some View {
        // Landscape two-up
        TabView(selection: $currentIndex) {
            let limit = cache.pageCount / 2
            ForEach(0..<limit, id: \.self) { pairIndex in
                let index1 = pairIndex * 2
                let index2 = index1 + 1
                
                HStack(spacing: 0) {
                    if let img1 = cache.getImage(at: index1) {
                        Image(uiImage: img1).resizable().applyComicEnhancements(isEnhanced: isEnhanced).aspectRatio(contentMode: .fit)
                    }
                    if index2 < cache.pageCount, let img2 = cache.getImage(at: index2) {
                        Image(uiImage: img2).resizable().applyComicEnhancements(isEnhanced: isEnhanced).aspectRatio(contentMode: .fit)
                    }
                }
                .tag(index1)
            }
        }
        .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))
    }
}

// Wrap Image to support pinch-to-zoom (Basic implementation)
struct ComicPageView: View {
    let image: UIImage?
    @State private var currentScale: CGFloat = 1.0
    
    var body: some View {
        if let image = image {
            GeometryReader { geo in
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: geo.size.width, height: geo.size.width * (image.size.height / image.size.width))
                    .frame(width: geo.size.width, height: geo.size.height)
                    .scaleEffect(currentScale)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { val in currentScale = max(1.0, val) }
                            .onEnded { _ in withAnimation(.spring()) { currentScale = 1.0 } }
                    )
            }
        } else {
            Color.black
        }
    }
}

// MARK: - Guided View Component
struct ComicGuidedPageView: View {
    let image: UIImage?
    let panels: [PanelExtractor.Panel]
    @Binding var masterIndex: Int
    let totalPages: Int
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
                Color.black
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

