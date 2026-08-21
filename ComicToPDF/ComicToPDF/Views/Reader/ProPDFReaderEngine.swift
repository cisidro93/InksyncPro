import SwiftUI
@preconcurrency import PDFKit
import PencilKit
import AVFoundation

/// Master Pro PDF Reader Engine View for InksyncPro
struct ProPDFReaderEngine: View {
    let pdf: ConvertedPDF
    var onDismiss: () -> Void
    var allBooks: [ConvertedPDF] = []

    @State private var chromeVisible = false
    @State private var currentPageIndex: Int = 0
    @State private var pdfDocument: PDFDocument?
    @State private var pdfViewReference: PDFView?
    @State private var resolvedURL: URL?

    // Inspector & Sheet Modals
    @State private var showingInspector = false
    @State private var showingOutlineDrawer = false
    @State private var showingPageManager = false
    @State private var showingSettings = false
    @State private var isPencilMode = false
    @State private var isCroppedMode = false
    @State private var isExpandedView = false
    @State private var isReflowMode = false
    @State private var showingFilterHUD = false
    @State private var shareAnnotatedPDFURL: URL? = nil

    // Text Selection & Markup HUD
    @State private var selectedTextForHUD: String? = nil
    @State private var speechSynthesizer = AVSpeechSynthesizer()

    // Environment & Preferences
    @ObservedObject private var prefs = EBookPreferences.shared
    @AppStorage("activeFilterPreset") private var activeFilterPreset: ReadingFilterPreset = .original
    @Environment(\.modelContext) private var modelContext
    @FocusState private var isReaderFocused: Bool
    @StateObject private var velocityEngine = ReaderVelocityEngine()
    @StateObject private var readingRoom = ReadingRoomSession()

    // Ambient page color extraction
    @State private var ambientPageColor: Color = .clear
    @State private var ambientColorTask: Task<Void, Never>? = nil

    @State private var sessionStartTime: Date = Date()
    @State private var showCropAdjustmentSheet = false
    @State private var activeCropInsets: CodableCropInsets = .zero
    @AppStorage("isMangaMode") private var isMangaMode = false
    @State private var activeZoomScale: CGFloat = 1.0
    @State private var showZoomPill = false
    @State private var zoomPillTask: Task<Void, Never>? = nil
    @State private var chromeIdleTask: Task<Void, Never>? = nil
    @State private var loadTask: Task<Void, Never>? = nil
    @State private var accessedSecurityScopedURL: URL? = nil
    // Hyperlink Destination Preview HUD State
    @State private var pendingLinkPreview: (pageIndex: Int, targetPage: PDFPage)? = nil

    // Toast Notifications
    @State private var toastMessage: String = ""
    @State private var showToast: Bool = false
    @State private var loadFailed: Bool = false
    @State private var loadErrorMessage: String = ""

    private var totalPages: Int {
        pdfDocument?.pageCount ?? pdf.pageCount
    }

