import SwiftUI
import WebKit
import ZIPFoundation
import SwiftData

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
    @State private var showingSettingsPanel = false
    
    // Utilities
    @ObservedObject private var orientationLock = OrientationLockManager.shared
    @ObservedObject private var sleepTimer = SleepTimerManager.shared
    @State private var deviceOrientation = UIDevice.current.orientation
    
    // Tools
    @State private var showShareSheet = false
    @State private var showSleepTimerPicker = false
    
    // Preferences — shared across all books


    
        // Per-book progress key: fingerprinted by filename
    private var progressKey: String { "ebook_progress_\(fileURL.lastPathComponent.hashValue)" }
    private var pageKey: String { "ebook_page_\(fileURL.lastPathComponent.hashValue)" }

    
    // State
    @State private var metadata: EBookMetadata?
    @State private var currentIndex: Int = 0
    @State private var isLoading = true
    @State private var showChapterList = false
    @State private var showHUD = true
    @State private var errorMessage: String?
    @State private var unzipDir: URL?

    // Page state matching current chapter
    @State private var chapterPage: Int = 0
    @State private var chapterTotalPages: Int = 1
    @StateObject private var velocityEngine = ReaderVelocityEngine()

    /// Direction of last chapter navigation — used to drive the push transition.
    @State private var isGoingForward: Bool = true
    
    @State private var activeHighlightToEdit: SDAnnotation? = nil
    @State private var annotationForFullEdit: SDAnnotation? = nil
    @State private var lastBrightnessDragValue: CGFloat = 0
    // Gap A: Annotations panel
    @State private var showAnnotations = false
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
    // Key for persisting the scroll fraction alongside the chapter index
    private var fractionKey: String { "ebook_fraction_\(fileURL.lastPathComponent.hashValue)" }

    private var totalChapters: Int { metadata?.spineItems.count ?? 1 }
    private var visibleChapters: [(index: Int, label: String)] {
        guard let spine = metadata?.spineItems else { return [] }
        return spine.enumerated().map { (index: $0.offset, label: !$0.element.label.isEmpty ? $0.element.label : "Chapter \($0.offset + 1)") }
    }
    private var progressFraction: Double {
        guard totalChapters > 1 else { return 0 }
        return Double(currentIndex) / Double(totalChapters - 1)
    }
    
    var body: some View {
        ZStack(alignment: .top) {
            // Background bleeds into status bar
            prefs.activeTheme.background(colorScheme: colorScheme).ignoresSafeArea()
            
            VStack(spacing: 0) {
                // ── Reading Progress Bar ──────────────────────────────────
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(prefs.activeTheme.foreground(colorScheme: colorScheme).opacity(0.08)).frame(height: 2)
                        Rectangle()
                            .fill(LinearGradient(colors: [Color(hex: "#7B5EA7"), Color(hex: "#B39DDB")],
                                                 startPoint: .leading, endPoint: .trailing))
                            .frame(width: geo.size.width * progressFraction, height: 2)
                            .animation(.spring(response: 0.4), value: progressFraction)
                    }
                }
                .frame(height: 2)
                
                // ── Main Reader ───────────────────────────────────────────
                Group {
                    if isLoading {
                        readerLoadingView
                    } else if let err = errorMessage {
                        readerErrorView(err)
                    } else if let meta = metadata, !meta.spineItems.isEmpty {
                        ZStack {
                            if prefs.paginationMode == EBookPaginationMode.paged.rawValue {
                                // ── Native UIPageViewController Page Curl ──────────────
                                // Uses UIPageViewController(.pageCurl) — the same native
                                // iOS page curl used by the comic and PDF readers.
                                EBookPageCurlReader(
                                    spineItem:   meta.spineItems[currentIndex],
                                    unzipDir:    unzipDir,
                                    prefs:       prefs,
                                    colorScheme: colorScheme,
                                    currentPage: $chapterPage,
                                    initialPage: chapterPage,
                                    totalPages:  $chapterTotalPages,
                                    onNext:      nextChapter,
                                    onPrev:      prevChapter,
                                    onCenterTap: { withAnimation(.easeInOut(duration: 0.2)) { showHUD.toggle() } },
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
                                            colorHex: "#ffd700",
                                            selectedText: selectedText
                                        )
                                        AnnotationStore.shared.add(highlight)
                                        let sdAnnotation = SDAnnotation(from: highlight)
                                        modelContext.insert(sdAnnotation)
                                        try? modelContext.save()
                                        activeHighlightToEdit = sdAnnotation
                                    },
                                    pdfID: pdf?.id,
                                    initialScrollFraction: UserDefaults.standard.double(forKey: "ebook_fraction_\(fileURL.lastPathComponent.hashValue)"),
                                    onScrollFractionChanged: { fraction in
                                        chapterScrollFraction = fraction
                                        saveProgress()
                                    },
                                    webViewRef: $webViewReference,
                                    onFootnoteTapped: { text in
                                        activeFootnoteText = text
                                    }
                                )
                            } else {
                                // ── Scroll Mode (continuous vertical) ──────────────────
                                EBookWebReader(
                                    spineItem:   meta.spineItems[currentIndex],
                                    unzipDir:    unzipDir,
                                    prefs:       prefs,
                                    colorScheme: colorScheme,
                                    currentPage: $chapterPage,
                                    initialPage: chapterPage,
                                    totalPages:  $chapterTotalPages,
                                    onNext:      nextChapter,
                                    onPrev:      prevChapter,
                                    onCenterTap: { withAnimation(.easeInOut(duration: 0.2)) { showHUD.toggle() } },
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
                                            colorHex: "#ffd700",
                                            selectedText: selectedText
                                        )
                                        AnnotationStore.shared.add(highlight)
                                        let sdAnnotation = SDAnnotation(from: highlight)
                                        modelContext.insert(sdAnnotation)
                                        try? modelContext.save()
                                        activeHighlightToEdit = sdAnnotation
                                    },
                                    pdfID: pdf?.id,
                                    initialScrollFraction: UserDefaults.standard.double(forKey: "ebook_fraction_\(fileURL.lastPathComponent.hashValue)"),
                                    onScrollFractionChanged: { fraction in
                                        chapterScrollFraction = fraction
                                        saveProgress()
                                    },
                                    webViewRef: $webViewReference,
                                    onFootnoteTapped: { text in
                                        activeFootnoteText = text
                                    }
                                )
                            }
                            
                            EdgeBrightnessGestureZone()
                        }
                    }
                    
                    if !showHUD {
                        KindleProgressFooterView(
                            currentPage: currentIndex + 1,
                            totalPages: totalChapters,
                            chapterPage: chapterPage,
                            chapterTotalPages: chapterTotalPages,
                            estimatedMinutesLeft: pdf.flatMap { ReaderProgressTracker.shared.progress(for: $0.id)?.estimatedMinutesRemaining }
                        )
                    }
                }
                .readingFilter(prefs.readingFilter)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
            }
            
            // ── HUD Overlays (tap-to-show UI) ─────────────────────────────
            if showChapterList { chapterDrawer }
        }
        .navigationBarHidden(true)
        .statusBarHidden(false)
        
        .overlay(alignment: .top) {
            if showHUD {
                topBar
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottom) {
            if showHUD {
                bottomBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        // Settings sheet lives here only — NOT duplicated inside chapterDrawer
        .sheet(isPresented: $showingSettingsPanel) {
            EBookSettingsPanel(bookID: pdf?.id.uuidString)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showSleepTimerPicker) {
            SleepTimerPickerSheet()
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(activityItems: [fileURL])
        }
        .popover(item: Binding<FootnoteItem?>(
            get: { activeFootnoteText.map { FootnoteItem(text: $0) } },
            set: { activeFootnoteText = $0?.text }
        )) { item in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Footnote")
                        .font(.headline)
                        .foregroundColor(.gray)
                    Text(item.text)
                        .font(.body)
                        .foregroundColor(.primary)
                }
                .padding()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(hex: prefs.activeTheme.cssBackground))
        }

        .task { await loadBook() }
        .onDisappear { cleanup(); saveProgress() }
        // FIX 4: Save scroll fraction whenever the chapter page changes
        .onChange(of: chapterPage) { _, _ in saveProgress() }
        // Also save position when the app goes to the background
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            saveProgress()
        }
        .overlay { if prefs.showReadingRuler { ReadingRulerOverlay() } }
        .onChange(of: sleepTimer.didFire) { _, fired in
            if fired { if let onExit = onExit { onExit() } else { dismiss() } }
        }
        // FIX 1+2: Colour picker popover for EPUB highlights
        .popover(item: $activeHighlightToEdit) { annotation in
            HighlightQuickPopoverView(
                annotation: annotation,
                onDelete: {
                    // Remove from AnnotationStore (in-memory + SwiftData via its own context)
                    let pid = annotation.pdfID
                    AnnotationStore.shared.delete(id: annotation.id, pdfID: pid)
                    // Also remove from the SwiftUI modelContext (UI layer)
                    modelContext.delete(annotation)
                    try? modelContext.save()
                    activeHighlightToEdit = nil
                },
                onEditNote: {
                    annotationForFullEdit = annotation
                    activeHighlightToEdit = nil
                },
                onColorSelected: { colorHex in
                    // Update colour in AnnotationStore (in-memory + SwiftData)
                    let pid = annotation.pdfID
                    let matching = AnnotationStore.shared.annotations(for: pid)
                        .first(where: { $0.id == annotation.id })
                    if var updated = matching {
                        updated.colorHex = colorHex
                        AnnotationStore.shared.update(updated)
                    }
                    // Also update the SDAnnotation in the SwiftUI model layer
                    annotation.colorHex = colorHex
                    try? modelContext.save()
                }
            )
            .presentationCompactAdaptation(.popover)
        }
        .sheet(item: $annotationForFullEdit) { annotation in
            AnnotationEditSheet(annotation: annotation)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        // Gap A: Annotations / highlights panel — same StudyNotebookView used by BookReaderEngine

        // Gap B: Full-text EPUB search sheet
        .sheet(isPresented: $showSearch) {
            if let meta = metadata {
                EPUBSearchView(
                    spineItems: meta.spineItems,
                    unzipDir: unzipDir,
                    onNavigate: { chapterIdx, matchText in
                        if chapterIdx == currentIndex {
                            // Same chapter: inject window.find() immediately
                            if let wv = webViewReference {
                                let safe = matchText
                                    .replacingOccurrences(of: "\\", with: "\\\\")
                                    .replacingOccurrences(of: "'", with: "\\'")
                                let js = """
                                (function() {
                                    window.getSelection()?.removeAllRanges();
                                    var found = window.find('\(safe)', false, false, true, false, false, false);
                                    if (!found) { window.find('\(safe)', false, false, false, false, false, false); }
                                })();
                                """
                                wv.evaluateJavaScript(js)
                            }
                        } else {
                            // 1. Navigate to the right chapter
                            isGoingForward = chapterIdx >= currentIndex
                            currentIndex = chapterIdx
                            chapterPage = 0
                            saveProgress()
                            // 2. After navigation, inject window.find() to scroll to + highlight match
                            // The pending match is picked up in .onChange(of: currentIndex)
                            pendingSearchMatch = matchText
                        }
                    }
                )
        .onChange(of: chapterPage) { _, newPage in
            velocityEngine.recordPageTurn()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("Reader_JumpToPage"))) { notification in
            if let pageIndex = notification.userInfo?["pageIndex"] as? Int, pageIndex >= 0, pageIndex < totalChapters {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    isGoingForward = pageIndex >= currentIndex
                    currentIndex = pageIndex
                    chapterPage = 0
                    saveProgress()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("Reader_JumpToChapterHref"))) { notification in
            if let href = notification.userInfo?["href"] as? String, !href.isEmpty, let meta = metadata {
                let cleanTarget = href.lowercased()
                if let targetIdx = meta.spineItems.firstIndex(where: { $0.href.lowercased().hasSuffix(cleanTarget) }) {
                    if targetIdx != currentIndex {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            isGoingForward = targetIdx >= currentIndex
                            currentIndex = targetIdx
                            chapterPage = 0
                            saveProgress()
                        }
                    }
                    if let fragment = notification.userInfo?["fragment"] as? String, !fragment.isEmpty {
                        Task {
                            try? await Task.sleep(nanoseconds: 500_000_000)
                            await MainActor.run {
                                if let wv = webViewReference {
                                    let js = "document.getElementById('\(fragment)')?.scrollIntoView({ behavior: 'smooth', block: 'start' });"
                                    wv.evaluateJavaScript(js)
                                }
                            }
                        }
                    }
                }
            }
        }
        // Gap B: After chapter navigation, inject window.find() into the live WebView
        .onChange(of: currentIndex) { _, _ in
            guard let match = pendingSearchMatch, !match.isEmpty else { return }
            // Small delay to allow the chapter to finish loading before find()
            Task {
                try? await Task.sleep(nanoseconds: 600_000_000) // 0.6s
                await MainActor.run {
                    if let wv = webViewReference {
                        let safe = match
                            .replacingOccurrences(of: "\\", with: "\\\\")
                            .replacingOccurrences(of: "'", with: "\\'")
                        // window.find: scroll to first match and select it
                        let js = """
                        (function() {
                            window.getSelection()?.removeAllRanges();
                            var found = window.find('\(safe)', false, false, true, false, false, false);
                            if (!found) { window.find('\(safe)', false, false, false, false, false, false); }
                        })();
                        """
                        wv.evaluateJavaScript(js)
                    }
                    pendingSearchMatch = nil
                }
            }
        }
    }
}

    // MARK: - Top Bar (Glass HUD)
    @ViewBuilder private var topBar: some View {
        HStack(spacing: 10) {
            // Back Button
            Button { if let onExit = onExit { onExit() } else { dismiss() } } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: Circle())
            }
            
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .shadow(color: .black.opacity(0.6), radius: 3)
            
            Spacer()
            
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
                }
            }

            // Bookmark
            Button { toggleBookmark() } label: {
                Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isBookmarked ? Color.orange : .white)
                    .frame(width: 34, height: 34)
                    .background(.ultraThinMaterial, in: Circle())
            }

            // Orientation lock
            Button { orientationLock.toggleLock(current: deviceOrientation) } label: {
                Image(systemName: orientationLock.isLocked ? "lock.rotation" : "lock.rotation.open")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(orientationLock.isLocked ? Color.orange : .white)
                    .frame(width: 34, height: 34)
                    .background(.ultraThinMaterial, in: Circle())
            }
            
            Menu {
                Section("Appearance") {
                    Button { showingSettingsPanel.toggle() } label: {
                        Label("Text & Layout", systemImage: "textformat.size")
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
                    // Gap A: Annotations + highlights panel
                    Button { NotificationCenter.default.post(name: .toggleStudyNotebook, object: nil) } label: {
                        Label("Highlights & Notes", systemImage: "highlighter")
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
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(.ultraThinMaterial, in: Circle())
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 52)
        .padding(.bottom, 10)
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0.55), Color.clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .top)
        )
    }
    
    // MARK: - Bottom Bar (Glass HUD)
    @ViewBuilder private var bottomBar: some View {
        VStack(spacing: 0) {
            // ── Progress Scrubber ─────────────────────────────────────────
            if totalChapters > 1 {
                HStack(spacing: 10) {
                    Text("1")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(width: 16, alignment: .leading)
                    Slider(
                        value: Binding(
                            get: { progressFraction },
                            set: { newVal in
                                let target = Int((newVal * Double(totalChapters - 1)).rounded())
                                withAnimation(.easeInOut(duration: 0.18)) { currentIndex = target }
                                saveProgress()
                            }
                        ),
                        in: 0...1
                    )
                    .tint(Color(hex: "#B39DDB"))
                    Text("\(totalChapters)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(width: 16, alignment: .trailing)
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 4)
                
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 0.5)
                    .padding(.horizontal, 16)
            }

            // ── Navigation row ─────────────────────────────────────────
            HStack(spacing: 24) {
                Button { prevChapter() } label: {
                    Image(systemName: "chevron.left.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(currentIndex == 0 ? .white.opacity(0.2) : .white.opacity(0.9))
                }
                .disabled(currentIndex == 0)
                
                VStack(spacing: 2) {
                    Text("Page \(chapterPage + 1) of \(chapterTotalPages)")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    if totalChapters > 1 {
                        Text("Chapter \(currentIndex + 1) / \(totalChapters)")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    // Time remaining estimate
                    if let mins = ReaderProgressTracker.shared.progress(for: pdf?.id ?? UUID())?.estimatedMinutesRemaining, mins > 0 {
                        Text("~\(mins)m left")
                            .font(.system(size: 10, weight: .regular, design: .rounded))
                            .foregroundStyle(Color(hex: "#B39DDB").opacity(0.8))
                    }
                }
                .frame(minWidth: 100)
                
                Button { nextChapter() } label: {
                    Image(systemName: "chevron.right.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(currentIndex >= totalChapters - 1 ? .white.opacity(0.2) : .white.opacity(0.9))
                }
                .disabled(currentIndex >= totalChapters - 1)
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 24)
        }
        .background(
            LinearGradient(
                colors: [Color.clear, Color.black.opacity(0.65)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
        )
    }
    
    // MARK: - Chapter Drawer
    @ViewBuilder private var chapterDrawer: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 72) // clear under top bar
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(visibleChapters, id: \.index) { item in
                            Button {
                                withAnimation(.spring()) {
                                    currentIndex = item.index
                                    chapterPage = 0
                                    chapterScrollFraction = 0.0
                                    showChapterList = false
                                }
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
    
    private func readerErrorView(_ msg: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.orange)
            Text("Couldn't Open Book").font(.headline).foregroundStyle(prefs.activeTheme.foreground(colorScheme: colorScheme))
            Text(msg).font(.subheadline).foregroundStyle(prefs.activeTheme.foreground(colorScheme: colorScheme).opacity(0.6))
                .multilineTextAlignment(.center).padding(.horizontal, 40)
        }
    }
    
    // MARK: - Navigation
    private func nextChapter() {
        if currentIndex >= totalChapters - 1 {
            // Last chapter — try to jump to next volume in series
            attemptSeriesContinuation()
            return
        }
        isGoingForward = true
        chapterPage = 0
        chapterScrollFraction = 0.0
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { currentIndex += 1 }
        saveProgress()
        trackEBookProgress()
    }

    /// Looks up the next unread book in the same series and posts OpenMergedBook so the
    /// library router opens it seamlessly — identical to the binge-mode flow in ReaderView.
    private func attemptSeriesContinuation() {
        guard let currentPDF = pdf,
              let seriesName = currentPDF.metadata.series, !seriesName.isEmpty else { return }

        // Include ALL books in the series (including the current) so we can find the
        // current book's position and step to the next. Excluding it breaks firstIndex.
        let siblings = allBooks
            .filter { $0.metadata.series == seriesName }
            .sorted { lhs, rhs in
                let lhsNum = Double(lhs.metadata.issueNumber ?? lhs.metadata.volume ?? "")
                let rhsNum = Double(rhs.metadata.issueNumber ?? rhs.metadata.volume ?? "")
                if let l = lhsNum, let r = rhsNum { return l < r }
                let lKey = lhs.metadata.issueNumber ?? lhs.metadata.volume ?? lhs.name
                let rKey = rhs.metadata.issueNumber ?? rhs.metadata.volume ?? rhs.name
                return lKey.localizedStandardCompare(rKey) == .orderedAscending
            }

        guard let currentIdx = siblings.firstIndex(where: { $0.id == currentPDF.id }) else { return }
        let nextIdx = siblings.index(after: currentIdx)
        guard siblings.indices.contains(nextIdx) else { return }
        NotificationCenter.default.post(name: .openMergedBook, object: siblings[nextIdx])
    }

    private func prevChapter() {
        guard currentIndex > 0 else { return }
        isGoingForward = false
        chapterPage = 99999 // Signal JS to jump to END of the previous chapter
        chapterScrollFraction = 1.0
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { currentIndex -= 1 }
        saveProgress()
        trackEBookProgress()
    }
    
    // MARK: - Load & Cleanup
    private func loadBook() async {
        Logger.shared.log("EBookReader: opening \(fileURL.lastPathComponent)", category: "EBook")
        
        // Restore saved progress
        let saved = UserDefaults.standard.integer(forKey: progressKey)
        let savedPage = UserDefaults.standard.integer(forKey: pageKey)
        
        // Linked Library: resolve security-scoped URL.
        var resolvedURL: URL = fileURL
        var accessedURL: URL? = nil
        
        if let pdf = pdf {
            if case .cloud = pdf.sourceMode {
                await MainActor.run { self.errorMessage = nil }
                do {
                    resolvedURL = try await CloudDownloadManager.shared.streamCloudFile(pdf: pdf)
                } catch {
                    await MainActor.run {
                        Logger.shared.log("EBookReader cloud stream failed: \(error.localizedDescription)", category: "EBook", type: .error)
                        self.errorMessage = "Failed to stream cloud file: \(error.localizedDescription)"
                        self.isLoading = false
                    }
                    return
                }
            } else if case .linked(let bm) = pdf.sourceMode,
               let url = try? BookmarkResolver.shared.resolve(bm) {
                let didAccess = url.startAccessingSecurityScopedResource()
                resolvedURL = url
                if didAccess { accessedURL = url }
            }
        }

        // Parse metadata (streaming OPF, no full unzip)
        let parsed = await EBookParser.shared.parse(epub: resolvedURL)
        
        // Unzip for content serving (WKWebView needs local file access)
        // Deterministic cache key: filename + mtime → same book reopens instantly
        let mtime = (try? resolvedURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
        let cacheKey = abs("\(resolvedURL.lastPathComponent)_\(Int(mtime.timeIntervalSince1970))".hashValue)
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("EBook_\(cacheKey)")

        do {
            if !FileManager.default.fileExists(atPath: dest.path) {
                // Unzip is a synchronous, potentially multi-second operation.
                // Doing it on the main actor blocks the runloop and risks a watchdog
                // kill during device orientation changes — move to a detached task.
                try await Task.detached(priority: .userInitiated) {
                    try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
                    try FileManager.default.unzipItem(at: resolvedURL, to: dest)
                }.value
            }
        } catch {
            accessedURL?.stopAccessingSecurityScopedResource()
            await MainActor.run {
                errorMessage = "Could not extract book: \(error.localizedDescription)"
                isLoading = false
            }
            Logger.shared.log("EBookReader: extraction failed — \(error.localizedDescription)", category: "EBook", type: .error)
            return
        }
        
        // Extraction done, stop security scope
        accessedURL?.stopAccessingSecurityScopedResource()
        
        await MainActor.run {
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
                // Apply per-book theme + typography profiles if saved
                if let bookID = pdf?.id.uuidString {
                    prefs.applyBookTheme(bookID: bookID)
                    prefs.applyBookTypography(bookID: bookID)
                }
            } else {
                self.errorMessage = "This EPUB file seems to be corrupted or missing a valid reading spine."
            }
            self.isLoading = false
            trackEBookProgress()
        }
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
        }
        if !progress.readingSessionDates.contains(where: { Calendar.current.isDateInToday($0) }) {
            progress.readingSessionDates.append(Date())
        }
        ReaderProgressTracker.shared.update(progress)
    }

    // MARK: - Bookmarks
    private var isBookmarked: Bool {
        guard let p = pdf ?? conversionManager.convertedPDFs.first(where: { $0.url.lastPathComponent == fileURL.lastPathComponent }) else { return false }
        return p.metadata.bookmarkedPages.contains(currentIndex)
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
            Logger.shared.log("Bookmark removed: chapter \(currentIndex + 1) of '\(p.name)'", category: "EBookReaderView", type: .info)
        } else {
            updated.metadata.bookmarkedPages.append(currentIndex)
            Logger.shared.log("Bookmark added: chapter \(currentIndex + 1) of '\(p.name)'", category: "EBookReaderView", type: .success)
        }
        
        conversionManager.convertedPDFs[idx] = updated
        conversionManager.saveLibrary()
        
        // Haptic feedback
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
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
                    if body == "next" { self.onNext() }
                    else if body == "prev" { self.onPrev() }
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
                        .filter { $0.kind == .highlight && $0.chapterTitle == self.spineItem.label }
                    for ann in annotations {
                        guard let text = ann.selectedText, let color = ann.colorHex else { continue }
                        let safeText = text
                            .replacingOccurrences(of: "`", with: "\\`")
                            .replacingOccurrences(of: "\"", with: "\\\"")
                            .replacingOccurrences(of: "\n", with: " ")
                        let js = "window.restoreInksyncHighlight(`\(safeText)`, '\(color)');"
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
        var contentURL = dir.appendingPathComponent(spineItem.href)
        if !FileManager.default.fileExists(atPath: contentURL.path) {
            if let decoded = spineItem.href.removingPercentEncoding {
                contentURL = dir.appendingPathComponent(decoded)
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
        
        // Generalize cleanup via SwiftReadability
        let cleanArticle = SwiftReadability.parse(html: rawHTML)
        var html = cleanArticle.content
        
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

        let renderWidth = size.width > 0 ? size.width : UIScreen.main.bounds.width
        let renderHeight = size.height > 0 ? size.height : UIScreen.main.bounds.height
        
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        let isLandscape = renderWidth > renderHeight
        let defaultColumns = isLandscape ? (prefs.autoLandscapeDualPage ? 2 : (isPad ? 2 : 1)) : 1
        let cols = prefs.columnCount == 0 ? defaultColumns : prefs.columnCount
        
        let m = isPaged ? max(20.0, margin) : margin
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
            font-family: 'Source Serif 4';
            src: local('SourceSerif4-Regular');
            font-weight: normal;
            font-style: normal;
        }
        @font-face {
            font-family: 'Source Serif 4';
            src: local('SourceSerif4-Regular');
            font-weight: bold;
            font-style: normal;
        }
        @font-face {
            font-family: 'Source Serif 4';
            src: local('SourceSerif4-Italic');
            font-weight: normal;
            font-style: italic;
        }
        @font-face {
            font-family: 'Source Serif 4';
            src: local('SourceSerif4-Italic');
            font-weight: bold;
            font-style: italic;
        }
        *, *::before, *::after { box-sizing: border-box; -webkit-tap-highlight-color: transparent; scroll-behavior: auto !important; }
        html {
            margin: 0 !important; padding: 0 !important;
            width: 100% !important;
            column-width: auto !important;
            touch-action: pan-x pan-y;
            scroll-behavior: auto !important;
            scroll-snap-type: none !important;
            background-color: \(bgColor) !important;
            \(isPaged ? """
            height: 100% !important;
            overflow-x: scroll !important;
            overflow-y: hidden !important;
            """ : """
            height: auto !important;
            overflow-x: hidden !important;
            overflow-y: auto !important;
            """)
        }
        body {
            color: \(textColor) !important;
            font-family: \(fontFamily) !important;
            font-size: \(fontSize)px !important;
            line-height: \(lineHeight) !important;
            text-align: \(textAlign) !important;
            margin: 0 !important;
            width: 100% !important;
            overflow: visible !important;
            background-color: transparent !important;
            word-wrap: break-word;
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
            \(isPaged ? """
            height: 100% !important;
            """ : """
            height: auto !important;
            """)
        }
        #inksync-viewport {
            margin: 0 !important;
            box-sizing: border-box !important;
            \(isPaged ? """
            display: block !important;
            position: static !important;
            padding-top: 60px !important;
            padding-bottom: 60px !important;
            padding-left: \(paddingLeft)px !important;
            padding-right: \(paddingRight)px !important;
            width: 100% !important;
            max-width: 100% !important;
            height: 100% !important;
            \(pagedCSS)
            """ : """
            display: block !important;
            width: 100% !important;
            height: auto !important;
            padding-top: 60px !important;
            padding-bottom: 60px !important;
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
        div, section, article, main, p, span, blockquote {
            max-height: none !important;
            overflow: visible !important;
        }
        div, section, article, main {
            height: auto !important;
        }
        div, section, article, main, p, blockquote {
            display: block !important;
            position: static !important;
            float: none !important;
        }
        """ : """
        div, section, article, main {
            max-height: none !important;
            height: auto !important;
            overflow: visible !important;
        }
        """)
        div, section, article {
            column-count: auto !important;
            column-width: auto !important;
        }
        p { margin-bottom: \(paraSpace)em !important; text-indent: \(paraIndent)em !important; }
        p, div, span, li, td, th, h1, h2, h3, h4, h5, h6 { color: \(textColor) !important; line-height: \(lineHeight); }
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
        mark.inksync-highlight { background-color: #ffd700; color: inherit; border-radius: 2px; mix-blend-mode: multiply; -webkit-mix-blend-mode: multiply; padding: 0 1px; }
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
            line-height: 0.85em !important;
            margin-top: 0.1em !important;
            margin-right: 0.1em !important;
            margin-bottom: -0.1em !important;
            font-weight: bold !important;
        }
        """)
        """
    }

    private func buildReaderCSS(prefs: EBookPreferences, colorScheme: ColorScheme, initialPage: Int, size: CGSize) -> String {
        let cssContent = computeCSS(prefs: prefs, size: size)
        let isPaged = prefs.paginationMode == EBookPaginationMode.paged.rawValue
        
        return """
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no, viewport-fit=cover">
        <style id="__inksync_live__">
        \(cssContent)
        </style>
        <script>
        document.addEventListener('DOMContentLoaded', function() {
            document.querySelectorAll('[style]').forEach(function(el) {
                el.style.removeProperty('background-color');
                el.style.removeProperty('color');
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
                if (_firstRun) {
                    _firstRun = false;
                    goToPage(_currentPage, false);
                } else {
                    _currentPage = Math.max(0, Math.min(Math.round(sv.scrollTop / pageHeight), _totalPages - 1));
                }
            }
            
            window.webkit.messageHandlers.metrics.postMessage({ current: _currentPage, total: _totalPages });
            postFraction();
        }

        function goToPage(page, smooth) {
            _currentPage = Math.max(0, Math.min(page, _totalPages - 1));
            var behavior = 'instant';
            
            var sv = document.scrollingElement || document.documentElement;
            var isHoriz = \(isPaged);
            if (isHoriz) {
                var pageStep = window.innerWidth;
                window.scrollTo({ left: _currentPage * pageStep, behavior: behavior });
            } else {
                window.scrollTo({ top: _currentPage * window.innerHeight, behavior: behavior });
            }
            
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

        // ── Highlight Engine ─────────────────────────────────────────────────
        window.applyInksyncHighlight = function(colorHex) {
            var sel = window.getSelection();
            if (!sel || sel.rangeCount === 0 || sel.isCollapsed) return;
            var text = sel.toString().trim();
            if (!text) return;
            var range = sel.getRangeAt(0);
            var mark = document.createElement('mark');
            mark.className = 'inksync-highlight';
            mark.style.backgroundColor = colorHex || '#ffd700';
            mark.style.color = 'inherit';
            mark.style.borderRadius = '2px';
            mark.style.mixBlendMode = 'multiply';
            try {
                range.surroundContents(mark);
            } catch(e) {
                var frag = range.extractContents();
                mark.appendChild(frag);
                range.insertNode(mark);
            }
            sel.removeAllRanges();
            window.webkit.messageHandlers.highlight.postMessage(text);
        };

        window.restoreInksyncHighlight = function(textToFind, colorHex) {
            if (!textToFind) return;
            var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null, false);
            var node;
            while ((node = walker.nextNode())) {
                var idx = node.nodeValue.indexOf(textToFind);
                if (idx !== -1) {
                    try {
                        var range = document.createRange();
                        range.setStart(node, idx);
                        range.setEnd(node, idx + textToFind.length);
                        var mark = document.createElement('mark');
                        mark.className = 'inksync-highlight';
                        mark.style.backgroundColor = colorHex || '#ffd700';
                        mark.style.color = 'inherit';
                        mark.style.borderRadius = '2px';
                        range.surroundContents(mark);
                    } catch(e) {}
                    break;
                }
            }
        };

        window.updateInksyncHighlightColor = function(textToFind, colorHex) {
            var marks = document.querySelectorAll('mark.inksync-highlight');
            for (var i = 0; i < marks.length; i++) {
                if (marks[i].textContent.trim() === textToFind.trim()) {
                    marks[i].style.backgroundColor = colorHex;
                    break;
                }
            }
        };

        window.removeInksyncHighlight = function(textToFind) {
            var marks = document.querySelectorAll('mark.inksync-highlight');
            for (var i = 0; i < marks.length; i++) {
                if (marks[i].textContent.trim() === textToFind.trim()) {
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
