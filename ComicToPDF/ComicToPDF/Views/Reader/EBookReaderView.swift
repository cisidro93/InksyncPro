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
    // Key for persisting the scroll fraction alongside the chapter index
    private var fractionKey: String { "ebook_fraction_\(fileURL.lastPathComponent.hashValue)" }

    private var totalChapters: Int { metadata?.spineItems.count ?? 1 }
    private var visibleChapters: [(index: Int, label: String)] {
        guard let spine = metadata?.spineItems else { return [] }
        let hasTOC = spine.contains(where: { !$0.label.isEmpty })
        
        if hasTOC {
            return spine.enumerated()
                .filter { !$0.element.label.isEmpty }
                .map { (index: $0.offset, label: $0.element.label) }
        } else {
            return spine.enumerated()
                .map { (index: $0.offset, label: "Chapter \($0.offset + 1)") }
        }
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
                                // FIX 1+2: Persist highlight to AnnotationStore + SwiftData.
                                // Open the colour-picker popover immediately so the user can
                                // change the colour — the selected hex is reflected in the DOM
                                // via the onColorSelected callback in HighlightQuickPopoverView.
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
                                    // Pop the colour picker popover immediately
                                    activeHighlightToEdit = sdAnnotation
                                },
                                pdfID: pdf?.id,
                                // FIX 4: Pass the saved fractional position so the chapter
                                // is restored to the exact scroll position, not the chapter start.
                                initialScrollFraction: UserDefaults.standard.double(forKey: "ebook_fraction_\(fileURL.lastPathComponent.hashValue)"),
                                onScrollFractionChanged: { fraction in
                                    chapterScrollFraction = fraction
                                    saveProgress()
                                },
                                // Gap B: Expose the live WKWebView so window.find() can be injected
                                webViewRef: $webViewReference
                            )
                            .padding(.horizontal, prefs.paginationMode == EBookPaginationMode.paged.rawValue ? prefs.textMargin : 0)
                            // Directional page-turn: slide left for forward, right for back.
                            // Using .id(currentIndex) forces SwiftUI to create a new view identity
                            // on every chapter change, guaranteeing the transition fires.
                            .id(currentIndex)
                            .transition(
                                .asymmetric(
                                    insertion: .push(from: isGoingForward ? .trailing : .leading),
                                    removal:   .push(from: isGoingForward ? .leading  : .trailing)
                                )
                            )
                            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: currentIndex)
                            
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
                        }
                    }
                }
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
            }
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
                                withAnimation(.spring()) { currentIndex = item.index; showChapterList = false }
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
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { currentIndex += 1 }
        saveProgress()
        trackEBookProgress()
    }

    /// Looks up the next unread book in the same series and posts OpenMergedBook so the
    /// library router opens it seamlessly — identical to the binge-mode flow in ReaderView.
    private func attemptSeriesContinuation() {
        guard let currentPDF = pdf,
              let seriesName = currentPDF.metadata.series, !seriesName.isEmpty else { return }

        // Robust sort: numeric-first, localizedStandardCompare fallback for "HC", "TPB", "#0" etc.
        let siblings = allBooks
            .filter { $0.metadata.series == seriesName && $0.id != currentPDF.id }
            .sorted { lhs, rhs in
                let lhsNum = Double(lhs.metadata.issueNumber ?? lhs.metadata.volume ?? "")
                let rhsNum = Double(rhs.metadata.issueNumber ?? rhs.metadata.volume ?? "")
                if let l = lhsNum, let r = rhsNum { return l < r }
                let lKey = lhs.metadata.issueNumber ?? lhs.metadata.volume ?? lhs.name
                let rKey = rhs.metadata.issueNumber ?? rhs.metadata.volume ?? rhs.name
                return lKey.localizedStandardCompare(rKey) == .orderedAscending
            }

        let selfKey = currentPDF.metadata.issueNumber ?? currentPDF.metadata.volume ?? currentPDF.name
        guard let currentIdx = siblings.firstIndex(where: { b in
            (b.metadata.issueNumber ?? b.metadata.volume ?? b.name) == selfKey
        }) else {
            if let first = siblings.first { NotificationCenter.default.post(name: .openMergedBook, object: first) }
            return
        }
        let nextIdx = siblings.index(after: currentIdx)
        guard siblings.indices.contains(nextIdx) else { return }
        NotificationCenter.default.post(name: .openMergedBook, object: siblings[nextIdx])
    }

    private func prevChapter() {
        guard currentIndex > 0 else { return }
        isGoingForward = false
        chapterPage = 99999 // Signal JS to jump to END of the previous chapter
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
        UserDefaults.standard.set(currentIndex, forKey: progressKey)
        UserDefaults.standard.set(chapterPage, forKey: pageKey)
        // FIX 4: Also persist the fractional scroll offset for within-chapter precision
        UserDefaults.standard.set(chapterScrollFraction, forKey: fractionKey)
        // Update ReaderProgressTracker with within-chapter offset too
        if let p = pdf ?? conversionManager.convertedPDFs.first(where: { $0.url.lastPathComponent == fileURL.lastPathComponent }) {
            let fraction = totalChapters > 1 ? Double(currentIndex) / Double(totalChapters - 1) : 0
            var progress = ReaderProgressTracker.shared.progress(for: p.id) ?? ReadingProgress(
                pdfID: p.id, lastOpenedAt: Date(), currentPageIndex: currentIndex,
                totalPagesRead: 1, completionFraction: fraction, readingSessionDates: []
            )
            progress.lastOpenedAt = Date()
            progress.currentPageIndex = currentIndex
            progress.currentChapterIndex = currentIndex
            progress.currentChapterOffset = chapterScrollFraction
            progress.completionFraction = fraction
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

// MARK: - Weak Script Message Proxy
/// WKUserContentController.add(_:name:) takes a STRONG reference to the handler.
/// This breaks the retain cycle:
///   WKWebView → UCC → WeakProxy (weak) → Coordinator
/// Without this, WKWebView is never deallocated and JS runs indefinitely → OOM crash.
/// Internal (not private) so BookReaderEngine.swift can also use it.
final class WeakScriptMessageProxy: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(ucc, didReceive: message)
    }
}

