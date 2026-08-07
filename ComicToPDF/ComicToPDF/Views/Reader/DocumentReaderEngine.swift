import SwiftUI
@preconcurrency import PDFKit
import PencilKit

struct DocumentReaderEngine: View {
    let pdf: ConvertedPDF
    var onDismiss: () -> Void
    
    @State private var chromeVisible = false
    @State private var currentPageIndex: Int = 0
    @State private var isPencilMode = false
    @State private var pdfDocument: PDFDocument?
    @State private var accessedURL: URL? = nil

    private var totalPages: Int {
        pdfDocument?.pageCount ?? pdf.pageCount
    }
    
    // KOReader Parity
    @State private var isReflowMode = false
    @State private var reflowText: String = "Extracting text..."
    @State private var showingSettings = false
    @State private var showSearch = false
    @State private var showJumpToPage = false
    @State private var jumpToPageText = ""
    @State private var pdfViewReference: PDFView? = nil
    @State private var resolvedURL: URL? = nil
    @State private var sessionStartTime: Date? = nil
    @ObservedObject private var prefs = EBookPreferences.shared
    @FocusState private var isReaderFocused: Bool
    @State private var lastBrightnessDragValue: CGFloat = 0
    @ObservedObject private var sleepTimer = SleepTimerManager.shared
    @StateObject private var velocityEngine = ReaderVelocityEngine()
    @State private var pagesReadThisSession: Int = 0
    @State private var showReadingStatsHUD = false
    
