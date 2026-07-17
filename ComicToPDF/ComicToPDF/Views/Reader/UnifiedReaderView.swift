import SwiftUI
import ZIPFoundation

struct UnifiedReaderView: View {
    let pdf: ConvertedPDF
    /// All books in the library — used for series-end continuation (next volume).
    var allBooks: [ConvertedPDF] = []
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    
    @State private var showNotebookPanel: Bool
    @AppStorage("studyNotebookPlacement") private var notebookPlacement: SidebarPlacement = .right

    init(pdf: ConvertedPDF, allBooks: [ConvertedPDF] = [], startWithNotebookOpen: Bool = false) {
        self.pdf = pdf
        self.allBooks = allBooks
        self._showNotebookPanel = State(initialValue: startWithNotebookOpen)
    }
    
    /// Tri-state: nil = still checking, true = comic EPUB, false = text EPUB
    @State private var epubComicCheckResult: Bool? = nil
    

    
    /// Computed once at init — determines whether we need an async check
    private var needsEPUBComicCheck: Bool {
        let ext = pdf.url.pathExtension.lowercased()
        return pdf.contentType == .book && ext == "epub"
    }
    
    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                if notebookPlacement == .left && showNotebookPanel && sizeClass == .regular {
                    StudyNotebookView(
                        bookID: pdf.id.uuidString,
                        bookTitle: pdf.name,
                        fileURL: pdf.url
                    )
                    .frame(width: min(geo.size.width * 0.38, 420))
                    .transition(.move(edge: .leading).combined(with: .opacity))
                    .id("sidebar_notebook_\(pdf.id)")
                    
                    Divider()
                        .background(Color.white.opacity(0.12))
                }
                