// MARK: - EBookWebReader (single reused WKWebView)
struct EBookWebReader: UIViewRepresentable {
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
    /// Called when the user highlights text — receives the selected string.
    var onHighlightCreated: ((String) -> Void)? = nil
    /// The PDF/book identity — used to restore previously saved highlights on chapter load.
    var pdfID: UUID? = nil
    /// FIX 4: Scroll fraction to restore within the chapter (0.0–1.0).
    /// Set from UserDefaults on open; updated via JS bridge on every page turn.
    var initialScrollFraction: Double = 0.0
    /// Called back from JS with the current scroll fraction whenever it changes.
    var onScrollFractionChanged: ((Double) -> Void)? = nil
    /// Gap B: Binding to share the web view reference for programmatic scripting (e.g. search).
    @Binding var webViewRef: WKWebView?

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Use WeakProxy so UCC doesn't strongly retain the coordinator
        let proxy = WeakScriptMessageProxy(context.coordinator)
        config.userContentController.add(proxy, name: "nav")
        config.userContentController.add(proxy, name: "metrics")
        // `highlight` handler: receives selected text when user taps Highlight
        config.userContentController.add(proxy, name: "highlight")
        // FIX 4: `scrollFraction` handler: receives the fractional scroll offset (0–1)
        // on every page navigation so we can save and restore within-chapter position.
        config.userContentController.add(proxy, name: "scrollFraction")