    @ViewBuilder private var documentContentView: some View {
        if isReflowMode {
            ReflowTextView(
                text: reflowText,
                onCenterTap: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        chromeVisible.toggle()
                    }
                },
                onPrevPage: {
                    if currentPageIndex > 0 {
                        currentPageIndex -= 1
                        HapticEngine.light()
                    }
                },
                onNextPage: {
                    if currentPageIndex < totalPages - 1 {
                        currentPageIndex += 1
                        HapticEngine.light()
                    }
                }
            )
        } else if let doc = pdfDocument {
            ZStack {
                PDFKitRepresentedView(document: doc,
                                      pdf: pdf,
                                      currentPageIndex: $currentPageIndex,
                                      chromeVisible: $chromeVisible,
                                      isPencilMode: $isPencilMode,
                                      pdfViewRef: $pdfViewReference,
                                      isAutoCropEnabled: isAutoCropEnabled)
                .colorInvertIfDark(theme: prefs.activeTheme)
                
                if prefs.pdfDualPage && currentPageIndex > 0 {
                    BookSpineCreaseOverlay()
                }
                
                if !isPencilMode && !isReflowMode {
                    KindleTapZoneOverlay(
                        onPrevPage: {
                            pageBackward()
                        },
                        onNextPage: {
                            pageForward()
                        },
                        onCenterTap: {
                            withAnimation(.spring(response: 0.38, dampingFraction: 0.85)) {
                                chromeVisible.toggle()
                            }
                        }
                    )
                    .allowsHitTesting((pdfViewReference?.scaleFactor ?? 1.0) <= ((pdfViewReference?.scaleFactorForSizeToFit ?? 1.0) * 1.05))
                }
                
                if !chromeVisible && !isPencilMode {
                    KindleProgressFooterView(
                        currentPage: currentPageIndex + 1,
                        totalPages: totalPages,
                        estimatedMinutesLeft: ReaderProgressTracker.shared.progress(for: pdf.id)?.estimatedMinutesRemaining
                    )
                }
            }
        } else {
            ProgressView("Loading Document...")
        }
    }
    
    var body: some View {
        ZStack {
            AmbientReaderBackground(theme: EBookTheme(rawValue: prefs.themeRaw) ?? .paper)
                .ignoresSafeArea()
            
            documentContentView
                .ignoresSafeArea()
            
            EdgeBrightnessGestureZone()
            
            ReaderChrome(
                title: pdf.name,
                pageText: "\(currentPageIndex + 1) / \(totalPages)",
                isVisible: $chromeVisible,
                onBack: {
                    savePosition(pageIndex: currentPageIndex)
                    onDismiss()
                },
                onBookmark: {
                    let bookmark = Annotation(pdfID: pdf.id, pageIndex: currentPageIndex, kind: .bookmark, createdAt: Date(), modifiedAt: Date())
                    AnnotationStore.shared.add(bookmark)
                },
                onSettingsToggle: { showingSettings = true },
                onTOCToggle: { NotificationCenter.default.post(name: .toggleStudyNotebook, object: nil) },
                onAnnotationsToggle: { isPencilMode.toggle() },
                onSearchToggle: { showSearch = true },
                currentProgress: Binding(
                    get: { Double(currentPageIndex) / Double(max(1, totalPages - 1)) },
                    set: {
                        currentPageIndex = Int($0 * Double(max(1, totalPages - 1)))
                    }
                ),
                totalPages: totalPages,
                getPageThumbnail: { index in
                    await PDFRenderActor.shared.renderPage(at: index, scale: 0.15)
                },
                onJumpToPage: {
                    jumpToPageText = ""
                    showJumpToPage = true
                },
                isPDF: true,
                isReflowActive: isReflowMode,
                isAutoCropEnabled: activeCropInsets.isEnabled,
                onCropToggle: { toggleSmartCrop() },
                onReflowToggle: {
                    isReflowMode.toggle()
                    if isReflowMode { updateReflowText() }
                },
                isSettingsActive: showingSettings,
                sessionStartTime: sessionStartTime
            )
            
            if isPencilMode && !isReflowMode {
                // Overlay PencilKit ToolPicker Indicator
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Text("Pencil Mode Active")
                            .font(.caption)
                            .padding(8)
                            .background(Color.blue.opacity(0.8))
                            .foregroundColor(.white)
                            .cornerRadius(8)
                            .padding()
                    }
                    .padding(.bottom, 60)
                }
                .transition(.opacity)
            }
        }
        .overlay { if prefs.showReadingRuler { ReadingRulerOverlay() } }
        .sheet(isPresented: $showReadingStatsHUD) {
            ReadingStatsHUDView(
                pdfID: pdf.id,
                bookTitle: pdf.name,
                totalPages: totalPages,
                currentPageIndex: currentPageIndex
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .onChange(of: sleepTimer.didFire) { _, fired in
            if fired { updateProgressAndDismiss() }
        }
        .onDisappear {
            savePosition(pageIndex: currentPageIndex)
            accessedURL?.stopAccessingSecurityScopedResource()
            Task {
                await PDFRenderActor.shared.clear()
            }
        }
        .onAppear {
            if sessionStartTime == nil {
                sessionStartTime = Date()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            Logger.shared.log("DocumentReaderEngine: Memory warning received. Purging PDF cache.", category: "Memory", type: .warning)
            Task {
                await PDFRenderActor.shared.clear()
            }
        }
        .sheet(isPresented: $showingSettings) {
            EBookSettingsPanel(bookID: pdf.id.uuidString, isPDF: true)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showSearch) {
            if let doc = pdfDocument, let pdfV = pdfViewReference {
                ReaderSearchView(document: doc, pdfView: pdfV)
                    .presentationDetents([.medium, .large])
            }
        }
        .task {
            // Linked Library: Resolve security-scoped URL before opening.
            // PDFDocument reads data lazily on draw, so we hold onto the access scope until disappear.
            let resolvedURL: URL
            var accessed: URL? = nil
            if case .linked(let bm) = pdf.sourceMode,
               let url = try? BookmarkResolver.shared.resolve(bm) {
                let didAccess = url.startAccessingSecurityScopedResource()
                resolvedURL = url
                if didAccess { accessed = url }
            } else {
                resolvedURL = pdf.url
            }

            let doc = PDFDocument(url: resolvedURL)
            self.accessedURL = accessed
            self.resolvedURL = resolvedURL
            pdfDocument = doc
            _ = await PDFRenderActor.shared.loadDocument(at: resolvedURL, externalAccessing: accessed != nil)
            if let saved = ReaderProgressTracker.shared.progress(for: pdf.id) {
                currentPageIndex = saved.currentPageIndex
            }
            let savedCrop = ReaderProgressTracker.shared.cropInsets(for: pdf.id)
            let initialCrop = savedCrop ?? (prefs.defaultCropModeRaw == "smartAuto" ? .smartAuto : CodableCropInsets(top: prefs.defaultCropTop, bottom: prefs.defaultCropBottom, left: prefs.defaultCropLeft, right: prefs.defaultCropRight, modeRaw: prefs.defaultCropModeRaw))
            applyCropInsets(initialCrop)
            if isReflowMode { updateReflowText() }
            isReaderFocused = true
        }
        .sheet(isPresented: $showCropAdjustmentSheet) {
            ProCropAdjustmentSheet(
                pdfID: pdf.id,
                pdfDocument: pdfDocument,
                currentPageIndex: currentPageIndex,
                onApplyCrop: { insets in
                    applyCropInsets(insets)
                },
                onDismiss: { showCropAdjustmentSheet = false }
            )
        }
        .onChange(of: currentPageIndex) { _, new in
            if isReflowMode { updateReflowText() }
            let duration = Date().timeIntervalSince(sessionStartTime ?? Date())
            velocityEngine.recordPageDuration(duration, remainingPages: max(0, totalPages - new - 1))
            pagesReadThisSession += 1
            savePosition(pageIndex: new)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            savePosition(pageIndex: currentPageIndex)
        }
        .focusable()
        .focused($isReaderFocused)
        .focusEffectDisabled()
        .alert("Go to Page", isPresented: $showJumpToPage) {
            TextField("Page number (1-\(totalPages))", text: $jumpToPageText)
                .keyboardType(.numberPad)
            Button("Cancel", role: .cancel) { }
            Button("Go") {
                if let pageNum = Int(jumpToPageText), pageNum >= 1 && pageNum <= totalPages {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        currentPageIndex = pageNum - 1
                    }
                }
            }
        } message: {
            Text("Enter a page number between 1 and \(totalPages).")
        }
        .onKeyPress(.leftArrow) {
            pageBackward()
            return .handled
        }
        .onKeyPress(.rightArrow) {
            pageForward()
            return .handled
        }
        .onKeyPress(.space) {
            pageForward()
            return .handled
        }
        .onKeyPress(.escape) {
            updateProgressAndDismiss()
            return .handled
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("Reader_JumpToPage"))) { notification in
            if let pageIndex = notification.userInfo?["pageIndex"] as? Int, pageIndex >= 0, pageIndex < totalPages {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    currentPageIndex = pageIndex
                }
            }
        }
        .preferredColorScheme(prefs.activeTheme.isDark ? .dark : .light)
    }

    private func updateProgressAndDismiss() {
        let maxP = max(1, totalPages)
        let curr = currentPageIndex + 1
        let frac = Double(curr) / Double(maxP)
        let prog = ReadingProgress(
            pdfID: pdf.id, lastOpenedAt: Date(), currentPageIndex: currentPageIndex,
            currentChapterIndex: nil, currentChapterOffset: nil,
            totalPagesRead: 1, completionFraction: frac,
            readingSessionDates: [Date()], estimatedMinutesRemaining: nil
        )
        ReaderProgressTracker.shared.update(prog)
        onDismiss()
    }
    
    private func pageForward() {
        if let pv = pdfViewReference, pv.canGoToNextPage {
            pv.goToNextPage(nil)
            HapticEngine.light()
        } else if currentPageIndex < totalPages - 1 {
            currentPageIndex += 1
            HapticEngine.light()
        }
    }
    
    private func pageBackward() {
        if let pv = pdfViewReference, pv.canGoToPreviousPage {
            pv.goToPreviousPage(nil)
            HapticEngine.light()
        } else if currentPageIndex > 0 {
            currentPageIndex -= 1
            HapticEngine.light()
        }
    }
    
    // MARK: KOReader Parity Dynamics
    
    private func updateReflowText() {
        guard let doc = pdfDocument, let page = doc.page(at: currentPageIndex) else { return }
        let raw = page.string ?? ""
        guard !raw.isEmpty else {
            self.reflowText = "No extractable text on this page."
            return
        }
        let paragraphs = raw
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        self.reflowText = paragraphs
    }
    
    @State private var isAutoCropEnabled = false
    @State private var showCropAdjustmentSheet = false
    @State private var activeCropInsets: CodableCropInsets = .zero

    private func applyCropInsets(_ insets: CodableCropInsets) {
        guard let doc = pdfDocument else { return }
        self.activeCropInsets = insets
        
        if insets.modeRaw == "none" {
            isAutoCropEnabled = false
            for i in 0..<doc.pageCount {
                if let page = doc.page(at: i) {
                    page.setBounds(page.bounds(for: .mediaBox), for: .cropBox)
                }
            }
            if let pv = pdfViewReference {
                pv.displayBox = .mediaBox
                pv.layoutDocumentView()
            }
        } else if insets.modeRaw == "smartAuto" {
            performSmartCrop()
        } else {
            // Custom Pro Crop Insets
            isAutoCropEnabled = true
            for i in 0..<doc.pageCount {
                if let page = doc.page(at: i) {
                    let mediaBox = page.bounds(for: .mediaBox)
                    let croppedRect = CGRect(
                        x: mediaBox.minX + (mediaBox.width * insets.left),
                        y: mediaBox.minY + (mediaBox.height * insets.bottom),
                        width: max(10, mediaBox.width * (1.0 - insets.left - insets.right)),
                        height: max(10, mediaBox.height * (1.0 - insets.top - insets.bottom))
                    )
                    page.setBounds(croppedRect, for: .cropBox)
                }
            }
            if let pv = pdfViewReference {
                pv.displayBox = .cropBox
                pv.layoutDocumentView()
            }
        }
    }

    private func toggleSmartCrop() {
        if activeCropInsets.isEnabled {
            applyCropInsets(.none)
        } else {
            performSmartCrop()
        }
    }

    private func performSmartCrop() {
        guard let doc = pdfDocument else { return }
        let url = resolvedURL ?? pdf.url
        
        isAutoCropEnabled = true
        let insets = CodableCropInsets(top: 0.10, bottom: 0.12, left: 0.10, right: 0.10, modeRaw: "smartAuto")
        self.activeCropInsets = insets
        ReaderProgressTracker.shared.saveCropInsets(insets, for: pdf.id)
        HapticEngine.medium()
        
        Task {
            let cropBoxes = await Task.detached(priority: .utility) { () -> [Int: CGRect] in
                guard let backgroundDoc = PDFDocument(url: url) else { return [:] }
                var results = [Int: CGRect]()
                for i in 0..<backgroundDoc.pageCount {
                    guard let page = backgroundDoc.page(at: i) else { continue }
                    let mediaBox = page.bounds(for: .mediaBox)
                    var unionBounds = CGRect.null
                    let charCount = page.numberOfCharacters
                    if charCount > 0 {
                        for charIndex in 0..<charCount {
                            let charBounds = page.characterBounds(at: charIndex)
                            if charBounds.width > 0 && charBounds.height > 0 {
                                unionBounds = unionBounds.union(charBounds)
                            }
                        }
                    }
                    if !unionBounds.isNull {
                        let croppedRect = unionBounds.insetBy(dx: -16, dy: -16)
                        let finalCrop = croppedRect.intersection(mediaBox)
                        if finalCrop.width > 50 && finalCrop.height > 50 {
                            results[i] = finalCrop
                        } else {
                            results[i] = mediaBox.insetBy(dx: mediaBox.width * 0.10, dy: mediaBox.height * 0.12)
                        }
                    } else {
                        results[i] = mediaBox.insetBy(dx: mediaBox.width * 0.10, dy: mediaBox.height * 0.12)
                    }
                }
                return results
            }.value

            await MainActor.run {
                for (i, cropBox) in cropBoxes {
                    if let page = doc.page(at: i) {
                        page.setBounds(cropBox, for: .cropBox)
                    }
                }
                if let pv = self.pdfViewReference {
                    pv.displayBox = .cropBox
                    pv.layoutDocumentView()
                    
                    if let currentPage = pv.currentPage {
                        let isLandscape = pv.bounds.width > pv.bounds.height
                        let isDual = self.prefs.pdfDualPage || (self.prefs.autoLandscapeDualPage && isLandscape)
                        let cropBounds = currentPage.bounds(for: .cropBox)
                        let pageWidthMultiplier: CGFloat = isDual ? 2.0 : 1.0
                        let totalPageWidth = cropBounds.width * pageWidthMultiplier
                        let scaleForWidth = pv.bounds.width / max(totalPageWidth, 1.0)
                        if scaleForWidth > 0 {
                            pv.scaleFactor = scaleForWidth * 1.02
                        }
                    }
                }
            }
        }
    }


    // Shared helper — save position to ReaderProgressTracker.
    private func savePosition(pageIndex: Int) {
        ReaderProgressTracker.shared.update(ReadingProgress(
            pdfID: pdf.id,
            lastOpenedAt: Date(),
            currentPageIndex: pageIndex,
            currentChapterIndex: nil,
            currentChapterOffset: nil,
            totalPagesRead: 1,
            completionFraction: Double(pageIndex + 1) / Double(max(1, totalPages)),
            readingSessionDates: [Date()],
            estimatedMinutesRemaining: nil
        ))
    }
}

