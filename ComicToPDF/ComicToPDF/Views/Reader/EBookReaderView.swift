import SwiftUI
import WebKit
import ZIPFoundation
import SwiftData
import AVFoundation

// MARK: - EBookReaderView
struct EBookReaderView: View {
    let fileURL: URL
    let title: String
    var pdf: ConvertedPDF? = nil
    var onExit: (() -> Void)? = nil
    /// All books in the library — used to find the next volume in a series.
    var allBooks: [ConvertedPDF] = []

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject var conversionManager: ConversionManager
    @ObservedObject private var prefs = EBookPreferences.shared
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.horizontalSizeClass) private var sizeClass
    @ObservedObject private var narrationEngine = EPUBNarrationEngine.shared
    @State private var showingSettingsPanel = false

    // Utilities
    @ObservedObject private var orientationLock = OrientationLockManager.shared
    @ObservedObject private var sleepTimer = SleepTimerManager.shared
    @State private var deviceOrientation = UIDevice.current.orientation

    // Tools
    @State private var showShareSheet = false
    @State private var showSleepTimerPicker = false

    // Preferences — shared across all books
    @StateObject private var velocityEngine = ReaderVelocityEngine()
    @State private var pageEntryTime = Date()

    private func recordEBookPageTurn() {
        let remaining = max(0, totalChapters - (currentIndex + 1))
        let targetID = pdf?.id ?? conversionManager.convertedPDFs.first(where: { $0.url.lastPathComponent == fileURL.lastPathComponent })?.id
        velocityEngine.recordPageTurn(remainingPages: remaining, pdfID: targetID)
    }

    private var bookIdentifier: String {
        if let id = pdf?.id {
            return id.uuidString
        }
        let cleanName = fileURL.lastPathComponent.components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
        return cleanName.isEmpty ? "default_book" : cleanName
    }

    // Per-book progress key: fingerprinted by stable identifier (deterministic across app launches)
    private var progressKey: String { "ebook_progress_\(bookIdentifier)" }
    private var pageKey: String { "ebook_page_\(bookIdentifier)" }


    // State
    @State private var metadata: EBookMetadata?
    @State private var currentIndex: Int = 0
    @State private var isLoading = true
    @State private var showChapterList = false
    @State private var showHUD = true
    @State private var isPencilMode = false
    @State private var pendingTargetAnchor: String? = nil
    @State private var hudIdleTask: Task<Void, Never>? = nil
    @State private var shouldAutoResumeNarrationOnChapterLoad: Bool = false

    private func startHUDIdleTimer(delay: UInt64 = 3_500_000_000) {
        // Keep HUD active while navigating; dismissal is explicit by tapping reading canvas
        hudIdleTask?.cancel()
    }

    private func dismissHUD() {
        hudIdleTask?.cancel()
        withAnimation(.easeInOut(duration: 0.2)) {
            showHUD = false
            selectedTextForHUD = nil
        }
    }

    private func toggleHUD() {
        withAnimation(.easeInOut(duration: 0.2)) {
            showHUD.toggle()
        }
        hudIdleTask?.cancel()
    }
    @State private var errorMessage: String?
    @State private var loadDiagnosticReport: DocumentDiagnosticReport? = nil
    @State private var unzipDir: URL?

    // Page state matching current chapter
    @State private var chapterPage: Int = 0
    @State private var chapterTotalPages: Int = 1
    @State private var startAtEndOfChapter: Bool = false

    private var sanitizedChapterPage: Int {
        min(max(1, chapterPage + 1), max(1, chapterTotalPages))
    }

    /// Direction of last chapter navigation — used to drive the push transition.
    @State private var isGoingForward: Bool = true

    @State private var activeHighlightToEdit: SDAnnotation? = nil
    @State private var annotationForFullEdit: SDAnnotation? = nil
    @State private var selectedTextForHUD: String? = nil
    @State private var isApplyingHighlightDirectly = false
    @State private var lastBrightnessDragValue: CGFloat = 0
    // Toast notification overlay state
    @State private var toastMessage: String = ""
    @State private var showToast: Bool = false
    @State private var toastTask: Task<Void, Never>? = nil
    // Gap A: Annotations & Study Notebook panel
    @State private var showAnnotations = false
    // Dedicated Book Highlights inspector
    @State private var showHighlights = false
    // Gap B: In-reader search
    @State private var showSearch = false
    /// Pending search match text — injected via window.find() after chapter navigation.
    @State private var pendingSearchMatch: String? = nil
    /// Gap B: Weak reference to the live WKWebView — used to call evaluateJavaScript for window.find().
    @State private var webViewReference: WKWebView? = nil
    /// FIX 4: Within-chapter position as a fractional scroll offset (0.0–1.0).
    /// Saved on every page turn and restored on chapter load, so position
    /// survives font-size changes and app restarts unlike a column-integer.
    @State private var chapterScrollFraction: Double = 0.0
    @State private var activeFootnoteText: String? = nil
    @State private var showRSVPSpeedReader = false
    // Key for persisting the scroll fraction alongside the chapter index
    private var fractionKey: String { "ebook_fraction_\(bookIdentifier)" }

    private var rsvpContentText: String {
        guard let dir = unzipDir,
              let item = metadata?.spineItems[safe: currentIndex] else {
            return currentChapterTitle ?? title
        }
        var chapterFileURL = dir.appendingPathComponent(item.href)
        if !FileManager.default.fileExists(atPath: chapterFileURL.path),
           let decoded = item.href.removingPercentEncoding {
            chapterFileURL = dir.appendingPathComponent(decoded)
        }
        if let rawHTML = (try? String(contentsOf: chapterFileURL, encoding: .utf8))
                      ?? (try? String(contentsOf: chapterFileURL, encoding: .isoLatin1)) {
            let plain = rawHTML
                .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "&nbsp;", with: " ")
                .replacingOccurrences(of: "&amp;",  with: "&")
                .replacingOccurrences(of: "&lt;",   with: "<")
                .replacingOccurrences(of: "&gt;",   with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            if !plain.isEmpty {
                return plain
            }
        }
        return currentChapterTitle ?? title
    }

    private var footnoteBinding: Binding<FootnoteItem?> {
        Binding<FootnoteItem?>(
            get: { activeFootnoteText.map { FootnoteItem(text: $0) } },
            set: { activeFootnoteText = $0?.text }
        )
    }

    private var currentChapterTitle: String? {
        guard let spine = metadata?.spineItems, spine.indices.contains(currentIndex) else { return nil }
        let label = spine[currentIndex].label.trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty ? nil : label
    }

    private var totalChapters: Int { metadata?.spineItems.count ?? 1 }
    private var visibleChapters: [(index: Int, label: String)] {
        guard let spine = metadata?.spineItems else { return [] }
        return spine.enumerated().map { (index: $0.offset, label: !$0.element.label.isEmpty ? $0.element.label : "Section \($0.offset + 1)") }
    }
    private var progressFraction: Double {
        guard totalChapters > 1 else { return 0 }
        return Double(currentIndex) / Double(totalChapters - 1)
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Background bleeds into status bar
            prefs.activeTheme.background(colorScheme: colorScheme).ignoresSafeArea()

            // ── Main Reader Canvas (100% Invariant Fixed Viewport) ─────
            Group {
                if isLoading {
                    readerLoadingView
                } else if let err = errorMessage {
                    readerErrorView(err)
                } else if let meta = metadata, !meta.spineItems.isEmpty {
                    readerCanvasView(meta: meta)
                }
            }
            .readingFilter(prefs.readingFilter)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .ignoresSafeArea()

            // ── Reading Progress Bar (Fixed Top Floating Overlay) ──────────
            GeometryReader { geo in
                let topInset = geo.safeAreaInsets.top
                ZStack(alignment: .leading) {
                    Rectangle().fill(prefs.activeTheme.foreground(colorScheme: colorScheme).opacity(0.08)).frame(height: 2)
                    Rectangle()
                        .fill(LinearGradient(colors: [Color(hex: "#7B5EA7"), Color(hex: "#B39DDB")],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * progressFraction, height: 2)
                        .animation(.spring(response: 0.4), value: progressFraction)
                }
                .frame(height: 2)
                .padding(.top, max(topInset > 0 ? topInset : 20, 16))
            }
            .frame(height: 2)
            .allowsHitTesting(false)

            // ── HUD Overlays (tap-to-show UI) ─────────────────────────────
            if showChapterList { chapterDrawer }
        }
        .navigationBarHidden(true)
        .statusBarHidden(false)
        .overlay { readerOverlays }
        .fullScreenCover(isPresented: $showRSVPSpeedReader) {
            rsvpSpeedReaderView
        }
        // Settings sheet lives here only — NOT duplicated inside chapterDrawer
        .sheet(isPresented: $showingSettingsPanel) {
            settingsSheet
        }
        .sheet(isPresented: $showAnnotations) {
            annotationsSheet
        }
        .sheet(isPresented: $showHighlights) {
            highlightsSheet
        }
        .sheet(isPresented: $showSleepTimerPicker) {
            SleepTimerPickerSheet()
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(activityItems: [fileURL])
        }
        .popover(item: footnoteBinding) { item in
            footnotePopover(for: item)
        }
        .task { await loadBook() }
        .onDisappear {
            hudIdleTask?.cancel()
            shouldAutoResumeNarrationOnChapterLoad = false
            clearSentenceHighlightInWebKit()
            narrationEngine.stop()
            cleanup()
            saveProgress()
        }
        // FIX 4: Save scroll fraction whenever the chapter page changes
        .onChange(of: chapterPage) { _, _ in
            saveProgress()
            recordEBookPageTurn()
            let elapsed = Date().timeIntervalSince(pageEntryTime)
            pageEntryTime = Date()
            Task {
                await ReadingPaceTracker.shared.recordPageTurn(wordsOnPage: 280, timeSpentSeconds: max(2.0, min(180.0, elapsed)))
            }
        }
        .onChange(of: showingSettingsPanel) { _, isShowing in
            if isShowing { hudIdleTask?.cancel() }
            else { startHUDIdleTimer(delay: 3_500_000_000) }
        }
        .onChange(of: showHighlights) { _, isShowing in
            if isShowing { hudIdleTask?.cancel() }
            else { startHUDIdleTimer(delay: 3_500_000_000) }
        }
        .onChange(of: showAnnotations) { _, isShowing in
            if isShowing { hudIdleTask?.cancel() }
            else { startHUDIdleTimer(delay: 3_500_000_000) }
        }
        .onChange(of: showSearch) { _, isShowing in
            if isShowing { hudIdleTask?.cancel() }
            else { startHUDIdleTimer(delay: 3_500_000_000) }
        }
        // Also save position when the app goes to the background
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            saveProgress()
        }
        .onChange(of: sleepTimer.didFire) { _, fired in
            if fired { if let onExit = onExit { onExit() } else { dismiss() } }
        }
        // FIX 1+2: Colour picker popover for EPUB highlights
        .popover(item: $activeHighlightToEdit) { annotation in
            highlightQuickPopover(for: annotation)
        }
        .sheet(item: $annotationForFullEdit) { annotation in
            AnnotationEditSheet(annotation: annotation)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        // Gap B: Full-text EPUB search sheet
        .sheet(isPresented: $showSearch) {
            searchSheet
        }
        .onReceive(NotificationCenter.default.publisher(for: .readerJumpToPage)) { notification in
            handleReaderJumpToPage(notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("Reader_JumpToChapterHref"))) { notification in
            handleJumpToChapterHref(notification)
        }
        .onChange(of: currentIndex) { _, _ in
            handleCurrentIndexChanged()
            if shouldAutoResumeNarrationOnChapterLoad {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    guard shouldAutoResumeNarrationOnChapterLoad else { return }
                    shouldAutoResumeNarrationOnChapterLoad = false
                    startNarration()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .annotationsDidChange)) { notif in
            handleAnnotationsDidChange(notif)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("InksyncPro.ShowToast"))) { notif in
            if let msg = notif.userInfo?["message"] as? String {
                showToastMessage(msg)
            }
        }
    }

    // MARK: - Reader Canvas
    @ViewBuilder
    private func readerCanvasView(meta: EBookMetadata) -> some View {
        ZStack {
            if prefs.paginationMode == EBookPaginationMode.paged.rawValue {
                pagedCurlReaderView(meta: meta)
            } else {
                scrollWebReaderView(meta: meta)
            }
            EdgeBrightnessGestureZone()
        }
    }

    @ViewBuilder
    private func pagedCurlReaderView(meta: EBookMetadata) -> some View {
        EBookPageCurlReader(
            spineItem:   meta.spineItems[safe: currentIndex] ?? meta.spineItems[0],
            unzipDir:    unzipDir,
            prefs:       prefs,
            colorScheme: colorScheme,
            currentPage: $chapterPage,
            initialPage: chapterPage,
            totalPages:  $chapterTotalPages,
            startAtEndOfChapter: startAtEndOfChapter,
            spineIndex:  currentIndex,
            isPencilMode: isPencilMode,
            onNext:      nextChapter,
            onPrev:      prevChapter,
            onCenterTap: toggleHUD,
            onPageTurn:  { recordEBookPageTurn() },
            isHUDShowing: showHUD,
            onHighlightCreated: { selectedText in
                guard !isApplyingHighlightDirectly else { return }
                let defaultColor = EBookPreferences.shared.defaultHighlightColor.rawValue
                applyHighlight(text: selectedText, colorHex: defaultColor, symbol: nil)
            },
            onHighlightCreatedWithMetadata: { idStr, selectedText, colorHex in
                let hId = UUID(uuidString: idStr) ?? UUID()
                saveHighlightFromDirectDOM(id: hId, text: selectedText, colorHex: colorHex)
            },
            onHighlightTapped: { tappedIdentifier in
                if let sdMatch = findMatchingAnnotation(tappedText: tappedIdentifier) {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        selectedTextForHUD = sdMatch.selectedText ?? tappedIdentifier
                        activeHighlightToEdit = sdMatch
                    }
                } else {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        selectedTextForHUD = tappedIdentifier
                    }
                }
                HapticEngine.selection()
            },
            onTextSelected: { text in
                withAnimation(.easeInOut(duration: 0.18)) {
                    selectedTextForHUD = text
                }
            },
            onSelectionDismissed: {
                guard !isApplyingHighlightDirectly else { return }
                withAnimation(.easeInOut(duration: 0.18)) {
                    selectedTextForHUD = nil
                }
            },
            pdfID: pdf?.id,
            initialScrollFraction: UserDefaults.standard.double(forKey: fractionKey),
            onScrollFractionChanged: { fraction in
                chapterScrollFraction = fraction
                saveProgress()
            },
            webViewRef: $webViewReference,
            onFootnoteTapped: { text in
                activeFootnoteText = text
            },
            targetAnchor: pendingTargetAnchor
        )
        .clipped()
        .id("ebook_\(prefs.pageTurnStyle.rawValue)")
    }

    @ViewBuilder
    private func scrollWebReaderView(meta: EBookMetadata) -> some View {
        EBookWebReader(
            spineItem:   meta.spineItems[safe: currentIndex] ?? meta.spineItems[0],
            unzipDir:    unzipDir,
            prefs:       prefs,
            colorScheme: colorScheme,
            currentPage: $chapterPage,
            initialPage: chapterPage,
            totalPages:  $chapterTotalPages,
            onNext:      nextChapter,
            onPrev:      prevChapter,
            onCenterTap: toggleHUD,
            onPageTurn:  { recordEBookPageTurn() },
            onHighlightCreated: { selectedText in
                guard let p = pdf else { return }
                let rawLabel = metadata?.spineItems[safe: currentIndex]?.label ?? ""
                let spineLabel = !rawLabel.isEmpty ? rawLabel : nil
                let highlight = Annotation(
                    pdfID: p.id,
                    pageIndex: currentIndex,
                    chapterTitle: spineLabel,
                    kind: .highlight,
                    createdAt: Date(),
                    modifiedAt: Date(),
                    colorHex: prefs.defaultHighlightColor.rawValue,
                    selectedText: selectedText
                )
                AnnotationStore.shared.add(highlight)
                activeHighlightToEdit = findMatchingAnnotation(tappedText: highlight.id.uuidString)
            },
            pdfID: pdf?.id,
            initialScrollFraction: UserDefaults.standard.double(forKey: fractionKey),
            onScrollFractionChanged: { fraction in
                chapterScrollFraction = fraction
                saveProgress()
            },
            webViewRef: $webViewReference,
            onFootnoteTapped: { text in
                activeFootnoteText = text
            }
        )
        .id("ebook_web_\(currentIndex)")
    }

    // MARK: - Top Bar (Glass HUD)
    @ViewBuilder private func topBar(topInset: CGFloat = 0) -> some View {
        HStack(spacing: 10) {
            // Back Button
            Button { if let onExit = onExit { onExit() } else { dismiss() } } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.inkText)
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().stroke(Color.inkBorderSubtle, lineWidth: 0.5))
            }

            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.inkText)
                .lineLimit(1)
                .shadow(color: colorScheme == .dark ? .black.opacity(0.6) : .clear, radius: 3)

            Spacer()

            // Narration playing badge
            if narrationEngine.isPlaying {
                Button { toggleNarration() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: narrationEngine.isPaused ? "pause.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 10))
                        Text(narrationEngine.isPaused ? "Paused" : "Playing")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(Color.green)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().stroke(Color.inkBorderSubtle, lineWidth: 0.5))
                }
            }

            // Sleep timer badge
            if sleepTimer.isActive {
                Button { showSleepTimerPicker = true } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "moon.zzz.fill").font(.system(size: 10))
                        Text(sleepTimer.formattedRemaining).font(.system(size: 11, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(Color.orange)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().stroke(Color.inkBorderSubtle, lineWidth: 0.5))
                }
            }

            // Bookmark
            Button { toggleBookmark() } label: {
                Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isBookmarked ? Color.orange : Color.inkText)
                    .frame(width: 34, height: 34)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().stroke(Color.inkBorderSubtle, lineWidth: 0.5))
            }

            // Orientation lock (iPad regular width)
            if sizeClass == .regular {
                Button { orientationLock.toggleLock(current: deviceOrientation) } label: {
                    Image(systemName: orientationLock.isLocked ? "lock.rotation" : "lock.rotation.open")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(orientationLock.isLocked ? Color.orange : Color.inkText)
                        .frame(width: 34, height: 34)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().stroke(Color.inkBorderSubtle, lineWidth: 0.5))
                }
            }

            // Dedicated Typography / Settings (aA) Button
            Button {
                HapticEngine.selection()
                showingSettingsPanel.toggle()
            } label: {
                Image(systemName: "textformat.size")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(showingSettingsPanel ? Color.orange : Color.inkText)
                    .frame(width: 34, height: 34)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().stroke(Color.inkBorderSubtle, lineWidth: 0.5))
            }
            .help("Typography, Font, Themes & Layout")
            .accessibilityLabel("Typography and Reader Settings")

            Menu {
                Section("Appearance") {
                    Button { showingSettingsPanel.toggle() } label: {
                        Label("Text & Layout", systemImage: "textformat.size")
                    }
                    if sizeClass != .regular {
                        Button { orientationLock.toggleLock(current: deviceOrientation) } label: {
                            Label(
                                orientationLock.isLocked ? "Unlock Orientation" : "Lock Orientation",
                                systemImage: orientationLock.isLocked ? "lock.rotation" : "lock.rotation.open"
                            )
                        }
                    }
                }
                Section("Navigate") {
                    Button { showChapterList = true } label: {
                        Label("Table of Contents", systemImage: "list.bullet.rectangle")
                    }
                    .disabled(metadata?.spineItems.isEmpty ?? true)
                    // Gap B: In-reader full-text search
                    Button { showSearch = true } label: {
                        Label("Search in Book", systemImage: "magnifyingglass")
                    }
                }
                Section("Tools") {
                    // Dedicated Book Highlights Inspector
                    Button {
                        HapticEngine.selection()
                        showHighlights = true
                    } label: {
                        Label("Book Highlights", systemImage: "highlighter")
                    }
                    // Dedicated Study Notebook (Notes, Cornell, PencilKit)
                    Button {
                        HapticEngine.selection()
                        if sizeClass == .regular {
                            NotificationCenter.default.post(name: .toggleStudyNotebook, object: nil)
                        } else {
                            showAnnotations = true
                        }
                    } label: {
                        Label("Study Notebook", systemImage: "note.text")
                    }
                    Button { toggleNarration() } label: {
                        Label(
                            narrationEngine.isActive ? "Stop Read Aloud" : "Read Aloud (TTS)",
                            systemImage: narrationEngine.isActive ? "speaker.slash.fill" : "speaker.wave.3"
                        )
                    }
                    Button {
                        HapticEngine.selection()
                        showRSVPSpeedReader = true
                    } label: {
                        Label("Speed Read (RSVP)", systemImage: "hare.fill")
                    }
                    Button { showShareSheet = true } label: {
                        Label("Share Book", systemImage: "square.and.arrow.up")
                    }
                    Button { showSleepTimerPicker = true } label: {
                        Label(
                            sleepTimer.isActive ? "Sleep Timer (\(sleepTimer.formattedRemaining))" : "Sleep Timer\u{2026}",
                            systemImage: "moon.zzz"
                        )
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.inkText)
                    .frame(width: 34, height: 34)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().stroke(Color.inkBorderSubtle, lineWidth: 0.5))
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, max(topInset + 8, 44))
        .padding(.bottom, 10)
        .background(
            LinearGradient(
                colors: colorScheme == .dark
                    ? [Color.black.opacity(0.65), Color.clear]
                    : [Color.white.opacity(0.92), Color.white.opacity(0.4), Color.clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .top)
        )
    }

    // MARK: - Bottom Bar (Glass HUD)
    @ViewBuilder private func bottomBar(bottomInset: CGFloat = 0) -> some View {
        VStack(spacing: 0) {
            // ── Progress Scrubber ─────────────────────────────────────────
            if totalChapters > 1 {
                HStack(spacing: 10) {
                    Text("1")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.inkSecondary)
                        .frame(width: 16, alignment: .leading)
                    Slider(
                        value: Binding(
                            get: { progressFraction },
                            set: { newVal in
                                let target = Int((newVal * Double(totalChapters - 1)).rounded())
                                if target != currentIndex {
                                    pendingTargetAnchor = nil
                                    chapterPage = 0
                                    chapterScrollFraction = 0.0
                                }
                                withAnimation(.easeInOut(duration: 0.18)) { currentIndex = target }
                                saveProgress()
                                startHUDIdleTimer()
                            }
                        ),
                        in: 0...1
                    )
                    .tint(Color(hex: "#B39DDB"))
                    Text("\(totalChapters)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.inkSecondary)
                        .frame(width: 16, alignment: .trailing)
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 4)

                Rectangle()
                    .fill(Color.inkBorderSubtle)
                    .frame(height: 0.5)
                    .padding(.horizontal, 16)
            }

            // ── Navigation row ─────────────────────────────────────────
            HStack(spacing: 24) {
                Button { prevChapter() } label: {
                    Image(systemName: "chevron.left.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(currentIndex == 0 ? Color.inkSecondary.opacity(0.25) : Color.inkText)
                }
                .disabled(currentIndex == 0)

                VStack(spacing: 2) {
                    Text("Page \(sanitizedChapterPage) of \(max(1, chapterTotalPages))")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.inkText)
                    if let title = currentChapterTitle {
                        Text(title)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.inkSecondary)
                            .lineLimit(1)
                    } else if totalChapters > 1 {
                        Text("Section \(currentIndex + 1) / \(totalChapters)")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.inkSecondary)
                    }
                    // Time remaining estimate
                    if let mins = ReaderProgressTracker.shared.progress(for: pdf?.id ?? UUID())?.estimatedMinutesRemaining, mins > 0 {
                        Text("~\(mins)m left")
                            .font(.system(size: 10, weight: .regular, design: .rounded))
                            .foregroundStyle(colorScheme == .dark ? Color(hex: "#B39DDB").opacity(0.85) : Color.inkViolet)
                    }
                }
                .frame(minWidth: 100)

                Button { nextChapter() } label: {
                    Image(systemName: "chevron.right.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(currentIndex >= totalChapters - 1 ? Color.inkSecondary.opacity(0.25) : Color.inkText)
                }
                .disabled(currentIndex >= totalChapters - 1)
            }
            .padding(.top, 14)
            .padding(.bottom, max(bottomInset + 8, 20))
            .padding(.horizontal, 24)
        }
        .background(
            LinearGradient(
                colors: colorScheme == .dark
                    ? [Color.clear, Color.black.opacity(0.70)]
                    : [Color.clear, Color.white.opacity(0.4), Color.white.opacity(0.92)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
        )
    }

    // MARK: - Chapter Drawer
    @ViewBuilder private var chapterDrawer: some View {
        ZStack {
            Color.black.opacity(0.3)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.spring()) {
                        showChapterList = false
                    }
                }

            VStack(spacing: 0) {
                Color.clear.frame(height: 72) // clear under top bar
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(visibleChapters, id: \.index) { item in
                                Button {
                                    let fromIndex = currentIndex
                                    let toIndex = item.index
                                    let fromLabel = currentChapterTitle
                                    if fromIndex != toIndex {
                                        ReadingJumpTracker.shared.recordJump(fromPage: fromIndex, toPage: toIndex, chapterLabel: fromLabel) {
                                            withAnimation(.spring()) {
                                                isGoingForward = fromIndex >= currentIndex
                                                currentIndex = fromIndex
                                                chapterPage = 0
                                                chapterScrollFraction = 0.0
                                                saveProgress()
                                            }
                                        }
                                    }
                                    withAnimation(.spring()) {
                                        currentIndex = item.index
                                        chapterPage = 0
                                        chapterScrollFraction = 0.0
                                        pendingTargetAnchor = nil
                                        showChapterList = false
                                    }
                                    dismissHUD()
                                    saveProgress()
                                } label: {
                                    HStack(spacing: 12) {
                                        RoundedRectangle(cornerRadius: 2)
                                            .fill(item.index == currentIndex ? Color(hex: "#7B5EA7") : Color.clear)
                                            .frame(width: 3, height: 22)
                                        Text(item.label)
                                            .font(.subheadline)
                                            .fontWeight(item.index == currentIndex ? .semibold : .regular)
                                            .foregroundStyle(
                                                item.index == currentIndex
                                                    ? Color(hex: "#7B5EA7")
                                                    : prefs.activeTheme.foreground(colorScheme: colorScheme)
                                            )
                                        Spacer()
                                        if item.index == currentIndex {
                                            Image(systemName: "book.fill")
                                                .font(.system(size: 10))
                                                .foregroundStyle(Color(hex: "#7B5EA7").opacity(0.7))
                                        }
                                    }
                                    .padding(.horizontal, 16).padding(.vertical, 13)
                                    .background(item.index == currentIndex ? Color(hex: "#7B5EA7").opacity(0.08) : Color.clear)
                                }
                                .buttonStyle(.plain)
                                .id(item.index)
                                Divider().opacity(0.3)
                            }
                        }
                    }
                    .onAppear { proxy.scrollTo(currentIndex, anchor: .center) }
                }
                .frame(maxWidth: 320)
                .background(prefs.activeTheme.background(colorScheme: colorScheme).opacity(0.97))
                .background(.thinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: .black.opacity(0.15), radius: 20, x: 0, y: 8)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 16)
                Spacer()
            }
        }
        .transition(.asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal:   .move(edge: .trailing).combined(with: .opacity)
        ))
    }

    // MARK: - Loading & Error States
    private var readerLoadingView: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(Color(hex: "#7B5EA7").opacity(0.12))
                    .frame(width: 72, height: 72)
                Image(systemName: "book.pages.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color(hex: "#7B5EA7"), Color(hex: "#B39DDB")],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
            }
            .symbolEffect(.pulse, options: .repeating)

            VStack(spacing: 6) {
                Text("Opening Book")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(prefs.activeTheme.foreground(colorScheme: colorScheme))
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(prefs.activeTheme.foreground(colorScheme: colorScheme).opacity(0.5))
                    .lineLimit(1)
            }

            ProgressView()
                .progressViewStyle(.circular)
                .tint(Color(hex: "#7B5EA7"))
        }
    }

    @ViewBuilder
    private func readerErrorView(_ msg: String) -> some View {
        if let report = loadDiagnosticReport {
            DocumentOpenErrorView(
                report: report,
                onRetry: {
                    isLoading = true
                    errorMessage = nil
                    loadDiagnosticReport = nil
                    Task { await loadBook() }
                },
                onDismiss: {
                    if let onExit = onExit { onExit() } else { dismiss() }
                }
            )
        } else {
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.orange)
                Text("Couldn't Open Book").font(.headline).foregroundStyle(prefs.activeTheme.foreground(colorScheme: colorScheme))
                Text(msg).font(.subheadline).foregroundStyle(prefs.activeTheme.foreground(colorScheme: colorScheme).opacity(0.6))
                    .multilineTextAlignment(.center).padding(.horizontal, 40)
            }
        }
    }

    // MARK: - Navigation
    private func nextChapter() {
        if !shouldAutoResumeNarrationOnChapterLoad && narrationEngine.isActive {
            narrationEngine.stop()
            clearSentenceHighlightInWebKit()
        }
        if currentIndex >= totalChapters - 1 {
            // Last chapter — try to jump to next volume in series
            shouldAutoResumeNarrationOnChapterLoad = false
            attemptSeriesContinuation()
            return
        }
        HapticEngine.medium()
        isGoingForward = true
        startAtEndOfChapter = false
        chapterPage = 0
        chapterScrollFraction = 0.0
        pendingTargetAnchor = nil
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { currentIndex += 1 }
        saveProgress()
        trackEBookProgress()
    }

    /// Delegates to ReadingContinuationResolver to auto-transition to the next book
    /// in the user's custom collection (story arc), virtual omnibus, or publisher series.
    private func attemptSeriesContinuation() {
        guard let currentPDF = pdf else { return }
        saveProgress()
        trackEBookProgress()
        _ = ReadingContinuationResolver.shared.continueReading(after: currentPDF, in: allBooks)
    }

    private func prevChapter() {
        shouldAutoResumeNarrationOnChapterLoad = false
        if narrationEngine.isActive {
            narrationEngine.stop()
            clearSentenceHighlightInWebKit()
        }
        guard currentIndex > 0 else { return }
        HapticEngine.medium()
        isGoingForward = false
        startAtEndOfChapter = true
        chapterPage = 0
        chapterScrollFraction = 1.0
        pendingTargetAnchor = nil
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { currentIndex -= 1 }
        saveProgress()
        trackEBookProgress()
    }

    // MARK: - Navigation & Search Handlers
    private func handleSearchNavigation(chapterIdx: Int, matchText: String) {
        if chapterIdx == currentIndex {
            if let wv = resolveActiveWebView() ?? webViewReference {
                let safe = matchText
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "'", with: "\\'")
                let js = """
                (function() {
                    window.getSelection()?.removeAllRanges();
                    var found = window.find('\(safe)', false, false, true, false, false, false);
                    if (!found) { found = window.find('\(safe)', false, false, false, false, false, false); }
                    if (!found) return -1;
                    var sel = window.getSelection();
                    if (sel && sel.rangeCount > 0) {
                        var range = sel.getRangeAt(0);
                        var rect = range.getBoundingClientRect();
                        var pageStep = (typeof getPageStep === 'function') ? getPageStep() : (window.innerWidth || 1);
                        var vp = document.getElementById('inksync-viewport') || document.body;
                        var curTransform = 0;
                        if (vp) {
                            var style = window.getComputedStyle(vp);
                            var matrix = new WebKitCSSMatrix(style.transform);
                            curTransform = Math.abs(matrix.m41);
                        }
                        var absoluteLeft = rect.left + curTransform;
                        var isMulti = (typeof _isMultiCol !== 'undefined') ? _isMultiCol : false;
                        var colWidth = isMulti ? (pageStep / 2) : pageStep;
                        if (colWidth > 0) {
                            return Math.floor(absoluteLeft / colWidth);
                        }
                    }
                    return -1;
                })();
                """
                wv.evaluateJavaScript(js) { result, _ in
                    if let col = result as? Int, col >= 0 {
                        DispatchQueue.main.async {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                self.chapterPage = col
                            }
                            self.saveProgress()
                        }
                    }
                }
            }
        } else {
            isGoingForward = chapterIdx >= currentIndex
            pendingTargetAnchor = nil
            currentIndex = chapterIdx
            chapterPage = 0
            saveProgress()
            pendingSearchMatch = matchText
        }
    }

    private func handleReaderJumpToPage(_ notification: Notification) {
        dismissHUD()
        showChapterList = false
        showHighlights = false
        showSearch = false
        showAnnotations = false

        // 1. If chapterTitle is specified, locate and jump to that chapter
        if let targetChapter = notification.userInfo?["chapterTitle"] as? String,
           let meta = metadata,
           let chapterIdx = meta.spineItems.firstIndex(where: {
               $0.label.localizedCaseInsensitiveContains(targetChapter) ||
               targetChapter.localizedCaseInsensitiveContains($0.label) ||
               ($0.tocTitle ?? "").localizedCaseInsensitiveContains(targetChapter) ||
               targetChapter.localizedCaseInsensitiveContains($0.tocTitle ?? "")
           }) {
            if chapterIdx != currentIndex {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    isGoingForward = chapterIdx >= currentIndex
                    pendingTargetAnchor = nil
                    currentIndex = chapterIdx
                }
            }
        }

        // 2. Navigate to specific page within chapter or whole chapter
        if let targetPage = notification.userInfo?["chapterPage"] as? Int ?? notification.userInfo?["pageIndex"] as? Int {
            if targetPage < chapterTotalPages {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    chapterPage = max(0, targetPage)
                }
                let activeWV = resolveActiveWebView() ?? webViewReference
                activeWV?.evaluateJavaScript("if(window.goToInksyncPage) window.goToInksyncPage(\(targetPage), false);")
                saveProgress()
            } else if targetPage < totalChapters && notification.userInfo?["chapterPage"] == nil {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    isGoingForward = targetPage >= currentIndex
                    pendingTargetAnchor = nil
                    currentIndex = targetPage
                    chapterPage = 0
                    saveProgress()
                }
            }
        }
    }

    private func handleJumpToChapterHref(_ notification: Notification) {
        dismissHUD()
        showChapterList = false
        showHighlights = false
        showSearch = false
        showAnnotations = false

        guard let rawHref = notification.userInfo?["href"] as? String, !rawHref.isEmpty, let meta = metadata else { return }
        let fragment = notification.userInfo?["fragment"] as? String ?? ""

        let cleanTarget = (rawHref.components(separatedBy: "#").first ?? rawHref).lowercased()
        let targetFileName = (cleanTarget as NSString).lastPathComponent.lowercased()

        guard let targetIdx = meta.spineItems.firstIndex(where: {
            let itemHref = $0.href.lowercased()
            let itemFileName = ($0.href as NSString).lastPathComponent.lowercased()
            return itemHref == cleanTarget || itemHref.hasSuffix("/" + cleanTarget) || itemFileName == targetFileName
        }) else { return }

        let targetFragment = fragment.isEmpty ? nil : fragment
        self.pendingTargetAnchor = targetFragment

        if targetIdx != currentIndex {
            shouldAutoResumeNarrationOnChapterLoad = false
            if narrationEngine.isActive {
                narrationEngine.stop()
                clearSentenceHighlightInWebKit()
            }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                isGoingForward = targetIdx >= currentIndex
                currentIndex = targetIdx
                chapterPage = 0
                saveProgress()
            }
        } else if let targetFragment = targetFragment {
            // Anchor navigation within current chapter
            let js = """
            (function() {
                var fragment = "\(targetFragment)";
                var el = document.getElementById(fragment) || document.getElementsByName(fragment)[0];
                if (el) {
                    var vp = document.getElementById('inksync-viewport');
                    var rect = el.getBoundingClientRect();
                    var absLeft = vp ? (rect.left - vp.getBoundingClientRect().left) : (rect.left + (_currentShift || 0));
                    var pageStep = (typeof getPageStep === 'function') ? getPageStep() : (window.innerWidth || 1);
                    var isMulti = (typeof _isMultiCol !== 'undefined') ? _isMultiCol : false;
                    var colWidth = isMulti ? (pageStep / 2) : pageStep;
                    if (colWidth > 0) {
                        var targetPage = Math.max(0, Math.min(Math.floor(absLeft / colWidth), _totalPages - 1));
                        if (typeof goToPage === 'function') {
                            goToPage(targetPage, false);
                        } else if (window.goToInksyncPage) {
                            window.goToInksyncPage(targetPage, false);
                        }
                    }
                }
            })();
            """
            let activeWV = resolveActiveWebView() ?? webViewReference
            activeWV?.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    private func handleAnnotationsDidChange(_ notif: Notification) {
        let activeWV = resolveActiveWebView() ?? webViewReference
        if let deletedID = notif.userInfo?["deletedID"] as? UUID {
            let idStr = deletedID.uuidString
            activeWV?.evaluateJavaScript("if (window.removeInksyncHighlight) { window.removeInksyncHighlight('\(idStr)'); }")
        }
        if let deletedText = notif.userInfo?["text"] as? String, !deletedText.isEmpty {
            let safeText = deletedText
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "`", with: "\\`")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: " ")
            activeWV?.evaluateJavaScript("if (window.removeInksyncHighlight) { window.removeInksyncHighlight(`\(safeText)`); }")
        }
    }

    private func handleCurrentIndexChanged() {
        guard let match = pendingSearchMatch, !match.isEmpty else { return }
        Task { @MainActor in
            // Poll for active webview readiness (up to 6 attempts, 150ms apart)
            for _ in 0..<6 {
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard let wv = resolveActiveWebView() ?? webViewReference else { continue }
                let safe = match
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "'", with: "\\'")
                let js = """
                (function() {
                    window.getSelection()?.removeAllRanges();
                    var found = window.find('\(safe)', false, false, true, false, false, false);
                    if (!found) { found = window.find('\(safe)', false, false, false, false, false, false); }
                    if (!found) return -1;
                    var sel = window.getSelection();
                    if (sel && sel.rangeCount > 0) {
                        var range = sel.getRangeAt(0);
                        var rect = range.getBoundingClientRect();
                        var pageStep = (typeof getPageStep === 'function') ? getPageStep() : (window.innerWidth || 1);
                        var vp = document.getElementById('inksync-viewport') || document.body;
                        var curTransform = 0;
                        if (vp) {
                            var style = window.getComputedStyle(vp);
                            var matrix = new WebKitCSSMatrix(style.transform);
                            curTransform = Math.abs(matrix.m41);
                        }
                        var absoluteLeft = rect.left + curTransform;
                        var isMulti = (typeof _isMultiCol !== 'undefined') ? _isMultiCol : false;
                        var colWidth = isMulti ? (pageStep / 2) : pageStep;
                        if (colWidth > 0) {
                            return Math.floor(absoluteLeft / colWidth);
                        }
                    }
                    return -1;
                })();
                """
                if let res = try? await wv.evaluateJavaScript(js), let col = res as? Int, col >= 0 {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        self.chapterPage = col
                    }
                    self.saveProgress()
                    self.pendingSearchMatch = nil
                    break
                }
            }
        }
    }

    nonisolated private static func unzipBook(from source: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.unzipItem(at: source, to: destination)
    }

    // MARK: - Load & Cleanup
    private func loadBook() async {
        Logger.shared.log("EBookReader: opening \(fileURL.lastPathComponent)", category: "EBook")

        // Restore saved progress
        var saved = UserDefaults.standard.integer(forKey: progressKey)
        let savedPage = UserDefaults.standard.integer(forKey: pageKey)

        // iCloud Sync Fallback: if local UserDefaults is 0, check ReaderProgressTracker (which syncs via NSUbiquitousKeyValueStore)
        let resolvedPDF = pdf ?? conversionManager.convertedPDFs.first(where: { $0.url.lastPathComponent == fileURL.lastPathComponent })
        if saved == 0, let p = resolvedPDF,
           let trackerProg = ReaderProgressTracker.shared.progress(for: p.id),
           let ch = trackerProg.currentChapterIndex, ch > 0 {
            saved = ch
        }

        // Linked Library: resolve security-scoped URL.
        var targetURL: URL = fileURL
        var accessedURL: URL? = nil

        if let pdf = pdf {
            if case .cloud = pdf.sourceMode {
                self.errorMessage = nil
                do {
                    targetURL = try await CloudDownloadManager.shared.streamCloudFile(pdf: pdf)
                } catch {
                    let report = DocumentOpenDiagnostics.logFailure(url: fileURL, pdf: pdf, error: error, context: "EBookReaderView")
                    self.loadDiagnosticReport = report
                    self.errorMessage = report.rootCauseDescription
                    self.isLoading = false
                    return
                }
            } else if case .linked(let bm) = pdf.sourceMode,
               let url = try? BookmarkResolver.shared.resolve(bm) {
                let didAccess = url.startAccessingSecurityScopedResource()
                targetURL = url
                if didAccess { accessedURL = url }
            }
        }

        let sourceURL = targetURL

        // Parse metadata (streaming OPF, no full unzip)
        let parsed = await EBookParser.shared.parse(epub: sourceURL)

        // Unzip for content serving (WKWebView needs local file access)
        // Deterministic cache key: bookIdentifier + mtime → same book reopens instantly across launches
        let mtime = (try? sourceURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
        let mtimeEpoch = Int(mtime.timeIntervalSince1970)
        let cacheKey = "\(bookIdentifier)_\(mtimeEpoch)"
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("EBook_\(cacheKey)")

        do {
            if !FileManager.default.fileExists(atPath: dest.path) {
                let destination = dest
                try await Task.detached(priority: .userInitiated) {
                    try Self.unzipBook(from: sourceURL, to: destination)
                }.value
            }
        } catch {
            accessedURL?.stopAccessingSecurityScopedResource()
            let report = DocumentOpenDiagnostics.logFailure(url: sourceURL, pdf: pdf, error: error, context: "EBookReaderView")
            self.loadDiagnosticReport = report
            self.errorMessage = report.rootCauseDescription
            self.isLoading = false
            return
        }

        // Extraction done, stop security scope
        accessedURL?.stopAccessingSecurityScopedResource()

        self.unzipDir = dest
        if let parsed = parsed, !parsed.spineItems.isEmpty {
            self.metadata = parsed
            // Restore saved chapter (clamp to valid range)
            let total = parsed.spineItems.count
            self.currentIndex = min(saved, max(0, total - 1))
            if saved == self.currentIndex {
                self.chapterPage = savedPage
            } else {
                self.chapterPage = 0
            }
            if let p = resolvedPDF,
               let trackerProg = ReaderProgressTracker.shared.progress(for: p.id),
               let offset = trackerProg.currentChapterOffset, offset > 0.0,
               UserDefaults.standard.double(forKey: fractionKey) == 0.0 {
                self.chapterScrollFraction = offset
            }
            // Apply per-book theme + typography profiles if saved
            if let bookID = pdf?.id.uuidString {
                prefs.applyBookTheme(bookID: bookID)
                prefs.applyBookTypography(bookID: bookID)
            }
        } else {
            let report = DocumentOpenDiagnostics.logFailure(url: sourceURL, pdf: pdf, error: nil, context: "EBookReaderView")
            self.loadDiagnosticReport = report
            self.errorMessage = report.rootCauseDescription
        }
        self.isLoading = false
        trackEBookProgress()
        startHUDIdleTimer(delay: 3_000_000_000)
    }

        private func saveProgress() {
        guard chapterPage < 99900 else { return }
        UserDefaults.standard.set(currentIndex, forKey: progressKey)
        UserDefaults.standard.set(chapterPage, forKey: pageKey)
        // FIX 4: Also persist the fractional scroll offset for within-chapter precision
        UserDefaults.standard.set(chapterScrollFraction, forKey: fractionKey)
        // Update ReaderProgressTracker with within-chapter offset too
        if let p = pdf ?? conversionManager.convertedPDFs.first(where: { $0.url.lastPathComponent == fileURL.lastPathComponent }) {
            let fraction = totalChapters > 1 ? Double(currentIndex) / Double(totalChapters - 1) : 0
            var progress = ReaderProgressTracker.shared.progress(for: p.id) ?? ReadingProgress(
                pdfID: p.id, lastOpenedAt: Date(), currentPageIndex: currentIndex,
                totalPagesRead: 0, completionFraction: fraction, readingSessionDates: []
            )
            progress.lastOpenedAt = Date()
            progress.currentPageIndex = currentIndex
            progress.currentChapterIndex = currentIndex
            progress.currentChapterOffset = chapterScrollFraction
            progress.completionFraction = fraction
            // Advance totalPagesRead to reflect chapters visited
            progress.totalPagesRead = max(progress.totalPagesRead, currentIndex + 1)
            ReaderProgressTracker.shared.update(progress)

            // Update ConversionManager library item metadata so shelves & stats immediately reflect reading state
            if let idx = conversionManager.convertedPDFs.firstIndex(where: { $0.id == p.id }) {
                conversionManager.convertedPDFs[idx].metadata.lastReadPage = currentIndex
                conversionManager.saveProgressOnly()
            }
        }
    }

    private func cleanup() {
        // Retain the unzip cache for fast reopen — only evict if older than 24 hours.
        guard let dir = unzipDir else { return }
        let cutoff = Date().addingTimeInterval(-86400)
        let mtime = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
        if mtime < cutoff {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    private func trackEBookProgress() {
        // Find the PDF in the ConversionManager
        // Fix #1: prefer the already-resolved pdf reference before falling back to filename scan
        guard let p = pdf ?? conversionManager.convertedPDFs.first(where: { $0.url.lastPathComponent == fileURL.lastPathComponent }) else { return }
        var progress = ReaderProgressTracker.shared.progress(for: p.id) ?? ReadingProgress(pdfID: p.id, lastOpenedAt: Date(), currentPageIndex: currentIndex, totalPagesRead: 1, completionFraction: 0, readingSessionDates: [])
        progress.lastOpenedAt = Date()
        progress.currentPageIndex = currentIndex
        progress.currentChapterIndex = currentIndex
        if totalChapters > 1 {
            progress.completionFraction = Double(currentIndex) / Double(totalChapters - 1)
        } else {
            progress.completionFraction = 1.0
        }
        if !progress.readingSessionDates.contains(where: { Calendar.current.isDateInToday($0) }) {
            progress.readingSessionDates.append(Date())
        }
        ReaderProgressTracker.shared.update(progress)
    }

    // MARK: - Bookmarks
    private var isBookmarked: Bool {
        guard let p = pdf ?? conversionManager.convertedPDFs.first(where: { $0.url.lastPathComponent == fileURL.lastPathComponent }) else { return false }
        let inMetadata = p.metadata.bookmarkedPages.contains(currentIndex)
        let inStore = AnnotationStore.shared.annotations(for: p.id).contains(where: { $0.pageIndex == currentIndex && $0.kind == .bookmark })
        return inMetadata || inStore
    }

    private func toggleBookmark() {
        guard let p = pdf ?? conversionManager.convertedPDFs.first(where: { $0.url.lastPathComponent == fileURL.lastPathComponent }),
              let idx = conversionManager.convertedPDFs.firstIndex(where: { $0.id == p.id }) else {
            Logger.shared.log("toggleBookmark: could not find pdf in conversionManager", category: "EBookReaderView", type: .warning)
            return
        }

        var updated = conversionManager.convertedPDFs[idx]
        if isBookmarked {
            updated.metadata.bookmarkedPages.removeAll(where: { $0 == currentIndex })
            let existing = AnnotationStore.shared.annotations(for: p.id).filter { $0.pageIndex == currentIndex && $0.kind == .bookmark }
            for b in existing {
                AnnotationStore.shared.delete(id: b.id, pdfID: p.id)
            }
            Logger.shared.log("Bookmark removed: chapter \(currentIndex + 1) of '\(p.name)'", category: "EBookReaderView", type: .info)
            toastMessage = "Bookmark Removed"
            showToast = true
        } else {
            if !updated.metadata.bookmarkedPages.contains(currentIndex) {
                updated.metadata.bookmarkedPages.append(currentIndex)
            }
            let rawLabel = metadata?.spineItems[safe: currentIndex]?.label ?? "Chapter \(currentIndex + 1)"
            let bookmark = Annotation(
                pdfID: p.id,
                pageIndex: currentIndex,
                chapterTitle: rawLabel,
                kind: .bookmark,
                createdAt: Date(),
                modifiedAt: Date()
            )
            AnnotationStore.shared.add(bookmark)
            Logger.shared.log("Bookmark added: chapter \(currentIndex + 1) of '\(p.name)'", category: "EBookReaderView", type: .success)
            toastMessage = "Bookmark Added"
            showToast = true
        }

        conversionManager.convertedPDFs[idx] = updated
        conversionManager.saveProgressOnly()

        HapticEngine.medium()
    }

    private func adjustEPUBSelection(delta: Int, isStart: Bool) {
        guard let wv = resolveActiveWebView() ?? webViewReference else { return }
        let js = "if (window.adjustInksyncSelection) { window.adjustInksyncSelection(\(delta), \(isStart ? "true" : "false")); } else { ''; }"
        wv.evaluateJavaScript(js) { res, _ in
            if let txt = res as? String, !txt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                DispatchQueue.main.async {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        self.selectedTextForHUD = txt
                    }
                    HapticEngine.selection()
                }
            }
        }
    }

    // MARK: - Text Selection & Highlighting HUD
    @ViewBuilder private func textSelectionHUDOverlay(bottomInset: CGFloat = 0) -> some View {
        if let selectedText = selectedTextForHUD, !selectedText.isEmpty {
            ZStack {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            selectedTextForHUD = nil
                        }
                        let wv = resolveActiveWebView() ?? webViewReference
                        wv?.evaluateJavaScript("window.getSelection()?.removeAllRanges();")
                    }

                VStack {
                    Spacer()
                    ProPDFTextSelectionHUD(
                        selectedText: selectedText,
                        pageIndex: currentIndex,
                        onHighlight: { color in
                            EBookPreferences.shared.defaultHighlightColor = color
                            applyHighlight(text: selectedText, colorHex: color.rawValue, symbol: nil, style: .highlight)
                        },
                        onMarkup: { color, style in
                            EBookPreferences.shared.defaultHighlightColor = color
                            applyHighlight(text: selectedText, colorHex: color.rawValue, symbol: nil, style: style)
                        },
                        onUnhighlight: {
                            unhighlightInEPUB(text: selectedText)
                            selectedTextForHUD = nil
                        },
                        onAddNote: { note in
                            applyHighlight(text: selectedText, colorHex: EBookPreferences.shared.defaultHighlightColor.rawValue, note: note, symbol: nil)
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
                            applyHighlight(text: selectedText, colorHex: EBookPreferences.shared.defaultHighlightColor.rawValue, symbol: symbol)
                            selectedTextForHUD = nil
                        },
                        onAdjustStart: { delta in
                            adjustEPUBSelection(delta: delta, isStart: true)
                        },
                        onAdjustEnd: { delta in
                            adjustEPUBSelection(delta: delta, isStart: false)
                        },
                        onDismiss: {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                selectedTextForHUD = nil
                            }
                            let wv = resolveActiveWebView() ?? webViewReference
                            wv?.evaluateJavaScript("window.getSelection()?.removeAllRanges();")
                        },
                        onSaveVocabulary: { word in
                            DictionaryLookupService.shared.lookupAndSave(
                                term: word,
                                contextSentence: selectedText,
                                bookTitle: pdf?.name ?? "General Reading",
                                bookID: pdf?.id.uuidString,
                                modelContext: modelContext
                            )
                            showToastMessage("Saved '\(word)' to Vocabulary")
                            HapticEngine.success()
                        }
                    )
                    .padding(.bottom, showHUD ? (bottomInset + 80) : max(bottomInset + 20, 30))
                    .padding(.horizontal, 20)
                }
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: - Reader Overlay & Sheet Subviews
    @ViewBuilder
    private var readerOverlays: some View {
        GeometryReader { geo in
            let topInset = geo.safeAreaInsets.top
            let bottomInset = geo.safeAreaInsets.bottom
            ZStack {
                if showHUD {
                    VStack(spacing: 0) {
                        topBar(topInset: topInset)
                            .transition(.move(edge: .top).combined(with: .opacity))
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture {
                                dismissHUD()
                            }
                        bottomBar(bottomInset: bottomInset)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    .ignoresSafeArea(edges: .vertical)
                }

                if narrationEngine.isActive {
                    VStack(spacing: 0) {
                        Spacer()
                        narrationFloatingHUD
                            .padding(.bottom, showHUD ? (bottomInset + 90) : (bottomInset + 24))
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    .ignoresSafeArea(edges: .bottom)
                    .zIndex(30)
                }

                if !showHUD {
                    VStack(spacing: 0) {
                        Spacer()
                        KindleProgressFooterView(
                            currentPage: currentIndex + 1,
                            totalPages: totalChapters,
                            chapterPage: chapterPage,
                            chapterTotalPages: chapterTotalPages,
                            chapterTitle: currentChapterTitle,
                            isBookSection: true,
                            estimatedMinutesLeft: pdf.flatMap { ReaderProgressTracker.shared.progress(for: $0.id)?.estimatedMinutesRemaining }
                        )
                        .padding(.bottom, max(bottomInset > 0 ? bottomInset - 10 : 0, 4))
                        .transition(.opacity)
                    }
                    .ignoresSafeArea(edges: .bottom)
                }

                if isPencilMode {
                    VStack {
                        HStack {
                            Button {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                                    isPencilMode = false
                                }
                                saveProgress()
                                if let onExit = onExit { onExit() } else { dismiss() }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "chevron.left")
                                        .font(.system(size: 14, weight: .bold))
                                    Text("Done")
                                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                                }
                                .foregroundStyle(Color.inkText)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(.ultraThinMaterial, in: Capsule())
                                .overlay(Capsule().stroke(Color.inkBorderSubtle, lineWidth: 0.5))
                                .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
                            }
                            .buttonStyle(.plain)
                            .padding(.leading, 16)
                            .padding(.top, max(topInset + 8, 44))

                            Spacer()
                        }

                        Spacer()

                        InksyncPenDockView(
                            onUndo: {
                                NotificationCenter.default.post(name: NSNotification.Name("EPUBReaderUndoDrawing"), object: nil)
                            },
                            onRedo: {
                                NotificationCenter.default.post(name: NSNotification.Name("EPUBReaderRedoDrawing"), object: nil)
                            },
                            onClearPage: {
                                NotificationCenter.default.post(name: NSNotification.Name("EPUBReaderClearDrawing"), object: nil)
                            },
                            onClose: {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                                    isPencilMode = false
                                }
                            }
                        )
                        .padding(.bottom, max(bottomInset + 12, 36))
                    }
                    .transition(.opacity)
                    .ignoresSafeArea(.keyboard)
                } else if !showHUD && selectedTextForHUD == nil {
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
                                    .foregroundStyle(Color.inkText)
                                    .frame(width: 44, height: 44)
                                    .background(.ultraThinMaterial)
                                    .clipShape(Circle())
                                    .overlay(Circle().stroke(Color.inkBorderSubtle, lineWidth: 0.5))
                                    .shadow(color: .black.opacity(0.18), radius: 6, x: 0, y: 3)
                            }
                            .padding(.trailing, 20)
                            .padding(.bottom, max(bottomInset + 8, 28))
                        }
                    }
                    .transition(.opacity)
                }

                textSelectionHUDOverlay(bottomInset: bottomInset)
                ReadingJumpToastOverlay()
                toastAlertOverlay(bottomInset: bottomInset)

                if prefs.showReadingRuler {
                    ReadingRulerOverlay()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ReaderToggleMarkupMode"))) { _ in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                isPencilMode.toggle()
                if isPencilMode {
                    InksyncInkingState.shared.activeToolMode = .write
                }
            }
        }
    }

    @ViewBuilder
    private var rsvpSpeedReaderView: some View {
        RSVPSpeedReadingView(
            rawText: rsvpContentText,
            bookTitle: currentChapterTitle ?? title
        ) { _ in }
    }

    @ViewBuilder
    private var settingsSheet: some View {
        EBookSettingsPanel(bookID: pdf?.id.uuidString)
            .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private var annotationsSheet: some View {
        if let p = pdf ?? conversionManager.convertedPDFs.first(where: { $0.url.lastPathComponent == fileURL.lastPathComponent }) {
            StudyNotebookView(
                bookID: p.id.uuidString,
                bookTitle: p.name,
                fileURL: p.url,
                showBackButton: true
            )
            .presentationDetents([.medium, .fraction(0.88)])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(28)
        }
    }

    @ViewBuilder
    private var highlightsSheet: some View {
        let matchedPDF = pdf ?? conversionManager.convertedPDFs.first(where: { $0.url.lastPathComponent == fileURL.lastPathComponent })
        let activeBookID = matchedPDF?.id.uuidString ?? fileURL.lastPathComponent
        let activeBookTitle = matchedPDF?.name ?? title

        BookHighlightsView(
            bookID: activeBookID,
            bookTitle: activeBookTitle,
            onJumpToHighlight: { highlight in
                var info: [String: Any] = [
                    "pageIndex": highlight.pageIndex,
                    "chapterPage": highlight.pageIndex,
                    "page": highlight.pageIndex
                ]
                if let chap = highlight.chapterTitle { info["chapterTitle"] = chap }
                if let text = highlight.selectedText { info["selectedText"] = text }
                NotificationCenter.default.post(name: .readerJumpToPage, object: nil, userInfo: info)
            }
        )
        .presentationDetents([.medium, .fraction(0.88)])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
    }

    @ViewBuilder
    private var searchSheet: some View {
        if let meta = metadata {
            EPUBSearchView(
                spineItems: meta.spineItems,
                unzipDir: unzipDir,
                onNavigate: { chapterIdx, matchText in
                    handleSearchNavigation(chapterIdx: chapterIdx, matchText: matchText)
                }
            )
        }
    }

    @ViewBuilder
    private func footnotePopover(for item: FootnoteItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Footnote", systemImage: "text.quote")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(action: {
                        HapticEngine.light()
                        activeFootnoteText = nil
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(item.text)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(prefs.activeTheme.foreground(colorScheme: colorScheme))
                    .lineSpacing(4)
            }
            .padding(20)
        }
        .frame(maxWidth: 480)
        .background(prefs.activeTheme.background(colorScheme: colorScheme))
        .presentationDetents([.fraction(0.35), .medium])
        .presentationCompactAdaptation(.popover)
    }

    private func deleteHighlight(_ annotation: SDAnnotation) {
        let idStr = annotation.id.uuidString
        let activeWV = resolveActiveWebView() ?? webViewReference
        if let text = annotation.selectedText {
            let safeText = text
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "`", with: "\\`")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: " ")
            activeWV?.evaluateJavaScript("if (window.removeInksyncHighlight) { window.removeInksyncHighlight('\(idStr)'); window.removeInksyncHighlight(`\(safeText)`); }")
        } else {
            activeWV?.evaluateJavaScript("if (window.removeInksyncHighlight) { window.removeInksyncHighlight('\(idStr)'); }")
        }
        let pid = annotation.pdfID
        AnnotationStore.shared.delete(id: annotation.id, pdfID: pid)
        modelContext.delete(annotation)
        try? modelContext.save()
        HapticEngine.selection()
        activeHighlightToEdit = nil
    }

    private func updateHighlightColor(_ annotation: SDAnnotation, colorHex: String) {
        let idStr = annotation.id.uuidString
        let activeWV = resolveActiveWebView() ?? webViewReference
        if let text = annotation.selectedText {
            let safeText = text
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "`", with: "\\`")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: " ")
            activeWV?.evaluateJavaScript("if (window.updateInksyncHighlightColor) { window.updateInksyncHighlightColor('\(idStr)', '\(colorHex)'); window.updateInksyncHighlightColor(`\(safeText)`, '\(colorHex)'); }")
        } else {
            activeWV?.evaluateJavaScript("if (window.updateInksyncHighlightColor) { window.updateInksyncHighlightColor('\(idStr)', '\(colorHex)'); }")
        }
        let pid = annotation.pdfID
        let matching = AnnotationStore.shared.annotations(for: pid)
            .first(where: { $0.id == annotation.id })
        if var updated = matching {
            updated.colorHex = colorHex
            AnnotationStore.shared.update(updated)
        }
        annotation.colorHex = colorHex
        try? modelContext.save()
        HapticEngine.selection()
    }

    @ViewBuilder
    private func highlightQuickPopover(for annotation: SDAnnotation) -> some View {
        HighlightQuickPopoverView(
            annotation: annotation,
            onDelete: {
                deleteHighlight(annotation)
            },
            onEditNote: {
                annotationForFullEdit = annotation
                activeHighlightToEdit = nil
            },
            onColorSelected: { colorHex in
                updateHighlightColor(annotation, colorHex: colorHex)
            }
        )
        .presentationCompactAdaptation(.popover)
    }

    private func resolveActiveWebView() -> WKWebView? {
        if let wv = webViewReference {
            return wv
        }
        if let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
           let window = windowScene.windows.first(where: { $0.isKeyWindow }) {
            return findWKWebView(in: window)
        }
        return nil
    }

    private func findWKWebView(in view: UIView) -> WKWebView? {
        if let wv = view as? WKWebView { return wv }
        for sub in view.subviews {
            if let found = findWKWebView(in: sub) {
                return found
            }
        }
        return nil
    }

    private func saveHighlightFromDirectDOM(id: UUID, text: String, colorHex: String) {
        guard let p = pdf ?? conversionManager.convertedPDFs.first(where: { $0.url.lastPathComponent == fileURL.lastPathComponent }) else { return }
        let rawLabel = metadata?.spineItems[safe: currentIndex]?.label ?? ""
        let spineLabel = !rawLabel.isEmpty ? rawLabel : nil

        let highlight = Annotation(
            id: id,
            pdfID: p.id,
            pageIndex: currentIndex,
            chapterTitle: spineLabel,
            kind: .highlight,
            createdAt: Date(),
            modifiedAt: Date(),
            colorHex: colorHex,
            selectedText: text
        )
        AnnotationStore.shared.add(highlight)
        HapticEngine.selection()
    }

    private func findMatchingAnnotation(tappedText: String) -> SDAnnotation? {
        guard let p = pdf ?? conversionManager.convertedPDFs.first(where: { $0.url.lastPathComponent == fileURL.lastPathComponent }) else { return nil }
        let storeAnns = AnnotationStore.shared.annotations(for: p.id)
        guard let match = storeAnns.first(where: { ann in
            guard ann.pageIndex == currentIndex else { return false }
            if ann.id.uuidString == tappedText { return true }
            guard let text = ann.selectedText, !text.isEmpty else { return false }
            return text.contains(tappedText) || tappedText.contains(text)
        }) else { return nil }

        let matchID = match.id
        let descriptor = FetchDescriptor<SDAnnotation>(predicate: #Predicate { $0.id == matchID })
        return try? modelContext.fetch(descriptor).first
    }

    private func applyHighlight(text: String, colorHex: String, note: String? = nil, symbol: String? = nil, style: AnnotationMarkupStyle = .highlight) {
        guard let p = pdf ?? conversionManager.convertedPDFs.first(where: { $0.url.lastPathComponent == fileURL.lastPathComponent }) else { return }
        let rawLabel = metadata?.spineItems[safe: currentIndex]?.label ?? ""
        let spineLabel = !rawLabel.isEmpty ? rawLabel : nil

        isApplyingHighlightDirectly = true
        defer {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                self.isApplyingHighlightDirectly = false
            }
        }

        let annKind: Annotation.AnnotationKind
        let toastTitle: String
        if note != nil {
            annKind = .note
            toastTitle = "Note Added"
        } else {
            switch style {
            case .underline:
                annKind = .underline
                toastTitle = "Underline Added"
            case .strikeOut:
                annKind = .strikeOut
                toastTitle = "Strikethrough Added"
            case .highlight:
                annKind = .highlight
                toastTitle = "Highlight Added"
            }
        }

        var highlight = Annotation(
            pdfID: p.id,
            pageIndex: currentIndex,
            chapterTitle: spineLabel,
            kind: annKind,
            createdAt: Date(),
            modifiedAt: Date(),
            colorHex: colorHex,
            selectedText: text,
            noteText: note
        )
        if let s = symbol {
            highlight.marginaliaSymbolRaw = s
            if note == nil {
                highlight.noteText = "Marginalia Symbol: \(s)"
            }
        }
        AnnotationStore.shared.add(highlight)

        let idStr = highlight.id.uuidString
        let safeSymbol = symbol?.replacingOccurrences(of: "'", with: "\\'") ?? ""
        let js = "if (window.applyInksyncHighlight) { window.applyInksyncHighlight('\(idStr)', '\(colorHex)', '\(safeSymbol)', '\(style.rawValue)'); }"
        let targetWV = resolveActiveWebView() ?? webViewReference
        targetWV?.evaluateJavaScript(js)
        showToastMessage(toastTitle)
        HapticEngine.selection()
    }

    private func unhighlightInEPUB(text: String) {
        guard let p = pdf ?? conversionManager.convertedPDFs.first(where: { $0.url.lastPathComponent == fileURL.lastPathComponent }) else { return }
        let storeAnns = AnnotationStore.shared.annotations(for: p.id)
        let chapterAnns = storeAnns.filter { $0.pageIndex == currentIndex }

        let matches: [Annotation]
        if let active = activeHighlightToEdit {
            matches = chapterAnns.filter { $0.id == active.id }
        } else if let matchByID = chapterAnns.first(where: { $0.id.uuidString == text }) {
            matches = [matchByID]
        } else {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let exact = chapterAnns.filter { $0.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed }
            if !exact.isEmpty {
                matches = exact
            } else {
                matches = chapterAnns.filter { ann in
                    guard let sel = ann.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines), !sel.isEmpty else { return false }
                    return sel == trimmed || sel.contains(trimmed) || trimmed.contains(sel)
                }
            }
        }

        let activeWV = resolveActiveWebView() ?? webViewReference
        let safeText = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")

        for match in matches {
            let idStr = match.id.uuidString
            activeWV?.evaluateJavaScript("if (window.removeInksyncHighlight) { window.removeInksyncHighlight('\(idStr)'); }")
            AnnotationStore.shared.delete(id: match.id, pdfID: p.id)
        }
        if matches.isEmpty {
            activeWV?.evaluateJavaScript("if (window.removeInksyncHighlight) { window.removeInksyncHighlight(`\(safeText)`); }")
        }
        activeWV?.evaluateJavaScript("if (window.removeInksyncHighlight) { window.removeInksyncHighlight(`\(safeText)`); window.getSelection()?.removeAllRanges(); }")

        try? modelContext.save()
        activeHighlightToEdit = nil
        selectedTextForHUD = nil
        showToastMessage("Highlight Removed")
        HapticEngine.selection()
    }

    private func showToastMessage(_ message: String) {
        toastTask?.cancel()
        toastMessage = message
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            showToast = true
        }
        toastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.25)) {
                self.showToast = false
            }
        }
    }

    @ViewBuilder private func toastAlertOverlay(bottomInset: CGFloat = 0) -> some View {
        if showToast {
            Text(toastMessage)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.inkText)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color.inkBorderSubtle, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                .padding(.bottom, max(bottomInset + 90, 110))
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(100)
        }
    }

    private func createZettelkastenCard(text: String) {
        guard let p = pdf ?? conversionManager.convertedPDFs.first(where: { $0.url.lastPathComponent == fileURL.lastPathComponent }) else { return }
        let card = SDNotebook(
            title: "Quote from \(p.name) (Section \(currentIndex + 1))",
            linkedBookID: p.id
        )
        modelContext.insert(card)
        try? modelContext.save()
        HapticEngine.success()
    }

    private func speakText(_ text: String) {
        HapticEngine.selection()
        narrationEngine.startReading(
            chapterText: text,
            onSentenceHighlight: { _, _ in }
        )
    }

    private func toggleNarration() {
        shouldAutoResumeNarrationOnChapterLoad = false
        if narrationEngine.isActive {
            clearSentenceHighlightInWebKit()
            narrationEngine.stop()
        } else {
            startNarration()
        }
    }

    private func startNarration() {
        HapticEngine.selection()
        if let wv = resolveActiveWebView() ?? webViewReference {
            wv.evaluateJavaScript("document.body.innerText") { (result, error) in
                if let text = result as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    narrationEngine.startReading(
                        chapterText: text,
                        voiceLanguage: Locale.current.language.languageCode?.identifier ?? "en-US",
                        title: title,
                        chapterName: currentChapterTitle ?? "",
                        onSentenceHighlight: { _, sentence in
                            highlightSentenceInWebKit(sentence)
                        },
                        onChapterFinished: {
                            clearSentenceHighlightInWebKit()
                            if currentIndex + 1 < totalChapters {
                                shouldAutoResumeNarrationOnChapterLoad = true
                                nextChapter()
                            }
                        }
                    )
                }
            }
        }
    }

    private func highlightSentenceInWebKit(_ sentence: String) {
        guard let wv = resolveActiveWebView() ?? webViewReference else { return }
        let clean = sentence.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }

        let theme = prefs.activeTheme
        let ttsBg = theme.cssTtsHighlightBg
        let ttsGlow = theme.cssTtsHighlightGlow

        // Wrap active spoken sentence in a theme-adaptive soft-focus highlight mark (Marco Arment Standard)
        let js = """
        (function() {
            var oldMarks = document.querySelectorAll('mark.inksync-tts-highlight');
            for (var i = 0; i < oldMarks.length; i++) {
                var p = oldMarks[i].parentNode;
                while (oldMarks[i].firstChild) p.insertBefore(oldMarks[i].firstChild, oldMarks[i]);
                p.removeChild(oldMarks[i]);
                p.normalize();
            }
            window.getSelection()?.removeAllRanges();
            var target = `\(clean.prefix(80))`;
            var found = window.find(target, false, false, true, false, true, false);
            if (found) {
                var sel = window.getSelection();
                if (sel && sel.rangeCount > 0) {
                    var range = sel.getRangeAt(0);
                    var mark = document.createElement('mark');
                    mark.className = 'inksync-tts-highlight';
                    mark.style.backgroundColor = '\(ttsBg)';
                    mark.style.borderRadius = '4px';
                    mark.style.padding = '2px 4px';
                    mark.style.boxShadow = '\(ttsGlow)';
                    mark.style.color = 'inherit';
                    mark.style.transition = 'background-color 0.22s ease-in-out, box-shadow 0.22s ease-in-out';
                    try {
                        range.surroundContents(mark);
                        mark.scrollIntoView({ behavior: 'smooth', block: 'center', inline: 'center' });
                    } catch(e) {
                        try {
                            var contents = range.extractContents();
                            mark.appendChild(contents);
                            range.insertNode(mark);
                            mark.scrollIntoView({ behavior: 'smooth', block: 'center', inline: 'center' });
                        } catch(err) {}
                    }
                    sel.removeAllRanges();
                }
            }
        })();
        """
        wv.evaluateJavaScript(js, completionHandler: nil)
    }

    private func clearSentenceHighlightInWebKit() {
        guard let wv = resolveActiveWebView() ?? webViewReference else { return }
        let js = """
        (function() {
            var oldMarks = document.querySelectorAll('mark.inksync-tts-highlight');
            for (var i = 0; i < oldMarks.length; i++) {
                var p = oldMarks[i].parentNode;
                while (oldMarks[i].firstChild) p.insertBefore(oldMarks[i].firstChild, oldMarks[i]);
                p.removeChild(oldMarks[i]);
                p.normalize();
            }
            window.getSelection()?.removeAllRanges();
        })();
        """
        wv.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: - Narration Floating HUD
    @ViewBuilder private var narrationFloatingHUD: some View {
        EPUBSpeechHUDView(engine: narrationEngine) {
            shouldAutoResumeNarrationOnChapterLoad = false
            clearSentenceHighlightInWebKit()
            narrationEngine.stop()
        }
    }
}

