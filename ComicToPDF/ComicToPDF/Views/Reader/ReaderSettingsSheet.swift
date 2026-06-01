import SwiftUI

// MARK: - ReaderSettingsSheet
// A premium bottom-sheet for all comic/manga reader settings.
// Replaces the old overcrowded Menu in ReaderView's topBar.

struct ReaderSettingsSheet: View {
    // Reading Mode
    @Binding var isMangaMode: Bool
    @Binding var isVerticalScroll: Bool

    // Layout
    @Binding var isDoublePageMode: Bool
    @Binding var autoLandscapeDualPage: Bool

    // Image Enhancement
    @Binding var autoContrastLevel: Double
    @Binding var smartSharpen: Bool
    @Binding var isAutoCropEnabled: Bool

    // Color Filter
    @Binding var colorFilter: ReaderColorFilter

    // Ambient
    @ObservedObject var ambientBrightness: AmbientBrightnessManager
    @Binding var brightnessLevel: CGFloat
    @Binding var warmthLevel: Double

    // Webtoon
    @Binding var isWebtoonAutoScrolling: Bool
    @Binding var webtoonScrollSpeed: Double

    // Callbacks
    var onJumpToPage: () -> Void
    var onTOC: () -> Void
    var onSleepTimer: () -> Void
    var onSharePage: () -> Void
    var onDone: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 24) {
                    readingModeSection
                    layoutSection
                    pageTurnSection
                    imageEnhancementSection
                    colorFilterSection
                    ambientSection
                    if isVerticalScroll { webtoonSection }
                    toolsSection
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
            .background(Color.inkBackground.ignoresSafeArea())
            .navigationTitle("Reader Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onDone(); dismiss() }
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.orange)
                }
            }
        }
    }

    // MARK: - Reading Mode
    private var readingModeSection: some View {
        SettingsSection(title: "Reading Mode", icon: "book.pages") {
            SettingsToggleRow(
                label: "Manga (Right-to-Left)",
                icon: "character.book.closed.ja",
                isOn: $isMangaMode
            )
            Divider().padding(.leading, 44)
            SettingsToggleRow(
                label: "Vertical Webtoon Scroll",
                icon: "arrow.down.doc",
                isOn: $isVerticalScroll
            )
        }
    }

    // MARK: - Layout
    private var layoutSection: some View {
        SettingsSection(title: "Layout", icon: "rectangle.split.2x1") {
            SettingsToggleRow(
                label: "Dual Page (Manual)",
                icon: "rectangle.split.2x1.fill",
                isOn: $isDoublePageMode
            )
            Divider().padding(.leading, 44)
            SettingsToggleRow(
                label: "Auto Dual Page in Landscape",
                icon: "iphone.landscape",
                isOn: $autoLandscapeDualPage
            )
        }
    }

    // MARK: - Page Turn Style
    @AppStorage("pageTurnStyle") private var pageTurnStyleRaw = PageTurnStyle.slide.rawValue
    private var currentTurnStyle: PageTurnStyle { PageTurnStyle(rawValue: pageTurnStyleRaw) ?? .slide }

    private var pageTurnSection: some View {
        SettingsSection(title: "Page Turn Style", icon: "hand.draw") {
            HStack(spacing: 12) {
                ForEach(PageTurnStyle.allCases, id: \.self) { style in
                    PageTurnStyleCard(style: style, isSelected: currentTurnStyle == style) {
                        UserDefaults.standard.set(style.rawValue, forKey: "pageTurnStyle")
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Image Enhancement
    private var imageEnhancementSection: some View {
        SettingsSection(title: "Image Enhancement", icon: "wand.and.stars") {
            SettingsToggleRow(
                label: "Smart Margin Crop",
                icon: "crop",
                isOn: $isAutoCropEnabled
            )
            Divider().padding(.leading, 44)
            SettingsSliderRow(
                label: "Auto Contrast Level",
                icon: "circle.lefthalf.filled",
                value: $autoContrastLevel,
                range: 1.0...2.0,
                step: 0.05,
                displayFormat: { String(format: "%.2f×", $0) }
            )
            Divider().padding(.leading, 44)
            SettingsToggleRow(
                label: "Smart Sharpening",
                icon: "diamond.fill",
                isOn: $smartSharpen
            )
        }
    }

    // MARK: - Color Filter
    private var colorFilterSection: some View {
        SettingsSection(title: "Color Filter", icon: "paintpalette") {
            HStack(spacing: 10) {
                ForEach(ReaderColorFilter.allCases, id: \.self) { filter in
                    ColorFilterCard(filter: filter, isSelected: colorFilter == filter) {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                            colorFilter = filter
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Ambient Lighting
    private var ambientSection: some View {
        SettingsSection(title: "Ambient Lighting", icon: "moon.stars") {
            SettingsToggleRow(
                label: "Night Mode (Auto)",
                icon: "moon.fill",
                isOn: Binding(
                    get: { ambientBrightness.autoNightMode },
                    set: { val in
                        ambientBrightness.autoNightMode = val
                        ambientBrightness.evaluate()
                    }
                )
            )
            Divider().padding(.leading, 44)
            SettingsSliderRow(
                label: "Screen Brightness",
                icon: "sun.max.fill",
                value: Binding<Double>(
                    get: { Double(brightnessLevel) },
                    set: { brightnessLevel = CGFloat($0) }
                ),
                range: 0.0...1.0,
                step: 0.05,
                displayFormat: { String(format: "%.0f%%", $0 * 100) }
            )
            Divider().padding(.leading, 44)
            SettingsSliderRow(
                label: "Night Warmth",
                icon: "flame.fill",
                value: $warmthLevel,
                range: 0.0...0.4,
                step: 0.02,
                displayFormat: { String(format: "%.0f%%", ($0 / 0.4) * 100) }
            )
            if ambientBrightness.autoNightMode {
                Divider().padding(.leading, 44)
                HStack(spacing: 10) {
                    Image(systemName: "moon.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.orange.opacity(0.7))
                        .frame(width: 28)
                    Text("Night window: \(ambientBrightness.nightWindowDescription)")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.inkTextSecondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
    }

    // MARK: - Webtoon
    private var webtoonSection: some View {
        SettingsSection(title: "Webtoon", icon: "arrow.down.to.line") {
            SettingsToggleRow(
                label: "Auto-Scroll",
                icon: "play.circle.fill",
                isOn: $isWebtoonAutoScrolling
            )
            if isWebtoonAutoScrolling {
                Divider().padding(.leading, 44)
                SettingsSliderRow(
                    label: "Scroll Speed",
                    icon: "speedometer",
                    value: $webtoonScrollSpeed,
                    range: 10.0...150.0,
                    step: 5.0,
                    displayFormat: { String(format: "%.0f px/s", $0) }
                )
            }
        }
    }

    // MARK: - Tools
    private var toolsSection: some View {
        SettingsSection(title: "Tools", icon: "wrench.and.screwdriver") {
            SettingsActionRow(label: "Jump to Page…", icon: "arrow.right.circle") {
                onJumpToPage()
                dismiss()
            }
            Divider().padding(.leading, 44)
            SettingsActionRow(label: "Table of Contents", icon: "list.bullet.rectangle") {
                onTOC()
                dismiss()
            }
            Divider().padding(.leading, 44)
            SettingsActionRow(label: "Share This Page", icon: "square.and.arrow.up") {
                onSharePage()
                dismiss()
            }
            Divider().padding(.leading, 44)
            SettingsActionRow(label: "Sleep Timer…", icon: "moon.zzz") {
                onSleepTimer()
                dismiss()
            }
        }
    }
}

// MARK: - Sub-components

private struct SettingsSection<Content: View>: View {
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

private struct SettingsToggleRow: View {
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

private struct SettingsActionRow: View {
    let label: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.inkTextSecondary)
                    .frame(width: 28)
                Text(label)
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
    }
}

private struct PageTurnStyleCard: View {
    let style: PageTurnStyle
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: style.icon)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(isSelected ? Color.orange : Color.inkTextSecondary)
                Text(style.label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.orange : Color.inkTextSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? Color.orange.opacity(0.12) : Color.inkSurfaceRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isSelected ? Color.orange.opacity(0.5) : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isSelected)
    }
}

private struct ColorFilterCard: View {
    let filter: ReaderColorFilter
    let isSelected: Bool
    let action: () -> Void

    private var cardColor: Color {
        switch filter {
        case .none:      return Color.white.opacity(0.12)
        case .sepia:     return Color(red: 0.44, green: 0.26, blue: 0.08).opacity(0.3)
        case .grayscale: return Color.gray.opacity(0.3)
        case .warm:      return Color(red: 1.0, green: 0.75, blue: 0.4).opacity(0.35)
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(cardColor)
                        .frame(width: 44, height: 44)
                    Image(systemName: filter.icon)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(isSelected ? Color.orange : Color.inkTextSecondary)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(isSelected ? Color.orange : Color.clear, lineWidth: 2)
                )
                Text(filter.label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.orange : Color.inkTextSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isSelected)
    }
}

private struct SettingsSliderRow: View {
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