// Custom PDFView to intercept native iOS Text Selection Menus
class HighlightablePDFView: PDFView {
    var onHighlightCreated: ((String, CGRect) -> Void)?
    
    private var lastScaledPage: PDFPage? = nil
    private var lastScaleWidth: CGFloat = 0
    
    override func layoutSubviews() {
        super.layoutSubviews()
        if EBookPreferences.shared.pdfFitToWidth {
            let currentWidth = self.bounds.width
            let currentPage = self.currentPage
            if currentWidth > 0 && (currentWidth != lastScaleWidth || currentPage != lastScaledPage) {
                lastScaleWidth = currentWidth
                lastScaledPage = currentPage
                if let page = currentPage {
                    let pageBounds = page.bounds(for: self.displayBox)
                    if pageBounds.width > 0 {
                        let scale = currentWidth / pageBounds.width
                        if self.scaleFactor != scale && scale > 0 {
                            self.scaleFactor = scale
                            Logger.shared.log("HighlightablePDFView: Auto-scaled page \(page.label ?? "") to fit width (\(scale))", category: "Reader", type: .info)
                        }
                    }
                }
            }
        }
    }
    
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(customHighlightAction(_:)) || action == #selector(customLookupAction(_:)) { return true }
        let allowed = ["copy:", "share:", "_lookup:", "_define:"]
        if allowed.contains(NSStringFromSelector(action)) { return true }
        return super.canPerformAction(action, withSender: sender)
    }
    
    @objc func customHighlightAction(_ sender: Any?) {
        guard let selection = self.currentSelection else { return }
        let text = selection.string ?? ""
        let pages = selection.pages
        
        for page in pages {
            let lineSelections = selection.selectionsByLine()
            let targetLines = lineSelections.isEmpty ? [selection] : lineSelections
            for lineSel in targetLines {
                let lineBounds = lineSel.bounds(for: page)
                guard lineBounds != .zero && lineBounds.width > 2 && lineBounds.height > 2 else { continue }
                let annotation = PDFAnnotation(bounds: lineBounds, forType: .highlight, withProperties: nil)
                annotation.color = UIColor.systemYellow.withAlphaComponent(0.45)
                page.addAnnotation(annotation)
            }
        }
        
        let bounds = selection.bounds(for: selection.pages.first ?? PDFPage())
        self.clearSelection()
        onHighlightCreated?(text, bounds)
    }
    
    @objc func customLookupAction(_ sender: Any?) {
        guard let selection = self.currentSelection, let text = selection.string, !text.isEmpty else { return }
        let docTitle = self.document?.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String ?? "PDF Document"
        DictionaryLookupService.shared.lookupAndSave(
            term: text,
            contextSentence: text,
            bookTitle: docTitle
        )
    }
    
    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        let highlightCommand = UICommand(title: "Highlight", action: #selector(customHighlightAction(_:)))
        let lookupCommand = UICommand(title: "Look Up 📖", action: #selector(customLookupAction(_:)))
        let highlightMenu = UIMenu(title: "Inksync", options: .displayInline, children: [highlightCommand, lookupCommand])
        builder.insertSibling(highlightMenu, afterMenu: .standardEdit)
    }
}