// MARK: - EBookWebReader (Declarative wrapper using WebKitUI.WebView)
struct EBookWebReader: View {
    let spineItem:  EBookMetadata.SpineItem
    let unzipDir:   URL?
    @ObservedObject var prefs: EBookPreferences
    let colorScheme: ColorScheme
    @Binding var currentPage: Int
    var initialPage: Int
    @Binding var totalPages: Int
    var onNext: () -> Void
    var onPrev: () -> Void
    var onCenterTap: () -> Void
    var onPageTurn: (() -> Void)? = nil
    var onHighlightCreated: ((String) -> Void)? = nil
    var pdfID: UUID? = nil
    var initialScrollFraction: Double = 0.0
    var onScrollFractionChanged: ((Double) -> Void)? = nil
    @Binding var webViewRef: WKWebView?
    var onFootnoteTapped: ((String) -> Void)? = nil

    @State private var isLoading: Bool = false
    @State private var progress: Double = 0.0
    @State private var styledHTML: String = ""
    @State private var baseUrl: URL? = nil
    @State private var initialPinchFontSize: Double = 16.0

    var body: some View {
        WebView(
            html: styledHTML,
            baseURL: baseUrl,
            isLoading: $isLoading,
            progress: $progress,
            webViewRef: $webViewRef,
            onNavigate: { url, webView in
                if url.scheme == "http" || url.scheme == "https" {
                    UIApplication.shared.open(url)
                    return false
                } else if let fragment = url.fragment {
                    // Try to extract footnote first via custom script
                    let js = """
                    (function() {
                        var el = document.getElementById('\(fragment)') || document.getElementsByName('\(fragment)')[0];
                        if (el) {
                            var text = el.innerText || el.textContent;
                            if (text && text.trim().length > 0 && text.trim().length < 1000) {
                                window.webkit.messageHandlers.footnote.postMessage({ "id": '\(fragment)', "text": text.trim() });
                            }
                        }
                    })();
                    """
                    webView.evaluateJavaScript(js, completionHandler: nil)

                    // Fallback scroll positioning
                    let navJS = """
                    (function() {
                        var el = document.getElementById('\(fragment)') || document.getElementsByName('\(fragment)')[0];
                        if (!el) return;
                        var pageStep = window.innerWidth || 1;
                        var rawPage = Math.floor(el.getBoundingClientRect().left / pageStep);
                        var currentP = (typeof _currentPage !== 'undefined') ? _currentPage : 0;
                        var targetPage = rawPage + currentP;
                        if (typeof goToPage === 'function') {
                            goToPage(Math.max(0, targetPage));
                        } else {
                            el.scrollIntoView({ behavior: 'smooth', block: 'start' });
                        }
                    })();
                    """
                    webView.evaluateJavaScript(navJS, completionHandler: nil)
                    return false
                }
                return true
            },
            messageHandler: { message in
                if message.name == "nav", let body = message.body as? String {
                    if body == "next" { self.onPageTurn?(); self.onNext() }
                    else if body == "prev" { self.onPageTurn?(); self.onPrev() }
                    else if body == "center" { self.onCenterTap() }
                } else if message.name == "metrics", let body = message.body as? [String: Int] {
                    self.currentPage = body["current"] ?? 0
                    self.totalPages = body["total"] ?? 1
                } else if message.name == "highlight", let text = message.body as? String, !text.isEmpty {
                    self.onHighlightCreated?(text)
                } else if message.name == "scrollFraction", let fraction = message.body as? Double {
                    self.onScrollFractionChanged?(fraction)
                } else if message.name == "footnote", let body = message.body as? [String: String], let text = body["text"] {
                    self.onFootnoteTapped?(text)
                }
            },
            onHighlight: {
                if let wv = webViewRef {
                    wv.evaluateJavaScript("window.getSelection().toString()") { (result, error) in
                        if let text = result as? String, !text.isEmpty {
                            self.onHighlightCreated?(text)
                        }
                    }
                }
            },
            didFinishNavigation: { webView in
                // Restore saved highlights
                if let pdfID = self.pdfID {
                    let annotations = AnnotationStore.shared.annotations(for: pdfID)
                        .filter { ann in
                            guard ann.kind == .highlight || ann.kind == .underline || ann.kind == .strikeOut else { return false }
                            // Match by chapter label if available, fall back to page index
                            if let title = ann.chapterTitle, !title.isEmpty {
                                let label = self.spineItem.label
                                if !label.isEmpty {
                                    return title.lowercased() == label.lowercased()
                                }
                            }
                            // Fallback: match by spine index position
                            return ann.pageIndex == (self.pdfID.flatMap { _ in
                                AnnotationStore.shared.annotations(for: pdfID).first?.pageIndex
                            } ?? ann.pageIndex)
                        }
                    for ann in annotations {
                        guard let text = ann.selectedText, let color = ann.colorHex else { continue }
                        let idStr = ann.id.uuidString
                        let safeText = text
                            .replacingOccurrences(of: "\\", with: "\\\\")
                            .replacingOccurrences(of: "`", with: "\\`")
                            .replacingOccurrences(of: "\"", with: "\\\"")
                            .replacingOccurrences(of: "\n", with: " ")
                        let safeSymbol = (ann.marginaliaSymbolRaw ?? "").replacingOccurrences(of: "'", with: "\\'")
                        let styleStr = ann.kind == .underline ? "underline" : (ann.kind == .strikeOut ? "strikeout" : "highlight")
                        let js = "window.restoreInksyncHighlight('\(idStr)', `\(safeText)`, '\(color)', '\(safeSymbol)', '\(styleStr)');"
                        webView.evaluateJavaScript(js)
                    }
                }

                // Restore the within-chapter fractional scroll position.
                let fraction = self.initialScrollFraction
                if fraction > 0.01 {
                    let isPaged = self.prefs.paginationMode == EBookPaginationMode.paged.rawValue
                    let restoreJS = """
                    setTimeout(function() {
                        var sv = document.scrollingElement || document.documentElement;
                        var isHoriz = \(isPaged);
                        if (isHoriz) {
                            var pageStep = window.innerWidth;
                            var totalPages = Math.max(1, Math.round(document.body.scrollWidth / pageStep));
                            var targetPage = Math.round(\(fraction) * (totalPages - 1));
                            if (window.goToInksyncPage) {
                                window.goToInksyncPage(targetPage, false);
                            } else {
                                window.scrollTo({ left: targetPage * pageStep, behavior: 'instant' });
                            }
                        } else {
                            window.scrollTo({ top: sv.scrollHeight * \(fraction), behavior: 'instant' });
                        }
                        window.webkit.messageHandlers.scrollFraction.postMessage(\(fraction));
                    }, 150);
                    """
                    webView.evaluateJavaScript(restoreJS)
                }
            },
            scrollViewDidEndDragging: { scrollView, decelerate in
                let isPaged = self.prefs.paginationMode == EBookPaginationMode.paged.rawValue
                guard isPaged else { return }

                let offset = scrollView.contentOffset.x
                let maxOffset = scrollView.contentSize.width - scrollView.bounds.width
                let threshold: CGFloat = 50.0

                if offset > maxOffset + threshold {
                    self.onNext()
                } else if offset < -threshold {
                    self.onPrev()
                }
            },
            scrollViewDidScroll: { scrollView in
                if scrollView.isDragging {
                    self.onPageTurn?()
                }
            },
            processDidTerminate: { webView in
                Logger.shared.log("WebKit process terminated (OOM Jetsam crash). Reloading EPUB chapter.", category: "EBookWebReader", type: .error)
                webView.reload()
            }
        )
        .gesture(
            MagnificationGesture()
                .onChanged { value in
                    if initialPinchFontSize == 0 {
                        initialPinchFontSize = prefs.fontSize
                    }
                    let newSize = initialPinchFontSize * Double(value)
                    let roundedSize = round(max(12.0, min(80.0, newSize)))
                    if prefs.fontSize != roundedSize {
                        prefs.fontSize = roundedSize
                    }
                }
                .onEnded { _ in
                    initialPinchFontSize = 0
                    if let bookID = pdfID?.uuidString, prefs.isTypographyLockedForBook(bookID) {
                        prefs.lockTypographyForBook(bookID)
                    }
                }
        )
        .task(id: spineItem.href) {
            await loadChapter()
        }
        .onReceive(prefs.objectWillChange) { _ in
            DispatchQueue.main.async {
                updateLiveCSS()
            }
        }
    }

