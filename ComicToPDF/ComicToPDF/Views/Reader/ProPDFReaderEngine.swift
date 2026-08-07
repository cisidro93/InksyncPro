import SwiftUI
@preconcurrency import PDFKit
import PencilKit
import AVFoundation

/// Master Pro PDF Reader Engine View for InksyncPro
struct ProPDFReaderEngine: View {
    let pdf: ConvertedPDF
    var onDismiss: () -> Void

    @State private var chromeVisible = false
    @State private var currentPageIndex: Int = 0
    @State private var pdfDocument: PDFDocument?
    @State private var pdfViewReference: PDFView?
    @State private var resolvedURL: URL?

    // Inspector & Sheet Modals
    @State private var showingInspector = false
    @State private var showingPageManager = false
    @State private var showingSettings = false
    @State private var isPencilMode = false
    @State private var isCroppedMode = false
    @State private var isExpandedView = false

    // Text Selection & Markup HUD
    @State private var selectedTextForHUD: String? = nil
    @State private var speechSynthesizer = AVSpeechSynthesizer()

    // Environment & Preferences
    @ObservedObject private var prefs = EBookPreferences.shared
    @Environment(\.modelContext) private var modelContext
    @FocusState private var isReaderFocused: Bool

    @State private var showCropAdjustmentSheet = false
    @State private var activeCropInsets: CodableCropInsets = .zero

    private var totalPages: Int {
        pdfDocument?.pageCount ?? pdf.pageCount
    }

