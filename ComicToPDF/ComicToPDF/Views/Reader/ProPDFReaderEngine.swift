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

    private var totalPages: Int {
        pdfDocument?.pageCount ?? pdf.pageCount
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
            EBookSettingsPanel()
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

                // Smart White Margin Crop Toggle
                Button(action: {
                    HapticEngine.medium()
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isCroppedMode.toggle()
                    }
                }) {
                    Image(systemName: isCroppedMode ? "crop.square.fill" : "crop.square")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(isCroppedMode ? .inkGreen : .white)
                        .frame(width: 38, height: 38)
                        .background(isCroppedMode ? Color.inkGreen.opacity(0.25) : Color.black.opacity(0.45))
                        .clipShape(Circle())
                }

                // Expand View Mode Toggle
                Button(action: {
                    HapticEngine.medium()
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpandedView.toggle()
                    }
                }) {
                    Image(systemName: isExpandedView ? "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left" : "arrow.up.left.and.down.right.magnifyingglass")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(isExpandedView ? .inkGreen : .white)
                        .frame(width: 38, height: 38)
                        .background(isExpandedView ? Color.inkGreen.opacity(0.25) : Color.black.opacity(0.45))
                        .clipShape(Circle())
                }

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
                await MainActor.run {
                    self.pdfDocument = doc
                    self.currentPageIndex = min(pdf.currentPage, doc.pageCount - 1)
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
        pdfView.displayMode = .singlePage
        pdfView.displayDirection = .horizontal
        pdfView.backgroundColor = .systemBackground

        // Double Tap Zoom & Single Tap gesture setup
        let tapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        pdfView.addGestureRecognizer(tapGesture)

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

        // Apply Margin Trimming / Cropping to Document Pages
        for i in 0..<document.pageCount {
            guard let page = document.page(at: i) else { continue }
            let mediaBox = page.bounds(for: .mediaBox)
            if isCroppedMode {
                let insetX = mediaBox.width * 0.10
                let insetY = mediaBox.height * 0.12
                let croppedRect = mediaBox.insetBy(dx: insetX, dy: insetY)
                page.setBounds(croppedRect, for: .cropBox)
            } else {
                page.setBounds(mediaBox, for: .cropBox)
            }
        }

        uiView.displayBox = isCroppedMode ? .cropBox : .mediaBox
        uiView.layoutDocumentView()

        // Calculate expanded scale factor to fill 100% of the screen width
        if isExpandedView || isCroppedMode {
            if let currentPage = uiView.currentPage {
                let activeBox: PDFDisplayBox = isCroppedMode ? .cropBox : .mediaBox
                let pageBounds = currentPage.bounds(for: activeBox)
                let pageWidthMultiplier: CGFloat = isDual ? 2.0 : 1.0
                let totalPageWidth = pageBounds.width * pageWidthMultiplier
                let scaleForWidth = uiView.bounds.width / max(totalPageWidth, 1.0)
                if scaleForWidth > 0 {
                    let targetScale = scaleForWidth * (isExpandedView ? 1.15 : 1.02)
                    if abs(uiView.scaleFactor - targetScale) > 0.01 {
                        uiView.scaleFactor = targetScale
                    }
                }
            }
        }

        // ✅ Guarantee PDFView active page always displays the target pageIndex
        if let targetPage = document.page(at: currentPageIndex), uiView.currentPage != targetPage {
            uiView.go(to: targetPage)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject {
        var parent: ProPDFViewRepresentable

        init(_ parent: ProPDFViewRepresentable) {
            self.parent = parent
        }

        @MainActor @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            parent.onTapCenter()
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