    private func loadChapter() async {
        guard let dir = unzipDir else { return }
        var rawHref = spineItem.href
        if let anchorIdx = rawHref.firstIndex(of: "#") {
            rawHref = String(rawHref[..<anchorIdx])
        }
        var contentURL = dir.appendingPathComponent(rawHref).standardizedFileURL
        if !FileManager.default.fileExists(atPath: contentURL.path) {
            if let decoded = rawHref.removingPercentEncoding {
                contentURL = dir.appendingPathComponent(decoded).standardizedFileURL
            }
        }
        guard FileManager.default.fileExists(atPath: contentURL.path) else { return }

        self.baseUrl = contentURL.deletingLastPathComponent()

        let cssToInject = buildReaderCSS(prefs: prefs, colorScheme: colorScheme, initialPage: initialPage, size: UIScreen.main.bounds.size)

        var rawHTML: String = ""
        var enc: String.Encoding = .utf8
        if let html = try? String(contentsOf: contentURL, usedEncoding: &enc) {
            rawHTML = html
        } else if let data = try? Data(contentsOf: contentURL) {
            rawHTML = String(data: data, encoding: .isoLatin1)
                   ?? String(data: data, encoding: .ascii)
                   ?? ""
        }

        // Preserve native markup if standard HTML, otherwise clean with SwiftReadability
        var html: String
        if rawHTML.contains("pdf-page-marker") || spineItem.href.hasSuffix("reflow.html") {
            html = rawHTML
        } else if rawHTML.range(of: "<body", options: .caseInsensitive) != nil {
            html = rawHTML
        } else {
            let cleanArticle = SwiftReadability.parse(html: rawHTML)
            html = cleanArticle.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if html.isEmpty || html.count < 20 {
                html = rawHTML
            }
        }

        // Wrap with viewport
        html = EBookWebReader.wrapHTMLBodyWithViewport(html)

        // Inject CSS
        if let range = html.range(of: "</head>", options: .caseInsensitive) {
            styledHTML = html.replacingCharacters(in: range, with: cssToInject + "</head>")
        } else {
            styledHTML = cssToInject + html
        }
    }