                ZStack {
                    Color(hex: "#0a0a0f").edgesIgnoringSafeArea(.all)
                    
                    switch pdf.contentType {
                    case .comic, .manga:
                        ComicReaderEngine(pdf: pdf, onDismiss: { dismiss() }, allBooks: allBooks)
                    case .book:
                        if pdf.url.pathExtension.lowercased() == "pdf" {
                            DocumentReaderEngine(pdf: pdf, onDismiss: { dismiss() })
                        } else if needsEPUBComicCheck {
                            // Async-resolved EPUB comic check
                            if let isComic = epubComicCheckResult {
                                if isComic {
                                    ComicReaderEngine(pdf: pdf, onDismiss: { dismiss() }, allBooks: allBooks)
                                } else {
                                    BookReaderEngine(pdf: pdf, onDismiss: { dismiss() }, allBooks: allBooks)
                                }
                            } else {
                                // Still checking — show loading indicator
                                ProgressView("Loading…")
                                    .foregroundColor(.white)
                            }
                        } else {
                            BookReaderEngine(pdf: pdf, onDismiss: { dismiss() }, allBooks: allBooks)
                        }
                    case .hybrid:
                        if pdf.url.pathExtension.lowercased() == "epub" {
                            ComicReaderEngine(pdf: pdf, onDismiss: { dismiss() }, allBooks: allBooks)
                        } else {
                            DocumentReaderEngine(pdf: pdf, onDismiss: { dismiss() })
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                
                if notebookPlacement == .right && showNotebookPanel && sizeClass == .regular {
                    Divider()
                        .background(Color.white.opacity(0.12))
                    
                    StudyNotebookView(
                        bookID: pdf.id.uuidString,
                        bookTitle: pdf.name,
                        fileURL: pdf.url
                    )
                    .frame(width: min(geo.size.width * 0.38, 420))
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .id("sidebar_notebook_\(pdf.id)")
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: showNotebookPanel)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: notebookPlacement)
        }
        .navigationBarHidden(true)
        .statusBar(hidden: true)
        .forceProMotion()
        .task {
            // Run the EPUB comic check off the main thread when the view appears
            if needsEPUBComicCheck && epubComicCheckResult == nil {
                let pdfCopy = self.pdf
                Logger.shared.log("UnifiedReaderView: Starting background EPUB check for '\(pdfCopy.name)'", category: "Reader", type: .info)
                let result = await Task.detached(priority: .userInitiated) {
                    Self.checkIsEPUBComic(pdf: pdfCopy)
                }.value
                await MainActor.run {
                    Logger.shared.log("UnifiedReaderView: Background EPUB check completed with result=\(result)", category: "Reader", type: .info)
                    epubComicCheckResult = result
                }
                // If we detected it's a comic, update the database so future opens skip this check
                if result {
                    Logger.shared.log("UnifiedReaderView: Upgrading contentType from .book to .hybrid for '\(pdfCopy.name)'", category: "Reader", type: .success)
                    ConversionManager.shared?.updateContentType(for: pdfCopy.id, to: .hybrid)
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { showNotebookPanel && sizeClass == .compact },
            set: { if !$0 { showNotebookPanel = false } }
        )) {
            StudyNotebookView(
                bookID: pdf.id.uuidString,
                bookTitle: pdf.name,
                fileURL: pdf.url,
                showBackButton: true
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleStudyNotebook)) { _ in
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                showNotebookPanel.toggle()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .hideStudyNotebook)) { _ in
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                showNotebookPanel = false
            }
        }
        .onAppear {
            Logger.shared.log("UnifiedReaderView presented for '\(pdf.name)'. contentType=\(pdf.contentType)", category: "Reader", type: .info)
        }
    }
    
    // MARK: - Static EPUB Comic Detection (runs off main thread)
    
    /// Determines whether a .book-classified EPUB is actually a fixed-layout comic.
    /// This is a static method so it can be called from a detached Task without capturing self.
    nonisolated private static func checkIsEPUBComic(pdf: ConvertedPDF) -> Bool {
        let ext = pdf.url.pathExtension.lowercased()
        guard ext == "epub" else {
            Logger.shared.log("isEPUBComic: Not an epub (ext=\(ext)), skipping", category: "Reader", type: .info)
            return false
        }
        
        // pdf.url is already sandbox-resolved by toDomainModel(), use it directly.
        let resolvedURL: URL
        var accessedURL: URL? = nil
        
        if case .linked(let bm) = pdf.sourceMode,
           let url = try? BookmarkResolver.shared.resolve(bm) {
            let didAccess = url.startAccessingSecurityScopedResource()
            resolvedURL = url
            if didAccess { accessedURL = url }
            Logger.shared.log("isEPUBComic: Using linked bookmark URL: \(url.path)", category: "Reader", type: .info)
        } else {
            resolvedURL = pdf.url
            let didAccess = resolvedURL.startAccessingSecurityScopedResource()
            if didAccess { accessedURL = resolvedURL }
            Logger.shared.log("isEPUBComic: Using local URL: \(resolvedURL.path)", category: "Reader", type: .info)
        }
        
        defer { accessedURL?.stopAccessingSecurityScopedResource() }
        
        // Verify the file actually exists
        let fileExists = FileManager.default.fileExists(atPath: resolvedURL.path)
        Logger.shared.log("isEPUBComic: File exists at path: \(fileExists) — \(resolvedURL.path)", category: "Reader", type: fileExists ? .info : .warning)
        guard fileExists else { return false }
        
        do {
            guard let archive = try? Archive(url: resolvedURL, accessMode: .read, pathEncoding: .utf8) else {
                Logger.shared.log("isEPUBComic: Failed to init Archive for \(resolvedURL.path)", category: "Reader", type: .warning)
                return false
            }
            
            var isComic = false
            
            // Strategy 1: OPF metadata check
            if let containerEntry = archive["META-INF/container.xml"] {
                var containerData = Data()
                _ = try archive.extract(containerEntry) { data in containerData.append(data) }
                
                if let containerStr = String(data: containerData, encoding: .utf8),
                   let opfPath = MetadataHeuristics.extractOPFPath(from: containerStr),
                   let opfEntry = archive[opfPath] {
                    
                    var opfData = Data()
                    _ = try archive.extract(opfEntry) { data in opfData.append(data) }
                    
                    if let opfStr = String(data: opfData, encoding: .utf8) {
                        let lowerOPF = opfStr.lowercased()
                        if lowerOPF.contains("pre-paginated") || 
                           lowerOPF.contains("comic-book") || 
                           lowerOPF.contains("fixed-layout") || 
                           lowerOPF.contains("image-based") ||
                           lowerOPF.contains("manga") {
                            isComic = true
                            Logger.shared.log("isEPUBComic: ✅ OPF metadata matched — routing to ComicReader", category: "Reader", type: .success)
                        }
                    }
                } else {
                    Logger.shared.log("isEPUBComic: Could not extract OPF path from container.xml", category: "Reader", type: .warning)
                }
            } else {
                Logger.shared.log("isEPUBComic: No META-INF/container.xml found in archive", category: "Reader", type: .warning)
            }
            
            // Strategy 2: Image-to-HTML ratio fallback
            if !isComic {
                let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "gif", "heic"]
                var imageCount = 0
                var htmlCount = 0
                for entry in archive {
                    let entryPathLower = entry.path.lowercased()
                    let name = (entryPathLower as NSString).lastPathComponent
                    guard !entryPathLower.contains("__macosx"), !name.hasPrefix("._"), name != ".ds_store", !entryPathLower.hasSuffix("/") else { continue }
                    let ext = (name as NSString).pathExtension
                    if imageExtensions.contains(ext) {
                        imageCount += 1
                    } else if ["xhtml", "html", "htm"].contains(ext) {
                        htmlCount += 1
                    }
                }
                Logger.shared.log("isEPUBComic: Image count=\(imageCount), HTML count=\(htmlCount)", category: "Reader", type: .info)
                if imageCount > 5 && imageCount >= htmlCount - 5 {
                    isComic = true
                    Logger.shared.log("isEPUBComic: ✅ Image ratio matched — routing to ComicReader", category: "Reader", type: .success)
                }
                
                // Strategy 3: Sample XHTML pages to see if they are thin image wrappers
                if !isComic && htmlCount > 5 {
                    let htmlEntries = archive.filter { entry in
                        let ext = (entry.path.lowercased() as NSString).pathExtension
                        return ["xhtml", "html", "htm"].contains(ext)
                    }
                    let sampled = htmlEntries.prefix(min(5, htmlEntries.count))
                    var imageWrapperCount = 0
                    for entry in sampled {
                        var htmlData = Data()
                        _ = try archive.extract(entry) { data in htmlData.append(data) }
                        if let html = String(data: htmlData, encoding: .utf8) {
                            let lower = html.lowercased()
                            // If the page has an <img> tag and very little text content, it's an image wrapper
                            if lower.contains("<img") && lower.count < 2000 {
                                imageWrapperCount += 1
                            }
                        }
                    }
                    Logger.shared.log("isEPUBComic: XHTML sample: \(imageWrapperCount)/\(sampled.count) are image wrappers", category: "Reader", type: .info)
                    if imageWrapperCount >= sampled.count - 1 && sampled.count >= 3 {
                        isComic = true
                        Logger.shared.log("isEPUBComic: ✅ XHTML sampling matched — routing to ComicReader", category: "Reader", type: .success)
                    }
                }
            }
            
            if !isComic {
                Logger.shared.log("isEPUBComic: ❌ No comic indicators found — routing to BookReader", category: "Reader", type: .info)
            }
            return isComic
        } catch {
            Logger.shared.log("isEPUBComic: Error checking ZIP structure: \(error.localizedDescription)", category: "Reader", type: .warning)
            return false
        }
    }
}
