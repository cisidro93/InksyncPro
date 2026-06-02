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
    @ObservedObject private var prefs = EBookPreferences.shared
    
    var body: some View {
        ZStack {
            prefs.activeTheme.background.edgesIgnoringSafeArea(.all)
            
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
                                      isPencilMode: $isPencilMode)
                .colorInvertIfDark(theme: prefs.activeTheme)
            } else {
                ProgressView("Loading Document...")
            }
            
            ReaderChrome(
                title: pdf.name,
                pageText: "\(currentPageIndex + 1) / \(totalPages)",
                isVisible: $chromeVisible,
                onBack: {
                    ReaderProgressTracker.shared.update(ReadingProgress(
                        pdfID: pdf.id, lastOpenedAt: Date(), currentPageIndex: currentPageIndex,
                        currentChapterIndex: nil, currentChapterOffset: nil,
                        totalPagesRead: 1, completionFraction: Double(currentPageIndex + 1) / Double(max(1, totalPages)),
                        readingSessionDates: [Date()], estimatedMinutesRemaining: nil
                    ))
                    onDismiss()
                },
                onBookmark: {
                    let bookmark = Annotation(pdfID: pdf.id, pageIndex: currentPageIndex, kind: .bookmark, createdAt: Date(), modifiedAt: Date())
                    AnnotationStore.shared.add(bookmark)
                },
                onSettingsToggle: { showingSettings = true },
                onAnnotationsToggle: { isPencilMode.toggle() },
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

            let doc = ConcurrencyLocks.pdfLock.withLock {
                PDFDocument(url: resolvedURL)
            }
            self.accessedURL = accessed
            pdfDocument = doc
            if let saved = ReaderProgressTracker.shared.progress(for: pdf.id) {
                currentPageIndex = saved.currentPageIndex
            }
            if isReflowMode { updateReflowText() }
        }
        .onChange(of: currentPageIndex) { old, new in
            if isReflowMode { updateReflowText() }
        }
        .onDisappear {
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
    }
    
    // MARK: KOReader Parity Dynamics
    
    private func updateReflowText() {
        guard let doc = pdfDocument, let page = doc.page(at: currentPageIndex) else { return }
        let extracted = page.string ?? ""
        self.reflowText = extracted.isEmpty ? "No extractable text on this page." : extracted
    }
    
    private func applySmartCrop() {
        guard let doc = pdfDocument else { return }
        for i in 0..<doc.pageCount {
            if let page = doc.page(at: i) {
                var crop = page.bounds(for: .cropBox)
                crop = crop.insetBy(dx: crop.width * 0.12, dy: crop.height * 0.12)
                page.setBounds(crop, for: .cropBox)
            }
        }
        // Force PDFView to re-layout: nil → reassign on next runloop tick.
        // Task.yield() is deterministic under CPU load (no magic 0.1s delay).
        pdfDocument = nil
        Task { @MainActor in
            await Task.yield()
            self.pdfDocument = doc
        }
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
    
    func makeUIView(context: Context) -> UIView {
        let pdfView = HighlightablePDFView()
        pdfView.document = document
        pdfView.autoScales = true
        pdfView.displayDirection = .vertical
        pdfView.displayMode = pdf.documentSubtype == .magazine ? .singlePageContinuous : .singlePageContinuous
        pdfView.delegate = context.coordinator
        
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
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    /// Remove the PDFViewPageChanged observer so it doesn't accumulate across
    /// repeated opens. Without this, each reader open registers a new observer
    /// and the Coordinator is retained by NotificationCenter indefinitely.
    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
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
        
        init(_ parent: PDFKitRepresentedView) {
            self.parent = parent
            super.init()
            toolPicker.addObserver(self)
        }
        
        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard !parent.isPencilMode else { return }
            parent.chromeVisible.toggle()
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
