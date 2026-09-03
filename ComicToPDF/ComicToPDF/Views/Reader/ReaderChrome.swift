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

    // Actions
    var onBack: () -> Void
    var onBookmark: () -> Void
    var onBookmarkActive: Bool = false
    var onSettingsToggle: () -> Void
    var onTOCToggle: (() -> Void)? = nil
    var onAnnotationsToggle: (() -> Void)? = nil
    var onCharacterMapToggle: (() -> Void)? = nil
    var onSearchToggle: (() -> Void)? = nil
    var isDialogueLensEnabled: Bool = false
    var onDialogueLensToggle: (() -> Void)? = nil

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
    var isMarkupActive: Bool = false
    var onCropToggle: (() -> Void)? = nil
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

    // Phase 3: Live Reading Room
    var isInRoom: Bool = false
    var roomPeerCount: Int = 0
    var onRoomToggle: (() -> Void)? = nil

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
        onCharacterMapToggle: (() -> Void)? = nil,
        onSearchToggle: (() -> Void)? = nil,
        isDialogueLensEnabled: Bool = false,
        onDialogueLensToggle: (() -> Void)? = nil,
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
        isMarkupActive: Bool = false,
        onCropToggle: (() -> Void)? = nil,
        onManualCropToggle: (() -> Void)? = nil,
        onReflowToggle: (() -> Void)? = nil,
        onMarkupToggle: (() -> Void)? = nil,
        isEnhanced: Bool = false,
        onEnhanceToggle: (() -> Void)? = nil,
        isSettingsActive: Bool = false,
        currentModeLabel: String? = nil,
        ambientColor: Color = .clear,
        isInRoom: Bool = false,
        roomPeerCount: Int = 0,
        onRoomToggle: (() -> Void)? = nil,
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
        self.onCharacterMapToggle = onCharacterMapToggle
        self.onSearchToggle = onSearchToggle
        self.isDialogueLensEnabled = isDialogueLensEnabled
        self.onDialogueLensToggle = onDialogueLensToggle
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
        self.isMarkupActive = isMarkupActive
        self.onCropToggle = onCropToggle
        self.onManualCropToggle = onManualCropToggle
        self.onReflowToggle = onReflowToggle
        self.onMarkupToggle = onMarkupToggle
        self.isEnhanced = isEnhanced
        self.onEnhanceToggle = onEnhanceToggle
        self.isSettingsActive = isSettingsActive
        self.currentModeLabel = currentModeLabel
        self.ambientColor = ambientColor
        self.isInRoom = isInRoom
        self.roomPeerCount = roomPeerCount
        self.onRoomToggle = onRoomToggle
        self.sessionStartTime = sessionStartTime
        self.onSwipeDown = onSwipeDown
    }

    // MARK: - Body

    var body: some View {
        VStack {
            topBar
                .offset(y: isVisible ? 0 : -12)
                // Phase 4A: swipe downward on the top bar to dismiss the reader
                .gesture(
                    DragGesture(minimumDistance: 20)
                        .onEnded { val in
                            if val.translation.height > 80 {
                                HapticEngine.light()
                                onSwipeDown?()
                            }
                        }
                )

            Spacer()

            bottomCard
                .offset(y: isVisible ? 0 : 16)
        }
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(isVisible)
        .animation(.spring(response: 0.42, dampingFraction: 0.88), value: isVisible)
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: 0) {
            // ── Back button ────────────────────────────────────────────────────
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.primary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }

            // ── Divider ────────────────────────────────────────────────────────
            chromeDivider

            if let startTime = sessionStartTime {
                SessionTimerView(startTime: startTime)
                
                chromeDivider
            }

            // ── Title ──────────────────────────────────────────────────────────
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 8)

            // ── Divider ────────────────────────────────────────────────────────
            chromeDivider

            // ── Action cluster ─────────────────────────────────────────────────
            HStack(spacing: 0) {
                if hSizeClass == .compact {
                    // iPhone compact cluster: Search, Settings (Aa), and More Actions Menu (...)
                    if let onSearch = onSearchToggle {
                        chromeButton(
                            icon: "magnifyingglass",
                            label: "Search Book",
                            active: false,
                            activeColor: .white,
                            action: onSearch
                        )
                    }

                    chromeButton(
                        icon: isSettingsActive ? "slider.horizontal.3" : "textformat.size",
                        label: "Appearance & Layout",
                        active: isSettingsActive,
                        activeColor: .white,
                        badgeText: isSettingsActive ? currentModeLabel : nil,
                        action: onSettingsToggle
                    )

                    // Overflow Menu
                    Menu {
                        if let onRoomToggle {
                            Button(action: onRoomToggle) {
                                Label(
                                    isInRoom ? "Leave Reading Room (\(roomPeerCount))" : "Join Reading Room",
                                    systemImage: isInRoom ? "person.2.wave.2.fill" : "person.2.wave.2"
                                )
                            }
                        }

                        if let onEnhance = onEnhanceToggle {
                            Button(action: onEnhance) {
                                Label("AI Summary & Insights", systemImage: "wand.and.stars")
                            }
                        }

                        if let onDialogueLens = onDialogueLensToggle {
                            Button(action: onDialogueLens) {
                                Label(isDialogueLensEnabled ? "Disable Dialogue Lens" : "AI Dialogue Lens", systemImage: "sparkle.magnifyingglass")
                            }
                        }

                        if isPDF {
                            Divider()
                            if let onMarkup = onMarkupToggle {
                                Button(action: onMarkup) {
                                    Label(isMarkupActive ? "Exit Pencil Markup" : "Pencil & Inking Markup", systemImage: isMarkupActive ? "pencil.slash" : "pencil.tip.crop.circle")
                                }
                            }
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
                                    Label("Manual Visual Crop Editor...", systemImage: "viewfinder")
                                }
                            }
                        }

                        if let onCharacterMap = onCharacterMapToggle {
                            Divider()
                            Button(action: onCharacterMap) {
                                Label("Character Map & Deep Study", systemImage: "square.stack.3d.up.badge.a")
                            }
                        }
                    } label: {
                        chromeButton(
                            icon: "ellipsis.circle",
                            label: "More Actions",
                            active: false,
                            activeColor: .white,
                            action: {}
                        )
                    }
                } else {
                    // iPad Regular cluster (full row of quick tools)
                    if let onRoomToggle {
                        chromeButton(
                            icon: isInRoom ? "person.2.wave.2.fill" : "person.2.wave.2",
                            label: "Reading Room",
                            active: isInRoom,
                            activeColor: Color(hex: "#4ECDC4"),
                            badgeText: (isInRoom && roomPeerCount > 0) ? "\(roomPeerCount)" : nil,
                            action: onRoomToggle
                        )
                    }

                    if onEnhanceToggle != nil {
                        chromeButton(
                            icon: "wand.and.stars",
                            label: "AI Summary",
                            active: isEnhanced,
                            activeColor: .yellow,
                            action: { onEnhanceToggle?() }
                        )
                    }

                    if let onMarkup = onMarkupToggle {
                        chromeButton(
                            icon: isMarkupActive ? "pencil.tip.crop.circle.badge.plus.fill" : "pencil.tip.crop.circle",
                            label: "Pencil & Inking",
                            active: isMarkupActive,
                            activeColor: .yellow,
                            action: onMarkup
                        )
                    }

                    if isPDF {
                        Button {
                            Haptics.shared.playImpact(style: .light)
                            onReflowToggle?()
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: isReflowActive ? "doc.richtext" : "text.alignleft")
                                    .font(.system(size: 13, weight: .semibold))
                                Text(isReflowActive ? "Original PDF" : "Reflow Text")
                                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                            }
                            .foregroundColor(isReflowActive ? .inkGreen : Color.primary.opacity(0.85))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                isReflowActive
                                    ? Color.inkGreen.opacity(0.18)
                                    : Color.white.opacity(0.08),
                                in: Capsule()
                            )
                            .overlay(
                                Capsule()
                                    .stroke(isReflowActive ? Color.inkGreen.opacity(0.4) : Color.white.opacity(0.12), lineWidth: 0.5)
                            )
                        }
                        .help(isReflowActive ? "Return to Original PDF Layout" : "Toggle Text Reflow Mode")
                        .accessibilityLabel(isReflowActive ? "Return to Original PDF Layout" : "Toggle Text Reflow Mode")
                    }

                    if isPDF {
                        Menu {
                            Button(action: { onCropToggle?() }) {
                                Label(
                                    isAutoCropEnabled ? "Disable Auto-Crop" : "Smart Auto-Crop",
                                    systemImage: isAutoCropEnabled ? "crop.slash" : "sparkles"
                                )
                            }
                            
                            if let onManual = onManualCropToggle {
                                Button(action: onManual) {
                                    Label("Manual Visual Crop Editor...", systemImage: "viewfinder")
                                }
                            }
                        } label: {
                            chromeButton(
                                icon: "crop",
                                label: "Crop Margins",
                                active: isAutoCropEnabled,
                                activeColor: .white
                            ) {}
                        }
                    }

                    if let onDialogueLens = onDialogueLensToggle {
                        chromeButton(
                            icon: "sparkle.magnifyingglass",
                            label: "AI Dialogue Lens",
                            active: isDialogueLensEnabled,
                            activeColor: .purple,
                            action: onDialogueLens
                        )
                    }

                    if let onSearch = onSearchToggle {
                        chromeButton(
                            icon: "magnifyingglass",
                            label: "Search Book",
                            active: false,
                            activeColor: .white,
                            action: onSearch
                        )
                    }

                    chromeButton(
                        icon: isSettingsActive ? "slider.horizontal.3" : "ellipsis",
                        label: "Reader Settings",
                        active: isSettingsActive,
                        activeColor: .white,
                        badgeText: isSettingsActive ? currentModeLabel : nil,
                        action: onSettingsToggle
                    )
                }
            }
        }
        .frame(height: 48)
        .background(topBarBackground)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        .frame(maxWidth: hSizeClass == .regular ? 760 : .infinity)  // constrain on iPad
        .padding(.horizontal, hSizeClass == .regular ? 32 : 16)
        .padding(.top, 8)
    }

    // MARK: - Bottom Card

    private var bottomCard: some View {
        VStack(spacing: 0) {
            // ── Scrubber ───────────────────────────────────────────────────────
            if let custom = customScrubber {
                custom
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 10)
            } else {
                HStack(spacing: 10) {
                    Text("1")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))
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
                    .tint(Color.white)
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
                                                .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
                                        )
                                        .shadow(color: .black.opacity(0.5), radius: 14, y: 6)
                                        
                                        Text("Page \(pageNum)")
                                            .font(.system(size: 11, weight: .bold, design: .rounded))
                                            .foregroundColor(.primary)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 4)
                                            .background(.ultraThinMaterial, in: Capsule())
                                            .overlay(Capsule().stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
                                    }
                                    .position(
                                        x: 14 + (sliderGeo.size.width - 28) * CGFloat(currentProgress),
                                        y: thumbY
                                    )
                                    .transition(.scale(scale: 0.8).combined(with: .opacity))
                                } else {
                                    Text("Page \(pageNum)")
                                        .font(.system(size: 13, weight: .bold, design: .rounded))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(Color(white: 0.15).opacity(0.85), in: Capsule())
                                        .overlay(Capsule().stroke(Color.white.opacity(0.2), lineWidth: 0.5))
                                        .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
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
                        .foregroundColor(.secondary)
                        .frame(width: 20, alignment: .trailing)
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)
            }
            
            if !isScrubbing {
                Text("\(Int(currentProgress * 100))%")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundColor(.secondary)
                    .padding(.bottom, 8)
            } else {
                Text(" ") // Keeps layout stable
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .padding(.bottom, 8)
            }

            // ── Thin divider ───────────────────────────────────────────────────
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 0.5)
                .padding(.horizontal, 16)

            // ── Action row ─────────────────────────────────────────────────────
            HStack {
                // Left cluster
                HStack(spacing: 4) {
                    barButton(
                        icon: onBookmarkActive ? "bookmark.fill" : "bookmark",
                        label: "Bookmark Page",
                        tint: onBookmarkActive ? Color.yellow : Color.primary
                    ) {
                        Haptics.shared.playImpact(style: .light)
                        onBookmark()
                    }

                    if hasCopyAction {
                        barButton(
                            icon: "doc.on.doc",
                            label: "Copy Selection",
                            tint: .primary
                        ) {
                            Haptics.shared.playImpact(style: .light)
                            onCopyToggle?()
                        }
                    }
                }

                Spacer()

                // Page counter / Time Left — centred and prominent
                Button {
                    Haptics.shared.playImpact(style: .light)
                    onProgressModeToggle?()
                } label: {
                    VStack(spacing: 2) {
                        Text(pageText)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundColor(.primary)
                        if let tr = timeRemainingText {
                            Text(tr)
                                .font(.system(size: 9, weight: .medium, design: .rounded))
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.5)
                        .onEnded { _ in
                            Haptics.shared.playImpact(style: .medium)
                            onJumpToPage?()
                        }
                )

                Spacer()

                // Right cluster
                HStack(spacing: 4) {
                    if let onMarkup = onMarkupToggle {
                        barButton(
                            icon: isMarkupActive ? "pencil.tip.crop.circle.badge.plus.fill" : "pencil.tip.crop.circle",
                            label: "Pencil Markup",
                            tint: isMarkupActive ? Color.yellow : Color.primary
                        ) {
                            Haptics.shared.playImpact(style: .light)
                            onMarkup()
                        }
                    }
                    if let onTOC = onTOCToggle {
                        barButton(icon: "list.bullet", label: "Table of Contents", tint: .primary) {
                            Haptics.shared.playImpact(style: .light)
                            onTOC()
                        }
                    }
                    if let onAnnotations = onAnnotationsToggle {
                        barButton(icon: "pencil.and.outline", label: "Pencil & Annotations", tint: .primary) {
                            Haptics.shared.playImpact(style: .light)
                            onAnnotations()
                        }
                    }
                    if let onCharacterMap = onCharacterMapToggle {
                        barButton(icon: "square.stack.3d.up.badge.a", label: "Character Map & Study", tint: .primary) {
                            Haptics.shared.playImpact(style: .light)
                            onCharacterMap()
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(bottomCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.3), radius: 18, y: -4)
        .frame(maxWidth: hSizeClass == .regular ? 680 : .infinity)  // constrain on iPad
        .padding(.horizontal, hSizeClass == .regular ? 32 : 12)
        .padding(.bottom, 12)
    }

    // MARK: - Shared Backgrounds

    private var topBarBackground: some View {
        ZStack {
            Color.clear.background(.ultraThinMaterial)
            if ambientColor != .clear {
                ambientColor.opacity(0.10)
            }
        }
    }

    private var bottomCardBackground: some View {
        ZStack {
            // Base: system material
            Rectangle().fill(.ultraThinMaterial)
            // Ambient tint overlay (Panels-style page colour)
            if ambientColor != .clear {
                Rectangle().fill(ambientColor.opacity(0.08))
            }
        }
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
