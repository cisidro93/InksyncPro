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
    var onDismiss: () -> Void
    
    @AppStorage("isAutoCropEnabled") private var isAutoCropEnabled = false
    @ObservedObject private var prefs = EBookPreferences.shared

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                // ── Drag pill ───────────────────────────────────────────────────────
                Capsule()
                    .fill(Color.white.opacity(0.25))
                    .frame(width: 36, height: 4)
                    .padding(.top, 12)
                    .padding(.bottom, 18)

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
                
                // ── Page Margins & Cropping ──────────────────────────────────────────
                sectionHeader("Page Margins & Cropping")
                
                VStack(spacing: 12) {
                    // 3-Way Mode Selector
                    HStack(spacing: 8) {
                        ForEach(["smartAuto", "custom", "none"], id: \.self) { mode in
                            let isSelected = prefs.defaultCropModeRaw == mode
                            Button {
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                                    prefs.defaultCropModeRaw = mode
                                    if mode == "smartAuto" {
                                        isAutoCropEnabled = true
                                        prefs.isSmartCropEnabled = true
                                    } else if mode == "none" {
                                        isAutoCropEnabled = false
                                        prefs.isSmartCropEnabled = false
                                    } else {
                                        isAutoCropEnabled = true
                                        prefs.isSmartCropEnabled = true
                                    }
                                }
                                HapticEngine.light()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: mode == "smartAuto" ? "sparkles" : (mode == "custom" ? "slider.horizontal.3" : "arrow.up.left.and.down.right"))
                                        .font(.system(size: 13, weight: .medium))
                                    Text(mode == "smartAuto" ? "Smart Auto" : (mode == "custom" ? "Manual" : "Full Page"))
                                        .font(.system(size: 12, weight: .semibold))
                                }
                                .foregroundStyle(isSelected ? Color.orange : Color.white.opacity(0.7))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(isSelected ? Color.orange.opacity(0.18) : Color.white.opacity(0.08))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(isSelected ? Color.orange.opacity(0.6) : Color.white.opacity(0.06), lineWidth: 1.5)
                                )
                            }
                            .buttonStyle(.plain)
                        }
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
                                        .fill(Color.orange.opacity(0.2))
                                        .frame(width: 36, height: 36)
                                    Image(systemName: "viewfinder")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundColor(.orange)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Visual Crop Editor...")
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundColor(.white)
                                    Text("Interactive live boundary trimming with visual guides")
                                        .font(.system(size: 12))
                                        .foregroundColor(.white.opacity(0.5))
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.white.opacity(0.4))
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 13, style: .continuous)
                                    .fill(Color.white.opacity(0.08))
                            )
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
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 28)
            }
        }
        .frame(maxHeight: min(540, UIScreen.main.bounds.height * 0.75))
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.45), radius: 30, y: -10)
    }

    // MARK: - Section Header

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.45))
                .tracking(0.8)
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
                        .fill(isActive ? Color.white : Color.white.opacity(0.1))
                        .frame(width: 36, height: 36)
                    Image(systemName: mode.hudIcon)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(isActive ? .black : .white)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.hudLabel)
                        .font(.system(size: 15, weight: isActive ? .semibold : .regular))
                        .foregroundColor(.white)
                    Text(mode.hudDescription)
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.5))
                }

                Spacer()

                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.white, Color.blue)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(isActive ? Color.white.opacity(0.15) : Color.clear)
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
                        .fill(isActive ? preset.hudTint : Color.white.opacity(0.1))
                        .frame(width: 36, height: 36)
                    Image(systemName: preset.icon)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.white)
                }

                Text(preset.rawValue)
                    .font(.system(size: 15, weight: isActive ? .semibold : .regular))
                    .foregroundColor(.white)

                Spacer()

                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.white, preset.hudTint)
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
                        .fill(isOn.wrappedValue ? Color.orange : Color.white.opacity(0.1))
                        .frame(width: 36, height: 36)
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(isOn.wrappedValue ? .white : .white)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: isOn.wrappedValue ? .semibold : .regular))
                        .foregroundColor(.white)
                    Text(description)
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.5))
                }

                Spacer()

                if isOn.wrappedValue {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.white, Color.orange)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(isOn.wrappedValue ? Color.white.opacity(0.15) : Color.clear)
            )
            .contentShape(Rectangle())
        }
    // MARK: - Slider Row

    @ViewBuilder
    private func hudSliderRow(label: String, icon: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Color.orange)
                    .frame(width: 24)
                
                Text(label)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundColor(.white)
                
                Spacer()
                
                Text(String(format: "%.1f%%", value.wrappedValue * 100))
                    .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundColor(Color.orange)
            }
            
            Slider(value: value, in: range, step: step)
                .tint(Color.orange)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
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
