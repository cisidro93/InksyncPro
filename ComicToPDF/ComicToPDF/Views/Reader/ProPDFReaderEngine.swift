import SwiftUI
import SwiftData
import Foundation
import Combine
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
    @State private var activeTappedAnnotationID: UUID? = nil
    @State private var activeTappedAnnotation: PDFAnnotation? = nil
    @State private var activeTappedAnnotationBounds: CGRect? = nil
    @State private var speechSynthesizer = AVSpeechSynthesizer()

    // Environment & Preferences
    @ObservedObject private var prefs = EBookPreferences.shared
    @ObservedObject private var inkingState = InksyncInkingState.shared
    @AppStorage("activeFilterPreset") private var activeFilterPreset: ReadingFilterPreset = .original
    @Environment(\.modelContext) private var modelContext
    @FocusState private var isReaderFocused: Bool
    @StateObject private var velocityEngine = ReaderVelocityEngine()
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
    @State private var articleColumnStep: Int = 0
    @State private var isNarratingPDF: Bool = false
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

    // Undo / Redo Markup Action History
    struct MarkupHistoryItem: Sendable {
        let id: UUID
        let pageIndex: Int
        let text: String
        let color: PDFHighlightColor
        let style: AnnotationMarkupStyle
    }
    @State private var recentMarkupHistory: [MarkupHistoryItem] = []
    @State private var undoneMarkupHistory: [MarkupHistoryItem] = []

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
        ReaderProgressTracker.shared.saveCropInsets(insets, for: pdf.id)
        if prefs.defaultCropModeRaw != insets.modeRaw {
            prefs.defaultCropModeRaw = insets.modeRaw
        }

        if insets.modeRaw == "none" {
            isCroppedMode = false
            if let pv = pdfViewReference {
                pv.displayBox = .mediaBox
                pv.autoScales = true
                pv.layoutDocumentView()
            }
            return
        } else if insets.modeRaw == "smartAuto" {
            isCroppedMode = true

            // KOReader / k2pdfopt Parity: Document-Wide Uniform Content Bounds
            // Sample representative pages across the document to compute the composite content box.
            let total = doc.pageCount
            let sampleCount = min(25, total)
            let step = max(1, total / sampleCount)

            var sampledLeftMargins: [CGFloat] = []
            var sampledRightMargins: [CGFloat] = []
            var sampledTopMargins: [CGFloat] = []
            var sampledBottomMargins: [CGFloat] = []

            for idx in stride(from: 0, to: total, by: step) {
                guard let page = doc.page(at: idx) else { continue }
                let mediaBox = page.bounds(for: .mediaBox)
                guard mediaBox.width > 50 && mediaBox.height > 50 else { continue }

                // If page has digital text layer, extract text bounding rect directly
                if let selection = page.selection(for: mediaBox) {
                    let textRect = selection.bounds(for: page)
                    if textRect.width > 20 && textRect.height > 20 {
                        let leftRatio = max(0, (textRect.minX - mediaBox.minX) / mediaBox.width)
                        let rightRatio = max(0, (mediaBox.maxX - textRect.maxX) / mediaBox.width)
                        let bottomRatio = max(0, (textRect.minY - mediaBox.minY) / mediaBox.height)
                        let topRatio = max(0, (mediaBox.maxY - textRect.maxY) / mediaBox.height)

                        sampledLeftMargins.append(leftRatio)
                        sampledRightMargins.append(rightRatio)
                        sampledBottomMargins.append(bottomRatio)
                        sampledTopMargins.append(topRatio)
                    }
                }
            }

            // Baseline sensitivity fallback if document has few or no digital text layers (scanned books)
            let baseSensitivity = max(0.03, min(0.09, prefs.autoCropSensitivity * 0.40))

            // Calculate safe minimal margins across all sampled pages with a protective 12pt cushion
            let safeLeftMargin: CGFloat
            let safeRightMargin: CGFloat
            let safeTopMargin: CGFloat
            let safeBottomMargin: CGFloat

            if !sampledLeftMargins.isEmpty {
                // Use the minimum margin found across all pages so NO text is ever clipped on ANY page.
                let rawMinLeft = max(0.01, (sampledLeftMargins.min() ?? baseSensitivity) - 0.02)
                let rawMinRight = max(0.01, (sampledRightMargins.min() ?? baseSensitivity) - 0.02)
                let rawMinTop = max(0.01, (sampledTopMargins.min() ?? baseSensitivity) - 0.02)
                let rawMinBottom = max(0.01, (sampledBottomMargins.min() ?? baseSensitivity) - 0.02)

                // Symmetrical horizontal margin ensures identical aspect ratio and stationary baseline across flips
                let horiz = min(rawMinLeft, rawMinRight)
                safeLeftMargin = min(0.18, max(baseSensitivity, horiz))
                safeRightMargin = safeLeftMargin
                safeTopMargin = min(0.15, max(baseSensitivity, rawMinTop))
                safeBottomMargin = min(0.15, max(baseSensitivity, rawMinBottom))
            } else {
                safeLeftMargin = baseSensitivity
                safeRightMargin = baseSensitivity
                safeTopMargin = baseSensitivity
                safeBottomMargin = baseSensitivity
            }

            // 1. Immediately apply to visible window (current page +- 8) for zero UI lag (<20ms)
            let curPage = currentPageIndex
            let visibleStart = max(0, curPage - 8)
            let visibleEnd = min(total - 1, curPage + 8)
            let isOddEven = prefs.isOddEvenCropEnabled
            let gutterOffset = isOddEven ? prefs.evenPageGutterOffset : 0.0

            if total > 0 {
                for i in visibleStart...visibleEnd {
                    if let page = doc.page(at: i) {
                        let mediaBox = page.bounds(for: .mediaBox)
                        let isEven = (i % 2 == 1) // 0-indexed page index (1-indexed: 2, 4, 6... is even)
                        let leftOffset = isEven ? safeLeftMargin : (safeLeftMargin + gutterOffset)
                        let rightOffset = isEven ? (safeRightMargin + gutterOffset) : safeRightMargin
                        let uniformCrop = CGRect(
                            x: mediaBox.minX + (mediaBox.width * leftOffset),
                            y: mediaBox.minY + (mediaBox.height * safeBottomMargin),
                            width: max(10, mediaBox.width * (1.0 - leftOffset - rightOffset)),
                            height: max(10, mediaBox.height * (1.0 - safeTopMargin - safeBottomMargin))
                        )
                        page.setBounds(uniformCrop, for: .cropBox)
                    }
                }
            }

            if let pv = pdfViewReference {
                pv.displayBox = .cropBox
                pv.autoScales = true
                pv.layoutDocumentView()
            }

            // 2. Offload remaining pages asynchronously so 1400-page books never stutter the main thread
            if total > 0 {
                Task { @MainActor in
                    for i in 0..<total {
                        if i >= visibleStart && i <= visibleEnd { continue }
                        if let page = doc.page(at: i) {
                            let mediaBox = page.bounds(for: .mediaBox)
                            let isEven = (i % 2 == 1)
                            let leftOffset = isEven ? safeLeftMargin : (safeLeftMargin + gutterOffset)
                            let rightOffset = isEven ? (safeRightMargin + gutterOffset) : safeRightMargin
                            let uniformCrop = CGRect(
                                x: mediaBox.minX + (mediaBox.width * leftOffset),
                                y: mediaBox.minY + (mediaBox.height * safeBottomMargin),
                                width: max(10, mediaBox.width * (1.0 - leftOffset - rightOffset)),
                                height: max(10, mediaBox.height * (1.0 - safeTopMargin - safeBottomMargin))
                            )
                            page.setBounds(uniformCrop, for: .cropBox)
                        }
                    }
                }
            }
        } else {
            // Custom Pro Crop Insets applied immediately to visible window, then asynchronously across remaining
            isCroppedMode = true
            let total = doc.pageCount
            let curPage = currentPageIndex
            let visibleStart = max(0, curPage - 8)
            let visibleEnd = min(total - 1, curPage + 8)
            let isOddEven = prefs.isOddEvenCropEnabled
            let gutterOffset = isOddEven ? prefs.evenPageGutterOffset : 0.0

            if total > 0 {
                for i in visibleStart...visibleEnd {
                    if let page = doc.page(at: i) {
                        let mediaBox = page.bounds(for: .mediaBox)
                        let isEven = (i % 2 == 1)
                        let leftOffset = isEven ? insets.left : (insets.left + gutterOffset)
                        let rightOffset = isEven ? (insets.right + gutterOffset) : insets.right
                        let croppedRect = CGRect(
                            x: mediaBox.minX + (mediaBox.width * leftOffset),
                            y: mediaBox.minY + (mediaBox.height * insets.top),
                            width: max(10, mediaBox.width * (1.0 - leftOffset - rightOffset)),
                            height: max(10, mediaBox.height * (1.0 - insets.top - insets.bottom))
                        )
                        page.setBounds(croppedRect, for: .cropBox)
                    }
                }
            }
            if let pv = pdfViewReference {
                pv.displayBox = .cropBox
                pv.autoScales = true
                pv.layoutDocumentView()
            }
            if total > 0 {
                Task { @MainActor in
                    for i in 0..<total {
                        if i >= visibleStart && i <= visibleEnd { continue }
                        if let page = doc.page(at: i) {
                            let mediaBox = page.bounds(for: .mediaBox)
                            let isEven = (i % 2 == 1)
                            let leftOffset = isEven ? insets.left : (insets.left + gutterOffset)
                            let rightOffset = isEven ? (insets.right + gutterOffset) : insets.right
                            let croppedRect = CGRect(
                                x: mediaBox.minX + (mediaBox.width * leftOffset),
                                y: mediaBox.minY + (mediaBox.height * insets.top),
                                width: max(10, mediaBox.width * (1.0 - leftOffset - rightOffset)),
                                height: max(10, mediaBox.height * (1.0 - insets.top - insets.bottom))
                            )
                            page.setBounds(croppedRect, for: .cropBox)
                        }
                    }
                }
            }
        }
    }

    private func reapplyCurrentCropMode() {
        if prefs.defaultCropModeRaw == "smartAuto" {
            applyCropInsets(CodableCropInsets.smartAuto)
        } else if prefs.defaultCropModeRaw == "custom" {
            let insets = CodableCropInsets(
                top: prefs.defaultCropTop,
                bottom: prefs.defaultCropBottom,
                left: prefs.defaultCropLeft,
                right: prefs.defaultCropRight,
                modeRaw: "custom"
            )
            applyCropInsets(insets)
        } else {
            applyCropInsets(CodableCropInsets.none)
        }
    }

    private func handleCropModeChange(_ newMode: String) {
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
            applyCropInsets(CodableCropInsets.smartAuto)
        } else {
            applyCropInsets(CodableCropInsets.none)
        }
    }

    private func handleCustomCropInsetsChange() {
        guard prefs.defaultCropModeRaw == "custom" else { return }
        let insets = CodableCropInsets(
            top: prefs.defaultCropTop,
            bottom: prefs.defaultCropBottom,
            left: prefs.defaultCropLeft,
            right: prefs.defaultCropRight,
            modeRaw: "custom"
        )
        applyCropInsets(insets)
    }

    private func handleOddEvenCropChange() {
        if prefs.defaultCropModeRaw == "smartAuto" || prefs.defaultCropModeRaw == "custom" {
            reapplyCurrentCropMode()
        }
    }

    private func handleGutterOffsetChange() {
        guard prefs.isOddEvenCropEnabled else { return }
        reapplyCurrentCropMode()
    }

    // MARK: - Reader View Composition & Sub-Expressions

    @ViewBuilder private var baseReaderStack: some View {
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
                .allowsHitTesting(!isPencilMode)

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

            if !chromeVisible && selectedTextForHUD == nil {
                KindleProgressFooterView(
                    currentPage: currentPageIndex + 1,
                    totalPages: max(1, totalPages),
                    estimatedMinutesLeft: ReaderProgressTracker.shared.progress(for: pdf.id)?.estimatedMinutesRemaining
                )
                .transition(.opacity)
            }

            toastAlertOverlay
            pdfNarrationHUD
            ReadingJumpToastOverlay()
            lockedPasswordOverlay

            if prefs.showReadingRuler {
                ReadingRulerOverlay()
            }
        }
    }

    private func handleDisappear() {
        saveReadingProgress()
        if let doc = pdfDocument {
            PDFAnnotationSyncBridge.shared.syncStoreToDocument(for: pdf.id, in: doc, at: resolvedURL)
        }
        loadTask?.cancel()
        zoomPillTask?.cancel()
        chromeIdleTask?.cancel()
        ambientColorTask?.cancel()
        speechSynthesizer.stopSpeaking(at: .immediate)
        pdfViewReference?.document = nil
        pdfViewReference = nil
        accessedSecurityScopedURL?.stopAccessingSecurityScopedResource()
        accessedSecurityScopedURL = nil
    }

    private func handleAnnotationsDidChange(_ notif: Notification) {
        guard let targetPDFID = notif.userInfo?["pdfID"] as? UUID, targetPDFID == pdf.id else { return }
        // Batch import from native PDF annotations shouldn't trigger re-application of annotations to the PDFDocument (they are already in the document!)
        if let isBatch = notif.userInfo?["isBatchImport"] as? Bool, isBatch { return }
        if let deletedID = notif.userInfo?["deletedID"] as? UUID {
            // Safely detach from native PDF document without re-invoking store.delete
            if let doc = pdfDocument {
                PDFAnnotationSyncBridge.shared.removeAnnotation(id: deletedID, from: doc, destinationURL: resolvedURL)
                if let pv = pdfViewReference {
                    forcePageRedraw(pv, pageIndex: currentPageIndex)
                }
            }
        } else if let doc = pdfDocument {
            PDFAnnotationSyncBridge.shared.applyStoreAnnotations(for: pdf.id, to: doc)
            if let pv = pdfViewReference {
                forcePageRedraw(pv, pageIndex: currentPageIndex)
            }
        }
    }

    @ViewBuilder
    private func applyKeyboardShortcuts<Content: View>(to content: Content) -> some View {
        content
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
            .onKeyPress(KeyEquivalent("p")) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                    isPencilMode.toggle()
                    if isPencilMode {
                        InksyncInkingState.shared.activeToolMode = .write
                    }
                }
                return .handled
            }
            .onKeyPress(characters: CharacterSet(charactersIn: "zZ"), phases: .down) { press in
                if press.modifiers.contains(.command) {
                    if press.modifiers.contains(.shift) {
                        performRedo()
                    } else {
                        performUndo()
                    }
                    return .handled
                }
                return .ignored
            }
    }

    @ViewBuilder
    private func applyCropObservers<Content: View>(to content: Content) -> some View {
        content
            .onChange(of: currentPageIndex) { _, newIndex in
                saveReadingProgress()
                extractAmbientColor(for: newIndex)
            }
            .onChange(of: prefs.pdfReflowMode) { _, enabled in
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isReflowMode = enabled
                }
            }
            .onChange(of: prefs.defaultCropModeRaw) { _, newMode in
                handleCropModeChange(newMode)
            }
            .onChange(of: prefs.defaultCropTop) { _, _ in
                handleCustomCropInsetsChange()
            }
            .onChange(of: prefs.defaultCropBottom) { _, _ in
                handleCustomCropInsetsChange()
            }
            .onChange(of: prefs.defaultCropLeft) { _, _ in
                handleCustomCropInsetsChange()
            }
            .onChange(of: prefs.defaultCropRight) { _, _ in
                handleCustomCropInsetsChange()
            }
            .onChange(of: prefs.isOddEvenCropEnabled) { _, _ in
                handleOddEvenCropChange()
            }
            .onChange(of: prefs.evenPageGutterOffset) { _, _ in
                handleGutterOffsetChange()
            }
    }

    @ViewBuilder
    private func applySheets<Content: View>(to content: Content) -> some View {
        content
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
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showingInspector) {
                ProDocumentInspectorView(
                    pdf: pdf,
                    pdfDocument: pdfDocument,
                    currentPageIndex: currentPageIndex,
                    onJumpToPage: { pageIdx in
                        jumpToPage(pageIdx)
                    },
                    onDeleteAnnotation: { ann in
                        removeAnnotation(id: ann.id, pageIndex: ann.pageIndex)
                    },
                    onDismiss: {
                        showingInspector = false
                    }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
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
                    },
                    onDocumentModified: {
                        handleDocumentModified()
                    }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showingSettings) {
                EBookSettingsPanel(bookID: pdf.id.uuidString, isPDF: true)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
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
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
    }

    @ViewBuilder
    private func applyNotificationHandlers<Content: View>(to content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                // Hardware & Battery Defense: Purge off-screen caches and clear selection on low memory
                selectedTextForHUD = nil
                activeSelectionSnapshot = nil
                ambientColorTask?.cancel()
                ambientPageColor = .clear
                pdfViewReference?.clearSelection()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
                // Suspend narration and release transient UI resources when entering background
                if isNarratingPDF {
                    speechSynthesizer.pauseSpeaking(at: .word)
                }
                selectedTextForHUD = nil
                activeSelectionSnapshot = nil
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                saveReadingProgress()
                if let doc = pdfDocument {
                    PDFAnnotationSyncBridge.shared.syncStoreToDocument(for: pdf.id, in: doc, at: resolvedURL)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .readerJumpToPage)) { notification in
                if let pageIndex = notification.userInfo?["pageIndex"] as? Int, pageIndex >= 0, pageIndex < totalPages {
                    jumpToPage(pageIndex)
                }
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
                    if isPencilMode {
                        InksyncInkingState.shared.activeToolMode = .write
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ReaderToggleSidebar"))) { _ in
                withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                    showingOutlineDrawer.toggle()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ReaderZoomIn"))) { _ in
                adjustZoom(delta: 0.15)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ReaderZoomOut"))) { _ in
                adjustZoom(delta: -0.15)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ReaderResetZoom"))) { _ in
                resetZoomToFit()
            }
            .onReceive(NotificationCenter.default.publisher(for: .annotationsDidChange)) { notif in
                handleAnnotationsDidChange(notif)
            }
    }

    var body: some View {
        let configured = baseReaderStack
            .task {
                // Apply per-book theme profile if configured for this document
                prefs.applyBookTheme(bookID: pdf.id.uuidString)
                // Reset quick filter override so saved document theme takes precedence
                activeFilterPreset = .original
                isReflowMode = prefs.pdfReflowMode
                AnnotationStore.shared.initialize(with: modelContext)
                loadPDFDocument()
            }
            .onDisappear {
                handleDisappear()
            }
        let withKeys = applyKeyboardShortcuts(to: configured)
        let withCrop = applyCropObservers(to: withKeys)
        let withNotifications = applyNotificationHandlers(to: withCrop)
        return applySheets(to: withNotifications)
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

    private var effectiveThemeBackgroundColor: Color {
        ReaderCanvasTheme.tokens(for: prefs.activeTheme).canvasBackground
    }

    @ViewBuilder private func pdfCanvasView(document: PDFDocument) -> some View {
        ZStack {
            effectiveThemeBackgroundColor
                .ignoresSafeArea()

            ProPDFViewRepresentable(
                pdf: pdf,
                document: document,
                currentPageIndex: $currentPageIndex,
                pdfViewRef: $pdfViewReference,
                isCroppedMode: isCroppedMode,
                isExpandedView: isExpandedView,
                isPencilMode: isPencilMode,
                themeBgColor: effectiveThemeBackgroundColor,
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
                    if text == nil {
                        activeTappedAnnotationID = nil
                    }
                    if isPencilMode && InksyncInkingState.shared.activeToolMode == .textHighlight {
                        activeSelectionSnapshot = snapshot
                        selectedTextForHUD = nil
                    } else {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            selectedTextForHUD = text
                            activeSelectionSnapshot = snapshot
                        }
                    }
                },
                onHighlightTapped: { id, text in
                    activeTappedAnnotationID = id
                    withAnimation(.easeInOut(duration: 0.18)) {
                        selectedTextForHUD = text
                        activeSelectionSnapshot = nil
                    }
                    HapticEngine.selection()
                },
                onHighlightTappedWithAnnotation: { ann, id, text, bounds in
                    activeTappedAnnotation = ann
                    activeTappedAnnotationID = id
                    activeTappedAnnotationBounds = bounds
                    withAnimation(.easeInOut(duration: 0.18)) {
                        selectedTextForHUD = text
                        activeSelectionSnapshot = nil
                    }
                    HapticEngine.selection()
                },
                onHighlightRequested: {
                    if let sel = pdfViewReference?.currentSelection, let pg = sel.pages.first ?? pdfViewReference?.currentPage {
                        saveMarkupFromSelection(selection: sel, page: pg, color: EBookPreferences.shared.defaultHighlightColor, style: .highlight)
                    } else if let text = activeSelectionSnapshot?.text ?? selectedTextForHUD ?? pdfViewReference?.currentSelection?.string,
                       !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        saveMarkup(text: text, color: EBookPreferences.shared.defaultHighlightColor, style: .highlight)
                        selectedTextForHUD = nil
                    }
                },
                onHighlightSelectionDirect: { selection, page, color in
                    saveMarkupFromSelection(selection: selection, page: page, color: color, style: .highlight)
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
                },
                onScannedPageDetected: {
                    showToastMessage("Scanned Page — Apple Pencil Highlighter Active")
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                        isPencilMode = true
                    }
                    HapticEngine.medium()
                },
                onUndoRequested: { pageIdx in
                    performUndo(preferredPageIndex: pageIdx)
                },
                onRedoRequested: { pageIdx in
                    performRedo(preferredPageIndex: pageIdx)
                }
            )
            .applyPDFTheme(
                theme: prefs.activeTheme,
                filter: prefs.readingFilter,
                filterPresetOverride: activeFilterPreset,
                isPencilMode: isPencilMode
            )
            .ignoresSafeArea()

            if isPencilMode {
                VStack {
                    HStack {
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                                isPencilMode = false
                            }
                            saveReadingProgress()
                            onDismiss()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "chevron.left")
                                    .font(.system(size: 14, weight: .bold))
                                Text("Done")
                                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: Capsule())
                            .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 0.5))
                            .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, 16)
                        .padding(.top, 50)

                        Spacer()
                    }

                    Spacer()

                    InksyncPenDockView(
                        onUndo: {
                            performUndo()
                        },
                        onRedo: {
                            performRedo()
                        },
                        onClearPage: {
                            clearCurrentPageMarkup()
                        },
                        onClose: {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                                isPencilMode = false
                            }
                        }
                    )
                    .padding(.bottom, 36)
                }
                .transition(.opacity)
                .ignoresSafeArea(.keyboard)
            } else if !chromeVisible && selectedTextForHUD == nil {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                                isPencilMode = true
                                InksyncInkingState.shared.activeToolMode = .write
                            }
                            HapticEngine.medium()
                        } label: {
                            Image(systemName: "pencil.tip.crop.circle")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                                .background(.ultraThinMaterial, in: Circle())
                                .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
                                .shadow(color: Color.black.opacity(0.25), radius: 8, y: 3)
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 20)
                        .padding(.bottom, 36)
                        .help("Open Pen Toolbar (P)")
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.85)))
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

    private func adjustZoom(delta: CGFloat) {
        guard let pv = pdfViewReference else { return }
        let fitScale = max(0.001, pv.scaleFactorForSizeToFit)
        let currentScale = pv.scaleFactor
        let newScale = max(fitScale * 0.4, min(fitScale * 6.0, currentScale + (fitScale * delta)))

        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut]) {
            pv.scaleFactor = newScale
        }

        let effectiveScale = newScale / fitScale
        activeZoomScale = effectiveScale
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            showZoomPill = true
        }

        if prefs.isZoomLocked {
            prefs.lockedZoomScale = newScale
        }

        startZoomPillTimer()
        HapticEngine.selection()
    }

    private func resetZoomToFit() {
        guard let pv = pdfViewReference else { return }
        let fitScale = max(0.001, pv.scaleFactorForSizeToFit)

        UIView.animate(withDuration: 0.3, delay: 0, options: [.curveEaseOut]) {
            pv.scaleFactor = fitScale
        }

        activeZoomScale = 1.0
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            showZoomPill = true
        }

        if prefs.isZoomLocked {
            prefs.lockedZoomScale = fitScale
        }

        showToastMessage("Fit to Page (100%)")
        startZoomPillTimer()
        HapticEngine.medium()
    }

    private func startZoomPillTimer() {
        zoomPillTask?.cancel()
        zoomPillTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.3)) {
                showZoomPill = false
            }
        }
    }

    @ViewBuilder private var zoomPillHUD: some View {
        if showZoomPill {
            let scalePct = Int(round(activeZoomScale * 100))
            VStack {
                HStack(spacing: 8) {
                    Button {
                        adjustZoom(delta: -0.10)
                    } label: {
                        Image(systemName: "minus")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 24, height: 24)
                            .background(Color.white.opacity(0.12), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Zoom Out")

                    Button {
                        resetZoomToFit()
                    } label: {
                        HStack(spacing: 4) {
                            Text("\(scalePct)%")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                            if abs(activeZoomScale - 1.0) > 0.04 {
                                Text("• Fit")
                                    .font(.system(size: 10, weight: .bold, design: .rounded))
                                    .foregroundStyle(Color.orange)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Reset to Page Fit (100%)")

                    Button {
                        adjustZoom(delta: 0.10)
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 24, height: 24)
                            .background(Color.white.opacity(0.12), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Zoom In")

                    Divider().frame(height: 14)

                    Button {
                        HapticEngine.selection()
                        prefs.isZoomLocked.toggle()
                        if prefs.isZoomLocked, let pv = pdfViewReference {
                            prefs.lockedZoomScale = pv.scaleFactor
                            showToastMessage("Zoom Level Locked")
                        } else {
                            showToastMessage("Zoom Unlocked")
                        }
                        startZoomPillTimer()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: prefs.isZoomLocked ? "lock.fill" : "lock.open")
                                .font(.system(size: 10, weight: .bold))
                            Text(prefs.isZoomLocked ? "Locked" : "Lock")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                        }
                        .foregroundStyle(prefs.isZoomLocked ? Color.orange : Color.white.opacity(0.85))
                    }
                    .buttonStyle(.plain)
                    .help(prefs.isZoomLocked ? "Unlock Zoom" : "Lock Zoom Across Pages")
                }
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.2), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
                .padding(.top, chromeVisible ? 70 : 50)
                Spacer()
            }
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
            .zIndex(10)
        }
    }

    @ViewBuilder private var pdfNarrationHUD: some View {
        if isNarratingPDF {
            VStack {
                Spacer()
                HStack(spacing: 12) {
                    Image(systemName: "waveform")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color.orange)
                        .symbolEffect(.variableColor.iterative, isActive: isNarratingPDF)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Reading Aloud (Page \(currentPageIndex + 1))")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        Text("Auto-advances on page completion")
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(.white.opacity(0.75))
                    }

                    Spacer()

                    Button {
                        HapticEngine.selection()
                        advancePage(forward: true)
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.white)
                            .padding(8)
                            .background(Color.white.opacity(0.15), in: Circle())
                    }
                    .buttonStyle(.plain)

                    Button {
                        HapticEngine.selection()
                        stopPDFNarration()
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.orange)
                            .padding(8)
                            .background(Color.orange.opacity(0.2), in: Circle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    Capsule()
                        .fill(Color.black.opacity(0.85))
                        .background(.ultraThinMaterial, in: Capsule())
                )
                .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
                .padding(.horizontal, 24)
                .padding(.bottom, chromeVisible ? 100 : 36)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .zIndex(120)
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
                        if let id = activeTappedAnnotationID {
                            updateHighlightColor(id: id, color: color, style: .highlight)
                        } else if let ann = activeTappedAnnotation {
                            ann.color = color.directHighlightUIColor
                            if let idStr = ann.userName, let uid = UUID(uuidString: idStr) {
                                updateHighlightColor(id: uid, color: color, style: .highlight)
                            } else {
                                if let pv = pdfViewReference {
                                    forcePageRedraw(pv, pageIndex: currentPageIndex)
                                }
                                if let doc = pdfViewReference?.document ?? pdfDocument {
                                    PDFAnnotationSyncBridge.shared.scheduleDebouncedDiskSync(for: pdf.id, in: doc, at: resolvedURL)
                                }
                                showToastMessage("Highlight Updated")
                                HapticEngine.selection()
                            }
                        } else {
                            saveMarkup(text: selectedText, color: color, style: .highlight)
                        }
                    },
                    onMarkup: { color, style in
                        EBookPreferences.shared.defaultHighlightColor = color
                        if let id = activeTappedAnnotationID {
                            updateHighlightColor(id: id, color: color, style: style)
                        } else if let ann = activeTappedAnnotation {
                            ann.color = (style == .highlight) ? color.directHighlightUIColor : color.uiColor
                            if let idStr = ann.userName, let uid = UUID(uuidString: idStr) {
                                updateHighlightColor(id: uid, color: color, style: style)
                            } else {
                                if let pv = pdfViewReference {
                                    forcePageRedraw(pv, pageIndex: currentPageIndex)
                                }
                                if let doc = pdfViewReference?.document ?? pdfDocument {
                                    PDFAnnotationSyncBridge.shared.scheduleDebouncedDiskSync(for: pdf.id, in: doc, at: resolvedURL)
                                }
                                showToastMessage("Highlight Updated")
                                HapticEngine.selection()
                            }
                        } else {
                            saveMarkup(text: selectedText, color: color, style: style)
                        }
                    },
                    onUnhighlight: {
                        if let id = activeTappedAnnotationID {
                            removeAnnotation(id: id, pageIndex: currentPageIndex, annotation: activeTappedAnnotation, bounds: activeTappedAnnotationBounds)
                            activeTappedAnnotationID = nil
                            activeTappedAnnotation = nil
                            activeTappedAnnotationBounds = nil
                            selectedTextForHUD = nil
                            pdfViewReference?.setCurrentSelection(nil, animate: false)
                        } else if let ann = activeTappedAnnotation {
                            // Find and clean matching store annotation if present
                            let store = AnnotationStore.shared
                            let pageCrop = (pdfViewReference?.document ?? pdfDocument)?.page(at: currentPageIndex)?.bounds(for: .cropBox) ?? .zero
                            if let matchedStoreAnn = store.annotations(for: pdf.id).first(where: { storeAnn in
                                guard storeAnn.pageIndex == currentPageIndex else { return false }
                                let textMatches = (storeAnn.selectedText != nil && (storeAnn.selectedText == selectedText || selectedText.contains(storeAnn.selectedText!))) ||
                                                  (ann.contents != nil && storeAnn.selectedText == ann.contents)
                                guard textMatches else { return false }
                                if let b = storeAnn.bounds, pageCrop.width > 0, pageCrop.height > 0 {
                                    let r = CGRect(
                                        x: pageCrop.minX + CGFloat(b.x) * pageCrop.width,
                                        y: pageCrop.minY + CGFloat(b.y) * pageCrop.height,
                                        width: CGFloat(b.width) * pageCrop.width,
                                        height: CGFloat(b.height) * pageCrop.height
                                    )
                                    return r.intersects(ann.bounds.insetBy(dx: -8, dy: -8))
                                }
                                return true
                            }) {
                                store.delete(id: matchedStoreAnn.id, pdfID: pdf.id)
                            }
                            if let page = (pdfViewReference?.document ?? pdfDocument)?.page(at: currentPageIndex) {
                                page.removeAnnotation(ann)
                                page.displaysAnnotations = false
                                page.displaysAnnotations = true
                            }
                            if let pv = pdfViewReference {
                                forcePageRedraw(pv, pageIndex: currentPageIndex)
                            }
                            if let doc = pdfViewReference?.document ?? pdfDocument {
                                PDFAnnotationSyncBridge.shared.scheduleDebouncedDiskSync(for: pdf.id, in: doc, at: resolvedURL)
                            }
                            activeTappedAnnotation = nil
                            activeTappedAnnotationBounds = nil
                            selectedTextForHUD = nil
                            pdfViewReference?.setCurrentSelection(nil, animate: false)
                            showToastMessage("Highlight Removed")
                            HapticEngine.selection()
                        } else {
                            unhighlightSelection(text: selectedText)
                            selectedTextForHUD = nil
                            activeTappedAnnotationID = nil
                            activeTappedAnnotation = nil
                            activeTappedAnnotationBounds = nil
                        }
                    },
                    onAddNote: { note in
                        saveNote(text: selectedText, note: note, color: EBookPreferences.shared.defaultHighlightColor)
                        showToastMessage("Note Saved")
                    },
                    onCopy: {
                        UIPasteboard.general.string = selectedText
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
                        showToastMessage("Marginalia Added")
                    },
                    onAdjustStart: { delta in
                        adjustActiveSelection(startDelta: delta, endDelta: 0)
                    },
                    onAdjustEnd: { delta in
                        adjustActiveSelection(startDelta: 0, endDelta: delta)
                    },
                    onDismiss: {
                        activeTappedAnnotationID = nil
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
                toggleBookmark()
            },
            onBookmarkActive: isCurrentPageBookmarked,
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
            selectedCropMode: activeCropInsets.modeRaw,
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
            onCropModeSelected: { mode in
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    switch mode {
                    case "smartAuto":
                        applyCropInsets(.smartAuto)
                    case "custom":
                        applyCropInsets(CodableCropInsets(
                            top: prefs.defaultCropTop,
                            bottom: prefs.defaultCropBottom,
                            left: prefs.defaultCropLeft,
                            right: prefs.defaultCropRight,
                            modeRaw: "custom"
                        ))
                    default:
                        applyCropInsets(.none)
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
                    if isPencilMode {
                        InksyncInkingState.shared.activeToolMode = .write
                    }
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
            sessionStartTime: sessionStartTime,
            onSwipeDown: {
                saveReadingProgress()
                onDismiss()
            }
        )
    }

    // MARK: - Actions & Persistence
    private func loadPDFDocument() {
        guard pdfDocument == nil else { return }
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

                    // Ingest and render all existing InkSync Pro highlights, notes, and ink from AnnotationStore onto the live document
                    PDFAnnotationSyncBridge.shared.applyStoreAnnotations(for: sourcePDF.id, to: doc)

                    // Ingest native third-party PDF annotations asynchronously in background so document opens in <50ms
                    Task(priority: .background) {
                        _ = await PDFAnnotationSyncBridge.shared.importNativeAnnotations(from: doc, for: sourcePDF.id, preferredPageIndex: savedIndex)
                    }
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
            PDFAnnotationSyncBridge.shared.applyStoreAnnotations(for: pdf.id, to: doc)
            Task { @MainActor in
                let imported = await PDFAnnotationSyncBridge.shared.importNativeAnnotations(from: doc, for: self.pdf.id, preferredPageIndex: self.currentPageIndex)
                if !imported.isEmpty {
                    PDFAnnotationSyncBridge.shared.applyStoreAnnotations(for: self.pdf.id, to: doc)
                }
            }
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
        saveReadingProgress()
        _ = ReadingContinuationResolver.shared.continueReading(after: pdf, in: allBooks)
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

    private var isCurrentPageBookmarked: Bool {
        let inStore = AnnotationStore.shared.annotations(for: pdf.id).contains(where: { $0.pageIndex == currentPageIndex && $0.kind == .bookmark })
        let inMetadata = pdf.metadata.bookmarkedPages.contains(currentPageIndex)
        return inStore || inMetadata
    }

    private func toggleBookmark() {
        let wasBookmarked = isCurrentPageBookmarked
        if wasBookmarked {
            let existing = AnnotationStore.shared.annotations(for: pdf.id).filter { $0.pageIndex == currentPageIndex && $0.kind == .bookmark }
            for b in existing {
                AnnotationStore.shared.delete(id: b.id, pdfID: pdf.id)
            }
            if let idx = ConversionManager.shared.convertedPDFs.firstIndex(where: { $0.id == pdf.id }) {
                ConversionManager.shared.convertedPDFs[idx].metadata.bookmarkedPages.removeAll(where: { $0 == currentPageIndex })
                ConversionManager.shared.saveProgressOnly()
            }
            showToastMessage("Bookmark Removed")
            HapticEngine.light()
        } else {
            let bookmark = Annotation(
                pdfID: pdf.id,
                pageIndex: currentPageIndex,
                chapterTitle: "Page \(currentPageIndex + 1)",
                kind: .bookmark,
                createdAt: Date(),
                modifiedAt: Date()
            )
            AnnotationStore.shared.add(bookmark)
            if let idx = ConversionManager.shared.convertedPDFs.firstIndex(where: { $0.id == pdf.id }) {
                if !ConversionManager.shared.convertedPDFs[idx].metadata.bookmarkedPages.contains(currentPageIndex) {
                    ConversionManager.shared.convertedPDFs[idx].metadata.bookmarkedPages.append(currentPageIndex)
                    ConversionManager.shared.saveProgressOnly()
                }
            }
            showToastMessage("Bookmark Added")
            HapticEngine.medium()
        }
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
            let remaining = max(0, totalPages - (clamped + 1))
            velocityEngine.recordPageTurn(remainingPages: remaining)
        }
        // Only update the SwiftUI binding. updateUIView() owns the single
        // authoritative call to pdfView.go(to:) via the isNavigatingProgrammatically
        // guard. Calling go(to:) here AND in updateUIView causes a double-navigation
        // race that manifests as every-other-page skipping.
        currentPageIndex = clamped
        saveReadingProgress()
    }

    private func handleDocumentModified() {
        guard let doc = pdfDocument else { return }
        if currentPageIndex >= doc.pageCount {
            currentPageIndex = max(0, doc.pageCount - 1)
        }
        pdfViewReference?.layoutDocumentView()
        saveReadingProgress()
    }

    private func advancePage(forward: Bool) {
        let isManga = isMangaMode || prefs.pdfRTL
        let effectiveForward = isManga ? !forward : forward

        guard let pdfView = pdfViewReference else { return }

        // Boox NeoReader Article / Column Mode Navigation
        if prefs.isArticleMode, let page = pdfView.currentPage, let doc = pdfView.document {
            let pageIdx = doc.index(for: page)
            let layout = PDFColumnDetector.shared.detectColumns(in: page, pageIndex: pageIdx)
            if layout.isMultiColumn {
                if effectiveForward {
                    if articleColumnStep + 1 < layout.columns.count {
                        articleColumnStep += 1
                        zoomToColumn(layout.columns[articleColumnStep], on: page, in: pdfView)
                        HapticEngine.selection()
                        return
                    } else {
                        articleColumnStep = 0
                    }
                } else {
                    if articleColumnStep > 0 {
                        articleColumnStep -= 1
                        zoomToColumn(layout.columns[articleColumnStep], on: page, in: pdfView)
                        HapticEngine.selection()
                        return
                    } else {
                        articleColumnStep = 0
                    }
                }
            }
        }

        let remaining = max(0, totalPages - (currentPageIndex + 1))
        if effectiveForward {
            if pdfView.canGoToNextPage {
                // Smooth directional CoreAnimation slide eliminates abrupt white/page flashes
                let transition = CATransition()
                transition.duration = 0.22
                transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                transition.type = .push
                transition.subtype = .fromRight
                pdfView.layer.add(transition, forKey: "pageFlipAnimation")

                // goToNextPage handles twoUp spread boundaries natively —
                // we never need to manually compute +1 or +2; PDFKit knows.
                pdfView.goToNextPage(nil)
                velocityEngine.recordPageTurn(remainingPages: remaining)
            } else {
                attemptPDFSeriesContinuation()
            }
        } else {
            if pdfView.canGoToPreviousPage {
                let transition = CATransition()
                transition.duration = 0.22
                transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                transition.type = .push
                transition.subtype = .fromLeft
                pdfView.layer.add(transition, forKey: "pageFlipAnimation")

                pdfView.goToPreviousPage(nil)
                velocityEngine.recordPageTurn(remainingPages: remaining)
            }
        }

        // If entering new page in Article Mode, zoom into first column
        if prefs.isArticleMode, let page = pdfView.currentPage, let doc = pdfView.document {
            let pageIdx = doc.index(for: page)
            let layout = PDFColumnDetector.shared.detectColumns(in: page, pageIndex: pageIdx)
            if layout.isMultiColumn && !layout.columns.isEmpty {
                let targetCol = effectiveForward ? layout.columns[0] : (layout.columns.last ?? layout.columns[0])
                articleColumnStep = effectiveForward ? 0 : (layout.columns.count - 1)
                zoomToColumn(targetCol, on: page, in: pdfView)
            }
        }

        // Live Reading Pace Tracking
        Task {
            let pageWords = pdfView.currentPage?.string?.components(separatedBy: .whitespacesAndNewlines).filter({ !$0.isEmpty }).count ?? 250
            await ReadingPaceTracker.shared.recordPageTurn(wordsOnPage: max(50, pageWords), timeSpentSeconds: 15.0)
        }
        HapticEngine.selection()

        // If continuous narration active, read new page
        if isNarratingPDF {
            startPDFNarration()
        }
    }

    private func zoomToColumn(_ column: PDFColumn, on page: PDFPage, in pdfView: PDFView) {
        let fitScale = pdfView.scaleFactorForSizeToFit
        let desiredScale = max(fitScale * 1.2, min(fitScale * 4.0, (pdfView.bounds.width - 24.0) / max(1, column.rect.width)))
        UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0, options: [.curveEaseOut]) {
            pdfView.scaleFactor = desiredScale
            let colCenter = CGPoint(x: column.rect.midX, y: column.rect.maxY)
            let viewPoint = pdfView.convert(colCenter, from: page)
            if let scrollView = pdfView.subviews.first(where: { $0 is UIScrollView }) as? UIScrollView {
                let targetOffsetX = max(0, viewPoint.x - (pdfView.bounds.width / 2.0))
                let targetOffsetY = max(0, viewPoint.y - 20)
                scrollView.setContentOffset(CGPoint(x: targetOffsetX, y: targetOffsetY), animated: false)
            }
        }
    }

    private func togglePDFNarration() {
        if isNarratingPDF {
            stopPDFNarration()
        } else {
            startPDFNarration()
        }
    }

    private func startPDFNarration() {
        guard let pdfView = pdfViewReference, let page = pdfView.currentPage, let text = page.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showToastMessage("No readable text on this page")
            return
        }
        speechSynthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        isNarratingPDF = true
        showToastMessage("Read Aloud Active")
        speechSynthesizer.speak(utterance)
    }

    private func stopPDFNarration() {
        speechSynthesizer.stopSpeaking(at: .immediate)
        isNarratingPDF = false
        showToastMessage("Read Aloud Stopped")
    }

    // MARK: - Highlight Annotation Pipeline

    /// Removes existing overlapping markup annotations to support instant recoloring & handle adjustment without stacking duplicates.
    private func removeOverlappingAnnotations(on page: PDFPage, text: String, bounds: CGRect, excludingID: UUID? = nil) {
        let existingAnns = page.annotations.filter { a in
            if let excl = excludingID, a.userName == excl.uuidString { return false }
            let t = a.type ?? ""
            guard t.contains("Highlight") || t.contains("Underline") || t.contains("StrikeOut") else { return false }
            // CRITICAL: Require spatial geometric intersection so highlighting common words elsewhere on the page never wipes out unrelated annotations.
            guard a.bounds.intersects(bounds.insetBy(dx: -4, dy: -4)) else { return false }
            if a.contents == nil || a.contents?.isEmpty == true { return true }
            return a.contents == text || text.contains(a.contents!) || a.contents!.contains(text)
        }
        for oldAnn in existingAnns {
            if let uidStr = oldAnn.userName, let uid = UUID(uuidString: uidStr) {
                AnnotationStore.shared.delete(id: uid, pdfID: pdf.id)
                let descriptor = FetchDescriptor<SDAnnotation>(predicate: #Predicate<SDAnnotation> { $0.id == uid })
                if let matched = try? modelContext.fetch(descriptor) {
                    for m in matched { modelContext.delete(m) }
                }
            }
            page.removeAnnotation(oldAnn)
        }
    }

    /// Commits a text markup annotation (highlight, underline, strikethrough)
    /// to the underlying PDFPage and persists it in `AnnotationStore`.
    ///
    /// **Three-path resolution strategy** (ordered by reliability):
    /// 1. `activeSelectionSnapshot.lines` — captured at selection time; most accurate.
    /// 2. `pdfView.currentSelection.selectionsByLine()` — fallback if snapshot is nil.
    /// 3. `doc.findString(text)` — last resort text search.
    /// CRITICAL: Point-Free Swift 6 & Apple PDFKit ISO 32000-1 coordinate standard.
    /// Quadrilateral points are computed in native PDF page space in standard Z-pattern
    /// (Top-Left, Top-Right, Bottom-Left, Bottom-Right) matching glyph geometry.
    private func saveMarkup(text: String, color: PDFHighlightColor, style: AnnotationMarkupStyle = .highlight) {
        // Build the RGBA UIColor directly — never via hex round-trip which can
        // silently collapse HSL saturation for colors like Emerald or Electric Blue.
        let highlightColor: UIColor
        switch style {
        case .underline, .strikeOut:
            highlightColor = color.uiColor
        case .highlight:
            highlightColor = color.directHighlightUIColor
        }
        let annotationID = UUID()
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
                page.displaysAnnotations = true
                let validRects = snapshot.lines.map(\.bounds).filter { $0 != .zero && $0.width > 2 && $0.height > 2 }
                if !validRects.isEmpty {
                    let unionBox = PDFHighlightGeometryHelper.unionBounds(for: validRects)
                    removeOverlappingAnnotations(on: page, text: text, bounds: unionBox, excludingID: annotationID)
                    let ann = PDFAnnotation(bounds: unionBox, forType: nativeType, withProperties: nil)
                    ann.userName = annotationID.uuidString
                    ann.color = highlightColor
                    ann.contents = text
                    ann.shouldDisplay = true
                    ann.shouldPrint = true
                    ann.quadrilateralPoints = PDFHighlightGeometryHelper.createQuadPoints(for: validRects, relativeTo: unionBox)
                    page.addAnnotation(ann)
                    didAddNative = true
                }
            }
        }

        // ── Path 2: Decompose current PDFView selection by line ───────────────────
        if !didAddNative, let pdfView = pdfViewReference, let selection = pdfView.currentSelection {
            for page in selection.pages {
                page.displaysAnnotations = true
                if let doc = pdfView.document {
                    targetPageIndex = doc.index(for: page)
                }
                let lines = selection.selectionsByLine()
                let targetLines = lines.isEmpty ? [selection] : lines
                let validRects = targetLines.compactMap { $0.bounds(for: page) }.filter { $0 != .zero && $0.width > 2 && $0.height > 2 }
                guard !validRects.isEmpty else { continue }

                let unionBox = PDFHighlightGeometryHelper.unionBounds(for: validRects)
                removeOverlappingAnnotations(on: page, text: text, bounds: unionBox, excludingID: annotationID)
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
                ann.userName = annotationID.uuidString
                ann.color = highlightColor
                ann.contents = text
                ann.shouldDisplay = true
                ann.shouldPrint = true
                ann.quadrilateralPoints = PDFHighlightGeometryHelper.createQuadPoints(for: validRects, relativeTo: unionBox)
                page.addAnnotation(ann)
                didAddNative = true
            }
        }

        // ── Path 3: Text-search fallback ──────────────────────────────────────────
        if !didAddNative, let doc = activeDoc, let page = doc.page(at: targetPageIndex) {
            page.displaysAnnotations = true
            let matches = doc.findString(text, withOptions: .caseInsensitive)
            for match in matches where match.pages.contains(page) {
                let lines = match.selectionsByLine()
                let targetLines = lines.isEmpty ? [match] : lines
                let validRects = targetLines.compactMap { $0.bounds(for: page) }.filter { $0 != .zero && $0.width > 2 && $0.height > 2 }
                guard !validRects.isEmpty else { continue }

                let unionBox = PDFHighlightGeometryHelper.unionBounds(for: validRects)
                removeOverlappingAnnotations(on: page, text: text, bounds: unionBox, excludingID: annotationID)
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
                ann.userName = annotationID.uuidString
                ann.color = highlightColor
                ann.contents = text
                ann.shouldDisplay = true
                ann.shouldPrint = true
                ann.quadrilateralPoints = PDFHighlightGeometryHelper.createQuadPoints(for: validRects, relativeTo: unionBox)
                page.addAnnotation(ann)
                didAddNative = true
                break
            }
        }

        // ── Path 4: Fallback to savedBounds bounding box ─────────────────────────
        if !didAddNative, let doc = activeDoc, let page = doc.page(at: targetPageIndex), let b = savedBounds {
            page.displaysAnnotations = true
            let pageBounds = page.bounds(for: .cropBox)
            let rect = CGRect(
                x: pageBounds.minX + (b.x * pageBounds.width),
                y: pageBounds.minY + (b.y * pageBounds.height),
                width: b.width * pageBounds.width,
                height: b.height * pageBounds.height
            )
            if rect.width > 2 && rect.height > 2 {
                removeOverlappingAnnotations(on: page, text: text, bounds: rect, excludingID: annotationID)
                let ann = PDFAnnotation(bounds: rect, forType: nativeType, withProperties: nil)
                ann.userName = annotationID.uuidString
                ann.color = highlightColor
                ann.contents = text
                ann.shouldDisplay = true
                ann.shouldPrint = true
                ann.quadrilateralPoints = PDFHighlightGeometryHelper.createQuadPoints(for: rect)
                page.addAnnotation(ann)
                didAddNative = true
            }
        }

        // ── Force repaint immediately without destroying active selection handles ─
        if let pv = pdfViewReference {
            forcePageRedraw(pv, pageIndex: targetPageIndex)
        }

        // ── Persist to AnnotationStore and sync to SwiftData ─────────────────────
        let highlight = Annotation(
            id: annotationID,
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
            PDFAnnotationSyncBridge.shared.scheduleDebouncedDiskSync(for: pdf.id, in: doc, at: resolvedURL)
        }
        recentMarkupHistory.append(MarkupHistoryItem(id: annotationID, pageIndex: targetPageIndex, text: text, color: color, style: style))
        undoneMarkupHistory.removeAll()
        activeSelectionSnapshot = nil
        showToastMessage(toastTitle)
        HapticEngine.selection()
    }

    // MARK: - Multi-Touch Undo & Redo Pipeline

    private func performUndo(preferredPageIndex: Int? = nil) {
        let targetPage = preferredPageIndex ?? currentPageIndex
        let coordinator = pdfViewReference?.delegate as? ProPDFViewRepresentable.Coordinator

        // 1. Try canvas stroke undo first
        if coordinator?.canvasProvider.undoVisible(preferredPageIndex: targetPage) == true {
            HapticEngine.medium()
            showToastMessage("Undo")
            return
        }

        // 2. Try native markup annotation undo
        if let lastMarkup = recentMarkupHistory.popLast() {
            undoneMarkupHistory.append(lastMarkup)
            removeAnnotation(id: lastMarkup.id, pageIndex: lastMarkup.pageIndex)
            HapticEngine.medium()
            showToastMessage("Undo Highlight")
            return
        }

        HapticEngine.light()
        showToastMessage("Nothing to Undo")
    }

    private func performRedo(preferredPageIndex: Int? = nil) {
        let targetPage = preferredPageIndex ?? currentPageIndex
        let coordinator = pdfViewReference?.delegate as? ProPDFViewRepresentable.Coordinator

        // 1. Try canvas stroke redo first
        if coordinator?.canvasProvider.redoVisible(preferredPageIndex: targetPage) == true {
            HapticEngine.medium()
            showToastMessage("Redo")
            return
        }

        // 2. Try native markup annotation redo
        if let redoMarkup = undoneMarkupHistory.popLast() {
            recentMarkupHistory.append(redoMarkup)
            saveMarkup(text: redoMarkup.text, color: redoMarkup.color, style: redoMarkup.style)
            HapticEngine.medium()
            showToastMessage("Redo Highlight")
            return
        }

        HapticEngine.light()
        showToastMessage("Nothing to Redo")
    }

    /// Directly commits a native PDFKit highlight annotation from a resolved PDFSelection & PDFPage.
    /// Bypasses asynchronous SwiftUI @State round-trips to eliminate race conditions during glide highlighting.
    private func saveMarkupFromSelection(
        selection: PDFSelection,
        page: PDFPage,
        color: PDFHighlightColor,
        style: AnnotationMarkupStyle = .highlight
    ) {
        guard let text = selection.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let doc = page.document ?? pdfViewReference?.document ?? pdfDocument else { return }

        let targetPageIndex = doc.index(for: page)
        guard targetPageIndex >= 0 else { return }

        let highlightColor: UIColor
        switch style {
        case .underline, .strikeOut:
            highlightColor = color.uiColor
        case .highlight:
            highlightColor = color.directHighlightUIColor
        }

        let annotationID = UUID()
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

        page.displaysAnnotations = true

        let lines = selection.selectionsByLine()
        let targetLines = lines.isEmpty ? [selection] : lines
        let validRects = targetLines.compactMap { $0.bounds(for: page) }.filter { $0 != .zero && $0.width > 2 && $0.height > 2 }

        var savedBounds: CodableCGRect? = nil
        var didAddNative = false

        let targetBox = !validRects.isEmpty ? PDFHighlightGeometryHelper.unionBounds(for: validRects) : selection.bounds(for: page)
        removeOverlappingAnnotations(on: page, text: text, bounds: targetBox, excludingID: annotationID)

        if !validRects.isEmpty {
            let unionBox = targetBox
            let pageBounds = page.bounds(for: .cropBox)
            if pageBounds.width > 0, pageBounds.height > 0 {
                savedBounds = CodableCGRect(
                    x: Double((unionBox.minX - pageBounds.minX) / pageBounds.width),
                    y: Double((unionBox.minY - pageBounds.minY) / pageBounds.height),
                    width: Double(unionBox.width / pageBounds.width),
                    height: Double(unionBox.height / pageBounds.height)
                )
            }
            let ann = PDFAnnotation(bounds: unionBox, forType: nativeType, withProperties: nil)
            ann.userName = annotationID.uuidString
            ann.color = highlightColor
            ann.contents = text
            ann.shouldDisplay = true
            ann.shouldPrint = true
            ann.quadrilateralPoints = PDFHighlightGeometryHelper.createQuadPoints(for: validRects, relativeTo: unionBox)
            page.addAnnotation(ann)
            didAddNative = true
        } else {
            let selBounds = selection.bounds(for: page)
            if selBounds.width > 2 && selBounds.height > 2 {
                let pageBounds = page.bounds(for: .cropBox)
                if pageBounds.width > 0, pageBounds.height > 0 {
                    savedBounds = CodableCGRect(
                        x: Double((selBounds.minX - pageBounds.minX) / pageBounds.width),
                        y: Double((selBounds.minY - pageBounds.minY) / pageBounds.height),
                        width: Double(selBounds.width / pageBounds.width),
                        height: Double(selBounds.height / pageBounds.height)
                    )
                }
                let ann = PDFAnnotation(bounds: selBounds, forType: nativeType, withProperties: nil)
                ann.userName = annotationID.uuidString
                ann.color = highlightColor
                ann.contents = text
                ann.shouldDisplay = true
                ann.shouldPrint = true
                ann.quadrilateralPoints = PDFHighlightGeometryHelper.createQuadPoints(for: selBounds)
                page.addAnnotation(ann)
                didAddNative = true
            }
        }

        // Repaint PDFView immediately so annotations appear with zero latency
        if let pv = pdfViewReference {
            forcePageRedraw(pv, pageIndex: targetPageIndex)
        }

        guard didAddNative else { return }

        // Persist to AnnotationStore and sync to SwiftData
        let highlight = Annotation(
            id: annotationID,
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
        let sdAnnotation = SDAnnotation(from: highlight)
        modelContext.insert(sdAnnotation)
        try? modelContext.save()
        PDFAnnotationSyncBridge.shared.scheduleDebouncedDiskSync(for: pdf.id, in: doc, at: resolvedURL)

        recentMarkupHistory.append(MarkupHistoryItem(id: annotationID, pageIndex: targetPageIndex, text: text, color: color, style: style))
        undoneMarkupHistory.removeAll()
        activeSelectionSnapshot = nil
        if !(isPencilMode && InksyncInkingState.shared.activeToolMode == .textHighlight) {
            selectedTextForHUD = text
        }
        showToastMessage(toastTitle)
        HapticEngine.selection()
    }

    private func saveHighlight(text: String, color: PDFHighlightColor) {
        saveMarkup(text: text, color: color, style: .highlight)
    }

    /// Dynamically expands or shrinks the active text selection range before highlighting.
    @MainActor
    private func adjustActiveSelection(startDelta: Int = 0, endDelta: Int = 0) {
        guard let pdfView = pdfViewReference,
              let selection = pdfView.currentSelection,
              let page = selection.pages.first ?? pdfView.currentPage else { return }

        let totalChars = page.numberOfCharacters
        guard totalChars > 0 else { return }

        let lines = selection.selectionsByLine()
        let firstLine = lines.first ?? selection
        let lastLine = lines.last ?? selection

        let firstBounds = firstLine.bounds(for: page)
        let lastBounds = lastLine.bounds(for: page)

        let startPoint = CGPoint(x: firstBounds.minX + 2, y: firstBounds.midY)
        let endPoint = CGPoint(x: lastBounds.maxX - 2, y: lastBounds.midY)

        var startIdx = page.characterIndex(at: startPoint)
        var endIdx = page.characterIndex(at: endPoint)

        if startIdx < 0 { startIdx = 0 }
        if endIdx < 0 { endIdx = startIdx }
        if startIdx > endIdx {
            swap(&startIdx, &endIdx)
        }

        let utf16Units = Array((page.string ?? "").utf16)
        let strLen = utf16Units.count

        func isWhitespace(_ codeUnit: UInt16) -> Bool {
            guard let scalar = UnicodeScalar(codeUnit) else { return false }
            return CharacterSet.whitespacesAndNewlines.contains(scalar)
        }

        func nudgeStart(from idx: Int, delta: Int) -> Int {
            guard strLen > 0 else { return idx }
            if delta < 0 {
                var p = max(0, idx - 1)
                while p > 0 && p < strLen && isWhitespace(utf16Units[p]) {
                    p -= 1
                }
                while p > 0 && (p - 1) < strLen && !isWhitespace(utf16Units[p - 1]) {
                    p -= 1
                }
                return p
            } else if delta > 0 {
                var p = min(strLen - 1, idx + 1)
                while p < strLen && !isWhitespace(utf16Units[p]) {
                    p += 1
                }
                while p < strLen && isWhitespace(utf16Units[p]) {
                    p += 1
                }
                return min(p, endIdx)
            }
            return idx
        }

        func nudgeEnd(from idx: Int, delta: Int) -> Int {
            guard strLen > 0 else { return idx }
            if delta > 0 {
                var p = min(strLen - 1, idx + 1)
                while p < strLen && isWhitespace(utf16Units[p]) {
                    p += 1
                }
                while p < strLen && !isWhitespace(utf16Units[p]) {
                    p += 1
                }
                return p
            } else if delta < 0 {
                var p = max(0, idx - 1)
                while p > 0 && p < strLen && !isWhitespace(utf16Units[p]) {
                    p -= 1
                }
                while p > 0 && (p - 1) < strLen && isWhitespace(utf16Units[p - 1]) {
                    p -= 1
                }
                return max(startIdx, p)
            }
            return idx
        }

        var newStart = startIdx
        var newEnd = endIdx

        if startDelta != 0 {
            newStart = nudgeStart(from: startIdx, delta: startDelta)
        }
        if endDelta != 0 {
            newEnd = nudgeEnd(from: endIdx, delta: endDelta)
        }

        if newEnd < newStart {
            newEnd = newStart
        }

        let targetRange = NSRange(location: newStart, length: max(1, newEnd - newStart + 1))
        guard targetRange.location + targetRange.length <= totalChars else { return }

        if let newSel = page.selection(for: targetRange), let txt = newSel.string, !txt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            pdfView.setCurrentSelection(newSel, animate: false)
            withAnimation(.easeInOut(duration: 0.15)) {
                self.selectedTextForHUD = txt
            }
            HapticEngine.selection()
        }
    }

    // MARK: - Remove / Unhighlight Pipeline

    /// Removes a highlight/markup annotation from the active PDF document and AnnotationStore.
    private func removeAnnotation(id: UUID, pageIndex: Int? = nil, annotation: PDFAnnotation? = nil, bounds: CGRect? = nil) {
        guard let doc = pdfViewReference?.document ?? pdfDocument else { return }
        let store = AnnotationStore.shared
        let existing = store.annotations(for: pdf.id).first(where: { $0.id == id })
        let text = existing?.selectedText
        let targetPage = pageIndex ?? existing?.pageIndex ?? currentPageIndex
        
        // 1. Direct removal if live annotation reference is provided
        if let liveAnn = annotation, let page = doc.page(at: targetPage) {
            page.removeAnnotation(liveAnn)
            page.displaysAnnotations = false
            page.displaysAnnotations = true
        }
        
        // 2. Remove native annotation from PDFPage via SyncBridge
        _ = PDFAnnotationSyncBridge.shared.removeAnnotation(
            id: id,
            from: doc,
            on: targetPage,
            text: text,
            destinationURL: resolvedURL,
            pdfID: pdf.id,
            targetAnnotation: annotation,
            bounds: bounds
        )
        
        // 3. Remove from AnnotationStore and SwiftData
        store.delete(id: id, pdfID: pdf.id)
        
        // 4. Force page redraw
        if let pv = pdfViewReference {
            forcePageRedraw(pv, pageIndex: targetPage)
        }
        
        showToastMessage("Highlight Removed")
        HapticEngine.selection()
    }

    /// Updates the color and optional markup style of an existing highlight annotation across all layers.
    private func updateHighlightColor(id: UUID, color: PDFHighlightColor, style: AnnotationMarkupStyle? = nil) {
        guard let doc = pdfViewReference?.document ?? pdfDocument else { return }
        let store = AnnotationStore.shared
        guard var existing = store.annotations(for: pdf.id).first(where: { $0.id == id }) else { return }
        
        let targetPage = existing.pageIndex
        existing.colorHex = color.rawValue
        existing.modifiedAt = Date()
        if let s = style {
            switch s {
            case .highlight: existing.kind = .highlight
            case .underline: existing.kind = .underline
            case .strikeOut: existing.kind = .strikeOut
            }
        }
        store.update(existing)
        
        // Update in SwiftData
        let ctx = modelContext
        let descriptor = FetchDescriptor<SDAnnotation>(predicate: #Predicate { $0.id == id })
        if let sdAnn = try? ctx.fetch(descriptor).first {
            sdAnn.colorHex = color.rawValue
            sdAnn.modifiedAt = Date()
            if let s = style {
                sdAnn.kindRaw = s.rawValue
            }
            try? ctx.save()
        }
        
        // Update in PDFKit page
        if let page = doc.page(at: targetPage) {
            let idStr = id.uuidString
            let nativeColor: UIColor
            switch style ?? .highlight {
            case .underline, .strikeOut: nativeColor = color.uiColor
            case .highlight: nativeColor = color.directHighlightUIColor
            }
            if let ann = page.annotations.first(where: { $0.userName == idStr }) {
                ann.color = nativeColor
            }
            if let pv = pdfViewReference {
                forcePageRedraw(pv, pageIndex: targetPage)
            }
        }
        
        PDFAnnotationSyncBridge.shared.scheduleDebouncedDiskSync(for: pdf.id, in: doc, at: resolvedURL)
        showToastMessage("Highlight Updated")
        HapticEngine.selection()
    }

    /// Erases all markup (ink drawings, highlights, underlines, strikeouts) from all currently visible pages
    private func clearCurrentPageMarkup() {
        guard let doc = pdfViewReference?.document ?? pdfDocument else { return }
        let coordinator = pdfViewReference?.delegate as? ProPDFViewRepresentable.Coordinator
        
        // 1. Identify all visible pages (handles both Single-Page and Dual-Page modes)
        let visiblePages = pdfViewReference?.visiblePages ?? [doc.page(at: currentPageIndex)].compactMap { $0 }
        let targetPageIndices: [Int] = visiblePages.compactMap { doc.index(for: $0) }.filter { $0 >= 0 }
        let effectiveIndices = targetPageIndices.isEmpty ? [currentPageIndex] : targetPageIndices
        
        // 2. Clear canvas drawings for each visible page
        for pageIdx in effectiveIndices {
            coordinator?.canvasProvider.clearDrawing(for: pageIdx)
        }
        
        // 3. Strip native PDF annotations from each visible page
        for page in visiblePages {
            let annotationsToRemove = page.annotations
            for annotation in annotationsToRemove {
                page.removeAnnotation(annotation)
            }
        }
        
        // 4. Remove all annotations for these pages from SwiftData
        let targetID: UUID = pdf.id
        for pageIdx in effectiveIndices {
            let descriptor = FetchDescriptor<SDAnnotation>(
                predicate: #Predicate<SDAnnotation> { annotation in
                    annotation.pdfID == targetID && annotation.pageIndex == pageIdx
                }
            )
            if let items = try? modelContext.fetch(descriptor) {
                for item in items {
                    modelContext.delete(item)
                }
            }
        }
        try? modelContext.save()
        
        // 5. Remove matching annotations from AnnotationStore
        let allStoreAnnotations = AnnotationStore.shared.annotations(for: targetID)
        for ann in allStoreAnnotations where effectiveIndices.contains(ann.pageIndex) {
            AnnotationStore.shared.delete(id: ann.id, pdfID: targetID)
        }
        
        // 6. Force page redraw for all visible pages
        if let pv = pdfViewReference {
            for pageIdx in effectiveIndices {
                forcePageRedraw(pv, pageIndex: pageIdx)
            }
        }
        
        // 7. Schedule disk sync
        PDFAnnotationSyncBridge.shared.scheduleDebouncedDiskSync(for: pdf.id, in: doc, at: resolvedURL)
        
        showToastMessage("Page Markup Cleared")
        HapticEngine.medium()
    }

    /// Unhighlights the current text selection or active snapshot
    private func unhighlightSelection(text: String) {
        guard let doc = pdfViewReference?.document ?? pdfDocument else { return }
        let targetPage = activeSelectionSnapshot?.pageIndex ?? currentPageIndex
        guard let page = doc.page(at: targetPage) else { return }
        let store = AnnotationStore.shared
        let pageAnnotations = store.annotations(for: pdf.id).filter { $0.pageIndex == targetPage }
        
        let pageCrop = page.bounds(for: .cropBox)
        let selectionBounds = pdfViewReference?.currentSelection?.bounds(for: page)
        
        var removedCount = 0
        for ann in pageAnnotations {
            guard let selText = ann.selectedText, !selText.isEmpty else { continue }
            let isExactText = selText == text
            let isSubstr = text.contains(selText) || selText.contains(text)
            
            var isSpatialMatch = false
            if let sb = selectionBounds, sb != .zero, let b = ann.bounds, pageCrop.width > 0, pageCrop.height > 0 {
                let rect = CGRect(
                    x: pageCrop.minX + CGFloat(b.x) * pageCrop.width,
                    y: pageCrop.minY + CGFloat(b.y) * pageCrop.height,
                    width: CGFloat(b.width) * pageCrop.width,
                    height: CGFloat(b.height) * pageCrop.height
                )
                isSpatialMatch = rect.intersects(sb.insetBy(dx: -8, dy: -8))
            }
            
            if (isExactText || isSubstr) && (selectionBounds == nil || isSpatialMatch) {
                removeAnnotation(id: ann.id, pageIndex: targetPage)
                removedCount += 1
            }
        }
        
        if removedCount == 0 {
            let matching = page.annotations.filter { ann in
                let t = ann.type ?? ""
                guard t.contains("Highlight") || t.contains("Underline") || t.contains("StrikeOut") else { return false }
                if let sb = selectionBounds, sb != .zero {
                    return ann.bounds.intersects(sb.insetBy(dx: -4, dy: -4))
                }
                if let c = ann.contents, c == text || text.contains(c) || c.contains(text) {
                    return true
                }
                return false
            }
            for ann in matching {
                if let idStr = ann.userName, let uid = UUID(uuidString: idStr) {
                    removeAnnotation(id: uid, pageIndex: targetPage, annotation: ann, bounds: ann.bounds)
                } else {
                    page.removeAnnotation(ann)
                }
                removedCount += 1
            }
            page.displaysAnnotations = false
            page.displaysAnnotations = true
            if let pv = pdfViewReference {
                forcePageRedraw(pv, pageIndex: targetPage)
            }
        }
        
        if removedCount > 0 {
            PDFAnnotationSyncBridge.shared.scheduleDebouncedDiskSync(for: pdf.id, in: doc, at: resolvedURL)
            showToastMessage("Highlight Removed")
            HapticEngine.selection()
        }
        
        pdfViewReference?.setCurrentSelection(nil, animate: false)
        activeSelectionSnapshot = nil
    }

    /// Repaints PDFView to display new annotation graphics smoothly without thrashing CATiledLayer.
    private func forcePageRedraw(_ pdfView: PDFView, pageIndex: Int) {
        if let page = pdfView.document?.page(at: pageIndex) {
            page.displaysAnnotations = false
            page.displaysAnnotations = true
        }
        pdfView.layoutDocumentView()
        pdfView.setNeedsDisplay()
        pdfView.documentView?.setNeedsDisplay()
        pdfView.documentView?.subviews.forEach { subview in
            subview.setNeedsDisplay()
            subview.layer.setNeedsDisplay()
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
        let sdAnnotation = SDAnnotation(from: noteAnn)
        modelContext.insert(sdAnnotation)
        try? modelContext.save()
        if let doc = pdfViewReference?.document ?? pdfDocument,
           let page = doc.page(at: currentPageIndex) {
            let pageBounds = page.bounds(for: .cropBox)
            let noteOrigin = CGPoint(x: pageBounds.minX + 30, y: pageBounds.maxY - 80)
            let noteRect = CGRect(origin: noteOrigin, size: CGSize(width: 28, height: 28))
            let nativeText = PDFAnnotation(bounds: noteRect, forType: .text, withProperties: nil)
            nativeText.userName = noteAnn.id.uuidString
            nativeText.color = color.uiColor
            nativeText.contents = note
            nativeText.iconType = .note
            nativeText.shouldDisplay = true
            nativeText.shouldPrint = true
            page.addAnnotation(nativeText)
            if let pv = pdfViewReference {
                forcePageRedraw(pv, pageIndex: currentPageIndex)
            }
            PDFAnnotationSyncBridge.shared.scheduleDebouncedDiskSync(for: pdf.id, in: doc, at: resolvedURL)
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
        let sdAnnotation = SDAnnotation(from: ann)
        modelContext.insert(sdAnnotation)
        try? modelContext.save()
        if let doc = pdfViewReference?.document ?? pdfDocument,
           let page = doc.page(at: currentPageIndex) {
            let pageBounds = page.bounds(for: .cropBox)
            let noteOrigin = CGPoint(x: pageBounds.minX + 30, y: pageBounds.maxY - 80)
            let noteRect = CGRect(origin: noteOrigin, size: CGSize(width: 28, height: 28))
            let nativeText = PDFAnnotation(bounds: noteRect, forType: .text, withProperties: nil)
            nativeText.userName = ann.id.uuidString
            nativeText.color = color.uiColor
            nativeText.contents = "\(symbol): \(text)"
            nativeText.iconType = .comment
            nativeText.shouldDisplay = true
            nativeText.shouldPrint = true
            page.addAnnotation(nativeText)
            if let pv = pdfViewReference {
                forcePageRedraw(pv, pageIndex: currentPageIndex)
            }
            PDFAnnotationSyncBridge.shared.scheduleDebouncedDiskSync(for: pdf.id, in: doc, at: resolvedURL)
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

// MARK: - Native iOS Contextual Menu Integration
/// ProPDFHighlightableView suppresses native iOS callout menus so InkSync Pro's
/// Kindle-style HUD and fluid automatic highlighting operate without obstruction.
@MainActor
class ProPDFHighlightableView: PDFView {
    var onHighlightRequested: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupEditMenuSuppression()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupEditMenuSuppression()
    }

    private func setupEditMenuSuppression() {
        disableEditMenuInteractions(in: self)
    }

    func disableEditMenuInteractions(in view: UIView) {
        let editInteractions = view.interactions.compactMap { $0 as? UIEditMenuInteraction }
        for editMenu in editInteractions {
            editMenu.dismissMenu()
            view.removeInteraction(editMenu)
        }
        for sub in view.subviews {
            disableEditMenuInteractions(in: sub)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        disableEditMenuInteractions(in: self)
    }

    override func didAddSubview(_ subview: UIView) {
        super.didAddSubview(subview)
        disableEditMenuInteractions(in: subview)
    }

    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        // Strip all default system menus so no native popups can be built
        builder.remove(menu: .standardEdit)
        builder.remove(menu: .lookup)
        builder.remove(menu: .learn)
        builder.remove(menu: .share)
        builder.remove(menu: .services)
        builder.remove(menu: .format)
        builder.remove(menu: .substitutions)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        // Suppress all standard edit actions so system callout menus never appear
        return false
    }

    @objc func applyHighlightFromMenu(_ sender: Any?) {
        onHighlightRequested?()
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
    var isPencilMode: Bool = false
    var themeBgColor: Color = .clear
    var onPrevPage: () -> Void
    var onNextPage: () -> Void
    var onTapCenter: () -> Void
    var onTextSelectionChanged: (String?, PDFSelectionSnapshot?) -> Void
    var onHighlightTapped: ((UUID?, String) -> Void)? = nil
    var onHighlightTappedWithAnnotation: ((PDFAnnotation?, UUID?, String, CGRect?) -> Void)? = nil
    var onHighlightRequested: (() -> Void)? = nil
    var onHighlightSelectionDirect: ((PDFSelection, PDFPage, PDFHighlightColor) -> Void)? = nil
    var onScaleChanged: ((CGFloat) -> Void)? = nil
    var onHyperlinkSelected: ((Int, PDFPage) -> Void)? = nil
    var onScannedPageDetected: (() -> Void)? = nil
    var onUndoRequested: ((Int) -> Void)? = nil
    var onRedoRequested: ((Int) -> Void)? = nil

    func makeUIView(context: Context) -> PDFView {
        let pdfView = ProPDFHighlightableView()
        pdfView.onHighlightRequested = { [weak coordinator = context.coordinator] in
            coordinator?.handleNativeHighlightAction()
        }
        pdfView.delegate = context.coordinator
        pdfView.pageOverlayViewProvider = context.coordinator.canvasProvider
        if UIDevice.current.userInterfaceIdiom == .pad {
            let pencilInteraction = UIPencilInteraction()
            pencilInteraction.delegate = context.coordinator
            pdfView.addInteraction(pencilInteraction)
        }
        // Horizontal paging feels most natural for a reader app on iOS
        pdfView.displayDirection = .horizontal
        pdfView.pageShadowsEnabled = true
        pdfView.backgroundColor = UIColor(themeBgColor)
        pdfView.isOpaque = false

        let prefs = EBookPreferences.shared
        let isLandscape = UIScreen.main.bounds.width > UIScreen.main.bounds.height
        let isDual = prefs.pdfDualPage || (prefs.autoLandscapeDualPage && isLandscape)

        let inkingState = InksyncInkingState.shared
        let currentToolMode = inkingState.activeToolMode
        let isPenDrawingTool = currentToolMode == .write || currentToolMode == .eraser
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        let autoPencilActive = isPad && prefs.applePencilAutoDraw
        let isCanvasMarkupActive = (isPencilMode && isPenDrawingTool) || inkingState.isColoringModeActive || (!isPencilMode && autoPencilActive && prefs.applePencilDefaultTool == "pen")

        if #available(iOS 16.0, *) {
            pdfView.isInMarkupMode = isCanvasMarkupActive
        }

        // Use singlePage (non-continuous) as the default mode so PDFViewPageChanged fires
        // reliably on every page turn. singlePageContinuous only fires on visible-page
        // threshold crossings which can miss pages when scrolling quickly.
        pdfView.usePageViewController(false)
        pdfView.displayMode = isDual ? .twoUp : .singlePage
        pdfView.displaysAsBook = isDual && !prefs.linkCoverAsSpread

        // Panels & Boox Parity: In dual mode, eliminate spine and edge gaps so spreads fill 100% of available screen space
        let margin = max(0, prefs.textMargin)
        let dualMargins = UIEdgeInsets(top: 0, left: 1, bottom: 0, right: 1)
        let singleMargins = UIEdgeInsets(top: 0, left: margin, bottom: 0, right: margin)
        pdfView.pageBreakMargins = isDual ? dualMargins : singleMargins

        if let sv = pdfView.subviews.first(where: { $0 is UIScrollView }) as? UIScrollView {
            sv.contentInsetAdjustmentBehavior = .never
            sv.contentInset = .zero
            sv.panGestureRecognizer.minimumNumberOfTouches = isCanvasMarkupActive ? 2 : 1
        }

        // Set page overlay provider BEFORE assigning document so PDFKit requests overlays for visible pages
        pdfView.pageOverlayViewProvider = context.coordinator.canvasProvider

        // Assign document AFTER display configuration so PDFKit lays out correctly
        pdfView.document = document
        pdfView.autoScales = true
        pdfView.minScaleFactor = 0.5
        pdfView.maxScaleFactor = 3.5

        // ── Tap gesture (finger & stylus) ──────────────────────────────────────────
        let tapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tapGesture.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue),
            NSNumber(value: UITouch.TouchType.pencil.rawValue)
        ]
        tapGesture.cancelsTouchesInView = false
        tapGesture.delegate = context.coordinator
        tapGesture.isEnabled = true
        pdfView.addGestureRecognizer(tapGesture)
        context.coordinator.tapGesture = tapGesture

        // ── 2-Finger Horizontal Swipe Page Turn (GoodNotes/Notability Parity) ──────
        let twoFingerSwipeLeft = UISwipeGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTwoFingerSwipeLeft(_:)))
        twoFingerSwipeLeft.numberOfTouchesRequired = 2
        twoFingerSwipeLeft.direction = .left
        twoFingerSwipeLeft.cancelsTouchesInView = false
        twoFingerSwipeLeft.delegate = context.coordinator
        pdfView.addGestureRecognizer(twoFingerSwipeLeft)
        context.coordinator.twoFingerSwipeLeft = twoFingerSwipeLeft

        let twoFingerSwipeRight = UISwipeGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTwoFingerSwipeRight(_:)))
        twoFingerSwipeRight.numberOfTouchesRequired = 2
        twoFingerSwipeRight.direction = .right
        twoFingerSwipeRight.cancelsTouchesInView = false
        twoFingerSwipeRight.delegate = context.coordinator
        pdfView.addGestureRecognizer(twoFingerSwipeRight)
        context.coordinator.twoFingerSwipeRight = twoFingerSwipeRight

        // ── Double-tap zoom (finger only) ─────────────────────────────────────────
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        doubleTap.cancelsTouchesInView = false
        pdfView.addGestureRecognizer(doubleTap)
        // Single-tap must wait for double-tap to fail — standard iOS pattern
        tapGesture.require(toFail: doubleTap)

        // ── 3-Finger Tap Redo shortcut (finger only) ──────────────────────────────
        let threeFingerTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleThreeFingerTap(_:)))
        threeFingerTap.numberOfTouchesRequired = 3
        threeFingerTap.numberOfTapsRequired = 1
        threeFingerTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        threeFingerTap.cancelsTouchesInView = false
        threeFingerTap.delegate = context.coordinator
        pdfView.addGestureRecognizer(threeFingerTap)
        context.coordinator.threeFingerTap = threeFingerTap

        // ── 2-Finger Tap Undo shortcut (finger only) ──────────────────────────────
        let twoFingerTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTwoFingerTap(_:)))
        twoFingerTap.numberOfTouchesRequired = 2
        twoFingerTap.numberOfTapsRequired = 1
        twoFingerTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        twoFingerTap.cancelsTouchesInView = false
        twoFingerTap.delegate = context.coordinator
        pdfView.addGestureRecognizer(twoFingerTap)
        context.coordinator.twoFingerTap = twoFingerTap

        // Single-tap page turn must wait for 2-finger tap to fail so multi-finger gestures don't turn the page
        tapGesture.require(toFail: twoFingerTap)

        // ── Finger Glide (word-snap) highlight gesture (finger only) ─────────────
        // 40ms duration when in text highlight mode for responsive fluid touch-drag,
        // 180ms minimum press duration when in normal reading allows scrolling/swiping.
        let fingerGlide = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleGlideSelection(_:)))
        let isDedicatedHighlighter = isPencilMode && currentToolMode == .textHighlight
        fingerGlide.minimumPressDuration = isDedicatedHighlighter ? 0.04 : 0.18
        fingerGlide.allowableMovement = 2000
        fingerGlide.cancelsTouchesInView = false
        fingerGlide.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        fingerGlide.delegate = context.coordinator
        fingerGlide.isEnabled = isDedicatedHighlighter || (!isPencilMode)
        pdfView.addGestureRecognizer(fingerGlide)
        context.coordinator.fingerGlide = fingerGlide
        // Single-tap only needs to wait for finger glide to fail
        tapGesture.require(toFail: fingerGlide)

        // ── Apple Pencil Glide (instant word-snap) highlight gesture (stylus only) ──
        // 20ms ultra-low latency allows Apple Pencil to immediately snap and select text on touch.
        let isPencilHighlightGlide = isDedicatedHighlighter ||
                                     (!isPencilMode && autoPencilActive && prefs.applePencilDefaultTool == "highlighter")
        let pencilGlide = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleGlideSelection(_:)))
        pencilGlide.minimumPressDuration = 0.02
        pencilGlide.allowableMovement = 2000
        pencilGlide.cancelsTouchesInView = false
        pencilGlide.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        pencilGlide.delegate = context.coordinator
        pencilGlide.isEnabled = isPencilHighlightGlide
        pdfView.addGestureRecognizer(pencilGlide)
        context.coordinator.pencilGlide = pencilGlide
        tapGesture.require(toFail: pencilGlide)

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
        context.coordinator.parent = self
        (uiView as? ProPDFHighlightableView)?.disableEditMenuInteractions(in: uiView)
        if uiView.document != document {
            uiView.document = document
            uiView.autoScales = true
        }
        if uiView.pageOverlayViewProvider == nil {
            uiView.pageOverlayViewProvider = context.coordinator.canvasProvider
        }

        let inkingState = InksyncInkingState.shared
        let currentToolMode = inkingState.activeToolMode
        let prefs = EBookPreferences.shared
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        let autoPencilActive = isPad && prefs.applePencilAutoDraw

        let isPenDrawingTool = currentToolMode == .write || currentToolMode == .eraser
        let isCanvasMarkupActive = (isPencilMode && isPenDrawingTool) || inkingState.isColoringModeActive || (!isPencilMode && autoPencilActive && prefs.applePencilDefaultTool == "pen")
        if context.coordinator.canvasProvider.isMarkupActive != isCanvasMarkupActive {
            context.coordinator.canvasProvider.isMarkupActive = isCanvasMarkupActive
        }
        if #available(iOS 16.0, *) {
            if uiView.isInMarkupMode != isCanvasMarkupActive {
                uiView.isInMarkupMode = isCanvasMarkupActive
            }
        }
        if context.coordinator.canvasProvider.pdfID != pdf.id {
            context.coordinator.canvasProvider.reset(for: pdf.id)
        }

        if let sv = uiView.subviews.first(where: { $0 is UIScrollView }) as? UIScrollView {
            if sv.panGestureRecognizer.minimumNumberOfTouches != (isCanvasMarkupActive ? 2 : 1) {
                sv.panGestureRecognizer.minimumNumberOfTouches = isCanvasMarkupActive ? 2 : 1
            }
        }
        if context.coordinator.tapGesture?.isEnabled == false {
            context.coordinator.tapGesture?.isEnabled = true
        }

        let isDedicatedHighlighter = isPencilMode && currentToolMode == .textHighlight
        let targetPencilGlide = isDedicatedHighlighter || (!isPencilMode && autoPencilActive && prefs.applePencilDefaultTool == "highlighter")
        let targetFingerGlide = isDedicatedHighlighter || (!isPencilMode)

        if context.coordinator.pencilGlide?.isEnabled != targetPencilGlide {
            context.coordinator.pencilGlide?.isEnabled = targetPencilGlide
        }
        if context.coordinator.fingerGlide?.isEnabled != targetFingerGlide {
            context.coordinator.fingerGlide?.isEnabled = targetFingerGlide
        }
        let targetPressDuration: TimeInterval = isDedicatedHighlighter ? 0.04 : 0.18
        if context.coordinator.fingerGlide?.minimumPressDuration != targetPressDuration {
            context.coordinator.fingerGlide?.minimumPressDuration = targetPressDuration
        }
        let isLandscape = uiView.bounds.width > uiView.bounds.height
        let isDual = prefs.pdfDualPage || (prefs.autoLandscapeDualPage && isLandscape)
        let targetDisplayMode: PDFDisplayMode = isDual ? .twoUp : .singlePage

        if uiView.displayMode != targetDisplayMode {
            uiView.displayMode = targetDisplayMode
        }
        let targetDisplaysAsBook = isDual && !prefs.linkCoverAsSpread
        if uiView.displaysAsBook != targetDisplaysAsBook {
            uiView.displaysAsBook = targetDisplaysAsBook
        }

        let margin = max(0, prefs.textMargin)
        let targetMargins = isDual ? UIEdgeInsets(top: 0, left: 1, bottom: 0, right: 1) : UIEdgeInsets(top: 0, left: margin, bottom: 0, right: margin)
        if uiView.pageBreakMargins != targetMargins {
            uiView.pageBreakMargins = targetMargins
        }

        let targetBg = UIColor(themeBgColor)
        if uiView.backgroundColor != targetBg {
            uiView.backgroundColor = targetBg
        }

        if let sv = uiView.subviews.first(where: { $0 is UIScrollView }) as? UIScrollView {
            if sv.contentInsetAdjustmentBehavior != .never {
                sv.contentInsetAdjustmentBehavior = .never
            }
            if sv.contentInset != .zero {
                sv.contentInset = .zero
            }
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
                uiView.maxScaleFactor = fitScale * 3.5
                if let sv = uiView.subviews.first(where: { $0 is UIScrollView }) as? UIScrollView {
                    sv.minimumZoomScale = fitScale
                    sv.maximumZoomScale = fitScale * 3.5
                }
            }

            if isExpandedView {
                let targetScale = max((fitScale > 0 ? fitScale : 1.0) * 1.35, 1.0)
                if abs(uiView.scaleFactor - targetScale) > 0.05 {
                    uiView.scaleFactor = targetScale
                }
            } else if prefs.isZoomLocked && prefs.lockedZoomScale > 0.1 {
                if abs(uiView.scaleFactor - prefs.lockedZoomScale) > 0.01 {
                    uiView.scaleFactor = prefs.lockedZoomScale
                }
            } else if context.coordinator.userCustomZoomScale == nil {
                if !uiView.autoScales {
                    uiView.autoScales = true
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
        uiView.gestureRecognizers?.forEach { uiView.removeGestureRecognizer($0) }
        coordinator.twoFingerTap = nil
        coordinator.threeFingerTap = nil
        coordinator.twoFingerSwipeLeft = nil
        coordinator.twoFingerSwipeRight = nil
        coordinator.fingerGlide = nil
        coordinator.pencilGlide = nil
        coordinator.tapGesture = nil
        uiView.delegate = nil
        uiView.document = nil
    }

    class Coordinator: NSObject, PDFViewDelegate, UIGestureRecognizerDelegate, UIPencilInteractionDelegate {
        var parent: ProPDFViewRepresentable
        let canvasProvider: PDFPageCanvasProvider
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

        // Strong references to glide and navigation gesture recognizers
        var fingerGlide: UILongPressGestureRecognizer? = nil
        var pencilGlide: UILongPressGestureRecognizer? = nil
        var tapGesture: UITapGestureRecognizer? = nil
        var twoFingerTap: UITapGestureRecognizer? = nil
        var threeFingerTap: UITapGestureRecognizer? = nil
        var twoFingerSwipeLeft: UISwipeGestureRecognizer? = nil
        var twoFingerSwipeRight: UISwipeGestureRecognizer? = nil

        private enum ActiveDragTarget {
            case none
            case adjustingStart(fixedEndPoint: CGPoint, page: PDFPage)
            case adjustingEnd(fixedStartPoint: CGPoint, page: PDFPage)
        }
        private var activeDragTarget: ActiveDragTarget = .none

        // Fluid Word-Snapping Glide Selection Session Tracking
        private var glideStartPoint: CGPoint? = nil
        private var glideStartPage: PDFPage? = nil
        private var glideStartWord: PDFSelection? = nil
        private var lastGlideWordCount: Int = 0
        private var glideTouchDownLocation: CGPoint? = nil
        private var glideTouchDownOnHighlight: HighlightMatch? = nil

        struct HighlightMatch {
            let annotation: PDFAnnotation?
            let id: UUID?
            let text: String
            let bounds: CGRect
            let selection: PDFSelection?
        }

        private var cancellables = Set<AnyCancellable>()

        init(_ parent: ProPDFViewRepresentable) {
            self.parent = parent
            self.canvasProvider = PDFPageCanvasProvider(pdfID: parent.pdf.id, isMarkupActive: parent.isPencilMode)
            super.init()

            InksyncInkingState.shared.$activeToolMode
                .receive(on: RunLoop.main)
                .sink { [weak self] mode in
                    self?.updateInkingGestures(for: mode)
                }
                .store(in: &cancellables)
        }

        func updateInkingGestures(for mode: ReaderToolMode) {
            let inkingState = InksyncInkingState.shared
            let prefs = EBookPreferences.shared
            let isPad = UIDevice.current.userInterfaceIdiom == .pad
            let autoPenActive = isPad && prefs.applePencilAutoDraw && prefs.applePencilDefaultTool == "pen"
            let autoHighlighterActive = isPad && prefs.applePencilAutoDraw && prefs.applePencilDefaultTool == "highlighter"

            let isPenDrawingTool = mode == .write || mode == .eraser
            let isCanvasMarkupActive = (parent.isPencilMode && isPenDrawingTool) || inkingState.isColoringModeActive || (!parent.isPencilMode && autoPenActive)
            canvasProvider.isMarkupActive = isCanvasMarkupActive
            if #available(iOS 16.0, *) {
                parent.pdfViewRef?.isInMarkupMode = isCanvasMarkupActive
            }

            if let pv = parent.pdfViewRef {
                if let sv = pv.subviews.first(where: { $0 is UIScrollView }) as? UIScrollView {
                    sv.panGestureRecognizer.minimumNumberOfTouches = isCanvasMarkupActive ? 2 : 1
                }
            }
            tapGesture?.isEnabled = true

            let isDedicatedHighlighter = parent.isPencilMode && mode == .textHighlight
            let isPencilGlide = isDedicatedHighlighter || (!parent.isPencilMode && autoHighlighterActive)
            let isFingerGlide = isDedicatedHighlighter || (!parent.isPencilMode)

            pencilGlide?.isEnabled = isPencilGlide
            fingerGlide?.isEnabled = isFingerGlide
            fingerGlide?.minimumPressDuration = isDedicatedHighlighter ? 0.04 : 0.18
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        @MainActor func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
            if !parent.isPencilMode {
                NotificationCenter.default.post(name: NSNotification.Name("ReaderToggleMarkupMode"), object: nil)
                InksyncInkingState.shared.activeToolMode = .write
            } else {
                InksyncInkingState.shared.toggleEraser()
            }
            HapticEngine.selection()
        }

        @available(iOS 17.5, *)
        @MainActor func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
            guard squeeze.phase == .ended else { return }
            HapticEngine.selection()
            NotificationCenter.default.post(name: NSNotification.Name("ReaderToggleMarkupMode"), object: nil)
        }

        @MainActor func handleNativeHighlightAction() {
            parent.onHighlightRequested?()
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

            let yDeltas: [CGFloat] = [0, -8, 8, -16, 16, -24, 24, -36, 36]
            let xDeltas: [CGFloat] = [0, -12, 12, -24, 24, -36, 36, -48, 48]

            for dy in yDeltas {
                for dx in xDeltas {
                    if dy == 0 && dx == 0 { continue }
                    let probe = CGPoint(x: point.x + dx, y: point.y + dy)
                    if let word = page.selectionForWord(at: probe),
                       let str = word.string, !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return (word, probe)
                    }
                    if let charSel = page.selection(from: probe, to: probe),
                       let str = charSel.string, !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return (charSel, probe)
                    }
                }
            }
            return nil
        }

        /// Proximity hit-test to detect whether a touch lands on an existing highlight annotation.
        /// Checks live PDFKit page annotations and falls back to AnnotationStore coordinates.
        private func findHighlight(at point: CGPoint, on page: PDFPage, in pdfView: PDFView) -> HighlightMatch? {
            // Check 1: Live PDFKit annotations on the page
            for ann in page.annotations {
                let typeName = ann.type ?? ""
                guard typeName.contains("Highlight") || typeName.contains("Underline") || typeName.contains("StrikeOut") else { continue }
                
                // Allow a comfortable hit-test padding around the annotation bounds
                let hitArea = ann.bounds.insetBy(dx: -14, dy: -10)
                if hitArea.contains(point) {
                    let annID = ann.userName.flatMap { UUID(uuidString: $0) }
                    let text = ann.contents ?? page.selection(for: ann.bounds)?.string ?? ""
                    let sel = page.selection(for: ann.bounds)
                    return HighlightMatch(annotation: ann, id: annID, text: text, bounds: ann.bounds, selection: sel)
                }
            }
            
            // Check 2: AnnotationStore normalized coordinates (fallback if PDFKit annotation bounds differ)
            let storeAnnotations = AnnotationStore.shared.annotations(for: parent.pdf.id)
            let pageCrop = page.bounds(for: .cropBox)
            guard pageCrop.width > 0, pageCrop.height > 0 else { return nil }
            
            let doc = pdfView.document
            let pageIdx = doc.flatMap { $0.index(for: page) } ?? parent.currentPageIndex
            
            for ann in storeAnnotations where ann.pageIndex == pageIdx {
                guard ann.kind == .highlight || ann.kind == .underline || ann.kind == .strikeOut else { continue }
                if let b = ann.bounds {
                    let rect = CGRect(
                        x: pageCrop.minX + CGFloat(b.x) * pageCrop.width,
                        y: pageCrop.minY + CGFloat(b.y) * pageCrop.height,
                        width: CGFloat(b.width) * pageCrop.width,
                        height: CGFloat(b.height) * pageCrop.height
                    )
                    if rect.insetBy(dx: -14, dy: -10).contains(point) {
                        let sel = page.selection(for: rect)
                        return HighlightMatch(annotation: nil, id: ann.id, text: ann.selectedText ?? "", bounds: rect, selection: sel)
                    }
                }
            }
            
            return nil
        }

        @MainActor private func presentHighlightHUD(for match: HighlightMatch, on page: PDFPage, in pdfView: PDFView) {
            if let sel = match.selection, let str = sel.string, !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                pdfView.setCurrentSelection(sel, animate: true)
            } else {
                pdfView.setCurrentSelection(nil, animate: false)
            }
            HapticEngine.selection()
            parent.onHighlightTappedWithAnnotation?(match.annotation, match.id, match.text, match.bounds)
            parent.onHighlightTapped?(match.id, match.text)
        }

        // MARK: - Fluid Word-Snapping Glide Selection
        @MainActor @objc func handleGlideSelection(_ gesture: UILongPressGestureRecognizer) {
            if parent.isPencilMode && InksyncInkingState.shared.activeToolMode != .textHighlight { return }
            guard let pdfView = gesture.view as? PDFView else { return }
            let locationInView = gesture.location(in: pdfView)

            switch gesture.state {
            case .began:
                glideTouchDownLocation = locationInView
                glideTouchDownOnHighlight = nil
                guard let page = pdfView.page(for: locationInView, nearest: true) else { return }

                // If the page has zero text glyphs (scanned comic or scanned document), switch to Pencil Highlighter
                if page.numberOfCharacters == 0 {
                    parent.onScannedPageDetected?()
                    return
                }

                let locationInPage = pdfView.convert(locationInView, to: page)

                // Check if touch begins on an existing highlight annotation
                if let hit = findHighlight(at: locationInPage, on: page, in: pdfView) {
                    glideTouchDownOnHighlight = hit
                    return
                }

                // Check if touch is near start handle or end handle of an existing selection to allow resizing
                if let currentSel = pdfView.currentSelection,
                   let text = currentSel.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   let selPage = currentSel.pages.first, selPage == page {
                    let lines = currentSel.selectionsByLine()
                    let firstLine = lines.first ?? currentSel
                    let lastLine = lines.last ?? currentSel

                    let firstBoundsInPage = firstLine.bounds(for: page)
                    let lastBoundsInPage = lastLine.bounds(for: page)

                    let firstBoundsInView = pdfView.convert(firstBoundsInPage, from: page)
                    let lastBoundsInView = pdfView.convert(lastBoundsInPage, from: page)

                    let startHandleInView = CGPoint(x: firstBoundsInView.minX, y: firstBoundsInView.midY)
                    let endHandleInView = CGPoint(x: lastBoundsInView.maxX, y: lastBoundsInView.midY)

                    let distToStart = hypot(locationInView.x - startHandleInView.x, locationInView.y - startHandleInView.y)
                    let distToEnd = hypot(locationInView.x - endHandleInView.x, locationInView.y - endHandleInView.y)
                    let handleHitRadius: CGFloat = 44.0

                    if distToStart <= handleHitRadius && distToStart <= distToEnd {
                        let fixedEndPointInPage = CGPoint(x: lastBoundsInPage.maxX, y: lastBoundsInPage.midY)
                        activeDragTarget = .adjustingStart(fixedEndPoint: fixedEndPointInPage, page: page)
                        HapticEngine.selection()
                        return
                    } else if distToEnd <= handleHitRadius {
                        let fixedStartPointInPage = CGPoint(x: firstBoundsInPage.minX, y: firstBoundsInPage.midY)
                        activeDragTarget = .adjustingEnd(fixedStartPoint: fixedStartPointInPage, page: page)
                        HapticEngine.selection()
                        return
                    }
                }

                activeDragTarget = .none

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
                if let startLoc = glideTouchDownLocation {
                    let dragDist = hypot(locationInView.x - startLoc.x, locationInView.y - startLoc.y)
                    if dragDist > 14.0 {
                        glideTouchDownOnHighlight = nil
                    } else if glideTouchDownOnHighlight != nil {
                        return
                    }
                }

                switch activeDragTarget {
                case .adjustingStart(let fixedEndPoint, let page):
                    let currentPointInPage = pdfView.convert(locationInView, to: page)
                    if let newSel = page.selection(from: currentPointInPage, to: fixedEndPoint) {
                        pdfView.setCurrentSelection(newSel, animate: false)
                        HapticEngine.selection()
                    }
                    return

                case .adjustingEnd(let fixedStartPoint, let page):
                    let currentPointInPage = pdfView.convert(locationInView, to: page)
                    if let newSel = page.selection(from: fixedStartPoint, to: currentPointInPage) {
                        pdfView.setCurrentSelection(newSel, animate: false)
                        HapticEngine.selection()
                    }
                    return

                case .none:
                    break
                }

                // If touch started on margin or whitespace, dynamically latch as soon as touch glides over text
                if glideStartPoint == nil {
                    guard let targetPage = pdfView.page(for: locationInView, nearest: true) else { return }
                    let rawPointInPage = pdfView.convert(locationInView, to: targetPage)
                    if let match = findWordSelection(at: rawPointInPage, on: targetPage) {
                        glideStartPoint = match.point
                        glideStartPage = targetPage
                        glideStartWord = match.word
                        lastGlideWordCount = 1
                        pdfView.setCurrentSelection(match.word, animate: false)
                        HapticEngine.selection()
                    }
                    return
                }

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
                activeDragTarget = .none

                let startLoc = glideTouchDownLocation ?? locationInView
                let dragDist = hypot(locationInView.x - startLoc.x, locationInView.y - startLoc.y)

                // If touch was a stationary tap on an existing highlight (< 14pt movement), present HUD and do not create duplicate
                if dragDist < 14.0, let page = pdfView.page(for: locationInView, nearest: true) {
                    let locationInPage = pdfView.convert(locationInView, to: page)
                    if let hit = glideTouchDownOnHighlight ?? findHighlight(at: locationInPage, on: page, in: pdfView) {
                        glideTouchDownLocation = nil
                        glideTouchDownOnHighlight = nil
                        glideStartPoint = nil
                        glideStartPage = nil
                        glideStartWord = nil
                        lastGlideWordCount = 0
                        presentHighlightHUD(for: hit, on: page, in: pdfView)
                        return
                    }
                }

                glideTouchDownLocation = nil
                glideTouchDownOnHighlight = nil

                if let selection = pdfView.currentSelection, let text = selection.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let isHighlighterMode = (parent.isPencilMode && InksyncInkingState.shared.activeToolMode == .textHighlight) ||
                                            (!parent.isPencilMode && EBookPreferences.shared.applePencilAutoDraw && EBookPreferences.shared.applePencilDefaultTool == "highlighter" && gesture == pencilGlide)
                    if isHighlighterMode {
                        if let targetPage = selection.pages.first ?? pdfView.currentPage {
                            let color = EBookPreferences.shared.defaultHighlightColor
                            parent.onHighlightSelectionDirect?(selection, targetPage, color)
                            HapticEngine.selection()
                        }
                        // In dedicated highlighter pen mode, clear selection immediately so user sees clean highlight without selection box
                        pdfView.setCurrentSelection(nil, animate: false)
                        parent.onTextSelectionChanged(nil, nil)
                    } else {
                        // Normal text selection in reader: DO NOT auto-commit a highlight! Present HUD for user choice (Highlight, Copy, Note)
                        selectionChanged(Notification(name: .PDFViewSelectionChanged, object: pdfView))
                    }
                    HapticEngine.light()
                }
                glideStartPoint = nil
                glideStartPage = nil
                glideStartWord = nil
                lastGlideWordCount = 0

            case .cancelled, .failed:
                activeDragTarget = .none
                glideTouchDownLocation = nil
                glideTouchDownOnHighlight = nil
                glideStartPoint = nil
                glideStartPage = nil
                glideStartWord = nil
                lastGlideWordCount = 0

            default:
                break
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            if parent.isPencilMode && InksyncInkingState.shared.activeToolMode != .textHighlight {
                if gestureRecognizer === pencilGlide || gestureRecognizer === fingerGlide {
                    return false
                }
            }
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            if gestureRecognizer === twoFingerSwipeLeft || gestureRecognizer === twoFingerSwipeRight ||
               otherGestureRecognizer === twoFingerSwipeLeft || otherGestureRecognizer === twoFingerSwipeRight {
                return true
            }
            if gestureRecognizer === twoFingerTap || otherGestureRecognizer === twoFingerTap ||
               gestureRecognizer === threeFingerTap || otherGestureRecognizer === threeFingerTap {
                return true
            }
            if parent.isPencilMode && InksyncInkingState.shared.activeToolMode != .textHighlight {
                if gestureRecognizer === pencilGlide || gestureRecognizer === fingerGlide ||
                   otherGestureRecognizer === pencilGlide || otherGestureRecognizer === fingerGlide {
                    return false
                }
            }
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            let inkingState = InksyncInkingState.shared
            let currentToolMode = inkingState.activeToolMode
            let prefs = EBookPreferences.shared
            let isPad = UIDevice.current.userInterfaceIdiom == .pad
            let autoPencilActive = isPad && prefs.applePencilAutoDraw
            let isPenDrawingTool = currentToolMode == .write || currentToolMode == .eraser
            let isCanvasMarkupActive = (parent.isPencilMode && isPenDrawingTool) || inkingState.isColoringModeActive || (!parent.isPencilMode && autoPencilActive && prefs.applePencilDefaultTool == "pen")

            // When in markup/drawing mode, NEVER allow tap gesture to receive Apple Pencil touches
            // so stippling, dotting 'i', punctuation, and quick pencil taps draw with 100% fidelity without turning pages.
            if isCanvasMarkupActive && gestureRecognizer == tapGesture {
                if touch.type == .pencil {
                    return false
                }
            }
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

            let inkingState = InksyncInkingState.shared
            let currentToolMode = inkingState.activeToolMode
            let prefs = EBookPreferences.shared
            let isPad = UIDevice.current.userInterfaceIdiom == .pad
            let autoPencilActive = isPad && prefs.applePencilAutoDraw
            let isPenDrawingTool = currentToolMode == .write || currentToolMode == .eraser
            let isCanvasMarkupActive = (parent.isPencilMode && isPenDrawingTool) || inkingState.isColoringModeActive || (!parent.isPencilMode && autoPencilActive && prefs.applePencilDefaultTool == "pen")

            let tapLocation = gesture.location(in: view)
            let width = view.bounds.width
            let zones = prefs.tapZoneStyle.zones
            let isManga = prefs.pdfRTL || UserDefaults.standard.bool(forKey: "isMangaMode")

            if isCanvasMarkupActive {
                // When inking is active, only finger taps in outer margin gutters turn the page.
                // Center taps are ignored so hand resting / inadvertent touches never toggle chrome or disrupt inking.
                let leftGutter = width * max(0.12, zones.leftEdge)
                let rightGutter = width * min(0.88, zones.rightEdge)

                if tapLocation.x < leftGutter {
                    HapticEngine.selection()
                    if isManga {
                        parent.onNextPage()
                    } else {
                        parent.onPrevPage()
                    }
                } else if tapLocation.x > rightGutter {
                    HapticEngine.selection()
                    if isManga {
                        parent.onPrevPage()
                    } else {
                        parent.onNextPage()
                    }
                }
                return
            }

            // If text is currently selected in PDFView, clear selection on single tap OUTSIDE the selection
            if let selection = view.currentSelection, let text = selection.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if let page = view.page(for: tapLocation, nearest: false) {
                    let pagePoint = view.convert(tapLocation, to: page)
                    let selectionBounds = selection.bounds(for: page)
                    // If tap is inside or directly adjoining the active selection (within 44pt horizontally or 32pt vertically), do not clear it
                    if selectionBounds.insetBy(dx: -44, dy: -32).contains(pagePoint) {
                        return
                    }
                }
                view.clearSelection()
                parent.onTextSelectionChanged(nil, nil)
                return
            }

            // If user taps directly on an existing highlight annotation, open the Kindle HUD with color and delete actions
            if let page = view.page(for: tapLocation, nearest: false) {
                let pagePoint = view.convert(tapLocation, to: page)
                if let hit = findHighlight(at: pagePoint, on: page, in: view) {
                    presentHighlightHUD(for: hit, on: page, in: view)
                    return
                }
            }

            if tapLocation.x < width * zones.leftEdge {
                if isManga {
                    parent.onNextPage()
                } else {
                    parent.onPrevPage()
                }
            } else if tapLocation.x > width * zones.rightEdge {
                if isManga {
                    parent.onPrevPage()
                } else {
                    parent.onNextPage()
                }
            } else {
                parent.onTapCenter()
            }
        }

        @MainActor @objc func handleTwoFingerSwipeLeft(_ gesture: UISwipeGestureRecognizer) {
            guard gesture.state == .ended else { return }
            let prefs = EBookPreferences.shared
            let isManga = prefs.pdfRTL || UserDefaults.standard.bool(forKey: "isMangaMode")
            HapticEngine.selection()
            if isManga {
                parent.onPrevPage()
            } else {
                parent.onNextPage()
            }
        }

        @MainActor @objc func handleTwoFingerSwipeRight(_ gesture: UISwipeGestureRecognizer) {
            guard gesture.state == .ended else { return }
            let prefs = EBookPreferences.shared
            let isManga = prefs.pdfRTL || UserDefaults.standard.bool(forKey: "isMangaMode")
            HapticEngine.selection()
            if isManga {
                parent.onNextPage()
            } else {
                parent.onPrevPage()
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

        // MARK: - Multi-Touch Undo & Redo Gesture Handlers

        @MainActor @objc func handleTwoFingerTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended else { return }
            guard let pdfView = gesture.view as? PDFView else { return }
            let location = gesture.location(in: pdfView)
            let targetPage: Int
            if let page = pdfView.page(for: location, nearest: true), let doc = pdfView.document {
                targetPage = doc.index(for: page)
            } else {
                targetPage = parent.currentPageIndex
            }
            parent.onUndoRequested?(targetPage)
        }

        @MainActor @objc func handleThreeFingerTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended else { return }
            guard let pdfView = gesture.view as? PDFView else { return }
            let location = gesture.location(in: pdfView)
            let targetPage: Int
            if let page = pdfView.page(for: location, nearest: true), let doc = pdfView.document {
                targetPage = doc.index(for: page)
            } else {
                targetPage = parent.currentPageIndex
            }
            parent.onRedoRequested?(targetPage)
        }

        @MainActor @objc func scaleChanged(_ notification: Notification) {
            guard let pdfView = notification.object as? PDFView else { return }
            let fitScale = pdfView.scaleFactorForSizeToFit
            let effectiveScale = pdfView.scaleFactor / max(0.01, fitScale)
            if abs(pdfView.scaleFactor - fitScale) > 0.05 {
                userCustomZoomScale = pdfView.scaleFactor
            }
            if EBookPreferences.shared.isZoomLocked {
                EBookPreferences.shared.lockedZoomScale = pdfView.scaleFactor
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
            // Panels / Boox Parity: If zoom is locked, reapply locked zoom scale across page turns
            let prefs = EBookPreferences.shared
            if prefs.isZoomLocked && prefs.lockedZoomScale > 0.1 {
                if abs(pdfView.scaleFactor - prefs.lockedZoomScale) > 0.01 {
                    pdfView.scaleFactor = prefs.lockedZoomScale
                }
            }
        }

        @MainActor @objc func selectionChanged(_ notification: Notification) {
            guard let pdfView = notification.object as? PDFView else { return }
            (pdfView as? ProPDFHighlightableView)?.disableEditMenuInteractions(in: pdfView)

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
