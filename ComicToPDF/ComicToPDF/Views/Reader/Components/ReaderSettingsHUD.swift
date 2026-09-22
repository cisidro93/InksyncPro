import SwiftUI

// MARK: - ReaderSettingsHUD
// A unified bottom-drawer HUD replacing the blind mode-cycling ellipsis tap.
// Shows all reading modes and filter presets with live checkmark indicators.
// Presented as a ZStack overlay (not a sheet) to keep the reader page visible behind it.

struct ReaderSettingsHUD: View {
    @Binding var readingMode: ComicReadingMode
    @Binding var activeFilterPreset: ReadingFilterPreset
    @Binding var prefersTwoUpSpreads: Bool
    var onOpenVisualCrop: (() -> Void)? = nil
    var isPDF: Bool = false
    var onSwitchToProPDF: (() -> Void)? = nil
    var onDismiss: () -> Void
    
    @AppStorage("isAutoCropEnabled") private var isAutoCropEnabled = false
    @ObservedObject private var prefs = EBookPreferences.shared
    @Environment(\.colorScheme) private var colorScheme

    private var isPad: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                // ── Drag pill ───────────────────────────────────────────────────────
                InkSheetDragPill()
                    .padding(.top, 4)
                    .padding(.bottom, 12)

                // ── Reader Engine Switcher (When PDF is loaded in Comic engine) ─────
                if isPDF || onSwitchToProPDF != nil {
                    VStack(alignment: .leading, spacing: 8) {
                        sectionHeader("Reader Engine")
                        
                        Button {
                            HapticEngine.selection()
                            onDismiss()
                            NotificationCenter.default.post(
                                name: NSNotification.Name("InksyncPro.switchReaderEngine"),
                                object: nil,
                                userInfo: ["engine": "proPDF"]
                            )
                            onSwitchToProPDF?()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "doc.richtext.fill")
                                    .font(.system(size: isPad ? 20 : 18, weight: .bold))
                                    .foregroundColor(.inkGreen)
                                    .frame(width: isPad ? 36 : 32, height: isPad ? 36 : 32)
                                    .background(Color.inkGreen.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
                                
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Switch to Pro PDF Reader")
                                        .font(.system(size: isPad ? 15 : 14, weight: .semibold, design: .rounded))
                                        .foregroundColor(Color.inkText)
                                    Text("Native text selection, highlighting, typography, & live reflow")
                                        .font(.system(size: isPad ? 12 : 11, weight: .regular))
                                        .foregroundColor(Color.inkSecondary)
                                }
                                
                                Spacer()
                                
                                Image(systemName: "arrow.right.circle.fill")
                                    .font(.system(size: isPad ? 18 : 16))
                                    .foregroundColor(.inkGreen)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Color.inkSurfaceRaised, in: RoundedRectangle(cornerRadius: 12))
                            .inkSpecularBorder(cornerRadius: 12)
                        }
                        .padding(.horizontal, 14)
                        .padding(.bottom, 16)
                    }
                }

                // ── Reading Mode ────────────────────────────────────────────────────
                sectionHeader("Reading Mode")

                VStack(spacing: 3) {
                    ForEach(ComicReadingMode.allCases, id: \.self) { mode in
                        modeRow(mode)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 20)

                // ── Color Filter ────────────────────────────────────────────────────
                sectionHeader("Color Filter")

                VStack(spacing: 3) {
                    ForEach(ReadingFilterPreset.allCases, id: \.self) { preset in
                        filterRow(preset)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 20)

                // ── Smart Tiers & Guided Flow ──────────────────────────────────────────
                sectionHeader("Smart Tiers & Guided Flow")

                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        ForEach(PanelInspectionStyle.allCases) { style in
                            panelStyleButton(style)
                        }
                    }
                    
                    Text(prefs.panelInspectionStyle.subtitle)
                        .font(.system(size: isPad ? 12 : 11, weight: .regular))
                        .foregroundColor(Color.inkSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)

                    Toggle(isOn: $prefs.isPDFSmartTiersActive) {
                        Label("PDF Smart Tiers Guided Flow", systemImage: "rectangle.split.3x1")
                            .font(.system(size: isPad ? 13 : 12, weight: .semibold))
                            .foregroundColor(Color.inkTextPrimary)
                    }
                    .tint(.inkGreen)
                    .padding(.horizontal, 4)
                    .padding(.top, 4)

                    Button {
                        HapticEngine.selection()
                        onDismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            NotificationCenter.default.post(name: NSNotification.Name("ComicReader_OpenPanelWorkspace"), object: nil)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            ZStack {
                                Circle()
                                    .fill(Color.inkViolet.opacity(0.18))
                                    .frame(width: isPad ? 36 : 32, height: isPad ? 36 : 32)
                                Image(systemName: "slider.horizontal.2.square")
                                    .font(.system(size: isPad ? 16 : 14, weight: .semibold))
                                    .foregroundColor(Color.inkViolet)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Adjust Smart Tiers & Flow...")
                                    .font(.system(size: isPad ? 15 : 13, weight: .semibold))
                                    .foregroundColor(Color.inkTextPrimary)
                                Text("Customize tiers, overlap, and manga/comic flow across book")
                                    .font(.system(size: isPad ? 12 : 11))
                                    .foregroundColor(Color.inkSecondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(Color.inkSecondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.inkViolet.opacity(0.08))
                        )
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 20)

                // ── Screen Space & Scaling (iPhone Full Bleed) ─────────────────────
                sectionHeader("Screen Space & Scaling")

                HStack(spacing: 8) {
                    ForEach(ComicPageFitMode.allCases) { mode in
                        fitModeButton(mode)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 20)
                
                // ── Page Margins & Cropping ──────────────────────────────────────────
                sectionHeader("Page Margins & Cropping")
                
                VStack(spacing: 12) {
                    // 3-Way Mode Selector
                    HStack(spacing: 8) {
                        cropModeButton(mode: "smartAuto", title: "Smart Auto", icon: "sparkles")
                        cropModeButton(mode: "custom",    title: "Manual",     icon: "slider.horizontal.3")
                        cropModeButton(mode: "none",      title: "Full Page",  icon: "arrow.up.left.and.down.right")
                    }

                    if prefs.defaultCropModeRaw == "custom" {
                        // Precision Manual Trim Sliders
                        hudSliderRow(label: "Top Trim", icon: "arrow.up", value: $prefs.defaultCropTop, range: 0.0...0.20, step: 0.005)
                        hudSliderRow(label: "Bottom Trim", icon: "arrow.down", value: $prefs.defaultCropBottom, range: 0.0...0.20, step: 0.005)
                        hudSliderRow(label: "Left Trim", icon: "arrow.left", value: $prefs.defaultCropLeft, range: 0.0...0.20, step: 0.005)
                        hudSliderRow(label: "Right Trim", icon: "arrow.right", value: $prefs.defaultCropRight, range: 0.0...0.20, step: 0.005)
                    } else if prefs.defaultCropModeRaw == "smartAuto" {
                        hudSliderRow(label: "Auto-Crop Sensitivity", icon: "crop.square", value: $prefs.autoCropSensitivity, range: 0.05...0.25, step: 0.01)
                    }

                    // Visual Crop Editor Button
                    if let onOpenCrop = onOpenVisualCrop {
                        Button {
                            HapticEngine.medium()
                            onOpenCrop()
                        } label: {
                            HStack(spacing: 12) {
                                ZStack {
                                    Circle()
                                        .fill(Color.inkOrange.opacity(0.2))
                                        .frame(width: isPad ? 40 : 36, height: isPad ? 40 : 36)
                                    Image(systemName: "viewfinder")
                                        .font(.system(size: isPad ? 18 : 16, weight: .semibold))
                                        .foregroundColor(Color.inkOrange)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Visual Crop Editor...")
                                        .font(.system(size: isPad ? 16 : 15, weight: .medium))
                                        .foregroundColor(Color.inkText)
                                    Text("Interactive live boundary trimming with visual guides")
                                        .font(.system(size: isPad ? 13 : 12))
                                        .foregroundColor(Color.inkSecondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(Color.inkSecondary)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 13, style: .continuous)
                                    .fill(Color.inkSurfaceRaised)
                            )
                            .inkSpecularBorder(cornerRadius: 13)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 20)

                // ── Page Options ────────────────────────────────────────────────────
                sectionHeader("Page Options")
                
                VStack(spacing: 12) {
                    toggleRow(
                        title: "Two-Page Spread",
                        description: "Displays side-by-side pages in landscape layout",
                        icon: "rectangle.split.2x1",
                        isOn: $prefersTwoUpSpreads
                    )
                    toggleRow(
                        title: "Volume Buttons Turn Pages",
                        description: "Use hardware volume buttons for fatigue-free one-handed reading",
                        icon: "speaker.wave.2",
                        isOn: $prefs.volumeButtonsTurnPages
                    )
                    if UIDevice.current.userInterfaceIdiom == .pad {
                        toggleRow(
                            title: "Apple Pencil Double-Tap",
                            description: "Switch between inking tool and eraser",
                            icon: "pencil.and.outline",
                            isOn: $prefs.applePencilAutoDraw
                        )
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 28)
            }
        }
        .frame(maxWidth: isPad ? 580 : .infinity)
        .frame(maxHeight: min(560, UIScreen.main.bounds.height * 0.78))
        .background(Color.inkSurfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .inkSpecularBorder(cornerRadius: 28)
        .shadow(color: Color.black.opacity(0.35), radius: 30, y: -10)
    }

    // MARK: - Section Header

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: isPad ? 13 : 11, weight: .semibold, design: .rounded))
                .foregroundColor(Color.inkSecondary)
                .tracking(isPad ? 1.0 : 0.8)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    // MARK: - Reading Mode Row

    @ViewBuilder
    private func modeRow(_ mode: ComicReadingMode) -> some View {
        let isActive = readingMode == mode
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                readingMode = mode
            }
            HapticEngine.light()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { onDismiss() }
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(isActive ? Color.inkText : Color.inkSecondary.opacity(0.12))
                        .frame(width: isPad ? 42 : 36, height: isPad ? 42 : 36)
                    Image(systemName: mode.hudIcon)
                        .font(.system(size: isPad ? 18 : 16, weight: .medium))
                        .foregroundColor(isActive ? (colorScheme == .dark ? Color.black : Color.white) : Color.inkText)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.hudLabel)
                        .font(.system(size: isPad ? 17 : 15, weight: isActive ? .semibold : .regular))
                        .foregroundColor(Color.inkText)
                    Text(mode.hudDescription)
                        .font(.system(size: isPad ? 13.5 : 12))
                        .foregroundColor(Color.inkSecondary)
                }

                Spacer()

                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: isPad ? 22 : 20))
                        .foregroundStyle(Color.white, Color.inkBlue)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(isActive ? Color.inkText.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Filter Preset Row

    @ViewBuilder
    private func filterRow(_ preset: ReadingFilterPreset) -> some View {
        let isActive = activeFilterPreset == preset
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                activeFilterPreset = preset
            }
            HapticEngine.light()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { onDismiss() }
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(isActive ? preset.hudTint : Color.inkSecondary.opacity(0.12))
                        .frame(width: isPad ? 42 : 36, height: isPad ? 42 : 36)
                    Image(systemName: preset.icon)
                        .font(.system(size: isPad ? 18 : 16, weight: .medium))
                        .foregroundColor(isActive ? .white : Color.inkText)
                }

                Text(preset.rawValue)
                    .font(.system(size: isPad ? 17 : 15, weight: isActive ? .semibold : .regular))
                    .foregroundColor(Color.inkText)

                Spacer()

                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: isPad ? 22 : 20))
                        .foregroundStyle(Color.white, preset.hudTint)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(isActive ? preset.hudTint.opacity(0.18) : Color.clear)
            )
            .contentShape(Rectangle())
        }
    }

    // MARK: - Toggle Row
    
    @ViewBuilder
    private func toggleRow(title: String, description: String, icon: String, isOn: Binding<Bool>) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                isOn.wrappedValue.toggle()
            }
            HapticEngine.light()
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(isOn.wrappedValue ? Color.inkOrange : Color.inkSecondary.opacity(0.12))
                        .frame(width: isPad ? 42 : 36, height: isPad ? 42 : 36)
                    Image(systemName: icon)
                        .font(.system(size: isPad ? 18 : 16, weight: .medium))
                        .foregroundColor(isOn.wrappedValue ? .white : Color.inkText)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: isPad ? 17 : 15, weight: isOn.wrappedValue ? .semibold : .regular))
                        .foregroundColor(Color.inkText)
                    Text(description)
                        .font(.system(size: isPad ? 13.5 : 12))
                        .foregroundColor(Color.inkSecondary)
                }

                Spacer()

                if isOn.wrappedValue {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: isPad ? 22 : 20))
                        .foregroundStyle(Color.white, Color.inkOrange)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(isOn.wrappedValue ? Color.inkOrange.opacity(0.12) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Slider Row

    @ViewBuilder
    private func hudSliderRow(label: String, icon: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: isPad ? 16 : 14, weight: .medium))
                    .foregroundColor(Color.inkOrange)
                    .frame(width: 24)
                
                Text(label)
                    .font(.system(size: isPad ? 16 : 14, weight: .regular))
                    .foregroundColor(Color.inkText)
                
                Spacer()
                
                Text(String(format: "%.1f%%", value.wrappedValue * 100))
                    .font(.system(size: isPad ? 15 : 13, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundColor(Color.inkOrange)
            }
            
            Slider(value: value, in: range, step: step)
                .tint(Color.inkOrange)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.inkSecondary.opacity(0.08))
        )
    }

    // MARK: - Crop Mode Button

    @ViewBuilder
    private func cropModeButton(mode: String, title: String, icon: String) -> some View {
        let isSelected: Bool = (prefs.defaultCropModeRaw == mode)
        Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                prefs.defaultCropModeRaw = mode
                let enabled = (mode != "none")
                isAutoCropEnabled = enabled
                prefs.isSmartCropEnabled = enabled
            }
            HapticEngine.light()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: isPad ? 15 : 13, weight: .medium))
                Text(title)
                    .font(.system(size: isPad ? 14 : 12, weight: .semibold))
            }
            .foregroundStyle(isSelected ? Color.inkOrange : Color.inkSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.inkOrange.opacity(0.18) : Color.inkSecondary.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isSelected ? Color.inkOrange.opacity(0.6) : Color.inkSecondary.opacity(0.15), lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Fit Mode Button

    @ViewBuilder
    private func fitModeButton(_ mode: ComicPageFitMode) -> some View {
        let isSelected: Bool = (prefs.comicPageFitMode == mode)
        Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                prefs.comicPageFitMode = mode
                if mode == .smartFit {
                    prefs.defaultCropModeRaw = "smartAuto"
                    isAutoCropEnabled = true
                    prefs.isSmartCropEnabled = true
                }
            }
            HapticEngine.selection()
        } label: {
            VStack(spacing: 5) {
                Image(systemName: mode.icon)
                    .font(.system(size: isPad ? 18 : 15, weight: isSelected ? .bold : .medium))
                Text(mode.title)
                    .font(.system(size: isPad ? 13 : 11, weight: isSelected ? .bold : .medium))
            }
            .foregroundStyle(isSelected ? Color.inkGreen : Color.inkSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(isSelected ? Color.inkGreen.opacity(0.2) : Color.inkSecondary.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(isSelected ? Color.inkGreen.opacity(0.6) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Panel Style Button

    @ViewBuilder
    private func panelStyleButton(_ style: PanelInspectionStyle) -> some View {
        let isSelected: Bool = (prefs.panelInspectionStyle == style)
        Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                prefs.panelInspectionStyle = style
            }
            HapticEngine.selection()
        } label: {
            VStack(spacing: 5) {
                Image(systemName: style.icon)
                    .font(.system(size: isPad ? 18 : 15, weight: isSelected ? .bold : .medium))
                Text(style.title)
                    .font(.system(size: isPad ? 13 : 11, weight: isSelected ? .bold : .medium))
            }
            .foregroundStyle(isSelected ? Color.inkGreen : Color.inkSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(isSelected ? Color.inkGreen.opacity(0.2) : Color.inkSecondary.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(isSelected ? Color.inkGreen.opacity(0.6) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - ComicReadingMode HUD extensions

extension ComicReadingMode {
    var hudIcon: String {
        switch self {
        case .pageHorizontal:  return "book.pages"
        case .mangaRTL:        return "arrow.left.to.line"
        case .panelNavigation: return "viewfinder"
        case .webtoonScroll:   return "arrow.down.doc"
        }
    }

    var hudLabel: String {
        switch self {
        case .pageHorizontal:  return "Standard (3D Curl)"
        case .mangaRTL:        return "Manga (Right-to-Left)"
        case .panelNavigation: return "Panel Navigation"
        case .webtoonScroll:   return "Webtoon Scroll"
        }
    }

    var hudDescription: String {
        switch self {
        case .pageHorizontal:  return "Swipe left to advance pages"
        case .mangaRTL:        return "Swipe right to advance pages"
        case .panelNavigation: return "Auto-zoom per panel using Vision"
        case .webtoonScroll:   return "Continuous vertical strip"
        }
    }
}

// MARK: - ReadingFilterPreset HUD extensions

extension ReadingFilterPreset {
    var hudTint: Color {
        switch self {
        case .original: return Color(white: 0.5)
        case .vintage:  return Color(red: 0.76, green: 0.55, blue: 0.30)
        case .eink:     return Color(white: 0.35)
        case .vibrant:  return Color(red: 0.35, green: 0.55, blue: 1.0)
        case .dark:     return Color(red: 0.35, green: 0.25, blue: 0.6)
        case .amber:    return Color(red: 1.0, green: 0.75, blue: 0.0)
        case .sepia:    return Color(red: 0.70, green: 0.55, blue: 0.40)
        case .custom:   return Color.blue
        }
    }
}