    private func updateLiveCSS() {
        guard let wv = webViewRef else { return }
        let css = buildReaderCSS(prefs: prefs, colorScheme: colorScheme, initialPage: currentPage, size: wv.bounds.size)
        let js = """
        (function() {
            var el = document.getElementById('__inksync_live__');
            if (!el) { el = document.createElement('style'); el.id = '__inksync_live__'; document.head.appendChild(el); }
            el.textContent = `\(css.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "`", with: "\\`"))`;
            if (window.postMetrics) {
                window.postMetrics();
            }
        })();
        """
        wv.evaluateJavaScript(js)
    }

    private static func wrapHTMLBodyWithViewport(_ html: String) -> String {
        if html.contains("id=\"inksync-viewport\"") || html.contains("id='inksync-viewport'") {
            return html
        }
        var result = html
        let bodyPattern = "<body([^>]*)>"
        if let regex = try? NSRegularExpression(pattern: bodyPattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: result, options: [], range: NSRange(result.startIndex..., in: result)) {
            let bodyTagRange = Range(match.range, in: result)!
            let insertionIndex = bodyTagRange.upperBound
            result.insert(contentsOf: "<div id=\"inksync-viewport\">", at: insertionIndex)
        } else {
            if let bodyIndex = result.range(of: "<body>", options: .caseInsensitive)?.upperBound {
                result.insert(contentsOf: "<div id=\"inksync-viewport\">", at: bodyIndex)
            }
        }

        if let closeBodyRange = result.range(of: "</body>", options: .caseInsensitive) {
            result.insert(contentsOf: "</div>", at: closeBodyRange.lowerBound)
        }
        return result
    }

