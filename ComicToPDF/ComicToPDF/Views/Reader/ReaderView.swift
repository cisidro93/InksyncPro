
import SwiftUI
import WebKit
import PDFKit
import ZIPFoundation

struct ReaderView: View {
    let fileURL: URL
    let contentType: ContentType
    var pdf: ConvertedPDF? // Added to support Bookmarking
    
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var conversionManager: ConversionManager
    
    @State private var isPanelViewEnabled = true
    @State private var isVerticalScroll = false
    
    // Unzip State
    @State private var unzippedDir: URL?
    @State private var pages: [URL] = []
    @State private var currentPageIndex = 0
    @State private var isLoading = true
    @State private var errorMessage: String?
    
    var body: some View {
        // ✅ Route: text-based EPUB → EBookReaderView, everything else → image reader
        if fileURL.pathExtension.lowercased() == "epub" && contentType == .book {
            EBookReaderView(
                fileURL: fileURL,
                title: fileURL.deletingPathExtension().lastPathComponent
            )
        } else {
            comicReaderBody
        }
    }
    
    // MARK: - Comic / Manga Reader
    private var comicReaderBody: some View {
        NavigationStack {
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
                        // PAGED MODE (Premium 3D Page Curl)
                        if fileURL.pathExtension.lowercased() != "pdf" {
                            if !pages.isEmpty {
                                PageCurlReaderView(
                                    pages: pages.enumerated().map { index, pageURL in
                                        Group {
                                            if fileURL.pathExtension.lowercased() == "epub" {
                                                EPUBSmartReader(
                                                    pageURL: pageURL,
                                                    panelMode: $isPanelViewEnabled,
                                                    onNextPage: nextPage,
                                                    onPrevPage: prevPage
                                                )
                                            } else {
                                                AsyncImage(url: pageURL) { phase in
                                                    if let image = phase.image {
                                                        image.resizable().aspectRatio(contentMode: .fit)
                                                    } else {
                                                        ProgressView()
                                                    }
                                                }
                                            }
                                        }
                                        .id(pageURL)
                                    },
                                    currentPageIndex: $currentPageIndex,
                                    transitionStyle: .pageCurl, // 3D Curl effect
                                    navigationOrientation: .horizontal
                                )
                                .ignoresSafeArea(edges: [.bottom, .horizontal])
                            }
                        } else {
                            PDFKitView(url: fileURL)
                        }
                    }
                }
                
                // Page Indicator (Only show in Paged Mode)
                if !isVerticalScroll && !pages.isEmpty && !isLoading {
                    VStack {
                        Spacer()
                        HStack {
                            Text("Page \(currentPageIndex + 1) / \(pages.count)")
                                .font(.caption)
                                .padding(6)
                                .background(.thinMaterial)
                                .cornerRadius(8)
                        }
                        .padding(.bottom, 20)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }.fontWeight(.bold)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 16) {
                        if let pdf = pdf {
                            Button(action: toggleBookmark) {
                                Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark")
                                    .foregroundColor(isBookmarked ? Theme.orange : Theme.blue)
                            }
                        }
                        
                        Menu {
                            Toggle("Vertical Scroll", isOn: $isVerticalScroll)
                            Toggle("Panel View", isOn: $isPanelViewEnabled)
                        } label: {
                            Image(systemName: "gear")
                        }
                    }
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
        } // End NavigationStack
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
                        if ["xhtml", "html"].contains(file.pathExtension.lowercased()) {
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
    func nextPage() {
        if currentPageIndex < pages.count - 1 { currentPageIndex += 1 }
    }
    
    func prevPage() {
        if currentPageIndex > 0 { currentPageIndex -= 1 }
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

// MARK: - Smart EPUB WebView
struct EPUBSmartReader: UIViewRepresentable {
    let pageURL: URL
    @Binding var panelMode: Bool
    var onNextPage: () -> Void
    var onPrevPage: () -> Void
    
    func makeUIView(context: Context) -> WKWebView {
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences = prefs
        
        // JAVASCRIPT: Handle Panels & Navigation internally
        let js = """
        var panelIndex = -1;
        var panels = [];
        var isPanelMode = \(panelMode);

        // CSS for Zoom
        var style = document.createElement('style');
        style.innerHTML = `body { transition: transform 0.4s ease; transform-origin: top left; overflow: hidden; touch-action: none; }`;
        document.head.appendChild(style);

        function initPanels() {
            var page = document.querySelector('.page');
            if (page && page.dataset.panels) {
                try { panels = JSON.parse(page.dataset.panels); } catch(e) {}
            }
        }
        
        // Main Tap Logic
        document.addEventListener('click', function(e) {
            e.preventDefault(); // Stop standard browser handling
            
            var x = e.clientX;
            var width = window.innerWidth;
            
            // Right Side Tap (Next)
            if (x > width * 0.4) {
                if (isPanelMode && panels.length > 0) {
                    // Try to advance panel
                    if (panelIndex < panels.length - 1) {
                        panelIndex++;
                        zoomToPanel();
                        return; // Stay on this page
                    }
                }
                // No panels left, go to next page
                window.webkit.messageHandlers.navHandler.postMessage("next");
            } 
            // Left Side Tap (Prev)
            else {
                if (isPanelMode && panels.length > 0) {
                    // Try to reverse panel
                    if (panelIndex > 0) {
                        panelIndex--;
                        zoomToPanel();
                        return; // Stay on this page
                    } else if (panelIndex === 0) {
                        // Reset zoom before going back
                        panelIndex = -1;
                        document.body.style.transform = "scale(1) translate(0,0)";
                        return;
                    }
                }
                // No panels left (or at start), go to prev page
                window.webkit.messageHandlers.navHandler.postMessage("prev");
            }
        });
        
        function zoomToPanel() {
            var p = panels[panelIndex];
            var scale = Math.min(window.innerWidth/p.width, window.innerHeight/p.height) * 0.98;
            var tx = -p.x * 100;
            var ty = -p.y * 100;
            document.body.style.transform = `scale(${1/p.width}) translate(${tx}%, ${ty}%)`; 
        }
        
        window.onload = initPanels;
        """
        
        let script = WKUserScript(source: js, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        config.userContentController.addUserScript(script)
        config.userContentController.add(context.coordinator, name: "navHandler")
        
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        webView.scrollView.isScrollEnabled = false // Disable scrolling to prevent interference
        
        return webView
    }
    
    func updateUIView(_ webView: WKWebView, context: Context) {
        if webView.url != pageURL {
            webView.loadFileURL(pageURL, allowingReadAccessTo: pageURL.deletingLastPathComponent())
        }
    }
    
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    
    class Coordinator: NSObject, WKScriptMessageHandler {
        var parent: EPUBSmartReader
        init(_ parent: EPUBSmartReader) { self.parent = parent }
        
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if let body = message.body as? String {
                if body == "next" {
                    parent.onNextPage()
                } else if body == "prev" {
                    parent.onPrevPage()
                }
            }
        }
    }
}

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
