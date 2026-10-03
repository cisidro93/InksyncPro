import SwiftUI
import ZIPFoundation

struct UnifiedReaderView: View {
    let initialPDF: ConvertedPDF
    /// All books in the library — used for series-end continuation (next volume).
    var allBooks: [ConvertedPDF] = []
    @State private var currentBook: ConvertedPDF
    var pdf: ConvertedPDF { currentBook }

    private var effectiveAllBooks: [ConvertedPDF] {
        if !allBooks.isEmpty {
            return allBooks
        }
        let libraryItems = LibraryService.shared.items
        if !libraryItems.isEmpty {
            return libraryItems
        }
        return ConversionManager.shared.convertedPDFs
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    
    @State private var showNotebookPanel: Bool
    @ObservedObject private var prefs = EBookPreferences.shared
    @AppStorage("studyNotebookPlacement") private var notebookPlacement: SidebarPlacement = .right
    @State private var notebookWidth: CGFloat = 380
    @State private var dragInitialWidth: CGFloat? = nil
    @State private var isDraggingDivider: Bool = false

    init(pdf: ConvertedPDF, allBooks: [ConvertedPDF] = [], startWithNotebookOpen: Bool = false, initialReadingMode: String? = nil) {
        self.initialPDF = pdf
        self.allBooks = allBooks
        self._currentBook = State(initialValue: pdf)
        self._showNotebookPanel = State(initialValue: startWithNotebookOpen)
        
        let initialCheck: Bool?
        if pdf.url.pathExtension.lowercased() == "epub" {
            if pdf.contentType == .book {
                initialCheck = false
            } else if pdf.contentType == .hybrid || pdf.contentType == .comic || pdf.contentType == .manga || pdf.metadata.isManga == true {
                initialCheck = true
            } else {
                initialCheck = nil
            }
        } else {
            initialCheck = nil
        }
        self._epubComicCheckResult = State(initialValue: initialCheck)

        let initialOverride: ContentType?
        if let mode = initialReadingMode?.lowercased() {
            if mode == "comic" {
                initialOverride = .comic
            } else if mode == "book" || mode == "ebook" || mode == "pdf" {
                initialOverride = .book
            } else {
                initialOverride = nil
            }
        } else {
            initialOverride = nil
        }
        self._activeEngineOverride = State(initialValue: initialOverride)
    }
    
    /// In-reader engine switcher state (allows switching between ProPDF, Comic, and EBook engines on the fly)
    @State private var activeEngineOverride: ContentType? = nil
    @State private var showingHelpSheet: Bool = false

    /// Fast, non-blocking check to verify if the file is a PDF (extension, title, or book content type)
    private var isPDFDocument: Bool {
        let ext = pdf.url.pathExtension.lowercased()
        if ext == "pdf" || pdf.name.lowercased().hasSuffix(".pdf") || pdf.metadata.title.lowercased().hasSuffix(".pdf") {
            return true
        }
        
        // Fast-path exclusion for non-PDF archive types and virtual omnibuses
        if pdf.url.scheme?.lowercased() == "virtual-omnibus" {
            return false
        }
        if ext == "epub" || ext == "cbz" || ext == "cbr" || ext == "cb7" || ext == "zip" || ext == "rar" {
            return false
        }
        
        // If content type is explicitly .book and file is not an EPUB archive, it is a PDF book
        if pdf.contentType == .book && ext != "epub" && !pdf.name.lowercased().hasSuffix(".epub") {
            return true
        }
        
        // URL path extension check on sanitized path
        let resolvedPath = LibraryFileRecord.resolveSandboxURL(pdf.url.absoluteString).pathExtension.lowercased()
        if resolvedPath == "pdf" {
            return true
        }
        
        return false
    }

    /// Tri-state: nil = still checking, true = comic EPUB, false = text EPUB
    @State private var epubComicCheckResult: Bool?
    
    /// Determines whether we need an async background check for this EPUB
    private var needsEPUBComicCheck: Bool {
        let ext = pdf.url.pathExtension.lowercased()
        if pdf.contentType == .comic || pdf.contentType == .manga || pdf.metadata.isManga == true {
            return false
        }
        return ext == "epub" && pdf.metadata.hasFormatOverride != true && epubComicCheckResult == nil
    }
    
    enum ActiveReaderEngine: Equatable {
        case comic
        case proPDF
        case eBook
        case checkingEPUB
        
        var displayName: String {
            switch self {
            case .comic: return "ComicReaderEngine"
            case .proPDF: return "ProPDFReaderEngine"
            case .eBook: return "EBookReaderView"
            case .checkingEPUB: return "Pending (ProgressView)"
            }
        }
    }

    // MARK: - Reader Engine Diagnostics & Routing Resolution
    
    private var resolvedReaderEngine: (engine: ActiveReaderEngine, rationale: String) {
        if isPDFDocument {
            if activeEngineOverride == .comic {
                return (.comic, "Manual engine override active: comic mode requested for PDF.")
            } else {
                return (.proPDF, "Native vector PDF document detected (%PDF binary signature or .pdf extension). Full text reflow, highlighting, and Apple Pencil active.")
            }
        } else if pdf.url.pathExtension.lowercased() == "epub" || pdf.name.lowercased().hasSuffix(".epub") {
            if activeEngineOverride == .book {
                return (.eBook, "Manual engine override active: eBook mode requested for EPUB.")
            } else if activeEngineOverride == .comic || epubComicCheckResult == true || pdf.contentType == .hybrid || pdf.contentType == .comic || pdf.contentType == .manga || pdf.metadata.isManga == true {
                return (.comic, "Image-heavy / comic EPUB detected. ComicReaderEngine active.")
            } else {
                return (.eBook, "Standard reflowable or fixed-layout EPUB document. WebKit dual-page median layout active.")
            }
        } else if pdf.contentType == .book {
            if activeEngineOverride == .comic {
                return (.comic, "Manual engine override active: comic mode requested for book.")
            } else if isPDFDocument {
                return (.proPDF, "Identified as .book content type. Native PDF engine active.")
            } else {
                return (.comic, "Identified as .book content type on non-PDF archive. ComicReaderEngine active.")
            }
        } else {
            if activeEngineOverride == .book && isPDFDocument {
                return (.proPDF, "Manual engine override active: book mode requested for PDF.")
            } else {
                return (.comic, "Comic archive format (CBZ/CBR/CB7/ZIP/RAR). Continuous vertical/spread canvas active.")
            }
        }
    }
    
    private func logReaderRouting(trigger: String) {
        let (engine, rationale) = resolvedReaderEngine
        let ext = pdf.url.pathExtension.lowercased()
        let fileSizeStr = ByteCountFormatter.string(fromByteCount: pdf.fileSize, countStyle: .file)
        let docName = pdf.name
        let fileSize = pdf.fileSize
        let contentTypeRaw = pdf.contentType.rawValue
        let hasOverride = pdf.metadata.hasFormatOverride ?? false
        let isPDF = isPDFDocument
        let engineOverrideRaw = activeEngineOverride?.rawValue ?? "none"
        let engineDisplayName = engine.displayName
        let urlString = pdf.url.absoluteString
        let isMismatch = (isPDF && engine == .comic && activeEngineOverride == nil)

        Task.detached(priority: .utility) {
            var headerPreview = "unknown"
            let resolvedURL = LibraryFileRecord.resolveSandboxURL(urlString)
            let didAccess = resolvedURL.startAccessingSecurityScopedResource()
            defer { if didAccess { resolvedURL.stopAccessingSecurityScopedResource() } }
            if let handle = try? FileHandle(forReadingFrom: resolvedURL) {
                defer { try? handle.close() }
                if let data = try? handle.read(upToCount: 8), !data.isEmpty {
                    let hex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
                    let ascii = String(data: data, encoding: .ascii)?.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ") ?? ""
                    headerPreview = "Hex: [\(hex)] ASCII: '\(ascii)'"
                }
            }

            let report = """
            [ReaderRouting] [\(trigger)]
              • Document: '\(docName)'
              • Extension: .\(ext.isEmpty ? "none" : ext)
              • File Size: \(fileSizeStr) (\(fileSize) bytes)
              • Header Bytes: \(headerPreview)
              • Evaluated ContentType: .\(contentTypeRaw) (hasFormatOverride: \(hasOverride))
              • Binary IsPDF: \(isPDF)
              • Active Engine Override: \(engineOverrideRaw)
              • MOUNTED READER: \(engineDisplayName)
              • Decision Rationale: \(rationale)
            """

            Logger.shared.log(report, category: "ReaderRouting", type: isMismatch ? .warning : .info)
        }
    }

    private var isTablet: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    private var canShowSplitSidebar: Bool {
        isTablet && sizeClass == .regular
    }

    @ViewBuilder
    private func splitReaderView(geo: GeometryProxy) -> some View {
        HStack(spacing: 0) {
            if notebookPlacement == .left && showNotebookPanel && canShowSplitSidebar {
                StudyNotebookView(
                    bookID: pdf.id.uuidString,
                    bookTitle: pdf.name,
                    fileURL: pdf.url
                )
                .frame(width: notebookWidth)
                .clipped()
                .transition(.move(edge: .leading).combined(with: .opacity))
                .id("sidebar_notebook_\(pdf.id)")
                
                draggableDivider(geo: geo, placement: .left)
            }
            
            ZStack {
                prefs.activeTheme.background.edgesIgnoringSafeArea(.all)
                
                switch resolvedReaderEngine.engine {
                case .comic:
                    ComicReaderEngine(pdf: currentBook, onDismiss: { dismiss() }, allBooks: effectiveAllBooks)
                        .id(currentBook.id)
                case .proPDF:
                    ProPDFReaderEngine(pdf: currentBook, onDismiss: { dismiss() }, allBooks: effectiveAllBooks)
                        .id(currentBook.id)
                case .eBook:
                    EBookReaderView(fileURL: currentBook.url, title: currentBook.name, pdf: currentBook, onExit: { dismiss() }, allBooks: effectiveAllBooks)
                        .id(currentBook.id)
                case .checkingEPUB:
                    ProgressView("Loading…")
                        .tint(Color.inkTextPrimary)
                        .foregroundColor(Color.inkTextPrimary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            
            if notebookPlacement == .right && showNotebookPanel && canShowSplitSidebar {
                draggableDivider(geo: geo, placement: .right)
                
                StudyNotebookView(
                    bookID: pdf.id.uuidString,
                    bookTitle: pdf.name,
                    fileURL: pdf.url
                )
                .frame(width: notebookWidth)
                .clipped()
                .transition(.move(edge: .trailing).combined(with: .opacity))
                .id("sidebar_notebook_\(pdf.id)")
            }
        }
    }

    private func runEPUBComicCheckIfNeeded() async {
        guard needsEPUBComicCheck && epubComicCheckResult == nil else { return }
        let pdfCopy = self.pdf
        Logger.shared.log("UnifiedReaderView: Starting background EPUB check for '\(pdfCopy.name)'", category: "Reader", type: .info)
        let result = await Task.detached(priority: .userInitiated) {
            Self.checkIsEPUBComic(pdf: pdfCopy)
        }.value
        await MainActor.run {
            Logger.shared.log("UnifiedReaderView: Background EPUB check completed with result=\(result)", category: "Reader", type: .info)
            epubComicCheckResult = result
            logReaderRouting(trigger: "EPUB check completed")
        }
        let newType: ContentType = result ? .hybrid : .book
        if pdfCopy.contentType != newType {
            Logger.shared.log("UnifiedReaderView: Updating contentType from \(pdfCopy.contentType) to \(newType) for '\(pdfCopy.name)'", category: "Reader", type: .success)
            ConversionManager.shared.updateContentType(for: pdfCopy.id, to: newType)
        }
    }

    var body: some View {
        GeometryReader { geo in
            splitReaderView(geo: geo)
                .onChange(of: geo.size.width) { _, newWidth in
                    let maxW = max(280, min(newWidth * 0.70, newWidth - 280))
                    if notebookWidth > maxW {
                        notebookWidth = maxW
                    } else if notebookWidth < 280 {
                        notebookWidth = min(380, maxW)
                    }
                }
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: showNotebookPanel)
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: notebookPlacement)
        }
        .ignoresSafeArea()
        .navigationBarHidden(true)
        .statusBar(hidden: true)
        .forceProMotion()
        .task {
            await runEPUBComicCheckIfNeeded()
        }
        .sheet(isPresented: Binding(
            get: { showNotebookPanel && !canShowSplitSidebar },
            set: { if !$0 { showNotebookPanel = false } }
        )) {
            StudyNotebookView(
                bookID: pdf.id.uuidString,
                bookTitle: pdf.name,
                fileURL: pdf.url,
                showBackButton: true
            )
            .presentationDetents([.medium, .fraction(0.88)])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(28)
        }
        .modifier(UnifiedReaderKeyboardModifier(
            showNotebookPanel: $showNotebookPanel,
            showingHelpSheet: $showingHelpSheet,
            prefs: prefs,
            dismiss: dismiss
        ))
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("InksyncPro.switchReaderEngine"))) { notification in
            let targetEngine = notification.userInfo?["engine"] as? String ?? ""
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                if targetEngine == "proPDF" {
                    activeEngineOverride = .book
                    ConversionManager.shared.updateContentType(for: pdf.id, to: .book)
                } else if targetEngine == "comic" {
                    activeEngineOverride = .comic
                    ConversionManager.shared.updateContentType(for: pdf.id, to: .comic)
                }
            }
            logReaderRouting(trigger: "Live Engine Switch -> \(targetEngine)")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("SwitchToBookReader"))) { _ in
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                activeEngineOverride = .book
                epubComicCheckResult = false
                ConversionManager.shared.updateContentType(for: pdf.id, to: .book)
            }
            logReaderRouting(trigger: "Fallback to Book Reader")
        }
        .onReceive(NotificationCenter.default.publisher(for: .openMergedBook)) { notif in
            if let nextBook = notif.object as? ConvertedPDF, nextBook.id != currentBook.id {
                Logger.shared.log("UnifiedReaderView: auto-transitioning in-place to '\(nextBook.name)'", category: "Reader", type: .info)
                let isComicOrManga = nextBook.contentType == .comic || nextBook.contentType == .manga || nextBook.metadata.isManga == true
                withAnimation(.easeInOut(duration: 0.22)) {
                    currentBook = nextBook
                    activeEngineOverride = nil
                    epubComicCheckResult = (nextBook.url.pathExtension.lowercased() == "epub") ? (isComicOrManga ? true : (nextBook.contentType == .book ? false : nil)) : nil
                }
                AppRouter.shared.updateCurrentReaderBook(nextBook)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name.NSProcessInfoPowerStateDidChange)) { _ in
            ReaderIdleTimerManager.shared.reassertKeepAwake()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            ReaderIdleTimerManager.shared.reassertKeepAwake()
        }
        .onAppear {
            ReaderIdleTimerManager.shared.enterReader()

            if isPDFDocument && pdf.contentType == .comic && pdf.metadata.hasFormatOverride != true {
                ConversionManager.shared.updateContentType(for: pdf.id, to: .book)
            }
            let ext = pdf.url.pathExtension.lowercased()
            if ext == "epub" && (pdf.contentType == .comic || pdf.contentType == .hybrid) && pdf.metadata.hasFormatOverride != true {
                ConversionManager.shared.updateContentType(for: pdf.id, to: .book)
            }
            logReaderRouting(trigger: "onAppear")

            setupVolumeButtonHandlers()
        }
        .onDisappear {
            ReaderIdleTimerManager.shared.leaveReader()
            VolumeButtonPageTurnManager.shared.stopListening()
            PDFSpeechNarrationEngine.shared.stop()
            EPUBNarrationEngine.shared.stop()
            ComicDialogueSpeechEngine.shared.stop()
        }
        .onChange(of: prefs.volumeButtonsTurnPages) { _, _ in
            setupVolumeButtonHandlers()
        }
        .onChange(of: prefs.invertVolumeButtons) { _, _ in
            setupVolumeButtonHandlers()
        }
        .environmentObject(ConversionManager.shared)
        .environmentObject(AppSettingsManager.shared)
    }
    
    // MARK: - Split-Screen Divider
    @ViewBuilder
    private func draggableDivider(geo: GeometryProxy, placement: SidebarPlacement) -> some View {
        ZStack {
            // Expanded invisible touch padding (44pt) so user's finger or Pencil never slips off the bar
            Color.clear
                .frame(width: 44)
                .contentShape(Rectangle())
            
            Rectangle()
                .fill(Color.white.opacity(isDraggingDivider ? 0.28 : 0.12))
                .frame(width: 1)
            
            Capsule()
                .fill(isDraggingDivider ? Color.orange : Color.orange.opacity(0.85))
                .frame(width: isDraggingDivider ? 5 : 4, height: isDraggingDivider ? 48 : 40)
                .shadow(color: .orange.opacity(isDraggingDivider ? 0.6 : 0.3), radius: isDraggingDivider ? 5 : 3)
        }
        .frame(width: 44)
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let totalWidth = geo.size.width
                    let startWidth = dragInitialWidth ?? notebookWidth
                    if dragInitialWidth == nil {
                        dragInitialWidth = notebookWidth
                        isDraggingDivider = true
                    }
                    
                    let delta = (placement == .right) ? -value.translation.width : value.translation.width
                    var proposed = startWidth + delta
                    let effectiveMinW: CGFloat = min(280, totalWidth * 0.40)
                    let effectiveMaxW: CGFloat = max(effectiveMinW, min(totalWidth * 0.70, totalWidth - 280))
                    proposed = max(effectiveMinW, min(proposed, effectiveMaxW))
                    
                    // Magnetic snap points at ~30%, ~50%, and ~65%
                    let snapPoints: [CGFloat] = [
                        totalWidth * 0.30,
                        totalWidth * 0.50,
                        totalWidth * 0.65
                    ]
                    for snap in snapPoints {
                        if abs(proposed - snap) < 14 {
                            if abs(notebookWidth - snap) >= 14 {
                                HapticEngine.selection()
                            }
                            proposed = snap
                            break
                        }
                    }
                    
                    notebookWidth = proposed
                }
                .onEnded { value in
                    let dismissDelta = (placement == .right) ? value.translation.width : -value.translation.width
                    let dismissVelocity = (placement == .right) ? value.predictedEndTranslation.width : -value.predictedEndTranslation.width
                    if (dismissDelta > 80 || dismissVelocity > 140) && notebookWidth <= 320 {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            showNotebookPanel = false
                        }
                        HapticEngine.medium()
                    }
                    dragInitialWidth = nil
                    isDraggingDivider = false
                }
        )
    }
    
    // MARK: - Static EPUB Comic Detection (runs off main thread)
    
    /// Strips HTML tags and script/style contents, returning only readable plain text character count.
    nonisolated private static func extractPlainTextLength(from html: String) -> Int {
        var count = 0
        var inTag = false
        var skipContent = false
        
        for c in html {
            if c == "<" {
                inTag = true
            } else if c == ">" {
                inTag = false
                skipContent = false
            } else if !inTag && !skipContent {
                if !c.isWhitespace {
                    count += 1
                }
            }
        }
        return count
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
        let access = try? BookmarkResolver.shared.resolveAccess(for: pdf)
        let resolvedURL: URL = access?.fileURL ?? pdf.url
        defer { access?.stopAccess() }
        Logger.shared.log("isEPUBComic: Using resolved URL: \(resolvedURL.path)", category: "Reader", type: .info)
        
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
                        if lowerOPF.contains("comic-book") || lowerOPF.contains("comicbook") || lowerOPF.contains("content=\"comic\"") || lowerOPF.contains("content=\"manga\"") || (lowerOPF.contains("fixed-layout") && (lowerOPF.contains("comic") || lowerOPF.contains("manga"))) || lowerOPF.contains("page-progression-direction=\"rtl\"") {
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
                        
                        // If average readable text count per page is present, it is a reflowable chapter-based text book.
                        if avgTextCharacters > 120 {
                            isComic = false
                            Logger.shared.log("isEPUBComic: ❌ High average text character count (\(avgTextCharacters)) -> Book", category: "Reader", type: .success)
                        } else if avgTextCharacters < 40 && imageRatio >= 0.85 {
                            // Minimal text count and high frequency of full-page image wrappers -> Comic
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

    private func setupVolumeButtonHandlers() {
        if prefs.volumeButtonsTurnPages {
            let invert = prefs.invertVolumeButtons
            VolumeButtonPageTurnManager.shared.onVolumeUp = {
                NotificationCenter.default.post(
                    name: NSNotification.Name(invert ? "ReaderAdvancePageBackward" : "ReaderAdvancePageForward"),
                    object: nil
                )
            }
            VolumeButtonPageTurnManager.shared.onVolumeDown = {
                NotificationCenter.default.post(
                    name: NSNotification.Name(invert ? "ReaderAdvancePageForward" : "ReaderAdvancePageBackward"),
                    object: nil
                )
            }
            VolumeButtonPageTurnManager.shared.startListening()
        } else {
            VolumeButtonPageTurnManager.shared.stopListening()
        }
    }
}

// MARK: - Dedicated Keyboard Shortcuts & Reader Notifications Modifier
private struct UnifiedReaderKeyboardModifier: ViewModifier {
    @Binding var showNotebookPanel: Bool
    @Binding var showingHelpSheet: Bool
    @ObservedObject var prefs: EBookPreferences
    let dismiss: DismissAction

    func body(content: Content) -> some View {
        content
            .readerKeyboardShortcuts(
                isEditingText: UIResponder.isTextInputActive,
                onNextPage: {
                    NotificationCenter.default.post(name: NSNotification.Name("ReaderAdvancePageForward"), object: nil)
                },
                onPreviousPage: {
                    NotificationCenter.default.post(name: NSNotification.Name("ReaderAdvancePageBackward"), object: nil)
                },
                onToggleReflow: {
                    NotificationCenter.default.post(name: NSNotification.Name("ReaderToggleReflowMode"), object: nil)
                },
                onToggleSpeech: {
                    NotificationCenter.default.post(name: NSNotification.Name("ReaderToggleSpeechMode"), object: nil)
                },
                onToggleHighlighter: {
                    NotificationCenter.default.post(name: NSNotification.Name("ReaderToggleHighlighterMode"), object: nil)
                },
                onToggleMarkup: {
                    NotificationCenter.default.post(name: NSNotification.Name("ReaderToggleMarkupMode"), object: nil)
                },
                onToggleNotebook: {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        showNotebookPanel.toggle()
                    }
                },
                onToggleSidebar: {
                    NotificationCenter.default.post(name: NSNotification.Name("ReaderToggleSidebar"), object: nil)
                },
                onZoomIn: {
                    NotificationCenter.default.post(name: NSNotification.Name("ReaderZoomIn"), object: nil)
                },
                onZoomOut: {
                    NotificationCenter.default.post(name: NSNotification.Name("ReaderZoomOut"), object: nil)
                },
                onResetZoom: {
                    NotificationCenter.default.post(name: NSNotification.Name("ReaderResetZoom"), object: nil)
                },
                onShowHelp: {
                    showingHelpSheet = true
                },
                onDismiss: {
                    dismiss()
                }
            )
            .sheet(isPresented: $showingHelpSheet) {
                KeyboardShortcutsCheatSheetView()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ReaderShowShortcutsHelp"))) { _ in
                showingHelpSheet = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleStudyNotebook)) { _ in
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    showNotebookPanel.toggle()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .openStudyNotebook)) { _ in
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    showNotebookPanel = true
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .hideStudyNotebook)) { _ in
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    showNotebookPanel = false
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("InksyncPro.showShortcutsSheet"))) { _ in
                showingHelpSheet = true
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("InksyncPro.toggleDualPage"))) { _ in
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    prefs.pdfDualPage.toggle()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("InksyncPro.toggleSmartCrop"))) { _ in
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    prefs.isSmartCropEnabled.toggle()
                }
            }
    }
}