// SwiftUI PDFView wrapper
struct PDFKitRepresentedView: UIViewRepresentable {
    let document: PDFDocument
    let pdf: ConvertedPDF
    @Binding var currentPageIndex: Int
    @Binding var chromeVisible: Bool
    @Binding var isPencilMode: Bool
    @Binding var pdfViewRef: PDFView?
    var isAutoCropEnabled: Bool = false
    
    @ObservedObject private var prefs = EBookPreferences.shared
    
    private func makePdfViewTransparent(_ pdfView: PDFView) {
        pdfView.isOpaque = false
        pdfView.backgroundColor = .clear
        pdfView.insetsLayoutMarginsFromSafeArea = false
        
        let stripView: (UIView) -> Void = { view in
            view.backgroundColor = .clear
            view.insetsLayoutMarginsFromSafeArea = false
            if let sv = view as? UIScrollView {
                sv.backgroundColor = .clear
                sv.contentInset = .zero
                sv.verticalScrollIndicatorInsets = .zero
                sv.horizontalScrollIndicatorInsets = .zero
                sv.contentInsetAdjustmentBehavior = .never
            }
        }
        
        pdfView.subviews.forEach { subview in
            stripView(subview)
            subview.subviews.forEach { inner in
                stripView(inner)
            }
        }
    }
    
