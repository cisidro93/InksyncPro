import SwiftUI

// MARK: - ReaderChrome
//
// Redesigned after deep analysis of Panels, Comixology, Chunky, and Apple Books:
//
//  TOP BAR   — Single frosted-glass capsule bar. Back ← | Title | Actions →
//              Slides in from the top with spring physics.
//
//  BOTTOM BAR — Single frosted-glass card. Scrubber on top, action row below.
//               Slides up from the bottom with matching spring physics.
//
// Neither bar uses scattered floating circles. All controls live on one surface
// per bar, consistent with how Panels and Apple Books handle the chrome.

struct ReaderChrome: View {
    let title: String
    let pageText: String
    @Binding var isVisible: Bool
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @Environment(\.colorScheme) private var colorScheme

    // Actions
    var onBack: () -> Void
    var onBookmark: () -> Void
    var onBookmarkActive: Bool = false
    var onSettingsToggle: () -> Void
    var onTOCToggle: (() -> Void)? = nil
    var onAnnotationsToggle: (() -> Void)? = nil
    var onSearchToggle: (() -> Void)? = nil
    var isDialogueLensEnabled: Bool = false
    var onDialogueLensToggle: (() -> Void)? = nil
    var onReadAloudToggle: (() -> Void)? = nil

    // Scrubber
    @Binding var currentProgress: Double
    let totalPages: Int
    var customScrubber: AnyView? = nil
    var getPageThumbnail: ((Int) async -> UIImage?)? = nil
    
    // Progress Intelligence
    var timeRemainingText: String? = nil
    var onProgressModeToggle: (() -> Void)? = nil
    var onJumpToPage: (() -> Void)? = nil

    // Copy Text Action (replaces TTS)
    var hasCopyAction: Bool = false
    var onCopyToggle: (() -> Void)? = nil

    // PDF tools
    var isPDF: Bool = false
    var isReflowActive: Bool = false
    var isAutoCropEnabled: Bool = false
    var selectedCropMode: String = "none"
    var isMarkupActive: Bool = false
    var onCropToggle: (() -> Void)? = nil
    var onCropModeSelected: ((String) -> Void)? = nil
    var onManualCropToggle: (() -> Void)? = nil
    var onReflowToggle: (() -> Void)? = nil
    var onMarkupToggle: (() -> Void)? = nil

    // Enhancement
    var isEnhanced: Bool = false
    var onEnhanceToggle: (() -> Void)? = nil

    // Mode indicator
    var isSettingsActive: Bool = false
    var currentModeLabel: String? = nil

    // Ambient tint from current page (Panels-style)
    var ambientColor: Color = .clear
    
    // Active reading session start time
    var sessionStartTime: Date? = nil

    // Phase 4A: Swipe-down-to-dismiss
    var onSwipeDown: (() -> Void)? = nil

    // Scrubber interaction state
    @State private var isScrubbing: Bool = false

