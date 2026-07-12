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
    @State private var showAnnotations = false
    @State private var showSearch = false
    @State private var pdfViewReference: PDFView? = nil
    @State private var resolvedURL: URL? = nil
    @ObservedObject private var prefs = EBookPreferences.shared
    @FocusState private var isReaderFocused: Bool
    @State private var lastBrightnessDragValue: CGFloat = 0
    @ObservedObject private var sleepTimer = SleepTimerManager.shared
    
    var body: some View {
        ZStack {
            prefs.activeTheme.background.edgesIgnoringSafeArea(.all)
            
            Group {
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
                    PDFKitRepresentedView(document: doc,
                                          pdf: pdf,
                                          currentPageIndex: $currentPageIndex,
                                          chromeVisible: $chromeVisible,
                                          isPencilMode: $isPencilMode,
                                          pdfViewRef: $pdfViewReference)
                    .colorInvertIfDark(theme: prefs.activeTheme)
                } else {
                    ProgressView("Loading Document...")
                }
            }
            .readingFilter(prefs.readingFilter)
            .ignoresSafeArea()
            
            // Edge Brightness Gesture Zones
            HStack {
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: 30)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                let delta = value.translation.height - lastBrightnessDragValue
                                lastBrightnessDragValue = value.translation.height
                                UIScreen.main.brightness -= delta * 0.005
                            }
                            .onEnded { _ in lastBrightnessDragValue = 0 }
                    )
                Spacer()
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: 30)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                let delta = value.translation.height - lastBrightnessDragValue
                                lastBrightnessDragValue = value.translation.height
                                UIScreen.main.brightness -= delta * 0.005
                            }
                            .onEnded { _ in lastBrightnessDragValue = 0 }
                    )
            }
            
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
                onTOCToggle: { showAnnotations = true },
                onAnnotationsToggle: { isPencilMode.toggle() },
                onSearchToggle: { showSearch = true },
                currentProgress: Binding(
                    get: { Double(currentPageIndex) / Double(max(1, totalPages - 1)) },
                    set: {
                        currentPageIndex = Int($0 * Double(max(1, totalPages - 1)))
                    }
                ),
                totalPages: totalPages,
                isPDF: true,
                isReflowActive: isReflowMode,
                onCropToggle: { applySmartCrop() },
                onReflowToggle: {
                    isReflowMode.toggle()
                    if isReflowMode { updateReflowText() }
                },
                isSettingsActive: showingSettings
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
        .onChange(of: sleepTimer.didFire) { _, fired in
            if fired {
                ReaderProgressTracker.shared.update(ReadingProgress(
                    pdfID: pdf.id, lastOpenedAt: Date(), currentPageIndex: currentPageIndex,
                    currentChapterIndex: nil, currentChapterOffset: nil,
                    totalPagesRead: 1, completionFraction: Double(currentPageIndex + 1) / Double(max(1, totalPages)),
                    readingSessionDates: [Date()], estimatedMinutesRemaining: nil
                ))
                onDismiss()
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
            if let saved = ReaderProgressTracker.shared.progress(for: pdf.id) {
                currentPageIndex = saved.currentPageIndex
            }
            if isReflowMode { updateReflowText() }
            isReaderFocused = true
        }
        // FIX 3: Save position on every page turn — not just on deliberate back-tap.
        // This ensures phone-calls, swipe-up app kills, and background terminations
        // never lose the user's reading position.
        .onChange(of: currentPageIndex) { _, new in
            if isReflowMode { updateReflowText() }
            savePosition(pageIndex: new)
        }
        // FIX 3b: Also save when the app goes to the background (resign-active).
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            savePosition(pageIndex: currentPageIndex)
        }
        .onDisappear {
            savePosition(pageIndex: currentPageIndex)
            accessedURL?.stopAccessingSecurityScopedResource()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            Logger.shared.log("DocumentReaderEngine: Memory warning received. Purging PDF cache.", category: "Memory", type: .warning)
            Task {
                await PDFRenderActor.shared.clear()
            }
        }
        .sheet(isPresented: $showingSettings) {
            EBookSettingsPanel(bookID: pdf.id.uuidString)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showAnnotations) {
            StudyNotebookView(
                bookID: pdf.id.uuidString,
                bookTitle: pdf.name,
                fileURL: pdf.url
            )
        }
        .sheet(isPresented: $showSearch) {
            if let doc = pdfDocument, let pdfV = pdfViewReference {
                ReaderSearchView(document: doc, pdfView: pdfV)
                    .presentationDetents([.medium, .large])
            }
        }
        .focusable()
        .focused($isReaderFocused)
        .focusEffectDisabled()
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
            ReaderProgressTracker.shared.update(ReadingProgress(
                pdfID: pdf.id, lastOpenedAt: Date(), currentPageIndex: currentPageIndex,
                currentChapterIndex: nil, currentChapterOffset: nil,
                totalPagesRead: 1, completionFraction: Double(currentPageIndex + 1) / Double(max(1, totalPages)),
                readingSessionDates: [Date()], estimatedMinutesRemaining: nil
            ))
            onDismiss()
            return .handled
        }
        .preferredColorScheme(prefs.activeTheme.isDark ? .dark : .light)
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
        let extracted = page.string ?? ""
        self.reflowText = extracted.isEmpty ? "No extractable text on this page." : extracted
    }
    
    // FIX 5: Smart crop now runs entirely on a background thread.
    // The previous implementation iterated every page on the main actor, causing
    // multi-second UI freezes on large PDFs (500+ pages).
    // Under Swift 6, we avoid capturing non-Sendable PDFDocument across actor boundaries
    // by passing the Sendable resolvedURL, creating a background document, and returning
    // a Sendable [Int: CGRect] dictionary.
    private func applySmartCrop() {
        guard let doc = pdfDocument else { return }
        let url = resolvedURL ?? pdf.url
        // Temporarily nil-out to signal loading state
        pdfDocument = nil
        Task {
            let cropBoxes = await Task.detached(priority: .utility) { () -> [Int: CGRect] in
                guard let backgroundDoc = PDFDocument(url: url) else { return [:] }
                var results = [Int: CGRect]()
                for i in 0..<backgroundDoc.pageCount {
                    guard let page = backgroundDoc.page(at: i) else { continue }
                    let pageBounds = page.bounds(for: .cropBox)
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
                        let finalCrop = croppedRect.intersection(pageBounds)
                        if finalCrop.width > 50 && finalCrop.height > 50 {
                            results[i] = finalCrop
                        }
                    } else {
                        var crop = pageBounds
                        crop = crop.insetBy(dx: crop.width * 0.08, dy: crop.height * 0.08)
                        results[i] = crop
                    }
                }
                return results
            }.value

            // Re-apply to doc and restore pdfDocument reference on MainActor
            await MainActor.run {
                for (i, cropBox) in cropBoxes {
                    if let page = doc.page(at: i) {
                        page.setBounds(cropBox, for: .cropBox)
                    }
                }
                self.pdfDocument = doc
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
    
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(customHighlightAction(_:)) { return true }
        let allowed = ["copy:", "share:", "_lookup:", "_define:"]
        if allowed.contains(NSStringFromSelector(action)) { return true }
        return super.canPerformAction(action, withSender: sender)
    }
    
    @objc func customHighlightAction(_ sender: Any?) {
        guard let selection = self.currentSelection, let page = selection.pages.first else { return }
        let text = selection.string ?? ""
        let bounds = selection.bounds(for: page)
        
        // Natively draw the highlight on the PDF document
        let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
        annotation.color = .systemYellow.withAlphaComponent(0.5)
        page.addAnnotation(annotation)
        
        self.clearSelection()
        onHighlightCreated?(text, bounds)
    }
    
    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        let highlightCommand = UICommand(title: "Highlight", action: #selector(customHighlightAction(_:)))
        let highlightMenu = UIMenu(title: "Inksync", options: .displayInline, children: [highlightCommand])
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
    
    @ObservedObject private var prefs = EBookPreferences.shared
    
    private func makePdfViewTransparent(_ pdfView: PDFView) {
        pdfView.isOpaque = false
        pdfView.backgroundColor = .clear
        for subview in pdfView.subviews {
            subview.backgroundColor = .clear
            if let scrollView = subview as? UIScrollView {
                scrollView.backgroundColor = .clear
            }
        }
    }
    
    private func configureDisplayMode(_ pdfView: PDFView, context: Context) {
        let currentMode = prefs.paginationMode
        context.coordinator.lastConfiguredPaginationMode = currentMode
        let isPaged = currentMode == EBookPaginationMode.paged.rawValue
        
        if isPaged {
            pdfView.displayMode = .singlePage
            pdfView.displayDirection = .horizontal
            pdfView.usePageViewController(true, withViewOptions: nil)
        } else {
            pdfView.usePageViewController(false)
            pdfView.displayMode = .singlePageContinuous
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
            // We use a background Task to avoid blocking the main thread.
            let writeURL = pdf.url
            DispatchQueue.global(qos: .background).async {
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
        pdfView.frame = container.bounds
        pdfView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(pdfView)
        
        canvasView.frame = container.bounds
        canvasView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(canvasView)
        
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(context.coordinator.handleTap(_:)))
        pdfView.addGestureRecognizer(tap)
        
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
            if context.coordinator.lastConfiguredPaginationMode != currentMode {
                configureDisplayMode(pdfView, context: context)
            }
            makePdfViewTransparent(pdfView)
            
            // Sync outer page change to the PDFView
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
    
    class Coordinator: NSObject, PDFViewDelegate, PKCanvasViewDelegate, PKToolPickerObserver {
        var parent: PDFKitRepresentedView
        weak var pdfView: PDFView?
        weak var canvasView: PKCanvasView?
        var toolPicker = PKToolPicker()
        var lastConfiguredPaginationMode: String?
        
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
            
            if location.x < width * zones.leftEdge {
                // Page backward
                if parent.currentPageIndex > 0 {
                    if let pv = pdfView, pv.canGoToPreviousPage {
                        pv.goToPreviousPage(nil)
                    } else {
                        parent.currentPageIndex -= 1
                    }
                    HapticEngine.light()
                }
            } else if location.x > width * zones.rightEdge {
                // Page forward
                if let doc = pdfView?.document, parent.currentPageIndex < doc.pageCount - 1 {
                    if let pv = pdfView, pv.canGoToNextPage {
                        pv.goToNextPage(nil)
                    } else {
                        parent.currentPageIndex += 1
                    }
                    HapticEngine.light()
                }
            } else {
                // Toggle chrome
                parent.chromeVisible.toggle()
            }
        }
        
        @objc func pageChanged(_ notification: Notification) {
            if let view = notification.object as? PDFView,
               let page = view.currentPage,
               let document = view.document {
                let index = document.index(for: page)
                Task { @MainActor in
                    self.parent.currentPageIndex = index
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