    private func configureDisplayMode(_ pdfView: PDFView, context: Context) {
        let currentMode = prefs.paginationMode
        context.coordinator.lastConfiguredPaginationMode = currentMode
        context.coordinator.lastFitToWidth = prefs.pdfFitToWidth
        let isPaged = currentMode == EBookPaginationMode.paged.rawValue
        let dualPageMode = prefs.pdfDualPage || (prefs.autoLandscapeDualPage && (pdfView.bounds.width > pdfView.bounds.height))
        
        let expectedDisplayMode: PDFDisplayMode
        if isPaged {
            expectedDisplayMode = dualPageMode ? .twoUp : .singlePage
        } else {
            expectedDisplayMode = dualPageMode ? .twoUpContinuous : .singlePageContinuous
        }
        pdfView.displayMode = expectedDisplayMode
        pdfView.displaysAsBook = !dualPageMode
        
        pdfView.displaysRTL = prefs.pdfRTL || pdf.metadata.isManga == true || pdf.contentType == .manga
        if isPaged {
            pdfView.displayDirection = .horizontal
            pdfView.displaysAsBook = true
            pdfView.usePageViewController(false)
        } else {
            pdfView.usePageViewController(false)
            pdfView.displayDirection = .vertical
        }
        pdfView.layoutDocumentView()
    }

