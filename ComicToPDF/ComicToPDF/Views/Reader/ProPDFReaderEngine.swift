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
    @State private var isReflowMode = false

    // Text Selection & Markup HUD
    @State private var selectedTextForHUD: String? = nil
    @State private var speechSynthesizer = AVSpeechSynthesizer()

    // Environment & Preferences
    @ObservedObject private var prefs = EBookPreferences.shared
    @Environment(\.modelContext) private var modelContext
    @FocusState private var isReaderFocused: Bool
    @StateObject private var velocityEngine = ReaderVelocityEngine()

    @State private var showCropAdjustmentSheet = false
    @State private var activeCropInsets: CodableCropInsets = .zero
    @AppStorage("isMangaMode") private var isMangaMode = false
    @State private var activeZoomScale: CGFloat = 1.0
    @State private var showZoomPill = false
    @State private var zoomPillTask: Task<Void, Never>? = nil
    // Hyperlink Destination Preview HUD State
    @State private var pendingLinkPreview: (pageIndex: Int, targetPage: PDFPage)? = nil

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
                pv.autoScales = false
                pv.autoScales = true
                pv.scaleFactor = pv.scaleFactorForSizeToFit
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
                pv.autoScales = false
                pv.autoScales = true
                pv.scaleFactor = pv.scaleFactorForSizeToFit
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
                pv.autoScales = false
                pv.autoScales = true
                pv.scaleFactor = pv.scaleFactorForSizeToFit
                pv.layoutDocumentView()
            }
        }
    }

    var body: some View {
        ZStack {
            Color.inkBackground
                .ignoresSafeArea()

            if isReflowMode {
                ProPDFReflowReaderView(
                    pdf: pdf,
                    pdfDocument: pdfDocument,
                    currentPageIndex: $currentPageIndex,
                    onDismiss: onDismiss,
                    onToggleReflow: {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            isReflowMode = false
                            prefs.pdfReflowMode = false
                        }
                    }
                )
            } else if let doc = pdfDocument {
                // PDF Core Canvas View
                ZStack {
                    ProPDFViewRepresentable(
                        document: doc,
                        currentPageIndex: $currentPageIndex,
                        pdfViewRef: $pdfViewReference,
                        isCroppedMode: isCroppedMode,
                        isExpandedView: isExpandedView,
                        onPrevPage: {
                            jumpToPage(isMangaMode ? currentPageIndex + 1 : currentPageIndex - 1)
                        },
                        onNextPage: {
                            jumpToPage(isMangaMode ? currentPageIndex - 1 : currentPageIndex + 1)
                        },
                        onTapCenter: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                chromeVisible.toggle()
                            }
                        },
                        onTextSelectionChanged: { text in
                            withAnimation(.easeInOut(duration: 0.18)) {
                                selectedTextForHUD = text
                            }
                        },
                        onScaleChanged: { scale in
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                activeZoomScale = scale
                                showZoomPill = true
                            }
                            zoomPillTask?.cancel()
                            zoomPillTask = Task {
                                try? await Task.sleep(nanoseconds: 1_500_000_000)
                                guard !Task.isCancelled else { return }
                                await MainActor.run {
                                    withAnimation(.easeInOut(duration: 0.3)) {
                                        showZoomPill = false
                                    }
                                }
                            }
                        },
                        onHyperlinkSelected: { destIndex, destPage in
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                                self.pendingLinkPreview = (destIndex, destPage)
                            }
                        }
                    )
                    .readingFilter(prefs.readingFilter)
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

            EdgeBrightnessGestureZone()

            // Floating Time & Battery Header
            VStack {
                FloatingReaderClockOverlay()
                    .padding(.top, 8)
                Spacer()
            }
            .ignoresSafeArea(edges: .bottom)

            // Zoom Scale Percentage Pill HUD
            if showZoomPill {
                VStack {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 11, weight: .bold))
                        Text("\(Int(round(activeZoomScale * 100)))%")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().stroke(Color.white.opacity(0.2), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
                    .padding(.top, chromeVisible ? 70 : 50)
                    Spacer()
                }
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
                .zIndex(10)
            }

            // Hyperlink Destination Preview HUD Modal Overlay
            if let preview = pendingLinkPreview {
                ZStack {
                    Color.black.opacity(0.45)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                self.pendingLinkPreview = nil
                            }
                        }
                    
                    HyperlinkPreviewHUD(
                        targetPageIndex: preview.pageIndex,
                        targetPage: preview.targetPage,
                        onConfirmJump: {
                            let targetIdx = preview.pageIndex
                            withAnimation(.easeInOut(duration: 0.2)) {
                                self.pendingLinkPreview = nil
                            }
                            jumpToPage(targetIdx)
                        },
                        onDismiss: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                self.pendingLinkPreview = nil
                            }
                        }
                    )
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
                }
                .zIndex(25)
            }

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
            } else if selectedTextForHUD == nil {
                KindleProgressFooterView(
                    currentPage: currentPageIndex + 1,
                    totalPages: max(1, totalPages),
                    estimatedMinutesLeft: ReaderProgressTracker.shared.progress(for: pdf.id)?.estimatedMinutesRemaining
                )
                .transition(.opacity)
            }

            ReadingJumpToastOverlay()
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) {
            jumpToPage(isMangaMode ? currentPageIndex + 1 : currentPageIndex - 1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            jumpToPage(isMangaMode ? currentPageIndex - 1 : currentPageIndex + 1)
            return .handled
        }
        .onKeyPress(.space) {
            jumpToPage(currentPageIndex + 1)
            return .handled
        }
        .task {
            loadPDFDocument()
        }
        .onChange(of: currentPageIndex) { _, _ in
            saveReadingProgress()
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
            // Top Floating Glass Bar
            HStack(spacing: 12) {
                Button(action: {
                    HapticEngine.light()
                    onDismiss()
                }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 36, height: 36)
                        .background(Color.white.opacity(0.12))
                        .clipShape(Circle())
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(pdf.name)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text("Page \(currentPageIndex + 1) of \(totalPages)")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.7))
                }

                Spacer()

                // Inspector (TOC / Search / Annotations)
                Button(action: {
                    HapticEngine.light()
                    showingInspector = true
                }) {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 36, height: 36)
                        .background(Color.white.opacity(0.12))
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
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 36, height: 36)
                        .background(Color.white.opacity(0.12))
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
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(activeCropInsets.isEnabled ? .inkGreen : .white)
                        .frame(width: 36, height: 36)
                        .background(activeCropInsets.isEnabled ? Color.inkGreen.opacity(0.25) : Color.white.opacity(0.12))
                        .clipShape(Circle())
                }
                .help("Crop Margins")
                .accessibilityLabel("Crop Margins")

                // Apple Pencil Ink Mode Toggle
                Button(action: {
                    HapticEngine.medium()
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isPencilMode.toggle()
                    }
                }) {
                    Image(systemName: "pencil.tip.crop.circle")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(isPencilMode ? .inkGreen : .white)
                        .frame(width: 36, height: 36)
                        .background(isPencilMode ? Color.inkGreen.opacity(0.25) : Color.white.opacity(0.12))
                        .clipShape(Circle())
                }
                .help("Apple Pencil Drawing Mode")
                .accessibilityLabel("Apple Pencil Drawing Mode")

                // Pro Text Reflow Mode Toggle
                Button(action: {
                    HapticEngine.medium()
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        isReflowMode.toggle()
                        prefs.pdfReflowMode = isReflowMode
                    }
                }) {
                    Image(systemName: isReflowMode ? "doc.plaintext.fill" : "doc.plaintext")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(isReflowMode ? .inkGreen : .white)
                        .frame(width: 36, height: 36)
                        .background(isReflowMode ? Color.inkGreen.opacity(0.25) : Color.white.opacity(0.12))
                        .clipShape(Circle())
                }
                .help("Pro Text Reflow Mode")
                .accessibilityLabel("Pro Text Reflow Mode")

                // Master Reader Settings
                Button(action: {
                    HapticEngine.light()
                    showingSettings = true
                }) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 36, height: 36)
                        .background(Color.white.opacity(0.12))
                        .clipShape(Circle())
                }
                .help("Reader Settings")
                .accessibilityLabel("Reader Settings")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
                    )
                    .shadow(color: Color.black.opacity(0.25), radius: 10, x: 0, y: 4)
            )
            .padding(.horizontal, 16)
            .padding(.top, 12)

            Spacer()

            // Bottom Floating Glass Capsule
            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    Text("\(currentPageIndex + 1)")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .frame(width: 36, alignment: .trailing)

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
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.7))
                        .frame(width: 36, alignment: .leading)
                }

                Divider()
                    .background(Color.white.opacity(0.12))

                HStack {
                    Button(action: {
                        HapticEngine.medium()
                        NotificationCenter.default.post(name: .toggleStudyNotebook, object: nil)
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "note.text")
                                .font(.system(size: 14, weight: .semibold))
                            Text("Notebook")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.12))
                        .clipShape(Capsule())
                    }

                    Spacer()

                    let pct = totalPages > 1 ? Int(round(Double(currentPageIndex) / Double(totalPages - 1) * 100)) : 100
                    HStack(spacing: 4) {
                        Image(systemName: "doc.text.fill")
                            .font(.system(size: 12, weight: .bold))
                        Text("Vector PDF • \(pct)%")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                    }
                    .foregroundColor(.inkGreen)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.inkGreen.opacity(0.15))
                    .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
                    )
                    .shadow(color: Color.black.opacity(0.3), radius: 12, x: 0, y: 6)
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


    private func saveReadingProgress() {
        var progress = ReaderProgressTracker.shared.progress(for: pdf.id) ?? ReadingProgress(
            pdfID: pdf.id,
            lastOpenedAt: Date(),
            currentPageIndex: currentPageIndex,
            totalPagesRead: 1,
            completionFraction: 0,
            readingSessionDates: []
        )
        progress.lastOpenedAt = Date()
        progress.currentPageIndex = currentPageIndex
        let total = max(1, totalPages)
        progress.completionFraction = Double(currentPageIndex + 1) / Double(total)
        ReaderProgressTracker.shared.update(progress)
    }

    private func jumpToPage(_ pageIndex: Int) {
        let clamped = max(0, min(pageIndex, totalPages - 1))
        if clamped != currentPageIndex {
            let fromPage = currentPageIndex
            if abs(clamped - fromPage) > 1 {
                ReadingJumpTracker.shared.recordJump(fromPage: fromPage, toPage: clamped) {
                    self.jumpToPage(fromPage)
                }
            }
            velocityEngine.recordPageTurn()
        }
        currentPageIndex = clamped
        if let doc = pdfDocument, let page = doc.page(at: clamped), pdfViewReference?.currentPage != page {
            pdfViewReference?.go(to: page)
        }
        saveReadingProgress()
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
            pdfView.setNeedsDisplay()
            HapticEngine.selection()
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
    var onPrevPage: () -> Void
    var onNextPage: () -> Void
    var onTapCenter: () -> Void
    var onTextSelectionChanged: (String?) -> Void
    var onScaleChanged: ((CGFloat) -> Void)? = nil
    var onHyperlinkSelected: ((Int, PDFPage) -> Void)? = nil

    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.delegate = context.coordinator
        // Start invisible — auto-scales causes a momentary zoom jolt on first layout.
        // We reveal the view only after layoutDocumentView() has settled.
        pdfView.alpha = 0
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

        let prefs = EBookPreferences.shared
        let isLandscape = UIScreen.main.bounds.width > UIScreen.main.bounds.height
        let isDual = prefs.pdfDualPage || (prefs.autoLandscapeDualPage && isLandscape)
        let spineLoc: UIPageViewController.SpineLocation = isDual ? .mid : .min
        let options: [UIPageViewController.OptionsKey: Any] = [
            .spineLocation: NSNumber(value: spineLoc.rawValue),
            .interPageSpacing: 16.0
        ]
        pdfView.usePageViewController(true, withViewOptions: options)

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

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.scaleChanged(_:)),
            name: .PDFViewScaleChanged,
            object: pdfView
        )

        // Allow one run-loop cycle for auto-scale layout, then fade in.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            pdfView.layoutDocumentView()
            UIView.animate(withDuration: 0.18) {
                pdfView.alpha = 1.0
            }
        }

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
        }
        uiView.displaysAsBook = false

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

        let boundsChanged = context.coordinator.lastBoundsSize != uiView.bounds.size

        if boundsChanged || cropStateChanged {
            if isExpandedView {
                let fitScale = uiView.scaleFactorForSizeToFit
                let targetScale = max(fitScale * 1.35, 1.25)
                if abs(uiView.scaleFactor - targetScale) > 0.05 {
                    uiView.scaleFactor = targetScale
                }
            } else if context.coordinator.userCustomZoomScale == nil {
                let fitScale = uiView.scaleFactorForSizeToFit
                if fitScale > 0 && abs(uiView.scaleFactor - fitScale) > 0.01 {
                    uiView.scaleFactor = fitScale
                }
            }
        }

        context.coordinator.lastBoundsSize = uiView.bounds.size

        // Guarantee PDFView active page displays target pageIndex cleanly without re-entrant animation corruption
        if let targetPage = document.page(at: currentPageIndex), uiView.currentPage != targetPage {
            if context.coordinator.lastTargetPageIndex != currentPageIndex {
                context.coordinator.lastTargetPageIndex = currentPageIndex
                uiView.go(to: targetPage)
            }
        } else {
            context.coordinator.lastTargetPageIndex = currentPageIndex
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
        NotificationCenter.default.removeObserver(coordinator, name: .PDFViewScaleChanged, object: uiView)
    }

    class Coordinator: NSObject, PDFViewDelegate {
        var parent: ProPDFViewRepresentable
        var lastCropMode: Bool = false
        var lastTextMargin: CGFloat = -1
        var lastPageIndex: Int = -1
        var lastTargetPageIndex: Int = -1
        var lastBoundsSize: CGSize = .zero
        var userCustomZoomScale: CGFloat? = nil

        init(_ parent: ProPDFViewRepresentable) {
            self.parent = parent
        }

        // MARK: - PDFViewDelegate Link Interception
        @MainActor @objc func pdfView(_ sender: PDFView, willPerform action: PDFAction) {
            if let actionGoTo = action as? PDFActionGoTo,
               let destPage = actionGoTo.destination.page,
               let doc = sender.document {
                let idx = doc.index(for: destPage)
                if idx >= 0 && idx < doc.pageCount {
                    HapticEngine.selection()
                    parent.onHyperlinkSelected?(idx, destPage)
                }
            }
        }

        @MainActor @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? PDFView else { return }
            let location = gesture.location(in: view)
            let width = view.bounds.width
            let prefs = EBookPreferences.shared
            let zones = prefs.tapZoneStyle.zones
            let isManga = prefs.pdfRTL || UserDefaults.standard.bool(forKey: "isMangaMode")

            if location.x < width * zones.leftEdge {
                if isManga {
                    parent.onNextPage()
                } else {
                    parent.onPrevPage()
                }
            } else if location.x > width * zones.rightEdge {
                if isManga {
                    parent.onPrevPage()
                } else {
                    parent.onNextPage()
                }
            } else {
                parent.onTapCenter()
            }
        }

        @MainActor @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let pdfView = gesture.view as? PDFView else { return }
            let currentScale = pdfView.scaleFactor
            let fitScale = pdfView.scaleFactorForSizeToFit
            let zoomTarget = fitScale * 2.5
            if currentScale > fitScale * 1.5 {
                pdfView.scaleFactor = fitScale
                userCustomZoomScale = nil
            } else {
                pdfView.scaleFactor = zoomTarget
                userCustomZoomScale = zoomTarget
            }
            let effectiveScale = pdfView.scaleFactor / max(0.01, fitScale)
            parent.onScaleChanged?(effectiveScale)
        }

        @MainActor @objc func scaleChanged(_ notification: Notification) {
            guard let pdfView = notification.object as? PDFView else { return }
            let fitScale = pdfView.scaleFactorForSizeToFit
            let effectiveScale = pdfView.scaleFactor / max(0.01, fitScale)
            if abs(pdfView.scaleFactor - fitScale) > 0.05 {
                userCustomZoomScale = pdfView.scaleFactor
            }
            parent.onScaleChanged?(effectiveScale)
        }

        @MainActor @objc func pageChanged(_ notification: Notification) {
            guard let pdfView = notification.object as? PDFView,
                  let page = pdfView.currentPage,
                  let doc = pdfView.document else { return }
            let idx = doc.index(for: page)
            if self.parent.currentPageIndex != idx {
                self.lastTargetPageIndex = idx
                self.parent.currentPageIndex = idx
            }
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