    init(
        title: String,
        pageText: String,
        isVisible: Binding<Bool>,
        onBack: @escaping () -> Void,
        onBookmark: @escaping () -> Void,
        onBookmarkActive: Bool = false,
        onSettingsToggle: @escaping () -> Void,
        onTOCToggle: (() -> Void)? = nil,
        onAnnotationsToggle: (() -> Void)? = nil,
        onSearchToggle: (() -> Void)? = nil,
        isDialogueLensEnabled: Bool = false,
        onDialogueLensToggle: (() -> Void)? = nil,
        onReadAloudToggle: (() -> Void)? = nil,
        currentProgress: Binding<Double>,
        totalPages: Int,
        customScrubber: AnyView? = nil,
        getPageThumbnail: ((Int) async -> UIImage?)? = nil,
        timeRemainingText: String? = nil,
        onProgressModeToggle: (() -> Void)? = nil,
        onJumpToPage: (() -> Void)? = nil,
        hasCopyAction: Bool = false,
        onCopyToggle: (() -> Void)? = nil,
        isPDF: Bool = false,
        isReflowActive: Bool = false,
        isAutoCropEnabled: Bool = false,
        selectedCropMode: String = "none",
        isMarkupActive: Bool = false,
        onCropToggle: (() -> Void)? = nil,
        onCropModeSelected: ((String) -> Void)? = nil,
        onManualCropToggle: (() -> Void)? = nil,
        onReflowToggle: (() -> Void)? = nil,
        onMarkupToggle: (() -> Void)? = nil,
        isEnhanced: Bool = false,
        onEnhanceToggle: (() -> Void)? = nil,
        isSettingsActive: Bool = false,
        currentModeLabel: String? = nil,
        ambientColor: Color = .clear,
        sessionStartTime: Date? = nil,
        onSwipeDown: (() -> Void)? = nil
    ) {
        self.title = title
        self.pageText = pageText
        self._isVisible = isVisible
        self.onBack = onBack
        self.onBookmark = onBookmark
        self.onBookmarkActive = onBookmarkActive
        self.onSettingsToggle = onSettingsToggle
        self.onTOCToggle = onTOCToggle
        self.onAnnotationsToggle = onAnnotationsToggle
        self.onSearchToggle = onSearchToggle
        self.isDialogueLensEnabled = isDialogueLensEnabled
        self.onDialogueLensToggle = onDialogueLensToggle
        self.onReadAloudToggle = onReadAloudToggle
        self._currentProgress = currentProgress
        self.totalPages = totalPages
        self.customScrubber = customScrubber
        self.getPageThumbnail = getPageThumbnail
        self.timeRemainingText = timeRemainingText
        self.onProgressModeToggle = onProgressModeToggle
        self.onJumpToPage = onJumpToPage
        self.hasCopyAction = hasCopyAction
        self.onCopyToggle = onCopyToggle
        self.isPDF = isPDF
        self.isReflowActive = isReflowActive
        self.isAutoCropEnabled = isAutoCropEnabled
        self.selectedCropMode = selectedCropMode
        self.isMarkupActive = isMarkupActive
        self.onCropToggle = onCropToggle
        self.onCropModeSelected = onCropModeSelected
        self.onManualCropToggle = onManualCropToggle
        self.onReflowToggle = onReflowToggle
        self.onMarkupToggle = onMarkupToggle
        self.isEnhanced = isEnhanced
        self.onEnhanceToggle = onEnhanceToggle
        self.isSettingsActive = isSettingsActive
        self.currentModeLabel = currentModeLabel
        self.ambientColor = ambientColor
        self.sessionStartTime = sessionStartTime
        self.onSwipeDown = onSwipeDown
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            if isVisible {
                VStack(spacing: 0) {
                    topBar
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .gesture(
                            DragGesture(minimumDistance: 20)
                                .onEnded { val in
                                    if val.translation.height > 80 {
                                        HapticEngine.light()
                                        onSwipeDown?()
                                    }
                                }
                        )

                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                isVisible = false
                            }
                        }

                    bottomBar
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                .ignoresSafeArea(edges: .vertical)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isVisible)
    }

    // MARK: - Top Bar (Clean EPUB-Standard Glass Gradient)

    private var topBar: some View {
        HStack(spacing: 10) {
            // ── Back button ────────────────────────────────────────────────────
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.inkText)
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().stroke(Color.inkBorderSubtle, lineWidth: 0.5))
            }
            .buttonStyle(.plain)

            // ── Title ──────────────────────────────────────────────────────────
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.inkText)
                .lineLimit(1)
                .truncationMode(.middle)
                .shadow(color: colorScheme == .dark ? .black.opacity(0.6) : .clear, radius: 3)

            Spacer()

            // ── Session Timer Badge ────────────────────────────────────────────
            if let startTime = sessionStartTime {
                SessionTimerView(startTime: startTime)
            }

            // ── Bookmark Button ────────────────────────────────────────────────
            Button(action: onBookmark) {
                Image(systemName: onBookmarkActive ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(onBookmarkActive ? Color.orange : Color.inkText)
                    .frame(width: 34, height: 34)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().stroke(Color.inkBorderSubtle, lineWidth: 0.5))
            }
            .buttonStyle(.plain)

            // ── Settings (aA) Button ───────────────────────────────────────────
            Button(action: onSettingsToggle) {
                Image(systemName: "textformat.size")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isSettingsActive ? Color.orange : Color.inkText)
                    .frame(width: 34, height: 34)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().stroke(Color.inkBorderSubtle, lineWidth: 0.5))
            }
            .buttonStyle(.plain)

            // ── More Actions Menu (...) ────────────────────────────────────────
            Menu {
                Section("Appearance") {
                    Button(action: onSettingsToggle) {
                        Label("Reader Settings", systemImage: "textformat.size")
                    }
                    if let onEnhance = onEnhanceToggle {
                        Button(action: onEnhance) {
                            Label("Color Filter & Enhance", systemImage: "slider.horizontal.3")
                        }
                    }
                    Menu {
                        ForEach(ComicPageFitMode.allCases) { mode in
                            Button {
                                EBookPreferences.shared.comicPageFitMode = mode
                            } label: {
                                if EBookPreferences.shared.comicPageFitMode == mode {
                                    Label(mode.title, systemImage: "checkmark")
                                } else {
                                    Label(mode.title, systemImage: mode.icon)
                                }
                            }
                        }
                    } label: {
                        Label("Screen Fit: \(EBookPreferences.shared.comicPageFitMode.title)", systemImage: EBookPreferences.shared.comicPageFitMode.icon)
                    }
                    if isPDF {
                        Button {
                            EBookPreferences.shared.isPDFSmartTiersActive.toggle()
                            HapticEngine.selection()
                        } label: {
                            Label(
                                EBookPreferences.shared.isPDFSmartTiersActive ? "Smart Tiers (Active)" : "Smart Tiers (Guided Flow)",
                                systemImage: EBookPreferences.shared.isPDFSmartTiersActive ? "checkmark.circle.fill" : "rectangle.split.3x1"
                            )
                        }
                        if EBookPreferences.shared.isPDFSmartTiersActive {
                            Button {
                                NotificationCenter.default.post(name: NSNotification.Name("PDFReader_OpenSmartTiersWorkspace"), object: nil)
                                HapticEngine.selection()
                            } label: {
                                Label("Adjust Smart Tiers & Flow", systemImage: "slider.horizontal.2.square")
                            }
                        }
                    } else {
                        Button {
                            NotificationCenter.default.post(name: NSNotification.Name("ComicReader_OpenPanelWorkspace"), object: nil)
                            HapticEngine.selection()
                        } label: {
                            Label("Adjust Smart Tiers & Flow", systemImage: "slider.horizontal.2.square")
                        }
                    }
                }
                Section("Navigate") {
                    if let onTOC = onTOCToggle {
                        Button(action: onTOC) {
                            Label("Table of Contents", systemImage: "list.bullet.rectangle")
                        }
                    }
                    if let onSearch = onSearchToggle {
                        Button(action: onSearch) {
                            Label("Search in Book", systemImage: "magnifyingglass")
                        }
                    }
                    if let onJump = onJumpToPage {
                        Button(action: onJump) {
                            Label("Page Thumbnails", systemImage: "square.grid.2x2")
                        }
                    }
                }
                Section("Tools") {
                    if let onAnnotations = onAnnotationsToggle {
                        Button(action: onAnnotations) {
                            Label("Study Notebook", systemImage: "note.text")
                        }
                    }
                    if let onMarkup = onMarkupToggle {
                        Button(action: onMarkup) {
                            Label(isMarkupActive ? "Exit Pencil Markup" : "Pencil Markup", systemImage: isMarkupActive ? "pencil.slash" : "pencil.tip.crop.circle")
                        }
                    }
                    if hasCopyAction, let onCopy = onCopyToggle {
                        Button(action: onCopy) {
                            Label("Copy Page Text", systemImage: "doc.on.doc")
                        }
                    }
                    if isPDF {
                        if let onReflow = onReflowToggle {
                            Button(action: onReflow) {
                                Label(isReflowActive ? "Original PDF Layout" : "Reflow Text", systemImage: "text.alignleft")
                            }
                        }
                        if let onCrop = onCropToggle {
                            Button(action: onCrop) {
                                Label(isAutoCropEnabled ? "Disable Auto-Crop" : "Smart Auto-Crop", systemImage: isAutoCropEnabled ? "crop.slash" : "sparkles")
                            }
                        }
                        if let onManual = onManualCropToggle {
                            Button(action: onManual) {
                                Label("Manual Visual Crop Editor\u{2026}", systemImage: "viewfinder")
                            }
                        }
                    }
                    if let onDialogueLens = onDialogueLensToggle {
                        Button(action: onDialogueLens) {
                            Label(isDialogueLensEnabled ? "Disable Dialogue Lens" : "AI Dialogue Lens", systemImage: "sparkle.magnifyingglass")
                        }
                    }
                    if let onReadAloud = onReadAloudToggle {
                        Button(action: onReadAloud) {
                            Label("Read Aloud (Speech)", systemImage: "speaker.wave.3")
                        }
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
        .padding(.top, 50)
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

    // MARK: - Bottom Bar (Clean EPUB-Standard Glass Gradient)

    private var bottomBar: some View {
        VStack(spacing: 0) {
            // ── Scrubber ───────────────────────────────────────────────────────
            if let custom = customScrubber {
                custom
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                    .padding(.bottom, 4)
            } else if totalPages > 1 {
                HStack(spacing: 10) {
                    Text("1")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.inkSecondary)
                        .frame(width: 20, alignment: .leading)

                    Slider(
                        value: Binding(
                            get: { currentProgress },
                            set: { newValue in
                                if abs(newValue - currentProgress) > (1.0 / Double(max(totalPages, 1))) {
                                    Haptics.shared.playImpact(style: .light)
                                }
                                currentProgress = newValue
                            }
                        ),
                        in: 0...1,
                        onEditingChanged: { editing in
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                isScrubbing = editing
                            }
                        }
                    )
                    .tint(Color(hex: "#B39DDB"))
                    .overlay(
                        GeometryReader { sliderGeo in
                            if isScrubbing {
                                let pageNum = max(1, Int(round(currentProgress * Double(max(totalPages - 1, 1))))) + 1
                                if getPageThumbnail != nil {
                                    let isPhone = hSizeClass == .compact
                                    let thumbW: CGFloat = isPhone ? 58 : 72
                                    let thumbH: CGFloat = isPhone ? 84 : 104
                                    let thumbY: CGFloat = isPhone ? -58 : -70
                                    VStack(spacing: 6) {
                                        ZStack {
                                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                .fill(.ultraThinMaterial)
                                                .frame(width: thumbW, height: thumbH)
                                            
                                            if let getThumb = getPageThumbnail {
                                                FloatingThumbnailView(index: pageNum - 1, getPageThumbnail: getThumb)
                                            }
                                        }
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                .stroke(Color.inkBorderSubtle, lineWidth: 0.5)
                                        )
                                        .shadow(color: .black.opacity(colorScheme == .dark ? 0.5 : 0.15), radius: 14, y: 6)
                                        
                                        Text("Page \(pageNum)")
                                            .font(.system(size: 11, weight: .bold, design: .rounded))
                                            .foregroundColor(Color.inkText)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 4)
                                            .background(.ultraThinMaterial, in: Capsule())
                                            .overlay(Capsule().stroke(Color.inkBorderSubtle, lineWidth: 0.5))
                                    }
                                    .position(
                                        x: 14 + (sliderGeo.size.width - 28) * CGFloat(currentProgress),
                                        y: thumbY
                                    )
                                    .transition(.scale(scale: 0.8).combined(with: .opacity))
                                } else {
                                    Text("Page \(pageNum)")
                                        .font(.system(size: 13, weight: .bold, design: .rounded))
                                        .foregroundColor(Color.inkText)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(Color.inkSurfaceRaised.opacity(0.95), in: Capsule())
                                        .overlay(Capsule().stroke(Color.inkBorderSubtle, lineWidth: 0.5))
                                        .shadow(color: .black.opacity(colorScheme == .dark ? 0.4 : 0.12), radius: 8, y: 4)
                                        .position(
                                            x: 14 + (sliderGeo.size.width - 28) * CGFloat(currentProgress),
                                            y: -24
                                        )
                                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                                }
                            }
                        }
                    )

                    Text("\(totalPages)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.inkSecondary)
                        .frame(width: 20, alignment: .trailing)
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 4)
            }

            Rectangle()
                .fill(Color.inkBorderSubtle)
                .frame(height: 0.5)
                .padding(.horizontal, 16)

            // ── Navigation row ─────────────────────────────────────────────────
            HStack(spacing: 24) {
                Button {
                    let step = 1.0 / Double(max(totalPages - 1, 1))
                    currentProgress = max(0.0, currentProgress - step)
                    HapticEngine.light()
                } label: {
                    Image(systemName: "chevron.left.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(currentProgress <= 0.001 ? Color.inkSecondary.opacity(0.25) : Color.inkText)
                }
                .buttonStyle(.plain)
                .disabled(currentProgress <= 0.001)

                Button {
                    HapticEngine.selection()
                    onProgressModeToggle?()
                } label: {
                    VStack(spacing: 2) {
                        Text(pageText)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.inkText)
                        if let tr = timeRemainingText, !tr.isEmpty {
                            Text(tr)
                                .font(.system(size: 10, weight: .regular, design: .rounded))
                                .foregroundStyle(colorScheme == .dark ? Color(hex: "#B39DDB").opacity(0.85) : Color.inkViolet)
                        }
                    }
                    .frame(minWidth: 100)
                }
                .buttonStyle(.plain)
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.5)
                        .onEnded { _ in
                            HapticEngine.medium()
                            onJumpToPage?()
                        }
                )

                Button {
                    let step = 1.0 / Double(max(totalPages - 1, 1))
                    currentProgress = min(1.0, currentProgress + step)
                    HapticEngine.light()
                } label: {
                    Image(systemName: "chevron.right.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(currentProgress >= 0.999 ? Color.inkSecondary.opacity(0.25) : Color.inkText)
                }
                .buttonStyle(.plain)
                .disabled(currentProgress >= 0.999)
            }
            .padding(.top, 14)
            .padding(.bottom, 28)
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

    // MARK: - Reusable Components

    private var chromeDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: 0.5, height: 22)
    }

    /// Icon button for the top bar action cluster
    @ViewBuilder
    private func chromeButton(
        icon: String,
        label: String = "",
        active: Bool,
        activeColor: Color,
        badgeText: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            Haptics.shared.playImpact(style: .light)
            action()
        } label: {
            VStack(spacing: 1) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(active ? activeColor : Color.primary.opacity(0.85))
                if let badge = badgeText {
                    Text(badge)
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(activeColor)
                        .lineLimit(1)
                }
            }
            .frame(width: 44, height: 44)
            .background(active ? activeColor.opacity(0.15) : Color.clear)
            .contentShape(Rectangle())
        }
        .help(label.isEmpty ? "Action" : label)
        .accessibilityLabel(label.isEmpty ? "Action" : label)
    }

    /// Icon button for the bottom action row
    @ViewBuilder
    private func barButton(icon: String, label: String = "", tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(tint)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .help(label.isEmpty ? "Action" : label)
        .accessibilityLabel(label.isEmpty ? "Action" : label)
    }
}