    func makeUIView(context: Context) -> UIView {
        let pdfView = HighlightablePDFView()
        context.coordinator.pdfView = pdfView
        DispatchQueue.main.async {
            self.pdfViewRef = pdfView
        }
        pdfView.document = document
        pdfView.autoScales = true
        pdfView.minScaleFactor = 0.25
        pdfView.maxScaleFactor = 10.0
        pdfView.displaysPageBreaks = false
        pdfView.pageBreakMargins = .zero
        pdfView.insetsLayoutMarginsFromSafeArea = false
        
        configureDisplayMode(pdfView, context: context)
        pdfView.delegate = context.coordinator
        
        makePdfViewTransparent(pdfView)
        
        pdfView.onHighlightCreated = { text, bounds in
            guard let page = pdfView.currentPage else { return }
            let index = document.index(for: page)
            
            // Normalize coordinates (0-1) for storage
            let pageBounds = page.bounds(for: .mediaBox)
            let normalizedBounds = CodableCGRect(
                x: Double(bounds.minX / pageBounds.width),
                y: Double(bounds.minY / pageBounds.height),
                width: Double(bounds.width / pageBounds.width),
                height: Double(bounds.height / pageBounds.height)
            )
            
            let annotation = Annotation(
                pdfID: pdf.id,
                pageIndex: index,
                kind: .highlight,
                createdAt: Date(),
                modifiedAt: Date(),
                colorHex: "#FFD700",
                selectedText: text,
                bounds: normalizedBounds
            )
            AnnotationStore.shared.add(annotation)

            // Gap C fix: Write the annotation back to the PDF document on disk.
            // PDFAnnotation is added to the in-memory PDFPage above in customHighlightAction,
            // but without this write, the highlight is lost when the app is relaunched.
            let writeURL = pdf.url
            Task { @MainActor in
                document.write(to: writeURL)
            }
        }
        
        let canvasView = PKCanvasView()
        canvasView.isOpaque = false
        canvasView.backgroundColor = .clear
        canvasView.drawingPolicy = .pencilOnly
        canvasView.delegate = context.coordinator
        
        // Disable canvas initially
        canvasView.isUserInteractionEnabled = false
        
        context.coordinator.pdfView = pdfView
        context.coordinator.canvasView = canvasView
        
        let container = UIView()
        container.insetsLayoutMarginsFromSafeArea = false
        container.clipsToBounds = false
        pdfView.frame = container.bounds
        pdfView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(pdfView)
        
        // Configure scroll view after pdfView is in hierarchy
        if let scrollView = pdfView.subviews.first(where: { $0 is UIScrollView }) as? UIScrollView {
            scrollView.contentInset = .zero
            scrollView.contentInsetAdjustmentBehavior = .never
        }
        
        canvasView.frame = container.bounds
        canvasView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(canvasView)
        
        let swipeLeft = UISwipeGestureRecognizer(target: context.coordinator, action: #selector(context.coordinator.handleSwipe(_:)))
        swipeLeft.direction = .left
        pdfView.addGestureRecognizer(swipeLeft)
        
        let swipeRight = UISwipeGestureRecognizer(target: context.coordinator, action: #selector(context.coordinator.handleSwipe(_:)))
        swipeRight.direction = .right
        pdfView.addGestureRecognizer(swipeRight)
        
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(context.coordinator.pageChanged(_:)),
            name: .PDFViewPageChanged,
            object: pdfView
        )
        
        return container
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.canvasView?.isUserInteractionEnabled = isPencilMode
        context.coordinator.parent = self
        
        if let canvasView = context.coordinator.canvasView {
            if isPencilMode {
                context.coordinator.toolPicker.setVisible(true, forFirstResponder: canvasView)
                context.coordinator.toolPicker.addObserver(canvasView)
                canvasView.becomeFirstResponder()
            } else {
                context.coordinator.toolPicker.setVisible(false, forFirstResponder: canvasView)
                context.coordinator.toolPicker.removeObserver(canvasView)
                canvasView.resignFirstResponder()
            }
        }
        
        if let pdfView = context.coordinator.pdfView {
            let currentMode = prefs.paginationMode
            let isPaged = currentMode == EBookPaginationMode.paged.rawValue
            let isLandscape = pdfView.bounds.width > pdfView.bounds.height
            let dualPageMode = prefs.pdfDualPage || (prefs.autoLandscapeDualPage && isLandscape)
            let fitToWidth = prefs.pdfFitToWidth
            
            let expectedDisplayMode: PDFDisplayMode
            if isPaged {
                expectedDisplayMode = dualPageMode ? .twoUp : .singlePage
            } else {
                expectedDisplayMode = dualPageMode ? .twoUpContinuous : .singlePageContinuous
            }
            
            let currentBoundsSize = pdfView.bounds.size
            let boundsChanged = currentBoundsSize != context.coordinator.lastBoundsSize && currentBoundsSize.width > 0 && currentBoundsSize.height > 0
            
            if pdfView.displayMode != expectedDisplayMode ||
                context.coordinator.lastConfiguredPaginationMode != currentMode ||
                context.coordinator.lastFitToWidth != fitToWidth {
                
                pdfView.displayMode = expectedDisplayMode
                pdfView.displaysAsBook = !dualPageMode
                context.coordinator.lastConfiguredPaginationMode = currentMode
                context.coordinator.lastFitToWidth = fitToWidth
                
                if isPaged {
                    pdfView.displayDirection = .horizontal
                    // NOTE: usePageViewController(true, ...) is intentionally NOT called here.
                    // Calling it from updateUIView while a system gesture (magnification loupe,
                    // text selection) is in-flight tears down and rebuilds PDFKit's internal
                    // UIPageViewController mid-gesture, triggering a spine-location VC-count
                    // assertion → SIGABRT. Configured exactly once in makeUIView via configureDisplayMode.
                } else {
                    pdfView.usePageViewController(false)
                    pdfView.displayDirection = .vertical
                }
                pdfView.displaysRTL = prefs.pdfRTL || pdf.metadata.isManga == true || pdf.contentType == .manga
                pdfView.layoutDocumentView()
            }
            
            let targetDisplayBox: PDFDisplayBox = isAutoCropEnabled ? .cropBox : .mediaBox
            if pdfView.displayBox != targetDisplayBox {
                pdfView.displayBox = targetDisplayBox
                pdfView.layoutDocumentView()
            }
            
            // Recalculate scaleFactor to expand pages to fill 100% of the screen width & height edge-to-edge
            // in both single-page and dual-page spread modes, using .cropBox when crop is active.
            let pageOrBoundsChanged = (context.coordinator.lastPageIndex != currentPageIndex) ||
                                      (context.coordinator.lastBoundsSize != currentBoundsSize)

            if pageOrBoundsChanged, let currentPage = pdfView.currentPage, currentBoundsSize.width > 0 && currentBoundsSize.height > 0 {
                let pageBounds = currentPage.bounds(for: pdfView.displayBox)
                let pageWidthMultiplier: CGFloat = dualPageMode ? 2.0 : 1.0
                let totalPageWidth = pageBounds.width * pageWidthMultiplier
                let totalPageHeight = pageBounds.height

                // Use min (fit) so the entire page is always visible edge-to-edge.
                // max (fill) zooms past content boundaries causing clipped text.
                let scaleForWidth = currentBoundsSize.width / max(totalPageWidth, 1.0)
                let scaleForHeight = currentBoundsSize.height / max(totalPageHeight, 1.0)
                let targetScale = min(scaleForWidth, scaleForHeight)

                if targetScale > 0 {
                    if pdfView.autoScales {
                        pdfView.autoScales = false
                    }
                    if abs(pdfView.scaleFactor - targetScale) > 0.005 {
                        pdfView.scaleFactor = targetScale
                        pdfView.layoutDocumentView()
                    }
                }
            }
            context.coordinator.lastPageIndex = currentPageIndex
            context.coordinator.lastBoundsSize = currentBoundsSize
            
            makePdfViewTransparent(pdfView)
            
            // Sync outer page change to the PDFView without triggering tile-destroying scale mutations
            if let document = pdfView.document,
               let currentPage = pdfView.currentPage {
                let viewPageIndex = document.index(for: currentPage)
                if viewPageIndex != currentPageIndex && currentPageIndex >= 0 && currentPageIndex < document.pageCount {
                    if let targetPage = document.page(at: currentPageIndex) {
                        pdfView.go(to: targetPage)
                    }
                }
            }
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    /// Remove the PDFViewPageChanged observer so it doesn't accumulate across
    /// repeated opens. Without this, each reader open registers a new observer
    /// and the Coordinator is retained by NotificationCenter indefinitely.
    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        if let canvasView = coordinator.canvasView {
            coordinator.toolPicker.setVisible(false, forFirstResponder: canvasView)
            coordinator.toolPicker.removeObserver(canvasView)
            canvasView.resignFirstResponder()
        }
        if let pdfView = coordinator.pdfView {
            NotificationCenter.default.removeObserver(coordinator, name: .PDFViewPageChanged, object: pdfView)
        }
        coordinator.pdfView = nil
        coordinator.canvasView = nil
    }
    
    @MainActor
    class Coordinator: NSObject, PDFViewDelegate, PKCanvasViewDelegate, PKToolPickerObserver {
        var parent: PDFKitRepresentedView
        weak var pdfView: PDFView?
        weak var canvasView: PKCanvasView?
        var toolPicker = PKToolPicker()
        var lastConfiguredPaginationMode: String?
        var lastFitToWidth: Bool?
        var lastBoundsSize: CGSize = .zero
        var lastPageIndex: Int = -1
        
        init(_ parent: PDFKitRepresentedView) {
            self.parent = parent
            super.init()
            toolPicker.addObserver(self)
        }
              @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard !parent.isPencilMode else { return }
            
            let location = gesture.location(in: gesture.view)
            let width = gesture.view?.bounds.width ?? 0
            
            let zones = EBookPreferences.shared.tapZoneStyle.zones
            let isRTL = EBookPreferences.shared.pdfRTL || parent.pdf.metadata.isManga == true || parent.pdf.contentType == .manga
            
            let tappedLeft = location.x < width * zones.leftEdge
            let tappedRight = location.x > width * zones.rightEdge
            
            let goBackward = isRTL ? tappedRight : tappedLeft
            let goForward = isRTL ? tappedLeft : tappedRight
            
            if goBackward {
                if let pv = pdfView {
                    if let scrollView = pv.subviews.first(where: { $0 is UIScrollView }) as? UIScrollView {
                        let pageHeight = scrollView.bounds.height
                        let currentOffset = scrollView.contentOffset.y
                        let maxOffsetY = scrollView.contentSize.height - pageHeight
                        
                        if maxOffsetY > 0.5 && currentOffset > 1.0 {
                            let newOffset = max(currentOffset - (pageHeight - 40), 0.0)
                            scrollView.setContentOffset(CGPoint(x: 0, y: newOffset), animated: false)
                            HapticEngine.light()
                        } else {
                            if parent.currentPageIndex > 0 {
                                pv.goToPreviousPage(nil)
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    let maxOffsetY2 = scrollView.contentSize.height - scrollView.bounds.height
                                    if maxOffsetY2 > 0 {
                                        scrollView.setContentOffset(CGPoint(x: 0, y: maxOffsetY2), animated: false)
                                    }
                                }
                                HapticEngine.light()
                            }
                        }
                    } else {
                        if parent.currentPageIndex > 0 {
                            pv.goToPreviousPage(nil)
                            HapticEngine.light()
                        }
                    }
                }
            } else if goForward {
                if let pv = pdfView {
                    if let scrollView = pv.subviews.first(where: { $0 is UIScrollView }) as? UIScrollView {
                        let pageHeight = scrollView.bounds.height
                        let currentOffset = scrollView.contentOffset.y
                        let maxOffsetY = scrollView.contentSize.height - pageHeight
                        
                        if maxOffsetY > 0.5 && currentOffset < maxOffsetY - 5.0 {
                            let newOffset = min(currentOffset + (pageHeight - 40), maxOffsetY)
                            scrollView.setContentOffset(CGPoint(x: 0, y: newOffset), animated: false)
                            HapticEngine.light()
                        } else {
                            if let doc = pv.document, parent.currentPageIndex < doc.pageCount - 1 {
                                pv.goToNextPage(nil)
                                HapticEngine.light()
                            }
                        }
                    } else {
                        if let doc = pv.document, parent.currentPageIndex < doc.pageCount - 1 {
                            pv.goToNextPage(nil)
                            HapticEngine.light()
                        }
                    }
                }
            } else {
                parent.chromeVisible.toggle()
            }
        }
        
        @objc func handleSwipe(_ gesture: UISwipeGestureRecognizer) {
            guard !parent.isPencilMode else { return }
            if let pv = pdfView, pv.scaleFactor > (pv.scaleFactorForSizeToFit * 1.15) {
                // User is zoomed in: allow panning inside page without triggering page turns
                return
            }
            
            let isRTL = EBookPreferences.shared.pdfRTL
            let swipeLeft = gesture.direction == .left
            let swipeRight = gesture.direction == .right
            
            let goBackward = isRTL ? swipeLeft : swipeRight
            let goForward = isRTL ? swipeRight : swipeLeft
            
            if goBackward {
                if parent.currentPageIndex > 0 {
                    if let pv = pdfView {
                        pv.goToPreviousPage(nil)
                        if let scrollView = pv.subviews.first(where: { $0 is UIScrollView }) as? UIScrollView {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                let maxOffsetY = scrollView.contentSize.height - scrollView.bounds.height
                                if maxOffsetY > 0 {
                                    scrollView.setContentOffset(CGPoint(x: 0, y: maxOffsetY), animated: false)
                                }
                            }
                        }
                    }
                    HapticEngine.light()
                }
            } else if goForward {
                if let doc = pdfView?.document, parent.currentPageIndex < doc.pageCount - 1 {
                    pdfView?.goToNextPage(nil)
                    HapticEngine.light()
                }
            }
        }
        