    private func applyCropInsets(_ insets: CodableCropInsets) {
        guard let doc = pdfDocument else { return }
        self.activeCropInsets = insets
        
        if insets.modeRaw == "none" {
            isCroppedMode = false
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
            isCroppedMode = true
            let sensitivity = max(0.05, min(0.25, prefs.autoCropSensitivity))
            for i in 0..<doc.pageCount {
                if let page = doc.page(at: i) {
                    let mediaBox = page.bounds(for: .mediaBox)
                    let insetX = mediaBox.width * sensitivity
                    let insetY = mediaBox.height * sensitivity * 1.2
                    page.setBounds(mediaBox.insetBy(dx: insetX, dy: insetY), for: .cropBox)
                }
            }
            if let pv = pdfViewReference {
                pv.displayBox = .cropBox
                pv.layoutDocumentView()
            }
        } else {
            // Custom Pro Crop Insets
            isCroppedMode = true
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

    var body: some View {
        ZStack {
            Color.inkBackground
                .ignoresSafeArea()

            if let doc = pdfDocument {
                // PDF Core Canvas View
                ZStack {
                    ProPDFViewRepresentable(
                        document: doc,
                        currentPageIndex: $currentPageIndex,
                        pdfViewRef: $pdfViewReference,
                        isCroppedMode: isCroppedMode,
                        isExpandedView: isExpandedView,
                        onTapCenter: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                chromeVisible.toggle()
                            }
                        },
                        onTextSelectionChanged: { text in
                            withAnimation(.easeInOut(duration: 0.18)) {
                                selectedTextForHUD = text
                            }
                        }
                    )
                    .ignoresSafeArea()


                    // PencilKit Ink Bearing Canvas Layer
                    if isPencilMode {
                        PageCanvasOverlay(
                            pdfID: pdf.id,
                            pageIndex: currentPageIndex,
                            isMarkupEnabled: isPencilMode
                        )
                        .ignoresSafeArea()
                    }
                }
            } else {
                // Loading State
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.2)
                        .tint(.inkGreen)
                    Text("Loading PDF Document...")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Theme.textSecondary)
                }
            }

            // Floating Time & Battery Header
            VStack {
                FloatingReaderClockOverlay()
                    .padding(.top, 8)
                Spacer()
            }
            .ignoresSafeArea(edges: .bottom)

            // Contextual Text Selection Markup HUD
            if let selectedText = selectedTextForHUD, !selectedText.isEmpty {
                VStack {
                    Spacer()
                    ProPDFTextSelectionHUD(
                        selectedText: selectedText,
                        pageIndex: currentPageIndex,
                        onHighlight: { color in
                            saveHighlight(text: selectedText, color: color)
                            selectedTextForHUD = nil
                        },
                        onAddNote: { note in
                            saveNote(text: selectedText, note: note)
                            selectedTextForHUD = nil
                        },
                        onCopy: {
                            selectedTextForHUD = nil
                        },
                        onSpeak: { text in
                            speakText(text)
                        },
                        onCreateZettelkastenCard: { text in
                            createZettelkastenCard(text: text)
                            selectedTextForHUD = nil
                        },
                        onAddMarginaliaSymbol: { symbol in
                            saveMarginalia(text: selectedText, symbol: symbol)
                            selectedTextForHUD = nil
                        }
                    )

                    .padding(.bottom, chromeVisible ? 80 : 30)
                    .padding(.horizontal, 20)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Top & Bottom Navigation Chrome
            if chromeVisible {
                proReaderChrome
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .task {
            loadPDFDocument()
        }
        .sheet(isPresented: $showingInspector) {
            ProDocumentInspectorView(
                pdf: pdf,
                pdfDocument: pdfDocument,
                currentPageIndex: currentPageIndex,
                onJumpToPage: { pageIdx in
                    jumpToPage(pageIdx)
                },
                onDismiss: {
                    showingInspector = false
                }
            )
        }
        .sheet(isPresented: $showingPageManager) {
            PDFPageManagerGridView(
                pdf: pdf,
                pdfDocument: pdfDocument,
                onJumpToPage: { pageIdx in
                    jumpToPage(pageIdx)
                },
                onDismiss: {
                    showingPageManager = false
                }
            )
        }
        .sheet(isPresented: $showingSettings) {
            EBookSettingsPanel(bookID: pdf.id.uuidString, isPDF: true)
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

    }


    // MARK: - Top & Bottom Chrome Toolbar
    private var proReaderChrome: some View {
        VStack {
            // Top Bar
            HStack(spacing: 16) {
                Button(action: {
                    HapticEngine.light()
                    onDismiss()
                }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 38, height: 38)
                        .background(Color.black.opacity(0.45))
                        .clipShape(Circle())
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(pdf.name)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text("Page \(currentPageIndex + 1) of \(totalPages)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                }

                Spacer()

                // Inspector (TOC / Search / Annotations)
                Button(action: {
                    HapticEngine.light()
                    showingInspector = true
                }) {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 38, height: 38)
                        .background(Color.black.opacity(0.45))
                        .clipShape(Circle())
                }
                .help("Document Inspector & TOC")
                .accessibilityLabel("Document Inspector & TOC")

                // Page Manager Grid
                Button(action: {
                    HapticEngine.light()
                    showingPageManager = true
                }) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 38, height: 38)
                        .background(Color.black.opacity(0.45))
                        .clipShape(Circle())
                }
                .help("Page Thumbnail Grid")
                .accessibilityLabel("Page Thumbnail Grid")

                // Smart White Margin Crop Toggle
                Button(action: {
                    HapticEngine.medium()
                    showCropAdjustmentSheet = true
                }) {
                    Image(systemName: activeCropInsets.isEnabled ? "crop.square.fill" : "crop.square")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(activeCropInsets.isEnabled ? .inkGreen : .white)
                        .frame(width: 38, height: 38)
                        .background(activeCropInsets.isEnabled ? Color.inkGreen.opacity(0.25) : Color.black.opacity(0.45))
                        .clipShape(Circle())
                }
                .help("Crop Margins")
                .accessibilityLabel("Crop Margins")

                // Expand View Mode Toggle
                Button(action: {
                    HapticEngine.medium()
                    isExpandedView.toggle()
                }) {
                    Image(systemName: isExpandedView ? "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left" : "arrow.up.left.and.down.right.magnifyingglass")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(isExpandedView ? .inkGreen : .white)
                        .frame(width: 38, height: 38)
                        .background(isExpandedView ? Color.inkGreen.opacity(0.25) : Color.black.opacity(0.45))
                        .clipShape(Circle())
                }
                .help("Expand Full Screen")
                .accessibilityLabel("Expand Full Screen")

                // Apple Pencil Ink Mode Toggle
                Button(action: {
                    HapticEngine.medium()
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isPencilMode.toggle()
                    }
                }) {
                    Image(systemName: "pencil.tip.crop.circle")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(isPencilMode ? .inkGreen : .white)
                        .frame(width: 38, height: 38)
                        .background(isPencilMode ? Color.inkGreen.opacity(0.25) : Color.black.opacity(0.45))
                        .clipShape(Circle())
                }
                .help("Apple Pencil Drawing Mode")
                .accessibilityLabel("Apple Pencil Drawing Mode")

                // Settings
                Button(action: {
                    HapticEngine.light()
                    showingSettings = true
                }) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 38, height: 38)
                        .background(Color.black.opacity(0.45))
                        .clipShape(Circle())
                }
                .help("Reader Settings")
                .accessibilityLabel("Reader Settings")
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            Spacer()

            // Bottom Slider Bar
            HStack(spacing: 12) {
                Text("\(currentPageIndex + 1)")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .frame(width: 28)

                Slider(
                    value: Binding(
                        get: { Double(currentPageIndex) },
                        set: { newPage in
                            jumpToPage(Int(newPage))
                        }
                    ),
                    in: 0...Double(max(0, totalPages - 1)),
                    step: 1
                )
                .accentColor(.inkGreen)

                Text("\(totalPages)")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(0.7))
                    .frame(width: 28)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.black.opacity(0.65))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.white.opacity(0.15), lineWidth: 1)
                    )
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    // MARK: - Actions & Persistence
    private func loadPDFDocument() {
        Task.detached(priority: .userInitiated) {
            let docURL = pdf.url
            if let doc = PDFDocument(url: docURL) {
                let savedIndex = await MainActor.run {
                    ReaderProgressTracker.shared.progress(for: self.pdf.id)?.currentPageIndex ?? 0
                }
                await MainActor.run {
                    self.pdfDocument = doc
                    self.currentPageIndex = max(0, min(savedIndex, doc.pageCount - 1))
                    let savedCrop = ReaderProgressTracker.shared.cropInsets(for: self.pdf.id)
                    let initialCrop = savedCrop ?? (self.prefs.defaultCropModeRaw == "smartAuto" ? .smartAuto : CodableCropInsets(top: self.prefs.defaultCropTop, bottom: self.prefs.defaultCropBottom, left: self.prefs.defaultCropLeft, right: self.prefs.defaultCropRight, modeRaw: self.prefs.defaultCropModeRaw))
                    self.applyCropInsets(initialCrop)
                }
            }
        }
    }


    private func jumpToPage(_ pageIndex: Int) {
        let clamped = max(0, min(pageIndex, totalPages - 1))
        currentPageIndex = clamped
        if let doc = pdfDocument, let page = doc.page(at: clamped) {
            pdfViewReference?.go(to: page)
        }
    }

    private func saveHighlight(text: String, color: PDFHighlightColor) {
        if let pdfView = pdfViewReference, let selection = pdfView.currentSelection {
            for page in selection.pages {
                let lineSelections = selection.selectionsByLine()
                let targetLines = lineSelections.isEmpty ? [selection] : lineSelections
                for lineSel in targetLines {
                    let lineBounds = lineSel.bounds(for: page)
                    guard lineBounds != .zero && lineBounds.width > 2 && lineBounds.height > 2 else { continue }
                    let annotation = PDFAnnotation(bounds: lineBounds, forType: .highlight, withProperties: nil)
                    annotation.color = color.uiColor.withAlphaComponent(0.45)
                    page.addAnnotation(annotation)
                }
            }
            pdfView.clearSelection()
        }

        let highlight = Annotation(
            pdfID: pdf.id,
            pageIndex: currentPageIndex,
            chapterTitle: "Page \(currentPageIndex + 1)",
            kind: .highlight,
            createdAt: Date(),
            modifiedAt: Date(),
            colorHex: color.rawValue,
            selectedText: text
        )
        AnnotationStore.shared.add(highlight)
    }

    private func saveNote(text: String, note: String) {
        let noteAnn = Annotation(
            pdfID: pdf.id,
            pageIndex: currentPageIndex,
            chapterTitle: "Page \(currentPageIndex + 1)",
            kind: .note,
            createdAt: Date(),
            modifiedAt: Date(),
            colorHex: PDFHighlightColor.yellow.rawValue,
            selectedText: text,
            noteText: note
        )
        AnnotationStore.shared.add(noteAnn)
    }

    private func saveMarginalia(text: String, symbol: String) {
        var ann = Annotation(
            pdfID: pdf.id,
            pageIndex: currentPageIndex,
            chapterTitle: "Page \(currentPageIndex + 1)",
            kind: .highlight,
            createdAt: Date(),
            modifiedAt: Date(),
            colorHex: PDFHighlightColor.yellow.rawValue,
            selectedText: text,
            noteText: "Marginalia Symbol: \(symbol)"
        )
        ann.marginaliaSymbolRaw = symbol
        AnnotationStore.shared.add(ann)
    }


    private func speakText(_ text: String) {
        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        speechSynthesizer.speak(utterance)
    }

    private func createZettelkastenCard(text: String) {
        let card = SDNotebook(
            title: "Quote from \(pdf.name) (Page \(currentPageIndex + 1))",
            linkedBookID: pdf.id
        )
        modelContext.insert(card)
        try? modelContext.save()
    }
}