    private func startChromeIdleTimer() {
        chromeIdleTask?.cancel()
        chromeIdleTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                chromeVisible = false
            }
        }
    }

    private func toggleChrome() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            chromeVisible.toggle()
        }
        if chromeVisible {
            startChromeIdleTimer()
        } else {
            chromeIdleTask?.cancel()
        }
    }

    private func showToastMessage(_ message: String) {
        toastMessage = message
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            showToast = true
        }
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.25)) {
                    showToast = false
                }
            }
        }
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
            let sensitivity = max(0.02, min(0.08, prefs.autoCropSensitivity * 0.35))
            for i in 0..<doc.pageCount {
                if let page = doc.page(at: i) {
                    let mediaBox = page.bounds(for: .mediaBox)
                    let insetX = mediaBox.width * sensitivity
                    let insetY = mediaBox.height * sensitivity
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
            // Deep black background with subtle ambient illumination
            Color.black
                .ignoresSafeArea()

            RadialGradient(
                colors: [ambientPageColor.opacity(0.18), Color.black],
                center: .center,
                startRadius: 80,
                endRadius: 450
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            mainContentView

            EdgeBrightnessGestureZone()

            // Floating Time & Battery Header
            VStack {
                FloatingReaderClockOverlay()
                    .padding(.top, 8)
                Spacer()
            }
            .allowsHitTesting(false)
            .ignoresSafeArea(edges: .bottom)

            zoomPillHUD
            hyperlinkPreviewModal
            textSelectionHUDOverlay
            readerChromeView
            filterHUDOverlay

            if readingRoom.isHosting {
                ReadingRoomOverlay(
                    session: readingRoom,
                    currentPage: currentPageIndex,
                    totalPages: max(1, totalPages)
                )
            }

            if !chromeVisible && selectedTextForHUD == nil {
                KindleProgressFooterView(
                    currentPage: currentPageIndex + 1,
                    totalPages: max(1, totalPages),
                    estimatedMinutesLeft: ReaderProgressTracker.shared.progress(for: pdf.id)?.estimatedMinutesRemaining
                )
                .transition(.opacity)
            }

            toastAlertOverlay
            ReadingJumpToastOverlay()
        }
        .overlay {
            if prefs.showReadingRuler {
                ReadingRulerOverlay()
            }
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) {
            advancePage(forward: false)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            advancePage(forward: true)
            return .handled
        }
        .onKeyPress(.space) {
            advancePage(forward: true)
            return .handled
        }
        .task {
            // Reset filter to original on every open so a persisted color-invert
            // filter from a previous session cannot corrupt page rendering appearance.
            activeFilterPreset = .original
            loadPDFDocument()
        }
        .onDisappear {
            loadTask?.cancel()
            zoomPillTask?.cancel()
            chromeIdleTask?.cancel()
            ambientColorTask?.cancel()
            accessedSecurityScopedURL?.stopAccessingSecurityScopedResource()
            accessedSecurityScopedURL = nil
            readingRoom.stop()
        }
        .onReceive(NotificationCenter.default.publisher(for: .readerJumpToPage)) { notification in
            if let pageIndex = notification.userInfo?["pageIndex"] as? Int, pageIndex >= 0, pageIndex < totalPages {
                jumpToPage(pageIndex)
            }
        }
        .onChange(of: currentPageIndex) { _, newIndex in
            saveReadingProgress()
            extractAmbientColor(for: newIndex)
        }
        .sheet(isPresented: $showingOutlineDrawer) {
            PDFOutlineDrawer(
                pdf: pdf,
                pdfDocument: pdfDocument,
                currentPageIndex: currentPageIndex,
                onJumpToPage: { pageIdx in
                    jumpToPage(pageIdx)
                },
                onDismiss: {
                    showingOutlineDrawer = false
                }
            )
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

    // MARK: - Subviews for Fast Compiler Type-Checking

    @ViewBuilder private var mainContentView: some View {
        if isReflowMode {
            ProPDFReflowReaderView(
                pdf: pdf,
                pdfDocument: pdfDocument,
                currentPageIndex: $currentPageIndex,
                onDismiss: {
                    saveReadingProgress()
                    onDismiss()
                },
                onToggleReflow: {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        isReflowMode = false
                        prefs.pdfReflowMode = false
                    }
                }
            )
        } else if let doc = pdfDocument {
            pdfCanvasView(document: doc)
        } else {
            pdfLoadingView
        }
    }

    @ViewBuilder private func pdfCanvasView(document: PDFDocument) -> some View {
        let isLandscape = UIScreen.main.bounds.width > UIScreen.main.bounds.height
        let isDual = prefs.pdfDualPage || (prefs.autoLandscapeDualPage && isLandscape)

        ZStack {
            ProPDFViewRepresentable(
                pdf: pdf,
                document: document,
                currentPageIndex: $currentPageIndex,
                pdfViewRef: $pdfViewReference,
                isCroppedMode: isCroppedMode,
                isExpandedView: isExpandedView,
                onPrevPage: {
                    advancePage(forward: false)
                },
                onNextPage: {
                    advancePage(forward: true)
                },
                onTapCenter: {
                    toggleChrome()
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
            .ignoresSafeArea()

            // Physical Book Spine Median Crease & Depth Shadow in Dual-Page Landscape
            if isLandscape && isDual && currentPageIndex > 0 {
                GeometryReader { _ in
                    HStack(spacing: 0) {
                        Spacer()

                        LinearGradient(
                            colors: [
                                Color.black.opacity(0.0),
                                Color.black.opacity(0.12),
                                Color.black.opacity(0.24),
                                Color.black.opacity(0.12),
                                Color.black.opacity(0.0)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: 22)
                        .allowsHitTesting(false)

                        Spacer()
                    }
                }
                .allowsHitTesting(false)
            }

            if isPencilMode {
                PageCanvasOverlay(
                    pdfID: pdf.id,
                    pageIndex: currentPageIndex,
                    isMarkupEnabled: isPencilMode
                )
                .ignoresSafeArea()
            }
        }
    }

    @ViewBuilder private var pdfLoadingView: some View {
        VStack(spacing: 16) {
            if loadFailed {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 40))
                    .foregroundColor(.orange)
                Text(loadErrorMessage.isEmpty ? "Unable to open PDF document." : loadErrorMessage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Button("Retry Loading") {
                    loadFailed = false
                    loadPDFDocument()
                }
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(Color.inkGreen, in: Capsule())
            } else {
                ProgressView()
                    .scaleEffect(1.2)
                    .tint(.inkGreen)
                Text("Loading PDF Document...")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
            }
        }
    }

    @ViewBuilder private var zoomPillHUD: some View {
        if showZoomPill {
            let scalePct = Int(round(activeZoomScale * 100))
            VStack {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .bold))
                    Text("\(scalePct)%")
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
            .allowsHitTesting(false)
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
            .zIndex(10)
        }
    }

    @ViewBuilder private var hyperlinkPreviewModal: some View {
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
    }

    @ViewBuilder private var textSelectionHUDOverlay: some View {
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
    }

    @ViewBuilder private var filterHUDOverlay: some View {
        if showingFilterHUD {
            VStack {
                Spacer()
                FilterHUDView(
                    activePreset: $activeFilterPreset,
                    onDismiss: {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            showingFilterHUD = false
                        }
                    }
                )
                .padding(.bottom, chromeVisible ? 84 : 20)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .zIndex(20)
        }
    }

    @ViewBuilder private var toastAlertOverlay: some View {
        if showToast {
            Text(toastMessage)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
                .padding(.bottom, 110)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(100)
        }
    }

    // MARK: - Master Unified Reader Chrome
    @ViewBuilder private var readerChromeView: some View {
        let pageStatus = "\(currentPageIndex + 1) / \(max(1, totalPages))  •  \(velocityEngine.estimatedTimeRemaining)"
        ReaderChrome(
            title: pdf.name,
            pageText: pageStatus,
            isVisible: $chromeVisible,
            onBack: {
                saveReadingProgress()
                onDismiss()
            },
            onBookmark: {
                let bookmark = Annotation(
                    pdfID: pdf.id,
                    pageIndex: currentPageIndex,
                    chapterTitle: "Page \(currentPageIndex + 1)",
                    kind: .bookmark,
                    createdAt: Date(),
                    modifiedAt: Date()
                )
                AnnotationStore.shared.add(bookmark)
                showToastMessage("Bookmark Added")
                HapticEngine.medium()
            },
            onBookmarkActive: AnnotationStore.shared.annotations(for: pdf.id).contains(where: { $0.pageIndex == currentPageIndex && $0.kind == .bookmark }),
            onSettingsToggle: {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    showingSettings = true
                }
            },
            onTOCToggle: {
                showingOutlineDrawer = true
            },
            onAnnotationsToggle: {
                NotificationCenter.default.post(name: .toggleStudyNotebook, object: nil)
            },
            onSearchToggle: {
                showingInspector = true
            },
            currentProgress: Binding(
                get: { Double(currentPageIndex) / Double(max(1, totalPages - 1)) },
                set: { jumpToPage(Int(round($0 * Double(max(1, totalPages - 1))))) }
            ),
            totalPages: max(1, totalPages),
            customScrubber: AnyView(
                VisualPDFScrubber(
                    currentIndex: $currentPageIndex,
                    totalPages: max(1, totalPages),
                    document: pdfDocument,
                    isMangaMode: isMangaMode
                )
            ),
            getPageThumbnail: { index in
                guard let doc = pdfDocument, let page = doc.page(at: index) else { return nil }
                return page.thumbnail(of: CGSize(width: 140, height: 190), for: .cropBox)
            },
            timeRemainingText: velocityEngine.estimatedTimeRemaining,
            onJumpToPage: {
                showingPageManager = true
            },
            hasCopyAction: true,
            onCopyToggle: {
                if let pdfView = pdfViewReference, let page = pdfView.currentPage, let text = page.string {
                    UIPasteboard.general.string = text
                    showToastMessage("Page Text Copied")
                    HapticEngine.success()
                }
            },
            isPDF: true,
            isReflowActive: isReflowMode,
            isAutoCropEnabled: activeCropInsets.isEnabled,
            onCropToggle: {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    if activeCropInsets.isEnabled {
                        applyCropInsets(.none)
                    } else {
                        applyCropInsets(.smartAuto)
                    }
                }
                HapticEngine.medium()
            },
            onManualCropToggle: {
                showCropAdjustmentSheet = true
            },
            onReflowToggle: {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isReflowMode.toggle()
                    prefs.pdfReflowMode = isReflowMode
                }
                HapticEngine.medium()
            },
            isEnhanced: activeFilterPreset != .original,
            onEnhanceToggle: {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    showingFilterHUD.toggle()
                }
            },
            isSettingsActive: showingSettings,
            ambientColor: ambientPageColor,
            isInRoom: readingRoom.isHosting,
            roomPeerCount: readingRoom.peers.count,
            onRoomToggle: {
                if readingRoom.isHosting {
                    readingRoom.stop()
                } else {
                    readingRoom.startHosting(bookID: pdf.id.uuidString)
                }
            },
            sessionStartTime: sessionStartTime,
            onSwipeDown: {
                saveReadingProgress()
                onDismiss()
            }
        )
    }

    // MARK: - Actions & Persistence
    private func loadPDFDocument() {
        loadTask?.cancel()
        loadTask = Task.detached(priority: .userInitiated) {
            let sourcePDF = self.pdf
            let resolvedURL: URL
            var accessedURL: URL? = nil
            
            if case .linked(let bm) = sourcePDF.sourceMode,
               let url = try? BookmarkResolver.shared.resolve(bm) {
                let didAccess = url.startAccessingSecurityScopedResource()
                resolvedURL = url
                if didAccess { accessedURL = url }
            } else {
                let sandboxURL = LibraryFileRecord.resolveSandboxURL(sourcePDF.url.absoluteString)
                let didAccess = sandboxURL.startAccessingSecurityScopedResource()
                resolvedURL = sandboxURL
                if didAccess { accessedURL = sandboxURL }
            }
            
            var loaded = PDFDocument(url: resolvedURL)
            if loaded == nil && resolvedURL != sourcePDF.url {
                let didAccessSource = sourcePDF.url.startAccessingSecurityScopedResource()
                if didAccessSource && accessedURL == nil { accessedURL = sourcePDF.url }
                loaded = PDFDocument(url: sourcePDF.url)
            }
            
            // Fail-safe 1: Memory-mapped byte buffer (bypasses direct file-path sandbox resolution lockouts)
            if loaded == nil {
                if let data = try? Data(contentsOf: resolvedURL, options: .alwaysMapped) {
                    loaded = PDFDocument(data: data)
                } else if let data = try? Data(contentsOf: sourcePDF.url, options: .alwaysMapped) {
                    loaded = PDFDocument(data: data)
                }
            }
            
            // Fail-safe 2: Check App Group containers directly if file was staged from Share Extension
            if loaded == nil {
                let filename = sourcePDF.url.lastPathComponent
                let groupIDs = [
                    "group.com.antigravity.ComicToPDF",
                    "group.com.antigravity.inksync",
                    "group.com.antigravity.InksyncPro"
                ]
                let containers: [URL] = groupIDs.compactMap {
                    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0)
                }
                for container in containers {
                    for sub in ["Inbox", "PendingConversions", "ShareStaging"] {
                        let candidate = container.appendingPathComponent(sub).appendingPathComponent(filename)
                        if FileManager.default.fileExists(atPath: candidate.path) {
                            if let doc = PDFDocument(url: candidate) {
                                loaded = doc
                                break
                            } else if let data = try? Data(contentsOf: candidate) {
                                loaded = PDFDocument(data: data)
                                break
                            }
                        }
                    }
                    if loaded != nil { break }
                }
            }
            
            // Automatically unlock encrypted PDFs with empty passwords if locked
            if let doc = loaded, doc.isLocked {
                doc.unlock(withPassword: "")
            }
            
            if let doc = loaded {
                let savedIndex = await MainActor.run {
                    ReaderProgressTracker.shared.progress(for: sourcePDF.id)?.currentPageIndex ?? 0
                }
                await MainActor.run {
                    if let accessed = accessedURL {
                        self.accessedSecurityScopedURL = accessed
                    }
                    self.pdfDocument = doc
                    self.loadFailed = false
                    self.currentPageIndex = max(0, min(savedIndex, doc.pageCount - 1))
                    let savedCrop = ReaderProgressTracker.shared.cropInsets(for: sourcePDF.id)
                    let initialCrop = savedCrop ?? (self.prefs.defaultCropModeRaw == "smartAuto" ? .smartAuto : .none)
                    self.applyCropInsets(initialCrop)
                    self.extractAmbientColor(for: self.currentPageIndex)
                    
                    // Ingest native third-party PDF annotations into AnnotationStore
                    _ = PDFAnnotationSyncBridge.shared.importNativeAnnotations(from: doc, for: sourcePDF.id)
                }
            } else {
                accessedURL?.stopAccessingSecurityScopedResource()
                await MainActor.run {
                    self.loadFailed = true
                    self.loadErrorMessage = "Unable to read PDF file at \(sourcePDF.name)."
                }
            }
        }
    }

    private func extractAmbientColor(for index: Int) {
        guard let doc = pdfDocument, let page = doc.page(at: index) else { return }
        ambientColorTask?.cancel()
        ambientColorTask = Task.detached(priority: .utility) {
            guard !Task.isCancelled else { return }
            let thumb = page.thumbnail(of: CGSize(width: 32, height: 32), for: .cropBox)
            guard let cgImage = thumb.cgImage else { return }
            
            let thumbSize = 32
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let bytesPerRow = thumbSize * 4
            var pixelBuffer = [UInt8](repeating: 0, count: thumbSize * bytesPerRow)

            guard let ctx = CGContext(
                data: &pixelBuffer,
                width: thumbSize,
                height: thumbSize,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }

            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: thumbSize, height: thumbSize))
            guard !Task.isCancelled else { return }

            func pixel(x: Int, y: Int) -> (CGFloat, CGFloat, CGFloat) {
                let offset = (y * bytesPerRow) + (x * 4)
                let r = CGFloat(pixelBuffer[offset])     / 255
                let g = CGFloat(pixelBuffer[offset + 1]) / 255
                let b = CGFloat(pixelBuffer[offset + 2]) / 255
                return (r, g, b)
            }

            var rSum: CGFloat = 0
            var gSum: CGFloat = 0
            var bSum: CGFloat = 0
            var count: CGFloat = 0

            let sampleSteps = 4
            for s in 0..<sampleSteps {
                let t = Int(Double(s + 1) / Double(sampleSteps + 1) * Double(thumbSize))
                for (x, y) in [(0, t), (thumbSize - 1, t), (t, 0), (t, thumbSize - 1)] {
                    let (r, g, b) = pixel(x: x, y: y)
                    rSum += r; gSum += g; bSum += b; count += 1
                }
            }

            guard count > 0, !Task.isCancelled else { return }
            let avgR = rSum / count
            let avgG = gSum / count
            let avgB = bSum / count

            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.6)) {
                    self.ambientPageColor = Color(red: avgR, green: avgG, blue: avgB)
                }
            }
        }
    }

    private func attemptPDFSeriesContinuation() {
        guard let seriesName = pdf.metadata.series, !seriesName.isEmpty else { return }
        let siblings = allBooks
            .filter { $0.metadata.series == seriesName && $0.id != pdf.id }
            .sorted { lhs, rhs in
                let lhsNum = Double(lhs.metadata.issueNumber ?? lhs.metadata.volume ?? "")
                let rhsNum = Double(rhs.metadata.issueNumber ?? rhs.metadata.volume ?? "")
                if let l = lhsNum, let r = rhsNum { return l < r }
                let lKey = lhs.metadata.issueNumber ?? lhs.metadata.volume ?? lhs.name
                let rKey = rhs.metadata.issueNumber ?? rhs.metadata.volume ?? rhs.name
                return lKey.localizedStandardCompare(rKey) == .orderedAscending
            }
        guard !siblings.isEmpty else { return }
        let selfKey = pdf.metadata.issueNumber ?? pdf.metadata.volume ?? pdf.name
        if let currentIdx = siblings.firstIndex(where: {
            ($0.metadata.issueNumber ?? $0.metadata.volume ?? $0.name) == selfKey
        }) {
            let nextIdx = siblings.index(after: currentIdx)
            guard siblings.indices.contains(nextIdx) else { return }
            NotificationCenter.default.post(name: .openMergedBook, object: siblings[nextIdx])
        } else if let first = siblings.first {
            NotificationCenter.default.post(name: .openMergedBook, object: first)
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
            if readingRoom.isHosting {
                readingRoom.broadcastPage(clamped, totalPages: max(1, totalPages))
            }
        }
        currentPageIndex = clamped
        if let doc = pdfDocument, let page = doc.page(at: clamped), pdfViewReference?.currentPage != page {
            pdfViewReference?.go(to: page)
        }
        saveReadingProgress()
    }

    private func advancePage(forward: Bool) {
        let isLandscape = UIScreen.main.bounds.width > UIScreen.main.bounds.height
        let isDual = prefs.pdfDualPage || (prefs.autoLandscapeDualPage && isLandscape)
        let isManga = isMangaMode || prefs.pdfRTL
        let effectiveForward = isManga ? !forward : forward

        if isDual {
            if effectiveForward {
                if currentPageIndex == 0 {
                    jumpToPage(1)
                } else if currentPageIndex >= totalPages - 1 {
                    attemptPDFSeriesContinuation()
                } else {
                    jumpToPage(min(totalPages - 1, currentPageIndex + 2))
                }
            } else {
                if currentPageIndex <= 1 {
                    jumpToPage(0)
                } else {
                    jumpToPage(max(0, currentPageIndex - 2))
                }
            }
        } else {
            if effectiveForward {
                if currentPageIndex >= totalPages - 1 {
                    attemptPDFSeriesContinuation()
                } else {
                    jumpToPage(currentPageIndex + 1)
                }
            } else {
                jumpToPage(max(0, currentPageIndex - 1))
            }
        }
        HapticEngine.selection()
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

// MARK: - Visual PDF Scrubber (Matches VisualComicScrubber)
struct VisualPDFScrubber: View {
    @Binding var currentIndex: Int
    let totalPages: Int
    let document: PDFDocument?
    var isMangaMode: Bool = false

    @State private var dragIndex: Int? = nil
    @State private var thumbXOffset: CGFloat = 0

    private let trackHeight: CGFloat = 10
    private let thumbSize: CGFloat = 26

    var body: some View {
        VStack(spacing: 0) {
            // Thumbnail preview card while scrubbing
            if let activeIndex = dragIndex, activeIndex >= 0 && activeIndex < totalPages {
                thumbnailCard(for: activeIndex)
                    .offset(x: clampedThumbOffset)
                    .padding(.bottom, 8)
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottom)))
                    .animation(.spring(response: 0.25, dampingFraction: 0.7), value: dragIndex)
            }

            GeometryReader { geo in
                let trackWidth = max(10, geo.size.width - thumbSize)
                let displayIndex = dragIndex ?? currentIndex
                let normalized = isMangaMode
                    ? CGFloat(totalPages - 1 - displayIndex)
                    : CGFloat(displayIndex)
                let ratio = totalPages > 1 ? min(max(normalized / CGFloat(totalPages - 1), 0), 1) : 0
                let thumbX = ratio * trackWidth

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.15))
                        .frame(height: trackHeight)

                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.9), Color.white.opacity(0.6)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: thumbX + thumbSize, height: trackHeight)

                    Circle()
                        .fill(Color.white)
                        .frame(width: thumbSize, height: thumbSize)
                        .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                        .shadow(
                            color: dragIndex != nil ? Color.white.opacity(0.35) : .clear,
                            radius: 10
                        )
                        .scaleEffect(dragIndex != nil ? 1.15 : 1.0)
                        .animation(.spring(response: 0.2, dampingFraction: 0.65), value: dragIndex != nil)
                        .offset(x: thumbX)
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { val in
                                    let percentage = min(max(val.location.x / max(1, geo.size.width), 0), 1)
                                    let rawIndex = Int(round(percentage * CGFloat(max(1, totalPages - 1))))
                                    let targeted = isMangaMode ? (totalPages - 1 - rawIndex) : rawIndex
                                    thumbXOffset = val.location.x - geo.size.width / 2
                                    if dragIndex != targeted {
                                        UISelectionFeedbackGenerator().selectionChanged()
                                        dragIndex = targeted
                                    }
                                }
                                .onEnded { _ in
                                    if let final = dragIndex {
                                        HapticEngine.light()
                                        currentIndex = final
                                    }
                                    dragIndex = nil
                                }
                        )
                }
                .frame(height: thumbSize)
            }
            .frame(height: thumbSize)
        }
    }

    private var clampedThumbOffset: CGFloat {
        max(-80, min(80, thumbXOffset))
    }

    @ViewBuilder
    private func thumbnailCard(for index: Int) -> some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .frame(width: 72, height: 104)

                if let doc = document, let page = doc.page(at: index) {
                    Image(uiImage: page.thumbnail(of: CGSize(width: 140, height: 200), for: .cropBox))
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 68, height: 100)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white.opacity(0.5)))
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.5), radius: 14, y: 6)

            Text("\(index + 1) / \(totalPages)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 0.5))
        }
    }
}