    private func computeCSS(prefs: EBookPreferences, size: CGSize) -> String {
        let isPaged = prefs.paginationMode == EBookPaginationMode.paged.rawValue

        let bgColor      = prefs.activeTheme.cssBackground
        let textColor    = ColorContrastCalculator.getLegibleTextColor(textHex: prefs.activeTheme.cssText, bgHex: bgColor)
        let linkColor    = prefs.activeTheme.cssLink
        let fontFamily   = prefs.fontFamily
        let fontSize     = Int(prefs.fontSize)
        let lineHeight   = String(format: "%.2f", prefs.lineHeight)
        let letterSpacing = String(format: "%.4fem", prefs.letterSpacing)
        let wordSpacing   = String(format: "%.4fem", prefs.wordSpacing)
        let textAlign     = prefs.textAlign
        let margin        = prefs.textMargin
        let paraSpace     = prefs.paragraphSpacing
        let paraIndent    = prefs.paragraphIndent
        let hyphenCSS     = prefs.hyphenation ? "auto" : "manual"
        let isDarkTheme   = prefs.activeTheme.isDark
        let blendMode     = isDarkTheme ? "normal" : "multiply"
        let highlightBg   = isDarkTheme ? "rgba(255, 214, 10, 0.38)" : "rgba(255, 214, 10, 0.45)"

        let renderWidth = size.width > 0 ? size.width : UIScreen.main.bounds.width
        let renderHeight = size.height > 0 ? size.height : UIScreen.main.bounds.height

        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        let isPhone = UIDevice.current.userInterfaceIdiom == .phone
        let isLandscape = renderWidth > renderHeight
        let defaultColumns = isLandscape ? (prefs.autoLandscapeDualPage ? 2 : (isPad ? 2 : 1)) : 1
        let cols = (isPhone && !isLandscape) ? 1 : (prefs.columnCount == 0 ? defaultColumns : prefs.columnCount)

        let m = isPaged ? (isPhone ? max(12.0, min(margin, 16.0)) : max(16.0, margin)) : (isPhone ? max(12.0, min(margin, 16.0)) : margin)
        let gap = 2 * m
        let colWidth = max(100.0, (renderWidth / CGFloat(cols)) - gap)

        let pagedCSS = isPaged ? """
            column-width: \(colWidth)px !important;
            column-gap: \(gap)px !important;
            column-fill: auto !important;
            column-rule: none !important;
        """ : ""

        let paddingLeft = m
        let paddingRight = m
        let topPadding: CGFloat = isPhone ? 28.0 : 64.0
        let bottomPadding: CGFloat = isPhone ? 32.0 : 64.0

        return """
        @font-face {
            font-family: 'Literata';
            src: local('Literata-Regular');
            font-weight: normal;
            font-style: normal;
        }
        @font-face {
            font-family: 'Literata';
            src: local('Literata-Bold');
            font-weight: bold;
            font-style: normal;
        }
        @font-face {
            font-family: 'Literata';
            src: local('Literata-Italic');
            font-weight: normal;
            font-style: italic;
        }
        @font-face {
            font-family: 'Literata';
            src: local('Literata-BoldItalic');
            font-weight: bold;
            font-style: italic;
        }
        @font-face {
            font-family: 'Atkinson Hyperlegible';
            src: local('AtkinsonHyperlegible-Regular');
            font-weight: normal;
            font-style: normal;
        }
        @font-face {
            font-family: 'Atkinson Hyperlegible';
            src: local('AtkinsonHyperlegible-Bold');
            font-weight: bold;
            font-style: normal;
        }
        @font-face {
            font-family: 'Atkinson Hyperlegible';
            src: local('AtkinsonHyperlegible-Italic');
            font-weight: normal;
            font-style: italic;
        }
        @font-face {
            font-family: 'Atkinson Hyperlegible';
            src: local('AtkinsonHyperlegible-BoldItalic');
            font-weight: bold;
            font-style: italic;
        }
        @font-face {
            font-family: 'OpenDyslexic';
            src: local('OpenDyslexic-Regular');
            font-weight: normal;
            font-style: normal;
        }
        @font-face {
            font-family: 'OpenDyslexic';
            src: local('OpenDyslexic-Bold');
            font-weight: bold;
            font-style: normal;
        }
        @font-face {
            font-family: 'OpenDyslexic';
            src: local('OpenDyslexic-Italic');
            font-weight: normal;
            font-style: italic;
        }
        @font-face {
            font-family: 'OpenDyslexic';
            src: local('OpenDyslexic-BoldItalic');
            font-weight: bold;
            font-style: italic;
        }
        @font-face {
            font-family: 'Merriweather';
            src: local('Merriweather-Regular');
            font-weight: normal;
            font-style: normal;
        }
        @font-face {
            font-family: 'Merriweather';
            src: local('Merriweather-Bold');
            font-weight: bold;
            font-style: normal;
        }
        @font-face {
            font-family: 'Merriweather';
            src: local('Merriweather-Italic');
            font-weight: normal;
            font-style: italic;
        }
        @font-face {
            font-family: 'Merriweather';
            src: local('Merriweather-BoldItalic');
            font-weight: bold;
            font-style: italic;
        }
        @font-face {
            font-family: 'SF Pro Text';
            src: local('SFProText-Regular');
            font-weight: normal;
            font-style: normal;
        }
        @font-face {
            font-family: 'SF Pro Text';
            src: local('SFProText-Bold');
            font-weight: bold;
            font-style: normal;
        }
        @font-face {
            font-family: 'SF Pro Text';
            src: local('SFProText-Italic');
            font-weight: normal;
            font-style: italic;
        }
        @font-face {
            font-family: 'SF Pro Text';
            src: local('SFProText-BoldItalic');
            font-weight: bold;
            font-style: italic;
        }
        @font-face {
            font-family: 'New York';
            src: local('NewYork-Regular');
            font-weight: normal;
            font-style: normal;
        }
        @font-face {
            font-family: 'New York';
            src: local('NewYork-Bold');
            font-weight: bold;
            font-style: normal;
        }
        @font-face {
            font-family: 'New York';
            src: local('NewYork-Italic');
            font-weight: normal;
            font-style: italic;
        }
        @font-face {
            font-family: 'New York';
            src: local('NewYork-BoldItalic');
            font-weight: bold;
            font-style: italic;
        }
        @font-face {
            font-family: 'Baskerville';
            src: local('Baskerville-Regular');
            font-weight: normal;
            font-style: normal;
        }
        @font-face {
            font-family: 'Baskerville';
            src: local('Baskerville-Bold');
            font-weight: bold;
            font-style: normal;
        }
        @font-face {
            font-family: 'Baskerville';
            src: local('Baskerville-Italic');
            font-weight: normal;
            font-style: italic;
        }
        @font-face {
            font-family: 'Baskerville';
            src: local('Baskerville-BoldItalic');
            font-weight: bold;
            font-style: italic;
        }

        :root {
            --bg-color: \(bgColor);
            --text-color: \(textColor);
            --link-color: \(linkColor);
            --font-size: \(fontSize)px;
            --line-height: \(lineHeight);
            color-scheme: \(isDarkTheme ? "dark" : "light");
        }
        * {
            box-sizing: border-box !important;
            -webkit-tap-highlight-color: transparent !important;
        }
        html, body {
            margin: 0 !important;
            padding: 0 !important;
            \(isPaged ? """
            width: 100vw !important;
            height: 100vh !important;
            overflow: hidden !important;
            """ : """
            width: 100% !important;
            height: auto !important;
            overflow-x: hidden !important;
            """)
            background-color: \(bgColor) !important;
            color: \(textColor) !important;
            font-family: \(fontFamily) !important;
            font-size: \(fontSize)px !important;
            line-height: \(lineHeight) !important;
            text-align: \(textAlign) !important;
            -webkit-text-size-adjust: none;
            letter-spacing: \(letterSpacing) !important;
            word-spacing: \(wordSpacing) !important;
            -webkit-hyphens: \(hyphenCSS) !important;
            hyphens: \(hyphenCSS) !important;
            text-rendering: optimizeLegibility !important;
            -webkit-font-variant-ligatures: common-ligatures !important;
            font-variant-ligatures: common-ligatures !important;
            -webkit-font-feature-settings: "kern", "liga" 1 !important;
            font-feature-settings: "kern", "liga" 1 !important;
        }
        #inksync-viewport {
            margin: 0 !important;
            box-sizing: border-box !important;
            \(isPaged ? """
            display: block !important;
            position: relative !important;
            width: 100vw !important;
            height: 100vh !important;
            padding-top: \(topPadding)px !important;
            padding-bottom: \(bottomPadding)px !important;
            padding-left: \(paddingLeft)px !important;
            padding-right: \(paddingRight)px !important;
            overflow: visible !important;
            \(pagedCSS)
            """ : """
            display: block !important;
            width: 100% !important;
            height: auto !important;
            padding-top: \(topPadding)px !important;
            padding-bottom: \(bottomPadding)px !important;
            padding-left: \(paddingLeft)px !important;
            padding-right: \(paddingRight)px !important;
            """)
        }
        body, p, span, li, td, th, div, a {
            font-family: \(fontFamily) !important;
        }
        body, p, li, td, th, a {
            font-size: \(fontSize)px !important;
        }
        h1 { font-size: \(Double(fontSize) * 1.5)px !important; font-family: \(fontFamily) !important; }
        h2 { font-size: \(Double(fontSize) * 1.3)px !important; font-family: \(fontFamily) !important; }
        h3 { font-size: \(Double(fontSize) * 1.15)px !important; font-family: \(fontFamily) !important; }
        h4 { font-size: \(Double(fontSize) * 1.05)px !important; font-family: \(fontFamily) !important; }
        h5, h6 { font-size: \(Double(fontSize) * 1.0)px !important; font-family: \(fontFamily) !important; }
        /* Prevent nested overflow and positioning containers from breaking horizontal column flow */
        #inksync-viewport *, body * {
            max-width: 100% !important;
            box-sizing: border-box !important;
            word-break: break-word !important;
            overflow-wrap: break-word !important;
        }
        /* Force container backgrounds to be transparent so the ambient paper texture is visible */
        #inksync-viewport, #inksync-viewport *:not(mark):not(.inksync-highlight):not(pre):not(code):not(table):not(tr):not(td):not(th) {
            background-color: transparent !important;
            background: transparent !important;
        }
        \(isPaged ? """
        div, section, article, main {
            max-height: none !important;
            overflow: visible !important;
            column-count: auto !important;
            column-width: auto !important;
        }
        img, figure, svg, table, pre, code, blockquote {
            break-inside: avoid !important;
            -webkit-column-break-inside: avoid !important;
            page-break-inside: avoid !important;
        }
        h1, h2, h3, h4, h5, h6 {
            break-after: avoid !important;
            -webkit-column-break-after: avoid !important;
            page-break-after: avoid !important;
        }
        """ : """
        div, section, article, main {
            max-height: none !important;
            height: auto !important;
            overflow: visible !important;
        }
        """)
        p { margin-bottom: \(paraSpace)em !important; text-indent: \(paraIndent)em !important; }
        p, div, span, li, td, th, h1, h2, h3, h4, h5, h6 { color: \(textColor) !important; line-height: \(lineHeight); \(prefs.isBoldTextEnabled ? "font-weight: 600 !important;" : "") }
        img, svg, .page, .chunk-container { display: block !important; margin-left: auto !important; margin-right: auto !important; }
        img { max-width: 100% !important; max-height: 100% !important; height: auto !important; border-radius: 4px; object-fit: contain !important; }
        img.gaiji, img[gaiji], img.inline-image { display: inline-block !important; vertical-align: middle !important; max-height: 1.2em !important; width: auto !important; margin: 0 0.1em !important; }
        pre, table, code {
            max-width: 100% !important;
            overflow-x: auto !important;
            word-wrap: break-word !important;
            white-space: pre-wrap !important;
        }
        a { color: \(linkColor) !important; }
        blockquote { border-left: 3px solid \(linkColor); margin-left: 0; padding-left: 16px; opacity: 0.85; }
        mark.inksync-highlight { display: inline; border-radius: 2px; background-color: \(highlightBg); mix-blend-mode: \(blendMode); -webkit-mix-blend-mode: \(blendMode); padding: 0 1px; color: inherit; }
        \(fontSize > 28 ? """
        .dropcap, .drop-cap, span.first-letter {
            float: none !important;
            font-size: 1em !important;
            line-height: inherit !important;
            margin: 0 !important;
            font-weight: inherit !important;
        }
        """ : """
        .dropcap, .drop-cap, span.first-letter {
            float: left !important;
            font-size: 3.2em !important;
            line-height: 0.82 !important;
            margin-right: 0.12em !important;
            margin-top: 0.05em !important;
            font-family: \(fontFamily) !important;
            color: \(textColor) !important;
            font-weight: bold !important;
        }
        """)
        </style>
        """
    }