struct FloatingThumbnailView: View {
    let index: Int
    let getPageThumbnail: (Int) async -> UIImage?
    @State private var image: UIImage? = nil
    
    var body: some View {
        ZStack {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 72, height: 104)
                    .cornerRadius(8)
            } else {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white.opacity(0.5)))
                    .frame(width: 72, height: 104)
            }
        }
        .task(id: index) {
            image = nil
            if let img = await getPageThumbnail(index) {
                image = img
            }
        }
    }
}

// MARK: - Isolated Timer Component to Prevent Redraw Pollution
struct SessionTimerView: View {
    let startTime: Date
    @State private var elapsed: TimeInterval = 0
    let timer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "timer")
                .font(.system(size: 11, weight: .bold))
            Text(formattedTime)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
        }
        .foregroundColor(.orange)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.orange.opacity(0.12), in: Capsule())
        .padding(.leading, 8)
        .onReceive(timer) { _ in
            elapsed = Date().timeIntervalSince(startTime)
        }
        .onAppear {
            elapsed = Date().timeIntervalSince(startTime)
        }
    }
    
    private var formattedTime: String {
        let secondsTotal = Int(elapsed)
        let hours = secondsTotal / 3600
        let minutes = (secondsTotal % 3600) / 60
        let seconds = secondsTotal % 60
        if hours > 0 {
            return String(format: "%dh %dm", hours, minutes)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }
}
