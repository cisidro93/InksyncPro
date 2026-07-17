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
    @State private var notebookWidth: CGFloat = 380

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
        let isEligibleType = pdf.contentType == .book || pdf.contentType == .hybrid
        return isEligibleType && ext == "epub" && pdf.metadata.hasFormatOverride != true
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
                    .frame(width: notebookWidth)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                    .id("sidebar_notebook_\(pdf.id)")
                    
                    // Custom Draggable Divider
                    ZStack {
                        Color.clear
                            .frame(width: 16)
                            .contentShape(Rectangle())
                        
                        Rectangle()
                            .fill(Color.white.opacity(0.12))
                            .frame(width: 1)
                        
                        Capsule()
                            .fill(Color.orange)
                            .frame(width: 4, height: 40)
                            .shadow(color: .orange.opacity(0.4), radius: 3)
                    }
                    .frame(width: 16)
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                let totalWidth = geo.size.width
                                let newWidth = value.location.x
                                notebookWidth = max(260, min(newWidth, totalWidth * 0.65))
                            }
                    )
                }
                
                ZStack {
                    Color(hex: "#0a0a0f").edgesIgnoringSafeArea(.all)
                    
                    switch pdf.contentType {
                    case .comic, .manga:
                        ComicReaderEngine(pdf: pdf, onDismiss: { dismiss() }, allBooks: allBooks)
                    case .book, .hybrid:
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
                            if pdf.contentType == .hybrid {
                                ComicReaderEngine(pdf: pdf, onDismiss: { dismiss() }, allBooks: allBooks)
                            } else {
                                BookReaderEngine(pdf: pdf, onDismiss: { dismiss() }, allBooks: allBooks)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                
                if notebookPlacement == .right && showNotebookPanel && sizeClass == .regular {
                    // Custom Draggable Divider
                    ZStack {
                        Color.clear
                            .frame(width: 16)
                            .contentShape(Rectangle())
                        
                        Rectangle()
                            .fill(Color.white.opacity(0.12))
                            .frame(width: 1)
                        
                        Capsule()
                            .fill(Color.orange)
                            .frame(width: 4, height: 40)
                            .shadow(color: .orange.opacity(0.4), radius: 3)
                    }
                    .frame(width: 16)
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                let totalWidth = geo.size.width
                                let newWidth = totalWidth - value.location.x
                                notebookWidth = max(260, min(newWidth, totalWidth * 0.65))
                            }
                    )
                    
                    StudyNotebookView(
                        bookID: pdf.id.uuidString,
                        bookTitle: pdf.name,
                        fileURL: pdf.url
                    )
                    .frame(width: notebookWidth)
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
                // Sync the scanned type to the database if it differs
                let newType: ContentType = result ? .hybrid : .book
                if pdfCopy.contentType != newType {
                    Logger.shared.log("UnifiedReaderView: Updating contentType from \(pdfCopy.contentType) to \(newType) for '\(pdfCopy.name)'", category: "Reader", type: .success)
                    ConversionManager.shared?.updateContentType(for: pdfCopy.id, to: newType)
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
    
    /// Strips HTML tags and script/style contents, returning only readable plain text characters.
    nonisolated private static func extractPlainTextLength(from html: String) -> Int {
        var result = ""
        var inTag = false
        var skipContent = false
        
        let chars = Array(html)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "<" {
                inTag = true
                if i + 6 < chars.count {
                    let sub = String(chars[i..<(i+7)]).lowercased()
                    if sub.hasPrefix("<style") || sub.hasPrefix("<script") {
                        skipContent = true
                    }
                }
            } else if c == ">" {
                inTag = false
                skipContent = false
            } else if !inTag && !skipContent {
                if !c.isWhitespace {
                    result.append(c)
                }
            }
            i += 1
        }
        return result.count
    }
    
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
            
            // Strategy 1: OPF metadata check (standard EPUB 3 fixed-layout properties)
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
            
            // Strategy 2: Content Analysis (Plain-Text-to-Image Ratio & DOM Heuristics)
            if !isComic {
                let htmlEntries = archive.filter { entry in
                    let ext = (entry.path.lowercased() as NSString).pathExtension
                    return ["xhtml", "html", "htm"].contains(ext)
                }
                
                if !htmlEntries.isEmpty {
                    // Sample up to 8 XHTML pages representing different parts of the book
                    let sampleSize = min(8, htmlEntries.count)
                    var sampledEntries: [Entry] = []
                    let strideStep = max(1, htmlEntries.count / sampleSize)
                    for idx in 0..<sampleSize {
                        let targetIdx = min(idx * strideStep, htmlEntries.count - 1)
                        if !sampledEntries.contains(where: { $0.path == htmlEntries[targetIdx].path }) {
                            sampledEntries.append(htmlEntries[targetIdx])
                        }
                    }
                    
                    var totalTextCharacters = 0
                    var pagesWithImages = 0
                    var sampledCount = 0
                    
                    for entry in sampledEntries {
                        var htmlData = Data()
                        do {
                            _ = try archive.extract(entry) { data in
                                htmlData.append(data)
                            }
                            sampledCount += 1
                            if let htmlString = String(data: htmlData, encoding: .utf8) {
                                let plainTextLength = Self.extractPlainTextLength(from: htmlString)
                                totalTextCharacters += plainTextLength
                                
                                let lower = htmlString.lowercased()
                                if lower.contains("<img") || lower.contains("<image") || lower.contains("<svg") {
                                    pagesWithImages += 1
                                }
                            }
                        } catch {
                            // ignore errors
                        }
                    }
                    
                    if sampledCount > 0 {
                        let avgTextCharacters = Double(totalTextCharacters) / Double(sampledCount)
                        let imageRatio = Double(pagesWithImages) / Double(sampledCount)
                        
                        Logger.shared.log("isEPUBComic: sampled \(sampledCount) pages. Avg text char count: \(avgTextCharacters), Image ratio: \(imageRatio)", category: "Reader", type: .info)
                        
                        // If average readable text count per page is high, it is a reflowable chapter-based text book.
                        if avgTextCharacters > 300 {
                            isComic = false
                            Logger.shared.log("isEPUBComic: ❌ High average text character count (\(avgTextCharacters)) -> Book", category: "Reader", type: .success)
                        } else if avgTextCharacters < 150 && imageRatio >= 0.75 {
                            // Low text count and high frequency of full-page image wrappers -> Comic
                            isComic = true
                            Logger.shared.log("isEPUBComic: ✅ Low text (\(avgTextCharacters)) and high image ratio (\(imageRatio)) -> Comic", category: "Reader", type: .success)
                        }
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
