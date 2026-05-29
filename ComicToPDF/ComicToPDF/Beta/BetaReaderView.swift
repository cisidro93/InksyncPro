import SwiftUI
import PDFKit
import WebKit
import SwiftData
import ZIPFoundation

struct BetaReaderView: View {
    let book: BetaBook
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject var libraryStore: BetaLibraryStore
    
    // UI HUD State
    @State private var showHUD = true
    @State private var brightness: CGFloat = UIScreen.main.brightness
    @State private var currentPageIndex = 0
    
    // Comic Loading State
    @State private var isLoading = true
    @State private var loadingError: String? = nil
    @State private var comicImageURLs: [URL] = []
    @State private var tempExtractDir: URL? = nil
    
    // Highlight Popover
    @State private var showingAddHighlight = false
    @State private var highlightText = ""
    @State private var highlightNote = ""
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            // Content Renderer
            Group {
                switch book.contentType {
                case .comic, .manga:
                    if isLoading {
                        loadingView
                    } else if let error = loadingError {
                        errorView(error)
                    } else {
                        comicPager
                    }
                case .pdf:
                    pdfReader
                case .epub:
                    epubReader
                }
            }
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.25)) {
                    showHUD.toggle()
                }
            }
            
            // HUD Overlay
            if showHUD {
                hudOverlay
            }
            
            // Add Highlight Dialog
            if showingAddHighlight {
                highlightDialog
            }
        }
        .statusBarHidden(!showHUD)
        .onAppear {
            currentPageIndex = max(0, min(book.currentPage, book.pageCount - 1))
            if book.contentType == .comic || book.contentType == .manga {
                loadComicImages()
            }
        }
        .onDisappear {
            saveProgress()
            cleanupTempFiles()
        }
    }
    
    // MARK: - Comic Loader
    
    private func loadComicImages() {
        Task {
            do {
                let result = try await BetaArchiveService.shared.extractComic(from: book.resolvedURL)
                await MainActor.run {
                    self.tempExtractDir = result.workingDir
                    self.comicImageURLs = result.imageURLs
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.loadingError = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }
    
    private func saveProgress() {
        book.currentPage = currentPageIndex
        book.lastReadDate = Date()
        try? modelContext.save()
        libraryStore.fetchBooks() // Refresh UI list
    }
    
    private func cleanupTempFiles() {
        if let dir = tempExtractDir {
            try? FileManager.default.removeItem(at: dir)
        }
    }
    
    // MARK: - Loading & Error States
    
    private var loadingView: some View {
        VStack(spacing: 15) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .orange))
                .scaleEffect(1.3)
            Text("Extracting pages...")
                .font(.subheadline)
                .foregroundStyle(.gray)
        }
    }
    
    private func errorView(_ msg: String) -> some View {
        VStack(spacing: 15) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title)
                .foregroundStyle(.red)
            Text("Failed to load document")
                .font(.headline)
                .foregroundStyle(.white)
            Text(msg)
                .font(.subheadline)
                .foregroundStyle(.gray)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            
            Button("Go Back") {
                dismiss()
            }
            .padding(.top, 10)
        }
    }
    
    // MARK: - Comic Page Pager
    
    private var comicPager: some View {
        TabView(selection: $currentPageIndex) {
            ForEach(0..<comicImageURLs.count, id: \.self) { index in
                ZoomableComicPage(imageURL: comicImageURLs[index])
                    .tag(index)
                    .ignoresSafeArea()
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .environment(\.layoutDirection, book.contentType == .manga ? .rightToLeft : .leftToRight)
    }
    
    // MARK: - PDF kit Reader
    
    private var pdfReader: some View {
        BetaPDFView(url: book.resolvedURL, currentPageIndex: $currentPageIndex)
            .ignoresSafeArea()
    }
    
    // MARK: - WebKit EPUB Reader
    
    private var epubReader: some View {
        BetaEPUBView(url: book.resolvedURL)
            .ignoresSafeArea()
    }
    
    // MARK: - HUD Overlays
    
    private var hudOverlay: some View {
        VStack {
            // Top Bar
            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.title3.bold())
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(Circle().fill(Color.black.opacity(0.6)))
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(book.title)
                        .font(.headline.bold())
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    
                    if let series = book.seriesName {
                        Text("\(series) - Vol. \(book.volumeNumber ?? "1")")
                            .font(.caption)
                            .foregroundStyle(.gray)
                    }
                }
                .padding(.leading, 8)
                
                Spacer()
                
                // Add Highlight Button
                Button {
                    highlightText = "Page \(currentPageIndex + 1)"
                    highlightNote = ""
                    showingAddHighlight = true
                } label: {
                    Image(systemName: "highlighter")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(Circle().fill(Color.black.opacity(0.6)))
                }
            }
            .padding(.horizontal)
            .padding(.top, 50)
            
            Spacer()
            
            // Bottom Scrubber Panel
            VStack(spacing: 12) {
                // Page Indicator
                Text("Page \(currentPageIndex + 1) of \(book.pageCount)")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.orange.opacity(0.8)))
                
                // Progress Slider
                HStack(spacing: 15) {
                    let pageRange = 0...max(0, book.pageCount - 1)
                    let pageBinding = Binding<Double>(
                        get: { Double(currentPageIndex) },
                        set: { currentPageIndex = Int($0) }
                    )
                    
                    Slider(value: pageBinding, in: Double(pageRange.lowerBound)...Double(pageRange.upperBound), step: 1)
                        .accentColor(.orange)
                }
                .padding(.horizontal)
                
                // Extra options (Brightness)
                HStack {
                    Image(systemName: "sun.min.fill")
                        .foregroundStyle(.gray)
                    
                    Slider(value: $brightness, in: 0.1...1.0)
                        .accentColor(.white)
                        .onChange(of: brightness) { _, newVal in
                            UIScreen.main.brightness = newVal
                        }
                    
                    Image(systemName: "sun.max.fill")
                        .foregroundStyle(.gray)
                }
                .padding(.horizontal)
                .padding(.bottom, 30)
            }
            .background(
                Rectangle()
                    .fill(Color.black.opacity(0.5))
                    .background(.ultraThinMaterial)
            )
        }
        .ignoresSafeArea(edges: .bottom)
        .transition(.opacity)
    }
    
    // MARK: - Highlight Notes Popover Dialog
    
    private var highlightDialog: some View {
        ZStack {
            Color.black.opacity(0.6)
                .ignoresSafeArea()
            
            VStack(spacing: 20) {
                Text("Add Library Clipping")
                    .font(.headline)
                    .foregroundStyle(.white)
                
                TextField("Highlighted Text / Quote", text: $highlightText)
                    .padding()
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(8)
                    .foregroundStyle(.white)
                
                TextField("Add personal note (optional)", text: $highlightNote)
                    .padding()
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(8)
                    .foregroundStyle(.white)
                
                HStack(spacing: 15) {
                    Button("Cancel") {
                        showingAddHighlight = false
                    }
                    .foregroundStyle(.gray)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 20)
                    .background(Capsule().stroke(Color.gray, lineWidth: 1))
                    
                    Button("Save Note") {
                        saveHighlight()
                        showingAddHighlight = false
                    }
                    .foregroundStyle(.black)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 20)
                    .background(Capsule().fill(Color.orange))
                }
            }
            .padding(25)
            .background(Color(hex: "#1A1A24"))
            .cornerRadius(16)
            .frame(width: 320)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
            )
        }
    }
    
    private func saveHighlight() {
        let text = highlightText.isEmpty ? "Page \(currentPageIndex + 1)" : highlightText
        let note = highlightNote
        
        let newHighlight = BetaHighlight(
            pageIndex: currentPageIndex,
            text: text,
            note: note
        )
        newHighlight.book = book
        modelContext.insert(newHighlight)
        try? modelContext.save()
    }
}