        @objc func pageChanged(_ notification: Notification) {
            guard let view = notification.object as? PDFView,
                  let page = view.currentPage,
                  let document = view.document else { return }
            
            let index = document.index(for: page)
            
            if Thread.isMainThread {
                self.updatePageIndex(index, in: view, page: page)
            } else {
                DispatchQueue.main.async {
                    self.updatePageIndex(index, in: view, page: page)
                }
            }
        }
        
        private func updatePageIndex(_ index: Int, in view: PDFView, page: PDFPage) {
            let pageChanged = self.parent.currentPageIndex != index
            self.parent.currentPageIndex = index
            
            if EBookPreferences.shared.pdfFitToWidth {
                let pageBounds = page.bounds(for: view.displayBox)
                let scale = view.bounds.width / pageBounds.width
                if view.scaleFactor != scale && scale > 0 {
                    view.scaleFactor = scale
                }
            }
        }
        
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            // Save ink annotation to AnnotationStore mapped to the current page
            guard let pdfView = pdfView, let page = pdfView.currentPage else { return }
            let index = parent.document.index(for: page)
            
            // Map PKDrawing bounds to PDF Page normalized coords for AnnotationStore
            let viewBounds = canvasView.bounds
            let drawingBounds = canvasView.drawing.bounds
            let normalizedBounds = CodableCGRect(
                x: Double(drawingBounds.minX / viewBounds.width),
                y: Double(drawingBounds.minY / viewBounds.height),
                width: Double(drawingBounds.width / viewBounds.width),
                height: Double(drawingBounds.height / viewBounds.height)
            )
            
            let annotation = Annotation(
                pdfID: parent.pdf.id,
                pageIndex: index,
                kind: .ink,
                createdAt: Date(),
                modifiedAt: Date(),
                bounds: normalizedBounds
            )
            AnnotationStore.shared.add(annotation)
        }
    }
}