        let wv = HighlightableWebView(frame: .zero, configuration: config)
        wv.isOpaque = false
        wv.backgroundColor = .clear
        wv.scrollView.backgroundColor = .clear
        wv.scrollView.contentInsetAdjustmentBehavior = .always
        wv.navigationDelegate = context.coordinator
        wv.onHighlightRequested = {
            wv.evaluateJavaScript("window.applyInksyncHighlight('#ffd700');")
        }

        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch(_:)))
        pinch.delegate = context.coordinator
        wv.addGestureRecognizer(pinch)

        DispatchQueue.main.async {
            self.webViewRef = wv
        }

        return wv
    }

    /// Called by SwiftUI when the view is removed from the hierarchy.
    /// Remove message handlers so WKUserContentController releases the proxy
    /// and the WKWebView can be fully deallocated.
    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.loadTask?.cancel()
        coordinator.loadTask = nil
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "nav")
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "metrics")
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "highlight")
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "scrollFraction")
        uiView.navigationDelegate = nil
    }
    
    func updateUIView(_ wv: WKWebView, context: Context) {
        guard let dir = unzipDir else { return }

        var contentURL = dir.appendingPathComponent(spineItem.href)
        if !FileManager.default.fileExists(atPath: contentURL.path) {
            if let decoded = spineItem.href.removingPercentEncoding {
                contentURL = dir.appendingPathComponent(decoded)
            }
        }
        guard FileManager.default.fileExists(atPath: contentURL.path) else { return }

        let currentStateHash = "\(prefs.themeRaw)_\(prefs.customThemeBg)_\(prefs.customThemeText)_\(prefs.fontSize)_\(prefs.fontFamily)_\(prefs.lineHeight)_\(prefs.letterSpacing)_\(prefs.wordSpacing)_\(prefs.hyphenation)_\(prefs.textMargin)_\(prefs.paragraphSpacing)_\(prefs.paragraphIndent)_\(prefs.paginationMode)_\(prefs.textAlign)_\(prefs.autoScroll)_\(prefs.autoScrollSpeed)_\(prefs.tapZoneStyleRaw)_\(wv.bounds.width)_\(wv.bounds.height)"
        
        let contentChanged = context.coordinator.lastLoadedHref != spineItem.href
        let themeChanged = context.coordinator.lastTheme != currentStateHash

        guard contentChanged || themeChanged else { return }
        context.coordinator.lastLoadedHref = spineItem.href
        context.coordinator.lastTheme = currentStateHash

        if contentChanged {
            // Capture value-type snapshots so the detached task never touches ObservableObject
            let capturedURL  = contentURL
            let capturedDir  = dir
            let capturedPage = initialPage

            // CSS is pure string computation — compute on main before the task
            let cssToInject  = buildReaderCSS(prefs: prefs, colorScheme: colorScheme, initialPage: capturedPage, size: wv.bounds.size)

            // Cancel any in-flight load from a previous chapter swipe
            context.coordinator.loadTask?.cancel()
            context.coordinator.loadTask = Task {
                guard !Task.isCancelled else { return }

                // Heavy I/O + string ops on a background thread
                let styledHTML: String? = await Task.detached(priority: .userInitiated) {
                    var rawHTML: String?
                    var enc: String.Encoding = .utf8
                    let optString = try? String(contentsOf: capturedURL, usedEncoding: &enc)
                    if let html = optString {
                        rawHTML = html
                    } else {
                        let optData = try? Data(contentsOf: capturedURL)
                        if let data = optData {
                            rawHTML = String(data: data, encoding: .isoLatin1)
                                   ?? String(data: data, encoding: .ascii)
                        }
                    }
                    guard var html = rawHTML else { return nil }

                    // Strip legacy charset tags
                    let pattern = "<meta[^>]*charset[^>]*>"
                    let optRegex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
                    if let regex = optRegex {
                        html = regex.stringByReplacingMatches(
                            in: html, range: NSRange(html.startIndex..., in: html), withTemplate: ""
                        )
                    }

                    // Inject pre-computed CSS
                    if let range = html.range(of: "</head>", options: .caseInsensitive) {
                        return html.replacingCharacters(in: range, with: cssToInject + "</head>")
                    }
                    return cssToInject + html
                }.value

                guard !Task.isCancelled, let html = styledHTML else { return }

                // Back on main: write injected file + load
                await MainActor.run {
                    let hrefHash = abs(capturedURL.lastPathComponent.hashValue)
                    let injectedURL = capturedURL.deletingLastPathComponent()
                        .appendingPathComponent("__inksync_\(hrefHash).injected.html")
                    try? html.write(to: injectedURL, atomically: true, encoding: .utf8)
                    wv.loadFileURL(injectedURL, allowingReadAccessTo: capturedDir)
                }
            }
        } else {
            // Preferences/Theme changed inside the same chapter — update stylesheet directly in DOM without reloading!
            injectLiveCSS(into: wv)
        }

        // Dynamically update tap zone boundaries in the WebView DOM
        let leftEdge = prefs.tapZoneStyle.zones.leftEdge
        let rightEdge = prefs.tapZoneStyle.zones.rightEdge
        wv.evaluateJavaScript("window.__inksync_left_edge = \(leftEdge); window.__inksync_right_edge = \(rightEdge);", completionHandler: nil)

        // Apply auto-scroll logic
        if prefs.autoScroll && prefs.paginationMode == EBookPaginationMode.continuous.rawValue {
            let speed = prefs.autoScrollSpeed * 1.5
            wv.evaluateJavaScript("window.startInksyncAutoScroll(\(speed));", completionHandler: nil)
        } else {
            wv.evaluateJavaScript("window.stopInksyncAutoScroll();", completionHandler: nil)
        }
    }

    private func computeCSS(prefs: EBookPreferences, size: CGSize) -> String {
        let isPaged = prefs.paginationMode == EBookPaginationMode.paged.rawValue

        let bgColor      = prefs.activeTheme.cssBackground
        let textColor    = prefs.activeTheme.cssText
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

        let overflowCSS = isPaged
            ? "overflow: hidden !important;"
            : "overflow-x: hidden !important; overflow-y: auto !important;"
        let widthCSS = isPaged ? "" : "width: 100vw !important; overflow-x: hidden !important;"
        
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        let isLandscape = size.width > size.height
        let defaultColumns = (isPad && isLandscape) ? 2 : 1
        let cols = prefs.columnCount == 0 ? defaultColumns : prefs.columnCount
        
        let gap = Int(margin * 2)
        
        let pagedCSS = isPaged ? """
            column-count: \(cols) !important;
            column-width: auto !important;
            column-gap: \(gap)px !important;
            column-fill: auto !important;
            column-rule: 1px solid rgba(128, 128, 128, 0.15) !important;
        """ : ""

        let paddingLeft = isPaged ? 0 : margin
        let paddingRight = isPaged ? 0 : margin

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
        *, *::before, *::after { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
        html {
            margin: 0 !important; padding: 0 !important;
            height: 100vh !important; width: 100vw !important;
            column-width: auto !important;
            \(overflowCSS)
            background-color: \(bgColor) !important;
        }
        body {
            color: \(textColor) !important;
            font-family: \(fontFamily) !important;
            font-size: \(fontSize)px !important;
            line-height: \(lineHeight) !important;
            text-align: \(textAlign) !important;
            \(pagedCSS)
            margin: 0 !important;
            height: 100vh !important;
            \(widthCSS)
            padding-top: 60px !important;
            padding-bottom: 60px !important;
            padding-left: \(paddingLeft)px !important;
            padding-right: \(paddingRight)px !important;
            box-sizing: border-box !important;
            word-wrap: break-word;
            -webkit-text-size-adjust: none;
            letter-spacing: \(letterSpacing) !important;
            word-spacing: \(wordSpacing) !important;
            -webkit-hyphens: \(hyphenCSS) !important;
            hyphens: \(hyphenCSS) !important;
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
        div, section, article {
            column-count: auto !important;
            column-width: auto !important;
        }
        p { margin-bottom: \(paraSpace)em !important; text-indent: \(paraIndent)em !important; }
        p, div, span, li, td, th, h1, h2, h3, h4, h5, h6 { color: \(textColor) !important; line-height: \(lineHeight); }
        img, svg, .page, .chunk-container { display: block !important; margin-left: auto !important; margin-right: auto !important; }
        img { max-width: 100%; height: auto; border-radius: 4px; object-fit: contain; max-height: calc(100vh - 120px); }
        pre, table, code {
            max-width: 100% !important;
            overflow-x: auto !important;
            word-wrap: break-word !important;
            white-space: pre-wrap !important;
        }
        a { color: \(linkColor) !important; }
        blockquote { border-left: 3px solid \(linkColor); margin-left: 0; padding-left: 16px; opacity: 0.85; }
        mark.inksync-highlight { background-color: #ffd700; color: inherit; border-radius: 2px; mix-blend-mode: multiply; -webkit-mix-blend-mode: multiply; padding: 0 1px; }
        """
    }

    /// Builds the full CSS + JS block as a pure string on the main actor.
    /// No disk I/O — safe to call synchronously before spawning a background task.
    private func buildReaderCSS(prefs: EBookPreferences, colorScheme: ColorScheme, initialPage: Int, size: CGSize) -> String {
        let cssContent = computeCSS(prefs: prefs, size: size)
        
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
        });

        var _currentPage = \(initialPage);
        var _totalPages = 1;
        var _firstRun = true;

        function postFraction() {
            var sv = document.scrollingElement || document.documentElement;
            var isHoriz = document.body.style.columnCount || window.getComputedStyle(document.body).columnCount !== 'auto';
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
            _totalPages = Math.max(1, Math.ceil(document.documentElement.scrollWidth / window.innerWidth));
            if (_firstRun) {
                _firstRun = false;
                if (_currentPage === 99999) {
                    _currentPage = _totalPages - 1;
                }
                goToPage(_currentPage, false);
            } else {
                window.webkit.messageHandlers.metrics.postMessage({ current: _currentPage, total: _totalPages });
                postFraction();
            }
        }

        function goToPage(page, smooth) {
            _currentPage = Math.max(0, Math.min(page, _totalPages - 1));
            var behavior = smooth ? 'smooth' : 'instant';
            window.scrollTo({ left: _currentPage * window.innerWidth, behavior: behavior });
            if (!_firstRun) {
                window.webkit.messageHandlers.metrics.postMessage({ current: _currentPage, total: _totalPages });
            }
            postFraction();
        }
        window.goToInksyncPage = goToPage;

        window.onload = function() { setTimeout(updateMetrics, 100); };
        window.addEventListener('resize', function() { updateMetrics(); goToPage(_currentPage, false); });

        var _sx = 0;
        document.addEventListener('touchstart', function(e) { _sx = e.changedTouches[0].clientX; }, {passive:true});
        document.addEventListener('touchend', function(e) {
            var dx = e.changedTouches[0].clientX - _sx;
            if (dx < -40) {
                if (_currentPage < _totalPages - 1) goToPage(_currentPage + 1, false);
                else window.webkit.messageHandlers.nav.postMessage('next');
            } else if (dx > 40) {
                if (_currentPage > 0) goToPage(_currentPage - 1, false);
                else window.webkit.messageHandlers.nav.postMessage('prev');
            }
        }, {passive:true});

        document.addEventListener('click', function(e) {
            if (e.target.tagName.toLowerCase() === 'a') return;
            var x = e.clientX; var w = window.innerWidth;
            var leftEdge = window.__inksync_left_edge || 0.30;
            var rightEdge = window.__inksync_right_edge || 0.70;
            if (x < w * leftEdge) {
                if (_currentPage > 0) goToPage(_currentPage - 1, true);
                else window.webkit.messageHandlers.nav.postMessage('prev');
            } else if (x > w * rightEdge) {
                if (_currentPage < _totalPages - 1) goToPage(_currentPage + 1, true);
                else window.webkit.messageHandlers.nav.postMessage('next');
            } else {
                window.webkit.messageHandlers.nav.postMessage('center');
            }
        });

        document.addEventListener('keydown', function(e) {
            if (e.key === 'ArrowRight' || e.key === 'Space') {
                if (_currentPage < _totalPages - 1) goToPage(_currentPage + 1, true);
                else window.webkit.messageHandlers.nav.postMessage('next');
                e.preventDefault();
            } else if (e.key === 'ArrowLeft') {
                if (_currentPage > 0) goToPage(_currentPage - 1, true);
                else window.webkit.messageHandlers.nav.postMessage('prev');
                e.preventDefault();
            }
        });

        var _scrollTimeout;
        window.addEventListener('scroll', function() {
            clearTimeout(_scrollTimeout);
            _scrollTimeout = setTimeout(postFraction, 100);
        });

        // ── Highlight Engine ─────────────────────────────────────────────────
        // Uses DOM Range + <mark> element wrapping.
        // document.execCommand('hiliteColor') is deprecated and produces no
        // visual output in WKWebView on iOS 16+, so we use Range.surroundContents().
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
                // Range crosses element boundaries — extract + rewrap
                var frag = range.extractContents();
                mark.appendChild(frag);
                range.insertNode(mark);
            }
            sel.removeAllRanges();
            window.webkit.messageHandlers.highlight.postMessage(text);
        };

        // Restore a previously saved highlight on chapter reload.
        // Called from Swift after didFinishNavigation.
        // Uses TreeWalker to locate the text node — window.find() is unreliable
        // in column/paged mode and execCommand('hiliteColor') is dead in iOS 16+.
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
                
                // Normalize scroll delta to ~16.7ms base speed step
                var step = (scrollSpeed * (delta / 16.67));
                window.scrollBy(0, step);
                
                requestAnimationFrame(scrollStep);
            }
            requestAnimationFrame(scrollStep);
        };
        window.stopInksyncAutoScroll = function() {
            scrollActive = false;
        };

        // Make text selectable (required in paged/column mode)
        document.addEventListener('DOMContentLoaded', function() {
            document.body.style.webkitUserSelect = 'text';
            document.body.style.userSelect = 'text';
        });
        </script>
        """
    }

    /// Injects a live CSS update into the existing WebView DOM — no reload required.
    private func injectLiveCSS(into webView: WKWebView) {
        let sv = webView.scrollView
        let isHoriz = prefs.paginationMode == EBookPaginationMode.paged.rawValue
        let currentFraction: Double
        if isHoriz {
            let maxScroll = sv.contentSize.width - sv.bounds.width
            currentFraction = maxScroll > 0 ? Double(sv.contentOffset.x / maxScroll) : 0.0
        } else {
            let maxScroll = sv.contentSize.height - sv.bounds.height
            currentFraction = maxScroll > 0 ? Double(sv.contentOffset.y / maxScroll) : 0.0
        }
        let clampedFraction = max(0.0, min(1.0, currentFraction))

        let css = computeCSS(prefs: prefs, size: webView.bounds.size)

        let js = """
        (function() {
            var el = document.getElementById('__inksync_live__');
            if (!el) { el = document.createElement('style'); el.id = '__inksync_live__'; document.head.appendChild(el); }
            el.textContent = `\(css.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "`", with: "\\`"))`;
            
            // Restore scroll position
            setTimeout(function() {
                var sv = document.scrollingElement || document.documentElement;
                var isHoriz = document.body.style.columnCount || window.getComputedStyle(document.body).columnCount !== 'auto';
                if (isHoriz) {
                    var maxScroll = sv.scrollWidth - window.innerWidth;
                    window.scrollTo({ left: maxScroll * \(clampedFraction), behavior: 'instant' });
                } else {
                    var maxScroll = sv.scrollHeight - window.innerHeight;
                    window.scrollTo({ top: maxScroll * \(clampedFraction), behavior: 'instant' });
                }
            }, 100);
        })();
        """
        webView.evaluateJavaScript(js)
    }

    
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, UIGestureRecognizerDelegate {
        var parent: EBookWebReader
        var lastLoadedHref: String = ""
        var lastTheme: String = ""
        var lastFontSize: Double = 0
        /// Cancellable reference — cancelled on every new chapter load to prevent stale renders
        var loadTask: Task<Void, Never>?
        var initialPinchFontSize: Double = 16.0

        init(_ parent: EBookWebReader) { self.parent = parent }

        func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "nav", let body = message.body as? String {
                if body == "next" { self.parent.onNext() }
                else if body == "prev" { self.parent.onPrev() }
                else if body == "center" { self.parent.onCenterTap() }
            } else if message.name == "metrics", let body = message.body as? [String: Int] {
                self.parent.currentPage = body["current"] ?? 0
                self.parent.totalPages = body["total"] ?? 1
            } else if message.name == "highlight", let text = message.body as? String, !text.isEmpty {
                self.parent.onHighlightCreated?(text)
            } else if message.name == "scrollFraction", let fraction = message.body as? Double {
                // FIX 4: Report the within-chapter scroll fraction back to Swift for persistence.
                self.parent.onScrollFractionChanged?(fraction)
            }
        }
        
        // Intercept navigation for Footnotes, External links, and Chapters
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated {
                if let url = navigationAction.request.url {
                    if url.scheme == "http" || url.scheme == "https" {
                        UIApplication.shared.open(url)
                    } else if let fragment = url.fragment {
                        // Internal anchor (e.g., footnote)
                        let js = """
                        var el = document.getElementById('\(fragment)') || document.getElementsByName('\(fragment)')[0];
                        if (el) {
                            var targetPage = Math.floor(el.getBoundingClientRect().left / window.innerWidth) + _currentPage;
                            goToPage(Math.max(0, targetPage));
                        }
                        """
                        webView.evaluateJavaScript(js, completionHandler: nil)
                    }
                }
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }

        /// Restore saved highlights and scroll position after every chapter load.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let pdfID = parent.pdfID else { return }
            let chapter = parent.spineItem.href
            let annotations = AnnotationStore.shared.annotations(for: pdfID)
                .filter { $0.kind == .highlight && $0.chapterTitle == parent.spineItem.label }
            for ann in annotations {
                guard let text = ann.selectedText, let color = ann.colorHex else { continue }
                let safeText = text
                    .replacingOccurrences(of: "`", with: "\\`")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                    .replacingOccurrences(of: "\n", with: " ")
                let _ = chapter // suppress unused warning
                let js = "window.restoreInksyncHighlight(`\(safeText)`, '\(color)');"
                webView.evaluateJavaScript(js)
            }

            // FIX 4: Restore the within-chapter fractional scroll position.
            // We use a 150ms delay to allow the layout engine to complete column
            // calculation before we scroll; without this, scrollWidth is still 0.
            let fraction = parent.initialScrollFraction
            if fraction > 0.01 {
                let restoreJS = """
                setTimeout(function() {
                    var sv = document.scrollingElement || document.documentElement;
                    var isHoriz = document.body.style.columnCount || window.getComputedStyle(document.body).columnCount !== 'auto';
                    if (isHoriz) {
                        var totalPages = Math.max(1, Math.ceil(sv.scrollWidth / window.innerWidth));
                        var targetPage = Math.round(\(fraction) * (totalPages - 1));
                        if (window.goToInksyncPage) {
                            window.goToInksyncPage(targetPage, false);
                        } else {
                            window.scrollTo({ left: targetPage * window.innerWidth, behavior: 'instant' });
                        }
                    } else {
                        window.scrollTo({ top: sv.scrollHeight * \(fraction), behavior: 'instant' });
                    }
                    // Report the fraction back to initialise the Swift state correctly
                    window.webkit.messageHandlers.scrollFraction.postMessage(\(fraction));
                }, 150);
                """
                webView.evaluateJavaScript(restoreJS)
            }
        }

        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            if gesture.state == .began {
                initialPinchFontSize = parent.prefs.fontSize
            } else if gesture.state == .changed {
                let newSize = initialPinchFontSize * Double(gesture.scale)
                let roundedSize = round(max(12.0, min(80.0, newSize)))
                if parent.prefs.fontSize != roundedSize {
                    parent.prefs.fontSize = roundedSize
                    if let bookID = parent.pdfID?.uuidString, parent.prefs.isTypographyLockedForBook(bookID) {
                        parent.prefs.lockTypographyForBook(bookID)
                    }
                }
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            return true
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            return nil
        }

        /// Recover from Jetsam Out-Of-Memory (OOM) WebKit process crashes.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            Logger.shared.log("WebKit process terminated (OOM Jetsam crash). Reloading EPUB chapter.", category: "EBookWebReader", type: .error)
            webView.reload()
        }
    }
} // end EBookWebReader

// MARK: - Safe array subscript
extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