    private func buildReaderCSS(prefs: EBookPreferences, colorScheme: ColorScheme, initialPage: Int, size: CGSize) -> String {
        let cssContent = computeCSS(prefs: prefs, size: size)
        let isPaged = prefs.paginationMode == EBookPaginationMode.paged.rawValue
        let isDarkTheme = prefs.activeTheme.isDark

        return """
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no, viewport-fit=cover">
        <style id="__inksync_live__">
        \(cssContent)
        </style>
        <script>
        var _isDarkTheme = \(isDarkTheme ? "true" : "false");

        function hexToRgba(hex, alpha) {
            if (!hex) return 'rgba(255, 214, 10, ' + alpha + ')';
            if (hex.indexOf('rgba') === 0 || hex.indexOf('hsla') === 0) return hex;
            var c = hex.replace('#', '');
            if (c.length === 3) {
                c = c[0] + c[0] + c[1] + c[1] + c[2] + c[2];
            }
            if (c.length >= 6) {
                var r = parseInt(c.substring(0, 2), 16) || 0;
                var g = parseInt(c.substring(2, 4), 16) || 0;
                var b = parseInt(c.substring(4, 6), 16) || 0;
                return 'rgba(' + r + ',' + g + ',' + b + ',' + alpha + ')';
            }
            return hex;
        }

        document.addEventListener('DOMContentLoaded', function() {
            document.querySelectorAll('[style]').forEach(function(el) {
                if (el.tagName !== 'MARK' && !el.classList.contains('inksync-highlight')) {
                    el.style.removeProperty('background-color');
                    el.style.removeProperty('color');
                }
            });
            var liveStyle = document.getElementById('__inksync_live__');
            if (liveStyle) {
                document.head.appendChild(liveStyle);
            }
        });

        var _currentPage = \(initialPage);
        var _totalPages = 1;
        var _firstRun = true;

        function postFraction() {
            var sv = document.scrollingElement || document.documentElement;
            var isHoriz = \(isPaged);
            var fraction = 0;
            if (isHoriz) {
                var maxScroll = sv.scrollWidth - window.innerWidth;
                if (maxScroll > 0) fraction = sv.scrollLeft / maxScroll;
            } else {
                var maxScroll = sv.scrollHeight - window.innerHeight;
                if (maxScroll > 0) fraction = sv.scrollTop / maxScroll;
            }
            window.webkit.messageHandlers.scrollFraction.postMessage(fraction);
        }

        function updateMetrics() {
            var sv = document.scrollingElement || document.documentElement;
            var pageStep = window.innerWidth;
            var isHoriz = \(isPaged);

            if (isHoriz) {
                var scrollW = Math.max(sv.scrollWidth, document.body.scrollWidth);
                var total = Math.floor((scrollW + 5) / pageStep);
                var remainder = (scrollW + 5) % pageStep;
                if (remainder > 35) { total += 1; }
                _totalPages = Math.max(1, total);
                if (_firstRun) {
                    _firstRun = false;
                    if (_currentPage === 99999) {
                        _currentPage = _totalPages - 1;
                    }
                    goToPage(_currentPage, false);
                } else {
                    _currentPage = Math.max(0, Math.min(Math.round(sv.scrollLeft / pageStep), _totalPages - 1));
                }
            } else {
                var pageHeight = window.innerHeight;
                _totalPages = Math.max(1, Math.round(sv.scrollHeight / pageHeight));
            }

            if (!_firstRun) {
                window.webkit.messageHandlers.metrics.postMessage({ current: _currentPage, total: _totalPages });
            }
            postFraction();
        }

        function goToPage(page, animate) {
            var isHoriz = \(isPaged);
            if (isHoriz) {
                var pageStep = window.innerWidth;
                var targetX = page * pageStep;
                if (animate) {
                    window.scrollTo({ left: targetX, behavior: 'smooth' });
                } else {
                    window.scrollTo(targetX, 0);
                }
            } else {
                var pageHeight = window.innerHeight;
                var targetY = page * pageHeight;
                if (animate) {
                    window.scrollTo({ top: targetY, behavior: 'smooth' });
                } else {
                    window.scrollTo(0, targetY);
                }
            }
            _currentPage = page;

            if (!_firstRun) {
                window.webkit.messageHandlers.metrics.postMessage({ current: _currentPage, total: _totalPages });
            }
            postFraction();
        }
        window.goToInksyncPage = goToPage;

        window.onload = function() {
            setTimeout(updateMetrics, 100);
            setTimeout(updateMetrics, 500);
            setTimeout(updateMetrics, 1500);
        };
        window.addEventListener('resize', function() { updateMetrics(); goToPage(_currentPage, false); });

        document.addEventListener('click', function(e) {
            if (e.target.tagName.toLowerCase() === 'a') return;
            if (window.getSelection() && !window.getSelection().isCollapsed) return;
            var x = e.clientX; var w = window.innerWidth;
            var leftEdge = window.__inksync_left_edge || 0.30;
            var rightEdge = window.__inksync_right_edge || 0.70;
            if (x < w * leftEdge) {
                if (_currentPage > 0) goToPage(_currentPage - 1, false);
                else window.webkit.messageHandlers.nav.postMessage('prev');
            } else if (x > w * rightEdge) {
                if (_currentPage < _totalPages - 1) goToPage(_currentPage + 1, false);
                else window.webkit.messageHandlers.nav.postMessage('next');
            } else {
                window.webkit.messageHandlers.nav.postMessage('center');
            }
        });

        document.addEventListener('keydown', function(e) {
            if (e.key === 'ArrowRight' || e.key === 'Space') {
                if (_currentPage < _totalPages - 1) goToPage(_currentPage + 1, false);
                else window.webkit.messageHandlers.nav.postMessage('next');
                e.preventDefault();
            } else if (e.key === 'ArrowLeft') {
                if (_currentPage > 0) goToPage(_currentPage - 1, false);
                else window.webkit.messageHandlers.nav.postMessage('prev');
                e.preventDefault();
            }
        });

        var _scrollTimeout;
        window.addEventListener('scroll', function() {
            clearTimeout(_scrollTimeout);
            _scrollTimeout = setTimeout(function() {
                updateMetrics();
            }, 50);
        });

        document.addEventListener('selectionchange', function() {
            var sel = window.getSelection();
            if (sel && sel.rangeCount > 0 && !sel.isCollapsed) {
                try {
                    window.__lastSelectedRange = sel.getRangeAt(0).cloneRange();
                    window.__lastSelectedText = sel.toString().trim();
                } catch(e) {}
            }
        });

        // ── Highlight & Markup Engine ─────────────────────────────────────────
        window.applyInksyncHighlight = function(id, colorHex, symbol, style) {
            if (typeof id === 'string' && id.indexOf('#') === 0) {
                style = symbol;
                symbol = colorHex;
                colorHex = id;
                id = '';
            }
            var sel = window.getSelection();
            var range = null;
            if (sel && sel.rangeCount > 0 && !sel.isCollapsed) {
                range = sel.getRangeAt(0);
            } else if (window.__lastSelectedRange) {
                range = window.__lastSelectedRange;
            }
            if (!range) return "";
            var text = (sel && !sel.isCollapsed) ? sel.toString().trim() : (window.__lastSelectedText || (range.toString ? range.toString().trim() : ''));
            if (!text) return "";
            var mark = document.createElement('mark');
            mark.className = 'inksync-highlight';
            if (id) mark.setAttribute('data-id', id);
            if (style) mark.setAttribute('data-style', style);
            var bgAlpha = _isDarkTheme ? 0.38 : 0.42;
            var highlightBg = hexToRgba(colorHex || '#FFD600', bgAlpha);
            if (style === 'underline') {
                mark.style.setProperty('background-color', 'transparent', 'important');
                mark.style.setProperty('text-decoration', 'underline', 'important');
                mark.style.setProperty('text-decoration-color', colorHex || '#FF9100', 'important');
                mark.style.setProperty('text-underline-offset', '3px', 'important');
            } else if (style === 'strikeout') {
                mark.style.setProperty('background-color', 'transparent', 'important');
                mark.style.setProperty('text-decoration', 'line-through', 'important');
                mark.style.setProperty('text-decoration-color', colorHex || '#FF4081', 'important');
            } else {
                mark.style.setProperty('background-color', highlightBg, 'important');
                mark.style.mixBlendMode = _isDarkTheme ? 'normal' : 'multiply';
            }
            mark.style.color = 'inherit';
            mark.style.borderRadius = '3px';
            mark.style.padding = '0 1px';
            if (symbol) {
                mark.setAttribute('data-symbol', symbol);
            }
            try {
                range.surroundContents(mark);
            } catch(e) {
                try {
                    var frag = range.extractContents();
                    mark.appendChild(frag);
                    range.insertNode(mark);
                } catch(err) {
                    var walker = document.createTreeWalker(range.commonAncestorContainer, NodeFilter.SHOW_TEXT, null, false);
                    var textNode;
                    while ((textNode = walker.nextNode())) {
                        if (range.intersectsNode && range.intersectsNode(textNode)) {
                            var subMark = document.createElement('mark');
                            subMark.className = 'inksync-highlight';
                            if (id) subMark.setAttribute('data-id', id);
                            if (style) subMark.setAttribute('data-style', style);
                            if (style === 'underline') {
                                subMark.style.setProperty('background-color', 'transparent', 'important');
                                subMark.style.setProperty('text-decoration', 'underline', 'important');
                                subMark.style.setProperty('text-decoration-color', colorHex || '#FF9100', 'important');
                                subMark.style.setProperty('text-underline-offset', '3px', 'important');
                            } else if (style === 'strikeout') {
                                subMark.style.setProperty('background-color', 'transparent', 'important');
                                subMark.style.setProperty('text-decoration', 'line-through', 'important');
                                subMark.style.setProperty('text-decoration-color', colorHex || '#FF4081', 'important');
                            } else {
                                subMark.style.setProperty('background-color', highlightBg, 'important');
                                subMark.style.mixBlendMode = _isDarkTheme ? 'normal' : 'multiply';
                            }
                            if (symbol) subMark.setAttribute('data-symbol', symbol);
                            var startOffset = (textNode === range.startContainer) ? range.startOffset : 0;
                            var endOffset = (textNode === range.endContainer) ? range.endOffset : textNode.nodeValue.length;
                            var subRange = document.createRange();
                            subRange.setStart(textNode, startOffset);
                            subRange.setEnd(textNode, endOffset);
                            try { subRange.surroundContents(subMark); } catch(x) {}
                        }
                    }
                }
            }
            if (sel) { try { sel.removeAllRanges(); } catch(e) {} }
            window.__lastSelectedRange = null;
            window.__lastSelectedText = null;
            return text;
        };

        window.adjustInksyncSelection = function(delta, isStart) {
            var sel = window.getSelection();
            var range = (sel && sel.rangeCount > 0 && !sel.isCollapsed) ? sel.getRangeAt(0) : window.__lastSelectedRange;
            if (!range) return "";
            try {
                if (isStart) {
                    if (delta < 0) {
                        if (range.startOffset > 0) {
                            range.setStart(range.startContainer, Math.max(0, range.startOffset - 1));
                        } else if (range.startContainer.previousSibling && range.startContainer.previousSibling.nodeType === Node.TEXT_NODE) {
                            var prev = range.startContainer.previousSibling;
                            range.setStart(prev, Math.max(0, prev.nodeValue.length - 1));
                        }
                    } else {
                        var maxStart = (range.startContainer === range.endContainer) ? range.endOffset - 1 : (range.startContainer.nodeValue ? range.startContainer.nodeValue.length : 0);
                        if (range.startOffset < maxStart) {
                            range.setStart(range.startContainer, range.startOffset + 1);
                        }
                    }
                } else {
                    if (delta > 0) {
                        var endLen = range.endContainer.nodeValue ? range.endContainer.nodeValue.length : 0;
                        if (range.endOffset < endLen) {
                            range.setEnd(range.endContainer, range.endOffset + 1);
                        } else if (range.endContainer.nextSibling && range.endContainer.nextSibling.nodeType === Node.TEXT_NODE) {
                            var next = range.endContainer.nextSibling;
                            range.setEnd(next, Math.min(next.nodeValue.length, 1));
                        }
                    } else {
                        var minEnd = (range.startContainer === range.endContainer) ? range.startOffset + 1 : 1;
                        if (range.endOffset > minEnd) {
                            range.setEnd(range.endContainer, range.endOffset - 1);
                        }
                    }
                }
                if (sel) {
                    sel.removeAllRanges();
                    sel.addRange(range);
                }
                window.__lastSelectedRange = range.cloneRange();
                var newText = range.toString().trim();
                window.__lastSelectedText = newText;
                return newText;
            } catch(e) {
                return range.toString().trim();
            }
        };

        window.restoreInksyncHighlight = function(id, textToFind, colorHex, symbol, style) {
            if (!textToFind) return;
            var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null, false);
            var node;
            var bgAlpha = _isDarkTheme ? 0.38 : 0.42;
            var highlightBg = hexToRgba(colorHex || '#FFD600', bgAlpha);
            while ((node = walker.nextNode())) {
                if (node.parentElement && node.parentElement.closest && node.parentElement.closest('mark.inksync-highlight')) continue;
                var idx = node.nodeValue.indexOf(textToFind);
                if (idx !== -1) {
                    try {
                        var range = document.createRange();
                        range.setStart(node, idx);
                        range.setEnd(node, idx + textToFind.length);
                        var mark = document.createElement('mark');
                        mark.className = 'inksync-highlight';
                        if (id) mark.setAttribute('data-id', id);
                        if (style) mark.setAttribute('data-style', style);
                        if (style === 'underline') {
                            mark.style.setProperty('background-color', 'transparent', 'important');
                            mark.style.setProperty('text-decoration', 'underline', 'important');
                            mark.style.setProperty('text-decoration-color', colorHex || '#FF9100', 'important');
                            mark.style.setProperty('text-underline-offset', '3px', 'important');
                        } else if (style === 'strikeout') {
                            mark.style.setProperty('background-color', 'transparent', 'important');
                            mark.style.setProperty('text-decoration', 'line-through', 'important');
                            mark.style.setProperty('text-decoration-color', colorHex || '#FF4081', 'important');
                        } else {
                            mark.style.setProperty('background-color', highlightBg, 'important');
                            mark.style.mixBlendMode = _isDarkTheme ? 'normal' : 'multiply';
                        }
                        mark.style.color = 'inherit';
                        mark.style.borderRadius = '3px';
                        mark.style.padding = '0 1px';
                        if (symbol) mark.setAttribute('data-symbol', symbol);
                        range.surroundContents(mark);
                    } catch(e) {}
                    break;
                }
            }
        };

        window.updateInksyncHighlightColor = function(idOrText, newColorHex) {
            if (!idOrText) return;
            var targetMarks = [];
            var idMark = document.querySelector('mark.inksync-highlight[data-id="' + idOrText + '"]');
            if (idMark) {
                targetMarks.push(idMark);
            } else {
                var marks = document.querySelectorAll('mark.inksync-highlight');
                for (var i = 0; i < marks.length; i++) {
                    if (marks[i].getAttribute('data-id') === idOrText || marks[i].textContent.trim() === idOrText.trim() || marks[i].textContent.indexOf(idOrText) !== -1 || idOrText.indexOf(marks[i].textContent) !== -1) {
                        targetMarks.push(marks[i]);
                    }
                }
            }
            var bgAlpha = _isDarkTheme ? 0.38 : 0.42;
            var highlightBg = hexToRgba(newColorHex || '#FFD600', bgAlpha);
            for (var j = 0; j < targetMarks.length; j++) {
                var m = targetMarks[j];
                var st = m.getAttribute('data-style');
                if (st === 'underline' || st === 'strikeout') {
                    m.style.setProperty('text-decoration-color', newColorHex || '#FF9100', 'important');
                } else {
                    m.style.setProperty('background-color', highlightBg, 'important');
                    m.style.mixBlendMode = _isDarkTheme ? 'normal' : 'multiply';
                }
            }
        };

        window.removeInksyncHighlight = function(idOrText) {
            var marks = document.querySelectorAll('mark.inksync-highlight');
            for (var i = 0; i < marks.length; i++) {
                if (marks[i].getAttribute('data-id') === idOrText || marks[i].textContent.trim() === idOrText.trim()) {
                    var parent = marks[i].parentNode;
                    while (marks[i].firstChild) {
                        parent.insertBefore(marks[i].firstChild, marks[i]);
                    }
                    parent.removeChild(marks[i]);
                    parent.normalize();
                    break;
                }
            }
        };

        // ── Auto Scroll ──────────────────────────────────────────────────
        var scrollActive = false;
        var scrollSpeed = 1.0;
        var lastTime = 0;

        window.startInksyncAutoScroll = function(speed) {
            scrollSpeed = speed;
            if (scrollActive) return;
            scrollActive = true;
            lastTime = performance.now();

            function scrollStep(timestamp) {
                if (!scrollActive) return;
                var delta = timestamp - lastTime;
                lastTime = timestamp;

                var step = (scrollSpeed * (delta / 16.67));
                window.scrollBy(0, step);

                requestAnimationFrame(scrollStep);
            }
            requestAnimationFrame(scrollStep);
        };
        window.stopInksyncAutoScroll = function() {
            scrollActive = false;
        };

        document.addEventListener('DOMContentLoaded', function() {
            document.body.style.webkitUserSelect = 'text';
            document.body.style.userSelect = 'text';
        });
        </script>
        """
    }
}

// MARK: - Safe array subscript
extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