// MARK: - ZoomableComicPage (UIScrollView Representable for pinch-to-zoom)

struct ZoomableComicPage: UIViewRepresentable {
    let imageURL: URL
    
    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.minimumZoomScale = 1.0
        scrollView.maximumZoomScale = 4.0
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.delegate = context.coordinator
        
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(imageView)
        
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            imageView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
        ])
        
        context.coordinator.imageView = imageView
        return scrollView
    }
    
    func updateUIView(_ uiView: UIScrollView, context: Context) {
        if let imageView = context.coordinator.imageView {
            imageView.image = UIImage(contentsOfFile: imageURL.path)
        }
        uiView.zoomScale = 1.0 // Reset zoom on page changes
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    class Coordinator: NSObject, UIScrollViewDelegate {
        var imageView: UIImageView?
        
        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            return imageView
        }
    }
}

// MARK: - BetaPDFView (PDFKit Representable)

struct BetaPDFView: UIViewRepresentable {
    let url: URL
    @Binding var currentPageIndex: Int
    
    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.document = PDFDocument(url: url)
        pdfView.autoScales = true
        pdfView.displayMode = .singlePage
        pdfView.displayDirection = .horizontal
        pdfView.usePageViewController(true)
        
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.handlePageChanged),
            name: .PDFViewPageChanged,
            object: pdfView
        )
        
        return pdfView
    }
    
    func updateUIView(_ uiView: PDFView, context: Context) {
        // Only jump if programmatic selection deviates from UI page
        if let document = uiView.document,
           let targetPage = document.page(at: currentPageIndex),
           uiView.currentPage != targetPage {
            uiView.go(to: targetPage)
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject {
        var parent: BetaPDFView
        
        init(_ parent: BetaPDFView) {
            self.parent = parent
        }
        
        @objc @MainActor func handlePageChanged(notification: Notification) {
            guard let pdfView = notification.object as? PDFView,
                  let document = pdfView.document,
                  let currentPage = pdfView.currentPage else { return }
            
            let index = document.index(for: currentPage)
            self.parent.currentPageIndex = index
        }
    }
}

// MARK: - BetaEPUBView (WKWebView Representable for reflowable content)

struct BetaEPUBView: UIViewRepresentable {
    let url: URL
    
    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.isOpaque = false
        webView.backgroundColor = .black
        
        // EPUB is a zipped archive. We must unzip and extract it to a local temp folder
        // then load its index HTML or contents.
        // For simplicity and bulletproof performance in the beta reader, we extract the archive
        // and point the webview to the first text resource or nav page.
        loadEPUBIntoWebView(webView)
        
        return webView
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    
    private func loadEPUBIntoWebView(_ webView: WKWebView) {
        Task {
            do {
                let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                
                // Open and unzip EPUB archive
                guard let archive = try? Archive(url: url, accessMode: .read) else { return }
                
                for entry in archive {
                    let destURL = tempDir.appendingPathComponent(entry.path)
                    try? FileManager.default.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    _ = try? archive.extract(entry, to: destURL)
                }
                
                // Find container.xml to locate root OPF
                let containerURL = tempDir.appendingPathComponent("META-INF/container.xml")
                guard let containerData = try? Data(contentsOf: containerURL),
                      let opfPath = parseOPFPath(from: containerData) else { return }
                
                let opfURL = tempDir.appendingPathComponent(opfPath)
                guard let opfData = try? Data(contentsOf: opfURL) else { return }
                
                // Parse first spine item ref href
                let parser = EPUBSpineParser()
                let xmlParser = XMLParser(data: opfData)
                xmlParser.delegate = parser
                xmlParser.parse()
                
                guard let firstHref = parser.spineHrefs.first else { return }
                let opfDir = opfURL.deletingLastPathComponent()
                let contentURL = opfDir.appendingPathComponent(firstHref).standardizedFileURL
                
                await MainActor.run {
                    webView.loadFileURL(contentURL, allowingReadAccessTo: tempDir)
                }
                
            } catch {
                print("BetaEPUBView: Failed to load EPUB: \(error)")
            }
        }
    }
    
    private func parseOPFPath(from data: Data) -> String? {
        let delegate = ReaderOPFPathDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.opfPath
    }
}

private class ReaderOPFPathDelegate: NSObject, XMLParserDelegate {
    var opfPath: String?
    
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String] = [:]) {
        if elementName.lowercased() == "rootfile", let path = attributes["full-path"] {
            opfPath = path
        }
    }
}

// XML parser to extract the spine items list
private class EPUBSpineParser: NSObject, XMLParserDelegate {
    var manifestItems: [String: String] = [:] // id: href
    var spineHrefs: [String] = []
    private var inSpine = false
    
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String] = [:]) {
        let name = elementName.components(separatedBy: ":").last ?? elementName
        let lower = name.lowercased()
        
        if lower == "item", let id = attributes["id"], let href = attributes["href"] {
            manifestItems[id] = href
        } else if lower == "spine" {
            inSpine = true
        } else if inSpine && lower == "itemref", let idref = attributes["idref"] {
            if let href = manifestItems[idref] {
                spineHrefs.append(href)
            }
        }
    }
    
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = elementName.components(separatedBy: ":").last ?? elementName
        if name.lowercased() == "spine" {
            inSpine = false
        }
    }
}
