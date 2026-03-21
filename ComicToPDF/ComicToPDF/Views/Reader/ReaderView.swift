
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
                        // ✅ ZERO-LATENCY METAL PPL READER
                        if fileURL.pathExtension.lowercased() != "pdf" {
                            if !pages.isEmpty {
                                PPLReaderView(pages: pages, currentPageIndex: $currentPageIndex)
                                    .ignoresSafeArea()
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
            .focusable()
            .onKeyPress(.leftArrow) {
                prevPage()
                return .handled
            }
            .onKeyPress(.rightArrow) {
                nextPage()
                return .handled
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }.fontWeight(.bold)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 16) {
                        if pdf != nil {
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