// MARK: - UIViewRepresentable for Vector PDFKit View
struct ProPDFViewRepresentable: UIViewRepresentable {
    let document: PDFDocument
    @Binding var currentPageIndex: Int
    @Binding var pdfViewRef: PDFView?
    var isCroppedMode: Bool
    var isExpandedView: Bool
    var onTapCenter: () -> Void
    var onTextSelectionChanged: (String?) -> Void

    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.document = document
        pdfView.autoScales = true
        pdfView.minScaleFactor = 0.25
        pdfView.maxScaleFactor = 10.0
        pdfView.displayMode = .singlePage
        pdfView.displayDirection = .horizontal
        // Must be .clear — .systemBackground causes a white page background that bleeds
        // through during page turns and when the theme is dark/sepia.
        pdfView.backgroundColor = .clear
        pdfView.isOpaque = false
        pdfView.insetsLayoutMarginsFromSafeArea = false

        if let scrollView = pdfView.subviews.first(where: { $0 is UIScrollView }) as? UIScrollView {
            scrollView.maximumZoomScale = 10.0
            scrollView.minimumZoomScale = 0.25
        }

        // Single Tap gesture setup
        let tapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tapGesture.cancelsTouchesInView = false
        pdfView.addGestureRecognizer(tapGesture)

        // Double Tap Zoom setup
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.cancelsTouchesInView = false
        pdfView.addGestureRecognizer(doubleTap)
        tapGesture.require(toFail: doubleTap)

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.pageChanged(_:)),
            name: .PDFViewPageChanged,
            object: pdfView
        )

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.selectionChanged(_:)),
            name: .PDFViewSelectionChanged,
            object: pdfView
        )

        DispatchQueue.main.async {
            self.pdfViewRef = pdfView
        }

        return pdfView
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        if uiView.document != document {
            uiView.document = document
        }

        let prefs = EBookPreferences.shared
        let isLandscape = uiView.bounds.width > uiView.bounds.height
        let isDual = prefs.pdfDualPage || (prefs.autoLandscapeDualPage && isLandscape)
        let targetDisplayMode: PDFDisplayMode = isDual ? .twoUp : .singlePage
        if uiView.displayMode != targetDisplayMode {
            uiView.displayMode = targetDisplayMode
            uiView.displaysAsBook = isDual
        }

        let hasCustomMargin = prefs.textMargin > 0
        let targetDisplayBox: PDFDisplayBox = (isCroppedMode || hasCustomMargin) ? .cropBox : .mediaBox
        
        let cropStateChanged = isCroppedMode != context.coordinator.lastCropMode ||
                               prefs.textMargin != context.coordinator.lastTextMargin
        if cropStateChanged {
            context.coordinator.lastCropMode = isCroppedMode
            context.coordinator.lastTextMargin = prefs.textMargin
            if let currentPage = uiView.currentPage {
                let docIndex = document.index(for: currentPage)
                let start = max(0, docIndex - 3)
                let end = min(document.pageCount - 1, docIndex + 3)
                for i in start...end {
                    guard let page = document.page(at: i) else { continue }
                    let mediaBox = page.bounds(for: .mediaBox)
                    if isCroppedMode {
                        let sensitivity = max(0.05, min(0.25, prefs.autoCropSensitivity))
                        let marginInset = prefs.textMargin * 0.5
                        let insetX = (mediaBox.width * sensitivity) + marginInset
                        let insetY = (mediaBox.height * sensitivity * 1.2) + marginInset
                        let croppedRect = mediaBox.insetBy(dx: insetX, dy: insetY)
                        page.setBounds(croppedRect, for: .cropBox)
                    } else if hasCustomMargin {
                        let marginX = prefs.textMargin
                        let marginY = prefs.textMargin * 0.75
                        let marginRect = mediaBox.insetBy(dx: marginX, dy: marginY)
                        page.setBounds(marginRect, for: .cropBox)
                    } else {
                        page.setBounds(mediaBox, for: .cropBox)
                    }
                }
            }
        }

        if uiView.displayBox != targetDisplayBox {
            uiView.displayBox = targetDisplayBox
        }

        let pageOrBoundsChanged = (context.coordinator.lastPageIndex != currentPageIndex) ||
                                  (context.coordinator.lastBoundsSize != uiView.bounds.size) ||
                                  cropStateChanged

        if isExpandedView {
            if pageOrBoundsChanged {
                if uiView.autoScales {
                    uiView.autoScales = false
                }
                let fitScale = uiView.scaleFactorForSizeToFit
                let targetScale = max(fitScale * 1.35, 1.25)
                if abs(uiView.scaleFactor - targetScale) > 0.05 {
                    uiView.scaleFactor = targetScale
                }
            }
        } else {
            if pageOrBoundsChanged, let currentPage = uiView.currentPage, uiView.bounds.width > 0 && uiView.bounds.height > 0 {
                let pageBounds = currentPage.bounds(for: uiView.displayBox)
                let pageWidthMultiplier: CGFloat = isDual ? 2.0 : 1.0
                let totalPageWidth = pageBounds.width * pageWidthMultiplier
                let totalPageHeight = pageBounds.height

                // Use min (fit) so the entire page is always visible.
                // max (fill) causes clipped text by zooming past the visible area.
                let scaleForWidth = uiView.bounds.width / max(totalPageWidth, 1.0)
                let scaleForHeight = uiView.bounds.height / max(totalPageHeight, 1.0)
                let targetScale = min(scaleForWidth, scaleForHeight)

                if targetScale > 0 {
                    if uiView.autoScales {
                        uiView.autoScales = false
                    }
                    if abs(uiView.scaleFactor - targetScale) > 0.005 {
                        uiView.scaleFactor = targetScale
                        uiView.layoutDocumentView()
                    }
                }
            }
        }

        context.coordinator.lastPageIndex = currentPageIndex
        context.coordinator.lastBoundsSize = uiView.bounds.size

        // Guarantee PDFView active page always displays the target pageIndex
        if let targetPage = document.page(at: currentPageIndex), uiView.currentPage != targetPage {
            uiView.go(to: targetPage)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    /// Remove observers to prevent memory leaks from accumulated registrations
    /// each time the ProPDF reader is opened.
    static func dismantleUIView(_ uiView: PDFView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator, name: .PDFViewPageChanged, object: uiView)
        NotificationCenter.default.removeObserver(coordinator, name: .PDFViewSelectionChanged, object: uiView)
    }

    class Coordinator: NSObject {
        var parent: ProPDFViewRepresentable
        var lastCropMode: Bool = false
        var lastTextMargin: CGFloat = -1
        var lastPageIndex: Int = -1
        var lastBoundsSize: CGSize = .zero

        init(_ parent: ProPDFViewRepresentable) {
            self.parent = parent
        }

        @MainActor @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            parent.onTapCenter()
        }

        @MainActor @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let pdfView = gesture.view as? PDFView else { return }
            let currentScale = pdfView.scaleFactor
            let fitScale = pdfView.scaleFactorForSizeToFit
            let zoomTarget = fitScale * 2.5
            if currentScale > fitScale * 1.5 {
                pdfView.scaleFactor = fitScale
            } else {
                pdfView.scaleFactor = zoomTarget
            }
        }

        @MainActor @objc func pageChanged(_ notification: Notification) {
            guard let pdfView = notification.object as? PDFView,
                  let page = pdfView.currentPage,
                  let doc = pdfView.document else { return }
            let idx = doc.index(for: page)
            self.parent.currentPageIndex = idx
        }

        @MainActor @objc func selectionChanged(_ notification: Notification) {
            guard let pdfView = notification.object as? PDFView else { return }
            if let selection = pdfView.currentSelection, let text = selection.string, !text.isEmpty {
                parent.onTextSelectionChanged(text)
            } else {
                parent.onTextSelectionChanged(nil)
            }
        }
    }
}
