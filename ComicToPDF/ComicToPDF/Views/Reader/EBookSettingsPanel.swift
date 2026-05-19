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

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // ── Live Preview Strip ────────────────────────────────────────
                livePreviewStrip

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
            ForEach(PanelTab.allCases, id: \.self) { tab in
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
            // Built-in 5 themes
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
                        ForEach([EBookTheme.slate, .night], id: \.self) { theme in
                            themeCard(theme)
                        }
                        // Custom slot
                        themeCard(.custom)
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
                        Button { prefs.fontSize = min(40, prefs.fontSize + 1) } label: {
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
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: isSelected)
    }

    // MARK: - Layout Tab
    private var layoutTab: some View {
        VStack(spacing: 20) {
            // Margins & Paragraph
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

            // Pagination
            ReaderSettingsSection(title: "Pagination", icon: "book.pages") {
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
            }

            // Reading Aids
            ReaderSettingsSection(title: "Reading Aids", icon: "eye") {
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