// MARK: - UIViewRepresentable for Vector PDFKit View
struct ProPDFViewRepresentable: UIViewRepresentable {
    let pdf: ConvertedPDF
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
        pdfView.displayDirection = .horizontal
        pdfView.pageShadowsEnabled = true
        pdfView.backgroundColor = .clear
        pdfView.isOpaque = false
        pdfView.insetsLayoutMarginsFromSafeArea = false
        pdfView.usePageViewController(false)

        let prefs = EBookPreferences.shared
        let isLandscape = UIScreen.main.bounds.width > UIScreen.main.bounds.height
        let isDual = prefs.pdfDualPage || (prefs.autoLandscapeDualPage && isLandscape)
        pdfView.displayMode = isDual ? .twoUp : .singlePage
        pdfView.displaysAsBook = isDual

        let margin = max(0, prefs.textMargin)
        pdfView.pageBreakMargins = UIEdgeInsets(top: 0, left: margin, bottom: 0, right: margin)

        // Assign document AFTER display configuration
        pdfView.document = document
        pdfView.autoScales = true
        pdfView.minScaleFactor = 0.25
        pdfView.maxScaleFactor = 6.0

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

        DispatchQueue.main.async {
            self.pdfViewRef = pdfView
        }

        return pdfView
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        if uiView.document != document {
            uiView.document = document
            // autoScales will re-compute fit after document swap without manual override.
            uiView.autoScales = true
        }
        let prefs = EBookPreferences.shared
        let isLandscape = uiView.bounds.width > uiView.bounds.height
        let isDual = prefs.pdfDualPage || (prefs.autoLandscapeDualPage && isLandscape)
        let targetDisplayMode: PDFDisplayMode = isDual ? .twoUp : .singlePage
        
