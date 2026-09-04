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
    @State private var activeSelectionSnapshot: PDFSelectionSnapshot? = nil
    @State private var speechSynthesizer = AVSpeechSynthesizer()

    // Environment & Preferences
    @ObservedObject private var prefs = EBookPreferences.shared
    @AppStorage("activeFilterPreset") private var activeFilterPreset: ReadingFilterPreset = .original
    @Environment(\.modelContext) private var modelContext
    @FocusState private var isReaderFocused: Bool
    @StateObject private var velocityEngine = ReaderVelocityEngine()
    @StateObject private var readingRoom = ReadingRoomSession()
    // ✅ Fix: Inject AppSettingsManager so we can pass pencilOnlyDrawing to PageCanvasOverlay,
    // preventing a silent fatal crash from a missing @EnvironmentObject in PKCanvasRepresentation.
    @EnvironmentObject private var settingsManager: AppSettingsManager

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
    @State private var loadDiagnosticReport: DocumentDiagnosticReport? = nil
    
    // Encrypted / Locked PDF State
    @State private var isDocumentLocked: Bool = false
    @State private var showingPasswordPrompt: Bool = false
    @State private var passwordInput: String = ""
    @State private var passwordErrorMessage: String? = nil
    @State private var pendingLockedDocument: PDFDocument? = nil

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
                        y: mediaBox.minY + (mediaBox.height * insets.top),
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
            lockedPasswordOverlay
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
            isReflowMode = prefs.pdfReflowMode
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
        .onReceive(NotificationCenter.default.publisher(for: .openManualCropEditor)) { _ in
            showCropAdjustmentSheet = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ReaderAdvancePageForward"))) { _ in
            advancePage(forward: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ReaderAdvancePageBackward"))) { _ in
            advancePage(forward: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ReaderToggleMarkupMode"))) { _ in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                isPencilMode.toggle()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ReaderToggleSidebar"))) { _ in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                showingOutlineDrawer.toggle()
            }
        }
        .onChange(of: prefs.pdfReflowMode) { _, enabled in
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                isReflowMode = enabled
            }
        }
        .onChange(of: prefs.defaultCropModeRaw) { _, newMode in
            if newMode == "custom" {
                let insets = CodableCropInsets(
                    top: prefs.defaultCropTop,
                    bottom: prefs.defaultCropBottom,
                    left: prefs.defaultCropLeft,
                    right: prefs.defaultCropRight,
                    modeRaw: "custom"
                )
                applyCropInsets(insets)
            } else if newMode == "smartAuto" {
                applyCropInsets(.smartAuto)
            } else {
                applyCropInsets(.none)
            }
        }
        .onChange(of: prefs.defaultCropTop) { _, _ in
            if prefs.defaultCropModeRaw == "custom" {
                applyCropInsets(CodableCropInsets(top: prefs.defaultCropTop, bottom: prefs.defaultCropBottom, left: prefs.defaultCropLeft, right: prefs.defaultCropRight, modeRaw: "custom"))
            }
        }
        .onChange(of: prefs.defaultCropBottom) { _, _ in
            if prefs.defaultCropModeRaw == "custom" {
                applyCropInsets(CodableCropInsets(top: prefs.defaultCropTop, bottom: prefs.defaultCropBottom, left: prefs.defaultCropLeft, right: prefs.defaultCropRight, modeRaw: "custom"))
            }
        }
        .onChange(of: prefs.defaultCropLeft) { _, _ in
            if prefs.defaultCropModeRaw == "custom" {
                applyCropInsets(CodableCropInsets(top: prefs.defaultCropTop, bottom: prefs.defaultCropBottom, left: prefs.defaultCropLeft, right: prefs.defaultCropRight, modeRaw: "custom"))
            }
        }
        .onChange(of: prefs.defaultCropRight) { _, _ in
            if prefs.defaultCropModeRaw == "custom" {
                applyCropInsets(CodableCropInsets(top: prefs.defaultCropTop, bottom: prefs.defaultCropBottom, left: prefs.defaultCropLeft, right: prefs.defaultCropRight, modeRaw: "custom"))
            }
        }
        .onDisappear {
            saveReadingProgress()
            if let doc = pdfDocument {
                PDFAnnotationSyncBridge.shared.syncStoreToDocument(for: pdf.id, in: doc)
            }
            accessedSecurityScopedURL?.stopAccessingSecurityScopedResource()
            accessedSecurityScopedURL = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            saveReadingProgress()
            if let doc = pdfDocument {
                PDFAnnotationSyncBridge.shared.syncStoreToDocument(for: pdf.id, in: doc)
            }
        }
        .onChange(of: isPencilMode) { _, enabled in
            pdfViewReference?.isInMarkupMode = enabled
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
                onTextSelectionChanged: { text, snapshot in
                    withAnimation(.easeInOut(duration: 0.18)) {
                        selectedTextForHUD = text
                        activeSelectionSnapshot = snapshot
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
            .applyFilterPreset(activeFilterPreset)
            .ignoresSafeArea()

            if isPencilMode {
                PageCanvasOverlay(
                    pdfID: pdf.id,
                    pageIndex: currentPageIndex,
                    isMarkupEnabled: isPencilMode,
                    pencilOnlyDrawing: settingsManager.conversionSettings.pencilOnlyDrawing
                )
                .allowsHitTesting(true)
                .ignoresSafeArea()
            }
        }
    }

    @ViewBuilder private var pdfLoadingView: some View {
        if loadFailed, let report = loadDiagnosticReport {
            DocumentOpenErrorView(
                report: report,
                onRetry: {
                    loadFailed = false
                    loadDiagnosticReport = nil
                    loadPDFDocument()
                },
                onDismiss: {
                    onDismiss()
                }
            )
        } else if loadFailed {
            VStack(spacing: 16) {
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
            }
        } else {
            VStack(spacing: 16) {
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
                        EBookPreferences.shared.defaultHighlightColor = color
                        saveMarkup(text: selectedText, color: color, style: .highlight)
                        selectedTextForHUD = nil
                    },
                    onMarkup: { color, style in
                        EBookPreferences.shared.defaultHighlightColor = color
                        saveMarkup(text: selectedText, color: color, style: style)
                        selectedTextForHUD = nil
                    },
                    onAddNote: { note in
                        saveNote(text: selectedText, note: note, color: EBookPreferences.shared.defaultHighlightColor)
                        selectedTextForHUD = nil
                    },
                    onCopy: {
                        UIPasteboard.general.string = selectedText
                        selectedTextForHUD = nil
                        HapticEngine.selection()
                        showToastMessage("Copied to Clipboard")
                    },
                    onSpeak: { text in
                        speakText(text)
                    },
                    onCreateZettelkastenCard: { text in
                        createZettelkastenCard(text: text)
                        selectedTextForHUD = nil
                    },
                    onAddMarginaliaSymbol: { symbol in
                        saveMarginalia(text: selectedText, symbol: symbol, color: EBookPreferences.shared.defaultHighlightColor)
                        selectedTextForHUD = nil
                    },
                    onDismiss: {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            selectedTextForHUD = nil
                            activeSelectionSnapshot = nil
                        }
                        pdfViewReference?.setCurrentSelection(nil, animate: false)
                    }
                )
                .padding(.bottom, chromeVisible ? 80 : 30)
                .padding(.horizontal, 20)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .zIndex(60)
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

    @ViewBuilder private var lockedPasswordOverlay: some View {
        if isDocumentLocked {
            ZStack {
                Color.black.opacity(0.85)
                    .ignoresSafeArea()

                VStack(spacing: 20) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(LinearGradient(colors: [.inkViolet, .inkOrange], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .shadow(color: .inkViolet.opacity(0.5), radius: 12)

                    VStack(spacing: 6) {
                        Text("Encrypted PDF Document")
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundColor(.white)

                        Text("This document is password protected. Enter the decryption password to read.")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16)
                    }

                    VStack(spacing: 12) {
                        SecureField("Enter Password", text: $passwordInput)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(passwordErrorMessage != nil ? Color.inkRed : Color.white.opacity(0.2), lineWidth: 1)
                            )
                            .onSubmit {
                                attemptUnlockWithPassword(passwordInput)
                            }

                        if let error = passwordErrorMessage {
                            Text(error)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.inkRed)
                                .transition(.opacity)
                        }
                    }
                    .padding(.horizontal, 24)

                    HStack(spacing: 14) {
                        Button {
                            onDismiss()
                        } label: {
                            Text("Cancel")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.white.opacity(0.8))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                        }

                        Button {
                            attemptUnlockWithPassword(passwordInput)
                        } label: {
                            Text("Unlock")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(LinearGradient(colors: [.inkViolet, .inkOrange], startPoint: .leading, endPoint: .trailing), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    .padding(.horizontal, 24)
                }
                .padding(24)
                .frame(maxWidth: 400)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.white.opacity(0.15), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.6), radius: 24, y: 12)
                .padding(.horizontal, 20)
            }
            .transition(.opacity)
            .zIndex(999)
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
            isMarkupActive: isPencilMode,
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
            onMarkupToggle: {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                    isPencilMode.toggle()
                }
                if isPencilMode {
                    showToastMessage("Pencil Markup Active")
                }
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
                if doc.isLocked {
                    await MainActor.run {
                        if let accessed = accessedURL {
                            self.accessedSecurityScopedURL = accessed
                        }
                        self.pendingLockedDocument = doc
                        self.isDocumentLocked = true
                        self.showingPasswordPrompt = true
                        self.loadFailed = false
                    }
                    return
                }
                
                let savedIndex = await MainActor.run {
                    ReaderProgressTracker.shared.progress(for: sourcePDF.id)?.currentPageIndex ?? 0
                }
                await MainActor.run {
                    if let accessed = accessedURL {
                        self.accessedSecurityScopedURL = accessed
                    }
                    self.pdfDocument = doc
                    self.resolvedURL = resolvedURL
                    self.loadFailed = false
                    self.currentPageIndex = max(0, min(savedIndex, doc.pageCount - 1))
                    let savedCrop = ReaderProgressTracker.shared.cropInsets(for: sourcePDF.id)
                    let initialCrop = savedCrop ?? (self.prefs.defaultCropModeRaw == "smartAuto" ? .smartAuto : .none)
                    self.applyCropInsets(initialCrop)
                    self.extractAmbientColor(for: self.currentPageIndex)
                    
                    // Ingest native third-party PDF annotations into AnnotationStore
                    _ = PDFAnnotationSyncBridge.shared.importNativeAnnotations(from: doc, for: sourcePDF.id)
                    // Ingest and render all existing InkSync Pro highlights, notes, and ink from AnnotationStore onto the live document
                    PDFAnnotationSyncBridge.shared.applyStoreAnnotations(for: sourcePDF.id, to: doc)
                }
            } else {
                accessedURL?.stopAccessingSecurityScopedResource()
                let report = DocumentOpenDiagnostics.logFailure(url: resolvedURL, pdf: sourcePDF, error: nil, context: "ProPDFReaderEngine")
                await MainActor.run {
                    self.loadDiagnosticReport = report
                    self.loadFailed = true
                    self.loadErrorMessage = report.rootCauseDescription
                }
            }
        }
    }

    private func attemptUnlockWithPassword(_ pass: String) {
        guard let doc = pendingLockedDocument else { return }
        if doc.unlock(withPassword: pass) || !doc.isLocked {
            HapticEngine.success()
            let savedIndex = ReaderProgressTracker.shared.progress(for: pdf.id)?.currentPageIndex ?? 0
            self.pdfDocument = doc
            self.pendingLockedDocument = nil
            self.isDocumentLocked = false
            self.showingPasswordPrompt = false
            self.loadFailed = false
            self.passwordErrorMessage = nil
            self.currentPageIndex = max(0, min(savedIndex, doc.pageCount - 1))
            let savedCrop = ReaderProgressTracker.shared.cropInsets(for: pdf.id)
            let initialCrop = savedCrop ?? (self.prefs.defaultCropModeRaw == "smartAuto" ? .smartAuto : .none)
            self.applyCropInsets(initialCrop)
            self.extractAmbientColor(for: self.currentPageIndex)
            _ = PDFAnnotationSyncBridge.shared.importNativeAnnotations(from: doc, for: pdf.id)
            PDFAnnotationSyncBridge.shared.applyStoreAnnotations(for: pdf.id, to: doc)
        } else {
            HapticEngine.error()
            self.passwordErrorMessage = "Incorrect password. Please verify and try again."
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
        // Only update the SwiftUI binding. updateUIView() owns the single
        // authoritative call to pdfView.go(to:) via the isNavigatingProgrammatically
        // guard. Calling go(to:) here AND in updateUIView causes a double-navigation
        // race that manifests as every-other-page skipping.
        currentPageIndex = clamped
        saveReadingProgress()
    }

    private func advancePage(forward: Bool) {
        let isManga = isMangaMode || prefs.pdfRTL
        let effectiveForward = isManga ? !forward : forward

        guard let pdfView = pdfViewReference else { return }

        if effectiveForward {
            if pdfView.canGoToNextPage {
                // goToNextPage handles twoUp spread boundaries natively —
                // we never need to manually compute +1 or +2; PDFKit knows.
                pdfView.goToNextPage(nil)
                velocityEngine.recordPageTurn()
                if readingRoom.isHosting {
                    readingRoom.broadcastPage(currentPageIndex, totalPages: max(1, totalPages))
                }
            } else {
                attemptPDFSeriesContinuation()
            }
        } else {
            if pdfView.canGoToPreviousPage {
                pdfView.goToPreviousPage(nil)
                velocityEngine.recordPageTurn()
                if readingRoom.isHosting {
                    readingRoom.broadcastPage(currentPageIndex, totalPages: max(1, totalPages))
                }
            }
        }
        HapticEngine.selection()
    }

    // MARK: - Highlight Annotation Pipeline

    /// Commits a text markup annotation (highlight, underline, strikethrough)
    /// to the underlying PDFPage and persists it in `AnnotationStore`.
    ///
    /// **Three-path resolution strategy** (ordered by reliability):
    /// 1. `activeSelectionSnapshot.lines` — captured at selection time; most accurate.
    /// 2. `pdfView.currentSelection.selectionsByLine()` — fallback if snapshot is nil.
    /// 3. `doc.findString(text)` — last resort text search.
    ///
    /// **No `quadrilateralPoints` are set.** Setting custom quad points that don't
    /// exactly match PDFKit's internal glyph-level geometry produces invisible
    /// annotations. PDFKit derives correct quad points from `bounds` automatically.
    private func saveMarkup(text: String, color: PDFHighlightColor, style: AnnotationMarkupStyle = .highlight) {
        // Build the RGBA UIColor directly — never via hex round-trip which can
        // silently collapse HSL saturation for colors like Emerald or Electric Blue.
        let highlightColor = color.directHighlightUIColor
        var didAddNative = false
        var savedBounds: CodableCGRect? = nil
        var targetPageIndex = currentPageIndex
        let activeDoc = pdfViewReference?.document ?? pdfDocument

        let nativeType: PDFAnnotationSubtype
        let annotationKind: Annotation.AnnotationKind
        let toastTitle: String
        switch style {
        case .underline:
            nativeType = .underline
            annotationKind = .underline
            toastTitle = "Underline Added"
        case .strikeOut:
            nativeType = .strikeOut
            annotationKind = .strikeOut
            toastTitle = "Strikethrough Added"
        case .highlight:
            nativeType = .highlight
            annotationKind = .highlight
            toastTitle = "Highlight Added"
        }

        // CRITICAL: Do NOT clear the selection before adding annotations.
        // PDFKit uses the active selection's glyph map to resolve annotation bounds.

        // ── Path 1: Use pre-captured selection snapshot ───────────────────────────
        if let snapshot = activeSelectionSnapshot {
            targetPageIndex = snapshot.pageIndex
            savedBounds = snapshot.normalizedBounds
            if let doc = activeDoc, let page = doc.page(at: snapshot.pageIndex) {
                let validRects = snapshot.lines.map(\.bounds).filter { $0 != .zero && $0.width > 2 && $0.height > 2 }
                if !validRects.isEmpty {
                    let unionBox = PDFHighlightGeometryHelper.unionBounds(for: validRects)
                    let ann = PDFAnnotation(bounds: unionBox, forType: nativeType, withProperties: nil)
                    ann.color = highlightColor
                    ann.contents = text
                    ann.quadrilateralPoints = PDFHighlightGeometryHelper.createQuadPoints(for: validRects, relativeTo: unionBox)
                    page.addAnnotation(ann)
                    didAddNative = true
                }
            }
        }

        // ── Path 2: Decompose current PDFView selection by line ───────────────────
        if !didAddNative, let pdfView = pdfViewReference, let selection = pdfView.currentSelection {
            for page in selection.pages {
                if let doc = pdfView.document {
                    targetPageIndex = doc.index(for: page)
                }
                let lines = selection.selectionsByLine()
                let targetLines = lines.isEmpty ? [selection] : lines
                let validRects = targetLines.compactMap { $0.bounds(for: page) }.filter { $0 != .zero && $0.width > 2 && $0.height > 2 }
                guard !validRects.isEmpty else { continue }
                
                let unionBox = PDFHighlightGeometryHelper.unionBounds(for: validRects)
                let pageBounds = page.bounds(for: .cropBox)
                if pageBounds.width > 0, pageBounds.height > 0, savedBounds == nil {
                    savedBounds = CodableCGRect(
                        x: Double((unionBox.minX - pageBounds.minX) / pageBounds.width),
                        y: Double((unionBox.minY - pageBounds.minY) / pageBounds.height),
                        width: Double(unionBox.width / pageBounds.width),
                        height: Double(unionBox.height / pageBounds.height)
                    )
                }
                let ann = PDFAnnotation(bounds: unionBox, forType: nativeType, withProperties: nil)
                ann.color = highlightColor
                ann.contents = text
                ann.quadrilateralPoints = PDFHighlightGeometryHelper.createQuadPoints(for: validRects, relativeTo: unionBox)
                page.addAnnotation(ann)
                didAddNative = true
            }
        }

        // ── Path 3: Text-search fallback ──────────────────────────────────────────
        if !didAddNative, let doc = activeDoc, let page = doc.page(at: targetPageIndex) {
            let matches = doc.findString(text, withOptions: .caseInsensitive)
            for match in matches where match.pages.contains(page) {
                let lines = match.selectionsByLine()
                let targetLines = lines.isEmpty ? [match] : lines
                let validRects = targetLines.compactMap { $0.bounds(for: page) }.filter { $0 != .zero && $0.width > 2 && $0.height > 2 }
                guard !validRects.isEmpty else { continue }
                
                let unionBox = PDFHighlightGeometryHelper.unionBounds(for: validRects)
                let pageBounds = page.bounds(for: .cropBox)
                if pageBounds.width > 0, pageBounds.height > 0, savedBounds == nil {
                    savedBounds = CodableCGRect(
                        x: Double((unionBox.minX - pageBounds.minX) / pageBounds.width),
                        y: Double((unionBox.minY - pageBounds.minY) / pageBounds.height),
                        width: Double(unionBox.width / pageBounds.width),
                        height: Double(unionBox.height / pageBounds.height)
                    )
                }
                let ann = PDFAnnotation(bounds: unionBox, forType: nativeType, withProperties: nil)
                ann.color = highlightColor
                ann.contents = text
                ann.quadrilateralPoints = PDFHighlightGeometryHelper.createQuadPoints(for: validRects, relativeTo: unionBox)
                page.addAnnotation(ann)
                didAddNative = true
                break
            }
        }

        // ── Path 4: Fallback to savedBounds bounding box ─────────────────────────
        if !didAddNative, let doc = activeDoc, let page = doc.page(at: targetPageIndex), let b = savedBounds {
            let pageBounds = page.bounds(for: .cropBox)
            let rect = CGRect(
                x: pageBounds.minX + (b.x * pageBounds.width),
                y: pageBounds.minY + (b.y * pageBounds.height),
                width: b.width * pageBounds.width,
                height: b.height * pageBounds.height
            )
            if rect.width > 2 && rect.height > 2 {
                let ann = PDFAnnotation(bounds: rect, forType: nativeType, withProperties: nil)
                ann.color = highlightColor
                ann.contents = text
                ann.quadrilateralPoints = PDFHighlightGeometryHelper.createQuadPoints(for: rect)
                page.addAnnotation(ann)
                didAddNative = true
            }
        }

        // ── NOW clear selection and force repaint (after annotations are committed) ─
        if let pv = pdfViewReference {
            pv.setCurrentSelection(nil, animate: false)
            forcePageRedraw(pv, pageIndex: targetPageIndex)
        }

        // ── Persist to AnnotationStore and sync to disk ───────────────────────────
        let highlight = Annotation(
            pdfID: pdf.id,
            pageIndex: targetPageIndex,
            chapterTitle: "Page \(targetPageIndex + 1)",
            kind: annotationKind,
            createdAt: Date(),
            modifiedAt: Date(),
            colorHex: color.rawValue,
            selectedText: text,
            bounds: savedBounds
        )
        AnnotationStore.shared.add(highlight)
        if let doc = activeDoc {
            PDFAnnotationSyncBridge.shared.syncStoreToDocument(for: pdf.id, in: doc, at: resolvedURL)
        }
        activeSelectionSnapshot = nil
        showToastMessage(toastTitle)
        HapticEngine.selection()
    }

    private func saveHighlight(text: String, color: PDFHighlightColor) {
        saveMarkup(text: text, color: color, style: .highlight)
    }

    /// Forces PDFView to repaint annotation tiles on the target page immediately.
    /// NOTE: We deliberately do NOT call go(to:) here — that fires PDFViewPageChanged
    /// outside of our isNavigatingProgrammatically guard and causes page-jump feedback loops.
    private func forcePageRedraw(_ pdfView: PDFView, pageIndex: Int) {
        pdfView.layoutDocumentView()
        pdfView.setNeedsDisplay()
        if let docView = pdfView.documentView {
            docView.setNeedsLayout()
            docView.layoutIfNeeded()
            docView.setNeedsDisplay()
            for pageView in docView.subviews {
                pageView.setNeedsDisplay()
                pageView.layer.setNeedsDisplay()
                for tile in pageView.subviews {
                    tile.setNeedsDisplay()
                    tile.layer.setNeedsDisplay()
                }
            }
        }
        for sv in pdfView.subviews {
            sv.setNeedsDisplay()
            for inner in sv.subviews {
                inner.setNeedsDisplay()
                inner.layer.setNeedsDisplay()
            }
        }
    }

    private func saveNote(text: String, note: String, color: PDFHighlightColor = EBookPreferences.shared.defaultHighlightColor) {
        let noteAnn = Annotation(
            pdfID: pdf.id,
            pageIndex: currentPageIndex,
            chapterTitle: "Page \(currentPageIndex + 1)",
            kind: .note,
            createdAt: Date(),
            modifiedAt: Date(),
            colorHex: color.rawValue,
            selectedText: text,
            noteText: note
        )
        AnnotationStore.shared.add(noteAnn)
        if let doc = pdfDocument {
            PDFAnnotationSyncBridge.shared.syncStoreToDocument(for: pdf.id, in: doc, at: resolvedURL)
        }
    }

    private func saveMarginalia(text: String, symbol: String, color: PDFHighlightColor = EBookPreferences.shared.defaultHighlightColor) {
        var ann = Annotation(
            pdfID: pdf.id,
            pageIndex: currentPageIndex,
            chapterTitle: "Page \(currentPageIndex + 1)",
            kind: .highlight,
            createdAt: Date(),
            modifiedAt: Date(),
            colorHex: color.rawValue,
            selectedText: text,
            noteText: "Marginalia Symbol: \(symbol)"
        )
        ann.marginaliaSymbolRaw = symbol
        AnnotationStore.shared.add(ann)
        if let doc = pdfDocument {
            PDFAnnotationSyncBridge.shared.syncStoreToDocument(for: pdf.id, in: doc, at: resolvedURL)
        }
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

// MARK: - PDF Selection Snapshot Model
struct PDFSelectionLine: Sendable {
    let bounds: CGRect
    let quadPoints: [CGPoint]
}

struct PDFSelectionSnapshot: Sendable {
    let text: String
    let pageIndex: Int
    let lines: [PDFSelectionLine]
    let normalizedBounds: CodableCGRect?
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
    var onTextSelectionChanged: (String?, PDFSelectionSnapshot?) -> Void
    var onScaleChanged: ((CGFloat) -> Void)? = nil
    var onHyperlinkSelected: ((Int, PDFPage) -> Void)? = nil

    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.delegate = context.coordinator
        // Horizontal paging feels most natural for a reader app on iOS
        pdfView.displayDirection = .horizontal
        pdfView.pageShadowsEnabled = true
        pdfView.backgroundColor = .clear
        pdfView.isOpaque = false

        let prefs = EBookPreferences.shared
        let isLandscape = UIScreen.main.bounds.width > UIScreen.main.bounds.height
        let isDual = prefs.pdfDualPage || (prefs.autoLandscapeDualPage && isLandscape)

        // Use singlePage (non-continuous) as the default mode so PDFViewPageChanged fires
        // reliably on every page turn. singlePageContinuous only fires on visible-page
        // threshold crossings which can miss pages when scrolling quickly.
        pdfView.usePageViewController(false)
        pdfView.displayMode = isDual ? .twoUp : .singlePage
        pdfView.displaysAsBook = isDual

        let margin = max(0, prefs.textMargin)
        pdfView.pageBreakMargins = UIEdgeInsets(top: 0, left: margin, bottom: 0, right: margin)

        // Assign document AFTER display configuration so PDFKit lays out correctly
        pdfView.document = document
        pdfView.autoScales = true
        pdfView.minScaleFactor = 0.25
        pdfView.maxScaleFactor = 8.0

        // ── Tap gesture (finger only) ──────────────────────────────────────────────
        // Restricted to .direct so Apple Pencil strokes never trigger page turns.
        let tapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tapGesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        tapGesture.cancelsTouchesInView = false
        pdfView.addGestureRecognizer(tapGesture)

        // ── Double-tap zoom (finger only) ─────────────────────────────────────────
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        doubleTap.cancelsTouchesInView = false
        pdfView.addGestureRecognizer(doubleTap)
        // Single-tap must wait for double-tap to fail — standard iOS pattern
        tapGesture.require(toFail: doubleTap)

        // ── Glide (word-snap) highlight gesture (finger and Apple Pencil) ────────
        // Allows both direct finger touches and Apple Pencil to perform fluid word-snapping
        // text selection and trigger the highlight HUD. When markup mode or auto-draw is active,
        // Apple Pencil strokes are intercepted by PageCanvasOverlay for smooth inking.
        let glideRecognizer = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleGlideSelection(_:)))
        glideRecognizer.minimumPressDuration = 0.18
        glideRecognizer.allowableMovement = 2000
        glideRecognizer.cancelsTouchesInView = false
        glideRecognizer.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue),
            NSNumber(value: UITouch.TouchType.pencil.rawValue)
        ]
        glideRecognizer.delegate = context.coordinator
        pdfView.addGestureRecognizer(glideRecognizer)
        // CRITICAL: Single-tap must wait for glide selection to fail.
        // Without this, lifting a finger from a word selection recognizes a tap
        // and immediately clears the selection before the user can tap Highlight.
        tapGesture.require(toFail: glideRecognizer)

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

            let fitScale = uiView.scaleFactorForSizeToFit
            if fitScale > 0.001 {
                uiView.minScaleFactor = fitScale
                uiView.maxScaleFactor = fitScale * 8.0
                if let sv = uiView.subviews.first(where: { $0 is UIScrollView }) as? UIScrollView {
                    sv.minimumZoomScale = fitScale
                    sv.maximumZoomScale = fitScale * 8.0
                }
            }

            if isExpandedView {
                let targetScale = max((fitScale > 0 ? fitScale : 1.0) * 1.35, 1.0)
                if abs(uiView.scaleFactor - targetScale) > 0.05 {
                    uiView.scaleFactor = targetScale
                }
            } else if context.coordinator.userCustomZoomScale == nil {
                if fitScale > 0.001 && abs(uiView.scaleFactor - fitScale) > fitScale * 0.05 {
                    uiView.scaleFactor = fitScale
                }
            }
        }

        context.coordinator.lastBoundsSize = uiView.bounds.size

        // ── Page navigation guard ─────────────────────────────────────────────────
        // Only call go(to:) when the index change originated from our code (bookmark
        // jump, scrubber, keyboard), NOT when it was already triggered by the user
        // scrolling (PDFViewPageChanged notification). Calling go(to:) in response to
        // a scroll notification creates a feedback loop that causes pages to be skipped.
        guard !context.coordinator.isNavigatingProgrammatically else { return }

        if let targetPage = document.page(at: currentPageIndex),
           uiView.currentPage != targetPage,
           context.coordinator.lastTargetPageIndex != currentPageIndex {
            context.coordinator.lastTargetPageIndex = currentPageIndex
            context.coordinator.isNavigatingProgrammatically = true
            uiView.go(to: targetPage)
            // Clear flag after RunLoop cycle so the resulting PDFViewPageChanged
            // notification (triggered by go(to:)) is correctly ignored.
            DispatchQueue.main.async {
                context.coordinator.isNavigatingProgrammatically = false
            }
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

    class Coordinator: NSObject, PDFViewDelegate, UIGestureRecognizerDelegate {
        var parent: ProPDFViewRepresentable
        var lastCropMode: Bool = false
        var lastTextMargin: CGFloat = -1
        var lastPageIndex: Int = -1
        var lastTargetPageIndex: Int = -1
        var lastBoundsSize: CGSize = .zero
        var userCustomZoomScale: CGFloat? = nil

        // Prevents updateUIView.go(to:) from re-triggering when PDFViewPageChanged fires
        // after a programmatic navigation call. Without this flag, the two fight each
        // other and pages get skipped or stuck.
        var isNavigatingProgrammatically: Bool = false

        // Fluid Word-Snapping Glide Selection Session Tracking
        private var glideStartPoint: CGPoint? = nil
        private var glideStartPage: PDFPage? = nil
        private var glideStartWord: PDFSelection? = nil
        private var lastGlideWordCount: Int = 0

        init(_ parent: ProPDFViewRepresentable) {
            self.parent = parent
        }

        /// Proximity-assisted word snapping so finger and Apple Pencil touches
        /// snap cleanly to words even when landing slightly between lines or on margins.
        private func findWordSelection(at point: CGPoint, on page: PDFPage) -> (word: PDFSelection, point: CGPoint)? {
            if let word = page.selectionForWord(at: point),
               let str = word.string, !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return (word, point)
            }
            if let charSel = page.selection(from: point, to: point),
               let str = charSel.string, !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return (charSel, point)
            }
            
            let yDeltas: [CGFloat] = [-8, 8, -16, 16, -24, 24]
            let xDeltas: [CGFloat] = [0, -12, 12, -24, 24]
            
            for dy in yDeltas {
                for dx in xDeltas {
                    let probe = CGPoint(x: point.x + dx, y: point.y + dy)
                    if let word = page.selectionForWord(at: probe),
                       let str = word.string, !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return (word, probe)
                    }
                }
            }
            return nil
        }

        // MARK: - Fluid Word-Snapping Glide Selection
        @MainActor @objc func handleGlideSelection(_ gesture: UILongPressGestureRecognizer) {
            guard let pdfView = gesture.view as? PDFView else { return }
            let locationInView = gesture.location(in: pdfView)

            switch gesture.state {
            case .began:
                guard let page = pdfView.page(for: locationInView, nearest: true) else { return }
                let locationInPage = pdfView.convert(locationInView, to: page)
                
                if let match = findWordSelection(at: locationInPage, on: page) {
                    glideStartPoint = match.point
                    glideStartPage = page
                    glideStartWord = match.word
                    lastGlideWordCount = 1
                    pdfView.setCurrentSelection(match.word, animate: false)
                    HapticEngine.selection()
                } else {
                    glideStartPoint = nil
                    glideStartPage = nil
                    glideStartWord = nil
                }

            case .changed:
                guard let startPoint = glideStartPoint,
                      let startPage = glideStartPage,
                      let currentTargetPage = pdfView.page(for: locationInView, nearest: true),
                      currentTargetPage == startPage else { return }
                
                let rawPointInPage = pdfView.convert(locationInView, to: startPage)
                let currentPointInPage = findWordSelection(at: rawPointInPage, on: startPage)?.point ?? rawPointInPage
                
                if let rangeSelection = startPage.selection(from: startPoint, to: currentPointInPage) {
                    if let endWord = startPage.selectionForWord(at: currentPointInPage) {
                        rangeSelection.add(endWord)
                    }
                    if let startWord = glideStartWord {
                        rangeSelection.add(startWord)
                    }
                    
                    let words = rangeSelection.string?.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }).count ?? 0
                    if words != lastGlideWordCount && words > 0 {
                        lastGlideWordCount = words
                        HapticEngine.selection()
                    }
                    
                    pdfView.setCurrentSelection(rangeSelection, animate: false)
                }

            case .ended:
                if let selection = pdfView.currentSelection, let text = selection.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    selectionChanged(Notification(name: .PDFViewSelectionChanged, object: pdfView))
                    HapticEngine.light()
                }
                glideStartPoint = nil
                glideStartPage = nil
                glideStartWord = nil
                lastGlideWordCount = 0

            case .cancelled, .failed:
                glideStartPoint = nil
                glideStartPage = nil
                glideStartWord = nil
                lastGlideWordCount = 0

            default:
                break
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            return true
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

            // If text is currently selected in PDFView, clear selection on single tap OUTSIDE the selection
            if let selection = view.currentSelection, let text = selection.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let tapLocation = gesture.location(in: view)
                if let page = view.page(for: tapLocation, nearest: false) {
                    let pagePoint = view.convert(tapLocation, to: page)
                    let selectionBounds = selection.bounds(for: page)
                    // If tap is inside or directly adjoining the active selection, do not clear it
                    if selectionBounds.insetBy(dx: -16, dy: -16).contains(pagePoint) {
                        return
                    }
                }
                view.clearSelection()
                parent.onTextSelectionChanged(nil, nil)
                return
            }

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
            // If we triggered this notification ourselves via go(to:), ignore it —
            // the binding is already set to the correct index.
            guard !isNavigatingProgrammatically else { return }
            guard let pdfView = notification.object as? PDFView,
                  let page = pdfView.currentPage,
                  let doc = pdfView.document else { return }
            let idx = doc.index(for: page)
            guard idx >= 0, idx < doc.pageCount else { return }
            if self.parent.currentPageIndex != idx {
                self.lastTargetPageIndex = idx
                self.parent.currentPageIndex = idx
            }
        }

        @MainActor @objc func selectionChanged(_ notification: Notification) {
            guard let pdfView = notification.object as? PDFView else { return }
            if let selection = pdfView.currentSelection, let text = selection.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                var linesInfo: [PDFSelectionLine] = []
                var pageIndex = parent.currentPageIndex
                var normBounds: CodableCGRect? = nil
                
                if let firstPage = selection.pages.first, let doc = pdfView.document {
                    pageIndex = doc.index(for: firstPage)
                    let pageBounds = firstPage.bounds(for: .cropBox)
                    let lineSelections = selection.selectionsByLine()
                    let targetLines = lineSelections.isEmpty ? [selection] : lineSelections
                    var validRects: [CGRect] = []
                    for lineSel in targetLines {
                        let lineBounds = lineSel.bounds(for: firstPage)
                        guard lineBounds != .zero, lineBounds.width > 2, lineBounds.height > 2 else { continue }
                        validRects.append(lineBounds)
                        linesInfo.append(PDFSelectionLine(bounds: lineBounds, quadPoints: []))
                    }
                    let unionBox = PDFHighlightGeometryHelper.unionBounds(for: validRects)
                    let targetBounds = !validRects.isEmpty ? unionBox : selection.bounds(for: firstPage)
                    if pageBounds.width > 0 && pageBounds.height > 0 {
                        normBounds = CodableCGRect(
                            x: Double((targetBounds.minX - pageBounds.minX) / pageBounds.width),
                            y: Double((targetBounds.minY - pageBounds.minY) / pageBounds.height),
                            width: Double(targetBounds.width / pageBounds.width),
                            height: Double(targetBounds.height / pageBounds.height)
                        )
                    }
                }
                let snapshot = PDFSelectionSnapshot(
                    text: text,
                    pageIndex: pageIndex,
                    lines: linesInfo,
                    normalizedBounds: normBounds
                )
                parent.onTextSelectionChanged(text, snapshot)
            } else {
                parent.onTextSelectionChanged(nil, nil)
            }
        }
    }
}
