import SwiftUI

// MARK: - EBookSettingsPanel
// Three-tab premium sheet: Themes · Typography · Layout
// Matches the SettingsSection/SettingsToggleRow visual system used in ReaderSettingsSheet.

struct EBookSettingsPanel: View {
    @ObservedObject var prefs = EBookPreferences.shared
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.dismiss) private var dismiss

    // Optional book ID for per-book locking
    var bookID: String? = nil
    var isPDF: Bool = false

    @State private var activeTab: PanelTab = .themes
    @State private var showCustomBgPicker = false
    @State private var showCustomTextPicker = false

    enum PanelTab: String, CaseIterable {
        case themes     = "Themes"
        case typography = "Typography"
        case layout     = "Layout"

        var icon: String {
            switch self {
            case .themes:     return "paintpalette"
            case .typography: return "textformat"
            case .layout:     return "rectangle.split.2x1"
            }
        }
    }

    private var visibleTabs: [PanelTab] {
        PanelTab.allCases
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // ── Live Preview Strip ────────────────────────────────────────
                if !isPDF || prefs.pdfReflowMode {
                    livePreviewStrip
                }

                // ── Tab Strip ────────────────────────────────────────────────
                tabStrip

                // ── Tab Content ──────────────────────────────────────────────
                ScrollView {
                    VStack(spacing: 20) {
                        switch activeTab {
                        case .themes:     themesTab
                        case .typography: typographyTab
                        case .layout:     layoutTab
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 20)
                    .padding(.bottom, 40)
                }
            }
            .background(Color.inkBackground.ignoresSafeArea())
            .navigationTitle("Reader Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.orange)
                }
            }
        }
    }

    // MARK: - Live Preview Strip
    private var livePreviewStrip: some View {
        let theme = prefs.activeTheme
        let bg    = theme.background
        let fg    = theme.text

        return ZStack {
            bg
            VStack(spacing: 4) {
                Text("The quick brown fox jumps over the lazy dog. Reading should feel effortless.")
                    .font(Font(UIFont(name: previewFontName, size: prefs.fontSize * 0.72) ?? .systemFont(ofSize: prefs.fontSize * 0.72)))
                    .foregroundColor(fg)
                    .lineSpacing((prefs.lineHeight - 1.0) * prefs.fontSize * 0.72)
                    .multilineTextAlignment(prefs.textAlign == "justify" ? .leading : .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(3)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 90)
        .overlay(
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 0.5),
            alignment: .bottom
        )
    }

    private var previewFontName: String {
        // Strip CSS fallbacks to get just the primary font name
        let raw = prefs.fontFamily
        let first = raw.components(separatedBy: ",").first ?? raw
        return first.trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
    }

    // MARK: - Tab Strip
    private var tabStrip: some View {
        HStack(spacing: 0) {
            ForEach(visibleTabs, id: \.self) { tab in
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                        activeTab = tab
                    }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 14, weight: activeTab == tab ? .semibold : .regular))
                        Text(tab.rawValue)
                            .font(.system(size: 11, weight: activeTab == tab ? .semibold : .regular))
                    }
                    .foregroundStyle(activeTab == tab ? Color.orange : Color.inkTextSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        activeTab == tab
                            ? Color.orange.opacity(0.08)
                            : Color.clear
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .background(Color.inkSurface)
        .overlay(Rectangle().fill(Color.white.opacity(0.07)).frame(height: 0.5), alignment: .bottom)
    }

    // MARK: - Themes Tab
    private var themesTab: some View {
        VStack(spacing: 20) {
            // Built-in themes
            ReaderSettingsSection(title: "Reading Themes", icon: "paintpalette") {
                VStack(spacing: 12) {
                    // Row 1
                    HStack(spacing: 10) {
                        ForEach([EBookTheme.paper, .parchment, .sepia], id: \.self) { theme in
                            themeCard(theme)
                        }
                    }
                    // Row 2
                    HStack(spacing: 10) {
                        ForEach([EBookTheme.slate, .night, .oled], id: \.self) { theme in
                            themeCard(theme)
                        }
                    }
                    // Row 3
                    HStack(spacing: 10) {
                        themeCard(.custom)
                        Spacer()
                        Spacer()
                    }
                }
                .padding(.vertical, 8)
            }

            // Custom colours (only shown when custom is selected)
            if prefs.themeRaw == EBookTheme.custom.rawValue {
                ReaderSettingsSection(title: "Custom Colours", icon: "eyedropper") {
                    Button {
                        showCustomBgPicker = true
                    } label: {
                        HStack(spacing: 12) {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color(hex: prefs.customThemeBg))
                                .frame(width: 28, height: 28)
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.2), lineWidth: 1))
                            Text("Page Background")
                                .font(.system(size: 15))
                                .foregroundStyle(Color.inkTextPrimary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.inkTextTertiary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)
                    .sheet(isPresented: $showCustomBgPicker) {
                        ColorPickerSheet(hex: $prefs.customThemeBg, title: "Page Background")
                    }

                    Divider().padding(.leading, 44)

                    Button {
                        showCustomTextPicker = true
                    } label: {
                        HStack(spacing: 12) {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color(hex: prefs.customThemeText))
                                .frame(width: 28, height: 28)
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.2), lineWidth: 1))
                            Text("Text Colour")
                                .font(.system(size: 15))
                                .foregroundStyle(Color.inkTextPrimary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.inkTextTertiary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)
                    .sheet(isPresented: $showCustomTextPicker) {
                        ColorPickerSheet(hex: $prefs.customThemeText, title: "Text Colour")
                    }
                }
            }

            // Eye Comfort Filters
            ReaderSettingsSection(title: "Eye Comfort Filters", icon: "eye.fill") {
                HStack(spacing: 10) {
                    ForEach(ReadingFilter.allCases) { filter in
                        Button {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                                prefs.readingFilter = filter
                            }
                            HapticEngine.light()
                        } label: {
                            VStack(spacing: 6) {
                                Image(systemName: filter == .none ? "eye.slash" : (filter == .midnight ? "moon.stars" : (filter == .amber ? "sun.max" : "cup.and.saucer")))
                                    .font(.system(size: 16, weight: .medium))
                                Text(filter.displayName)
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundStyle(prefs.readingFilter == filter ? Color.orange : Color.inkTextSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(prefs.readingFilter == filter ? Color.orange.opacity(0.12) : Color.inkSurfaceRaised)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(prefs.readingFilter == filter ? Color.orange.opacity(0.5) : Color.clear, lineWidth: 1.5)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }

            // Auto-Theme Scheduling
            ReaderSettingsSection(title: "Auto-Theme Schedule", icon: "clock.arrow.2.circlepath") {
                ReaderSettingsToggleRow(
                    label: "Day / Night Auto-Switching",
                    icon: "moon.phase.quarter.moon",
                    isOn: $prefs.isAutoThemeEnabled
                )

                if prefs.isAutoThemeEnabled {
                    Divider().padding(.leading, 44)

                    // Day Theme Picker
                    HStack(spacing: 12) {
                        Image(systemName: "sun.max.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(Color.orange)
                            .frame(width: 28)
                        Text("Daytime Theme")
                            .font(.system(size: 15))
                            .foregroundStyle(Color.inkTextPrimary)
                        Spacer()
                        Picker("Day Theme", selection: $prefs.dayThemeRaw) {
                            Text("Paper").tag(EBookTheme.paper.rawValue)
                            Text("Parchment").tag(EBookTheme.parchment.rawValue)
                            Text("Sepia").tag(EBookTheme.sepia.rawValue)
                        }
                        .pickerStyle(.menu)
                        .tint(.orange)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)

                    Divider().padding(.leading, 44)

                    // Night Theme Picker
                    HStack(spacing: 12) {
                        Image(systemName: "moon.stars.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(Color.purple)
                            .frame(width: 28)
                        Text("Nighttime Theme")
                            .font(.system(size: 15))
                            .foregroundStyle(Color.inkTextPrimary)
                        Spacer()
                        Picker("Night Theme", selection: $prefs.nightThemeRaw) {
                            Text("Night").tag(EBookTheme.night.rawValue)
                            Text("OLED").tag(EBookTheme.oled.rawValue)
                            Text("Slate").tag(EBookTheme.slate.rawValue)
                        }
                        .pickerStyle(.menu)
                        .tint(.orange)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            }

            // Per-book memory
            if let bookID {
                ReaderSettingsSection(title: "This Book", icon: "book.closed") {
                    ReaderSettingsToggleRow(
                        label: "Remember Theme for This Book",
                        icon: "bookmark.fill",
                        isOn: Binding(
                            get: { prefs.bookThemes[bookID] != nil },
                            set: { lock in
                                var themes = prefs.bookThemes
                                if lock { themes[bookID] = prefs.themeRaw } else { themes.removeValue(forKey: bookID) }
                                prefs.bookThemes = themes
                            }
                        )
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func themeCard(_ theme: EBookTheme) -> some View {
        let isSelected = prefs.themeRaw == theme.rawValue
        Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                prefs.themeRaw = theme.rawValue
            }
            HapticEngine.light()
        } label: {
            VStack(spacing: 6) {
                // Mini page preview
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(theme == .custom ? Color(hex: prefs.customThemeBg) : theme.background)
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(0..<3, id: \.self) { i in
                            Capsule()
                                .fill((theme == .custom ? Color(hex: prefs.customThemeText) : theme.text).opacity(i == 2 ? 0.4 : 0.75))
                                .frame(height: 3)
                                .frame(maxWidth: i == 2 ? .infinity * 0.6 : .infinity)
                        }
                    }
                    .padding(8)
                }
                .frame(height: 56)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(isSelected ? Color.orange : Color.white.opacity(0.1), lineWidth: isSelected ? 2 : 0.5)
                )

                Text(theme.displayName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.orange : Color.inkTextSecondary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: isSelected)
    }

    // MARK: - Typography Tab
    private var typographyTab: some View {
        VStack(spacing: 20) {
            if isPDF && !prefs.pdfReflowMode {
                HStack(spacing: 12) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(Color.orange)
                    Text("Typography settings apply to Reflow Text mode. Switch to Reflow mode in Layout or Top Bar to customize fonts.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.85))
                }
                .padding(12)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            }

            // Font Selector
            ReaderSettingsSection(title: "Typeface", icon: "textformat") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(EBookFontFamily.allCases) { family in
                            fontChip(family)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }

            // Size & Line Height
            ReaderSettingsSection(title: "Size & Spacing", icon: "textformat.size") {
                // Font Size
                HStack(spacing: 12) {
                    Image(systemName: "textformat.size.smaller")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.inkTextSecondary)
                        .frame(width: 28)
                    Text("Size")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.inkTextPrimary)
                    Spacer()
                    HStack(spacing: 16) {
                        Button { prefs.fontSize = max(12, prefs.fontSize - 1) } label: {
                            Image(systemName: "minus.circle.fill")
                                .font(.system(size: 24))
                                .foregroundStyle(Color.inkTextSecondary)
                        }
                        Text("\(Int(prefs.fontSize))pt")
                            .font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
                            .foregroundStyle(Color.inkTextPrimary)
                            .frame(width: 44, alignment: .center)
                        Button { prefs.fontSize = min(80, prefs.fontSize + 1) } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 24))
                                .foregroundStyle(Color.orange)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                Divider().padding(.leading, 44)

                // Line Height
                SliderRow(
                    label: "Line Height",
                    icon: "line.3.horizontal",
                    value: $prefs.lineHeight,
                    range: 1.0...2.5,
                    step: 0.05,
                    displayFormat: { String(format: "%.2f×", $0) }
                )

                Divider().padding(.leading, 44)

                // Letter Spacing
                SliderRow(
                    label: "Letter Spacing",
                    icon: "character.magnify",
                    value: $prefs.letterSpacing,
                    range: -0.05...0.15,
                    step: 0.005,
                    displayFormat: { String(format: "%+.0f%%", $0 * 100) }
                )

                Divider().padding(.leading, 44)

                // Word Spacing
                SliderRow(
                    label: "Word Spacing",
                    icon: "space",
                    value: $prefs.wordSpacing,
                    range: -0.05...0.30,
                    step: 0.01,
                    displayFormat: { String(format: "%+.0f%%", $0 * 100) }
                )
            }

            // Alignment & Hyphenation
            ReaderSettingsSection(title: "Alignment", icon: "text.alignleft") {
                HStack(spacing: 10) {
                    ForEach(EBookTextAlign.allCases) { align in
                        Button {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                                prefs.textAlign = align.rawValue
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: align.icon)
                                    .font(.system(size: 14, weight: .medium))
                                Text(align.displayName)
                                    .font(.system(size: 13, weight: .medium))
                            }
                            .foregroundStyle(prefs.textAlign == align.rawValue ? Color.orange : Color.inkTextSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(prefs.textAlign == align.rawValue ? Color.orange.opacity(0.12) : Color.inkSurfaceRaised)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(prefs.textAlign == align.rawValue ? Color.orange.opacity(0.5) : Color.clear, lineWidth: 1.5)
                            )
                        }
                        .buttonStyle(.plain)
                        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: prefs.textAlign)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                Divider().padding(.leading, 44)

                ReaderSettingsToggleRow(
                    label: "Hyphenation",
                    icon: "arrow.left.and.line.vertical.and.arrow.right",
                    isOn: $prefs.hyphenation
                )

                Divider().padding(.leading, 44)

                ReaderSettingsToggleRow(
                    label: "Bold Text",
                    icon: "bold",
                    isOn: $prefs.isBoldTextEnabled
                )
            }

            // Per-book typography lock
            if let bookID {
                let isLocked = prefs.isTypographyLockedForBook(bookID)
                ReaderSettingsSection(title: "This Book", icon: isLocked ? "lock.fill" : "lock.open") {
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            if isLocked {
                                prefs.unlockTypographyForBook(bookID)
                            } else {
                                prefs.lockTypographyForBook(bookID)
                            }
                        }
                        HapticEngine.success()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: isLocked ? "lock.fill" : "lock.open")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(isLocked ? Color.orange : Color.inkTextSecondary)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(isLocked ? "Typography Locked for This Book" : "Lock Typography for This Book")
                                    .font(.system(size: 15))
                                    .foregroundStyle(Color.inkTextPrimary)
                                Text(isLocked ? "Tap to unlock and use global settings" : "Save current settings for this book only")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.inkTextSecondary)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private func fontChip(_ family: EBookFontFamily) -> some View {
        let isSelected = prefs.fontFamily == family.rawValue
        Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                prefs.fontFamily = family.rawValue
            }
            HapticEngine.light()
        } label: {
            Text(family.displayName)
                .font(family.previewFont)
                .foregroundStyle(isSelected ? Color.orange : Color.inkTextPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isSelected ? Color.orange.opacity(0.12) : Color.inkSurface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(isSelected ? Color.orange.opacity(0.6) : Color.white.opacity(0.08), lineWidth: 1.5)
                )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func panelCropModeButton(mode: String, title: String, icon: String) -> some View {
        let isSelected: Bool = (prefs.defaultCropModeRaw == mode)
        Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                prefs.defaultCropModeRaw = mode
                let enabled = (mode != "none")
                prefs.isSmartCropEnabled = enabled
            }
            HapticEngine.light()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(isSelected ? Color.orange : Color.inkTextSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.orange.opacity(0.12) : Color.inkSurfaceRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isSelected ? Color.orange.opacity(0.5) : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Layout Tab
    private var layoutTab: some View {
        VStack(spacing: 20) {
            if isPDF {
                // PDF Reading & Reflow Mode (Prominent Top Section)
                ReaderSettingsSection(title: "PDF Display & Reflow", icon: "doc.plaintext") {
                    ReaderSettingsToggleRow(
                        label: "Pro Text Reflow Mode",
                        icon: "doc.text.magnifyingglass",
                        isOn: $prefs.pdfReflowMode
                    )
                }

                // PDF Margins & Crop Control
                ReaderSettingsSection(title: "PDF Page Margins & Cropping", icon: "crop") {
                    // Mode Selector (Smart Auto / Manual Custom / Full Page)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Crop Mode")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.inkTextSecondary)
                        
                        HStack(spacing: 8) {
                            panelCropModeButton(mode: "smartAuto", title: "Smart Auto", icon: "sparkles")
                            panelCropModeButton(mode: "custom",    title: "Manual",     icon: "slider.horizontal.3")
                            panelCropModeButton(mode: "none",      title: "Full Page",  icon: "arrow.up.left.and.down.right")
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)

                    Divider().padding(.leading, 44)

                    if prefs.defaultCropModeRaw == "custom" {
                        // Precision Manual Trim Sliders
                        SliderRow(
                            label: "Top Trim",
                            icon: "arrow.up",
                            value: $prefs.defaultCropTop,
                            range: 0.0...0.20,
                            step: 0.005,
                            displayFormat: { String(format: "%.1f%%", $0 * 100) }
                        )
                        Divider().padding(.leading, 44)
                        SliderRow(
                            label: "Bottom Trim",
                            icon: "arrow.down",
                            value: $prefs.defaultCropBottom,
                            range: 0.0...0.20,
                            step: 0.005,
                            displayFormat: { String(format: "%.1f%%", $0 * 100) }
                        )
                        Divider().padding(.leading, 44)
                        SliderRow(
                            label: "Left Trim",
                            icon: "arrow.left",
                            value: $prefs.defaultCropLeft,
                            range: 0.0...0.20,
                            step: 0.005,
                            displayFormat: { String(format: "%.1f%%", $0 * 100) }
                        )
                        Divider().padding(.leading, 44)
                        SliderRow(
                            label: "Right Trim",
                            icon: "arrow.right",
                            value: $prefs.defaultCropRight,
                            range: 0.0...0.20,
                            step: 0.005,
                            displayFormat: { String(format: "%.1f%%", $0 * 100) }
                        )
                        Divider().padding(.leading, 44)
                    } else if prefs.defaultCropModeRaw == "smartAuto" {
                        SliderRow(
                            label: "Auto-Crop Sensitivity",
                            icon: "crop.square",
                            value: $prefs.autoCropSensitivity,
                            range: 0.05...0.25,
                            step: 0.01,
                            displayFormat: { String(format: "%.0f%%", $0 * 100) }
                        )
                        Divider().padding(.leading, 44)
                    }

                    // Interactive Visual Crop Editor Button
                    Button {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            NotificationCenter.default.post(name: .openManualCropEditor, object: nil)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "viewfinder")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Color.orange)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Visual Crop Editor...")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(Color.inkTextPrimary)
                                Text("Interactive live boundary trimming with visual guides")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.inkTextSecondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.inkTextSecondary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                }

                // PDF Spreads & Orientation
                ReaderSettingsSection(title: "PDF Spreads", icon: "book.pages") {
                    ReaderSettingsToggleRow(
                        label: "Dual-Page Spreads",
                        icon: "rectangle.split.2x1",
                        isOn: $prefs.pdfDualPage
                    )
                    Divider().padding(.leading, 44)
                    ReaderSettingsToggleRow(
                        label: "Auto Dual-Page in Landscape",
                        icon: "rectangle.landscape.rotate",
                        isOn: $prefs.autoLandscapeDualPage
                    )
                }
            } else {
                // EPUB Page Layout
                ReaderSettingsSection(title: "Page Layout", icon: "doc.text") {
                    SliderRow(
                        label: "Page Margins",
                        icon: "arrow.left.and.right",
                        value: $prefs.textMargin,
                        range: 0...60,
                        step: 4,
                        displayFormat: { "\(Int($0))pt" }
                    )
                    Divider().padding(.leading, 44)
                    SliderRow(
                        label: "Paragraph Spacing",
                        icon: "arrow.up.and.down",
                        value: $prefs.paragraphSpacing,
                        range: 0...2.0,
                        step: 0.1,
                        displayFormat: { String(format: "%.1fem", $0) }
                    )
                    Divider().padding(.leading, 44)
                    SliderRow(
                        label: "First-Line Indent",
                        icon: "increase.indent",
                        value: $prefs.paragraphIndent,
                        range: 0...3.0,
                        step: 0.2,
                        displayFormat: { String(format: "%.1fem", $0) }
                    )
                }
            }

            if !isPDF {
                // Columns
                ReaderSettingsSection(title: "Columns", icon: "columns") {
                    HStack(spacing: 10) {
                        ForEach([0, 1, 2], id: \.self) { cols in
                            Button {
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                                    prefs.columnCount = cols
                                }
                            } label: {
                                VStack(spacing: 6) {
                                    Image(systemName: cols == 0 ? "wand.and.stars" : (cols == 1 ? "rectangle.portrait" : "rectangle.split.2x1"))
                                        .font(.system(size: 18, weight: .medium))
                                    Text(cols == 0 ? "Auto" : (cols == 1 ? "Single" : "Double"))
                                        .font(.system(size: 12, weight: .medium))
                                }
                                .foregroundStyle(prefs.columnCount == cols ? Color.orange : Color.inkTextSecondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(prefs.columnCount == cols ? Color.orange.opacity(0.12) : Color.inkSurfaceRaised)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(prefs.columnCount == cols ? Color.orange.opacity(0.5) : Color.clear, lineWidth: 1.5)
                                )
                            }
                            .buttonStyle(.plain)
                            .animation(.spring(response: 0.25, dampingFraction: 0.75), value: prefs.columnCount)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }

                // Pagination
                ReaderSettingsSection(title: "Pagination & Spreads", icon: "book.pages") {
                    HStack(spacing: 10) {
                        ForEach(EBookPaginationMode.allCases) { mode in
                            Button {
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                                    prefs.paginationMode = mode.rawValue
                                }
                            } label: {
                                VStack(spacing: 6) {
                                    Image(systemName: mode.icon)
                                        .font(.system(size: 18, weight: .medium))
                                    Text(mode.rawValue)
                                        .font(.system(size: 12, weight: .medium))
                                }
                                .foregroundStyle(prefs.paginationMode == mode.rawValue ? Color.orange : Color.inkTextSecondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(prefs.paginationMode == mode.rawValue ? Color.orange.opacity(0.12) : Color.inkSurfaceRaised)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(prefs.paginationMode == mode.rawValue ? Color.orange.opacity(0.5) : Color.clear, lineWidth: 1.5)
                                )
                            }
                            .buttonStyle(.plain)
                            .animation(.spring(response: 0.25, dampingFraction: 0.75), value: prefs.paginationMode)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    
                    if prefs.paginationMode == EBookPaginationMode.paged.rawValue {
                        Divider().padding(.leading, 44)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("PAGE TRANSITION STYLE")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.inkTextSecondary)
                                .padding(.horizontal, 16)
                            
                            HStack(spacing: 8) {
                                ForEach(PageTurnStyle.displayCases, id: \.self) { style in
                                    Button {
                                        withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                                            prefs.pageTurnStyle = style
                                        }
                                        HapticEngine.selection()
                                    } label: {
                                        VStack(spacing: 5) {
                                            Image(systemName: style.icon)
                                                .font(.system(size: 16, weight: .medium))
                                            Text(style.label)
                                                .font(.system(size: 11, weight: .medium))
                                        }
                                        .foregroundStyle(prefs.pageTurnStyle == style ? Color.orange : Color.inkTextSecondary)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 10)
                                        .background(
                                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                .fill(prefs.pageTurnStyle == style ? Color.orange.opacity(0.12) : Color.inkSurfaceRaised)
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                .stroke(prefs.pageTurnStyle == style ? Color.orange.opacity(0.5) : Color.clear, lineWidth: 1.5)
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                        .padding(.vertical, 6)
                    }
                    
                    Divider().padding(.leading, 44)
                    
                    ReaderSettingsToggleRow(
                        label: "Full-Screen Panoramic Spreads",
                        icon: "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left",
                        isOn: $prefs.fullBleedSpreads
                    )
                    
                    Divider().padding(.leading, 44)
                    
                    ReaderSettingsToggleRow(
                        label: "Show Clock & Status Header",
                        icon: "clock",
                        isOn: $prefs.showClockHeader
                    )
                    
                    if prefs.showClockHeader {
                        Divider().padding(.leading, 44)
                        ReaderSettingsToggleRow(
                            label: "Show Battery Percentage",
                            icon: "battery.100",
                            isOn: $prefs.showBatteryPercentage
                        )
                    }
                }
            }


            // Reading Aids & Auto-Crop
            ReaderSettingsSection(title: "Reading Aids & Auto-Crop", icon: "crop") {
                ReaderSettingsToggleRow(
                    label: "White-Margin Auto-Crop",
                    icon: "crop",
                    isOn: $prefs.isSmartCropEnabled
                )
                if prefs.isSmartCropEnabled {
                    Divider().padding(.leading, 44)
                    SliderRow(
                        label: "Crop Threshold",
                        icon: "slider.horizontal.3",
                        value: $prefs.autoCropSensitivity,
                        range: 0.02...0.25,
                        step: 0.01,
                        displayFormat: { String(format: "%.0f%%", $0 * 100) }
                    )
                }
                Divider().padding(.leading, 44)
                ReaderSettingsToggleRow(
                    label: "Reading Ruler",
                    icon: "minus",
                    isOn: $prefs.showReadingRuler
                )
                Divider().padding(.leading, 44)
                ReaderSettingsToggleRow(
                    label: "Auto-Scroll",
                    icon: "play.circle",
                    isOn: $prefs.autoScroll
                )
                if prefs.autoScroll {
                    Divider().padding(.leading, 44)
                    SliderRow(
                        label: "Scroll Speed",
                        icon: "speedometer",
                        value: $prefs.autoScrollSpeed,
                        range: 0.5...3.0,
                        step: 0.1,
                        displayFormat: { String(format: "%.1f×", $0) }
                    )
                }
            }

            // Tap Zone Layout (KOReader style)
            ReaderSettingsSection(title: "Tap Navigation Zones", icon: "hand.tap") {
                HStack(spacing: 8) {
                    ForEach(TapZoneStyle.allCases, id: \.self) { style in
                        Button {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                                prefs.tapZoneStyle = style
                            }
                            HapticEngine.light()
                        } label: {
                            VStack(spacing: 6) {
                                Image(systemName: style.icon)
                                    .font(.system(size: 16, weight: .medium))
                                Text(style.rawValue.capitalized)
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundStyle(prefs.tapZoneStyle == style ? Color.orange : Color.inkTextSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(prefs.tapZoneStyle == style ? Color.orange.opacity(0.12) : Color.inkSurfaceRaised)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(prefs.tapZoneStyle == style ? Color.orange.opacity(0.5) : Color.clear, lineWidth: 1.5)
                            )
                        }
                        .buttonStyle(.plain)
                        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: prefs.tapZoneStyle)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }

            if isPDF {
                ReaderSettingsSection(title: "PDF Layout Options", icon: "doc.richtext") {
                    ReaderSettingsToggleRow(
                        label: "Two-Up (Dual Page)",
                        icon: "rectangle.split.2x1",
                        isOn: Binding(
                            get: { prefs.pdfDualPage },
                            set: { prefs.pdfDualPage = $0 }
                        )
                    )
                    Divider().padding(.leading, 44)
                    ReaderSettingsToggleRow(
                        label: "Fit Page to Width",
                        icon: "arrow.left.and.right.square",
                        isOn: Binding(
                            get: { prefs.pdfFitToWidth },
                            set: { prefs.pdfFitToWidth = $0 }
                        )
                    )
                    Divider().padding(.leading, 44)
                    ReaderSettingsToggleRow(
                        label: "Right-to-Left (Manga) Mode",
                        icon: "arrow.left.to.line",
                        isOn: Binding(
                            get: { prefs.pdfRTL },
                            set: { prefs.pdfRTL = $0 }
                        )
                    )
                }
            }
        }
    }
}

// MARK: - Shared Section Container (matches ReaderSettingsSheet style)
struct ReaderSettingsSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.orange)
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.inkTextSecondary)
                    .tracking(0.8)
            }
            .padding(.horizontal, 4)

            VStack(spacing: 0) {
                content()
            }
            .background(Color.inkSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

// MARK: - Toggle Row
struct ReaderSettingsToggleRow: View {
    let label: String
    let icon: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(isOn ? Color.orange : Color.inkTextSecondary)
                .frame(width: 28)
            Text(label)
                .font(.system(size: 15))
                .foregroundStyle(Color.inkTextPrimary)
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(Color.orange)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - Slider Row
private struct SliderRow: View {
    let label: String
    let icon: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let displayFormat: (Double) -> String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.inkTextSecondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(label)
                        .font(.system(size: 15))
                        .foregroundStyle(Color.inkTextPrimary)
                    Spacer()
                    Text(displayFormat(value))
                        .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(Color.orange)
                }
                Slider(value: $value, in: range, step: step)
                    .tint(Color.orange)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - Colour Picker Sheet
private struct ColorPickerSheet: View {
    @Binding var hex: String
    let title: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            VStack(spacing: 32) {
                ColorPicker(title, selection: Binding(
                    get: { Color(hex: hex) },
                    set: { hex = $0.toHex() ?? hex }
                ), supportsOpacity: false)
                .labelsHidden()
                .scaleEffect(2)
                .frame(height: 120)
                Spacer()
            }
            .padding(40)
            .background(Color.inkBackground.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
    }
}