        if uiView.displayMode != targetDisplayMode {
            uiView.displayMode = targetDisplayMode
        }
        uiView.displaysAsBook = isDual

        let margin = max(0, prefs.textMargin)
        let targetMargins = UIEdgeInsets(top: 0, left: margin, bottom: 0, right: margin)
        if uiView.pageBreakMargins != targetMargins {
            uiView.pageBreakMargins = targetMargins
        }

        let targetDisplayBox: PDFDisplayBox = isCroppedMode ? .cropBox : .mediaBox
        if uiView.displayBox != targetDisplayBox {
            uiView.displayBox = targetDisplayBox
        }

        let boundsChanged = context.coordinator.lastBoundsSize != uiView.bounds.size
        let cropStateChanged = isCroppedMode != context.coordinator.lastCropMode ||
                               prefs.textMargin != context.coordinator.lastTextMargin

        if boundsChanged || cropStateChanged {
            context.coordinator.lastCropMode = isCroppedMode
            context.coordinator.lastTextMargin = prefs.textMargin

            // Recompute fitScale against real current frame; only touch scaleFactor
            // if autoScales is off (i.e. user has manually zoomed in via gesture).
            let fitScale = uiView.scaleFactorForSizeToFit
            if fitScale > 0.001 {
                uiView.minScaleFactor = fitScale
                uiView.maxScaleFactor = fitScale * 7.0
                if let sv = uiView.subviews.first(where: { $0 is UIScrollView }) as? UIScrollView {
                    sv.minimumZoomScale = fitScale
                    sv.maximumZoomScale = fitScale * 7.0
                }
            }

            if isExpandedView {
                let targetScale = max((fitScale > 0 ? fitScale : 1.0) * 1.35, 1.0)
                if abs(uiView.scaleFactor - targetScale) > 0.05 {
                    uiView.scaleFactor = targetScale
                }
            } else if context.coordinator.userCustomZoomScale == nil {
                // Defer to autoScales for the baseline fit — only nudge if PDFKit
                // settled on a value that is clearly wrong (> 5% off actual fit).
                if fitScale > 0.001 && abs(uiView.scaleFactor - fitScale) > fitScale * 0.05 {
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
            guard let pdfView = gesture.view as? PDFView,
                  let page = pdfView.currentPage,
                  let doc = pdfView.document else { return }
            let pageIdx = doc.index(for: page)
            let tapLocationInView = gesture.location(in: pdfView)
            let tapLocationInPage = pdfView.convert(tapLocationInView, to: page)
            let currentScale = pdfView.scaleFactor
            let fitScale = pdfView.scaleFactorForSizeToFit

            let layout = PDFColumnDetector.shared.detectColumns(in: page, pageIndex: pageIdx)
            if layout.isMultiColumn, let targetCol = PDFColumnDetector.shared.findTargetColumn(at: tapLocationInPage, in: layout) {
                if currentScale > fitScale * 1.3 {
                    // Zoom back out
                    UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0, options: [.curveEaseOut]) {
                        pdfView.scaleFactor = fitScale
                        self.userCustomZoomScale = nil
                    }
                } else {
                    // Zoom to fit column width
                    let colWidth = targetCol.rect.width
                    let desiredScale = max(fitScale * 1.2, min(fitScale * 4.0, (pdfView.bounds.width - 24.0) / max(1, colWidth)))
                    
                    UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0, options: [.curveEaseOut]) {
                        pdfView.scaleFactor = desiredScale
                        self.userCustomZoomScale = desiredScale
                        
                        // Center horizontally on column
                        let colCenter = CGPoint(x: targetCol.rect.midX, y: targetCol.rect.maxY)
                        let viewPoint = pdfView.convert(colCenter, from: page)
                        if let scrollView = pdfView.subviews.first(where: { $0 is UIScrollView }) as? UIScrollView {
                            let targetOffsetX = max(0, viewPoint.x - (pdfView.bounds.width / 2.0))
                            let targetOffsetY = max(0, viewPoint.y - 20)
                            scrollView.setContentOffset(CGPoint(x: targetOffsetX, y: targetOffsetY), animated: false)
                        }
                    }
                    HapticEngine.light()
                }
            } else {
                let zoomTarget = fitScale * 2.5
                if currentScale > fitScale * 1.5 {
                    UIView.animate(withDuration: 0.3) {
                        pdfView.scaleFactor = fitScale
                        self.userCustomZoomScale = nil
                    }
                } else {
                    UIView.animate(withDuration: 0.3) {
                        pdfView.scaleFactor = zoomTarget
                        self.userCustomZoomScale = zoomTarget
                    }
                }
            }
            let effectiveScale = pdfView.scaleFactor / max(0.01, fitScale)
            self.parent.onScaleChanged?(effectiveScale)
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
