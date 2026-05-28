import SwiftUI

// MARK: - ReaderSettingsHUD
// A unified bottom-drawer HUD replacing the blind mode-cycling ellipsis tap.
// Shows all reading modes and filter presets with live checkmark indicators.
// Presented as a ZStack overlay (not a sheet) to keep the reader page visible behind it.

struct ReaderSettingsHUD: View {
    @Binding var readingMode: ComicReadingMode
    @Binding var activeFilterPreset: ReadingFilterPreset
    var onDismiss: () -> Void
    
    @AppStorage("isAutoCropEnabled") private var isAutoCropEnabled = false

    var body: some View {
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
            
            // ── Page Options ────────────────────────────────────────────────────
            sectionHeader("Page Options")
            
            VStack(spacing: 3) {
                toggleRow(
                    title: "Smart Margin Crop",
                    description: "Auto-removes white borders from scanned pages",
                    icon: "crop",
                    isOn: $isAutoCropEnabled
                )
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 36)
        }
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
        .buttonStyle(.plain)
    }
    
    // MARK: - Segment Row
    
    @ViewBuilder
    private func segmentRow(title: String, icon: String, options: [(String, String)], selection: Binding<String>) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.1))
                    .frame(width: 36, height: 36)
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.white)
            }
            
            Text(title)
                .font(.system(size: 15, weight: .regular))
                .foregroundColor(.white)
            
            Spacer()
            
            Picker("", selection: selection) {
                ForEach(options, id: \.1) { option in
                    Text(option.0).tag(option.1)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 160)
            // Tinting the segmented control for the dark theme
            .onAppear {
                let attr = [NSAttributedString.Key.foregroundColor: UIColor.white]
                UISegmentedControl.appearance().setTitleTextAttributes(attr, for: .normal)
                UISegmentedControl.appearance().selectedSegmentTintColor = UIColor.orange
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - ComicReadingMode HUD extensions

extension ComicReadingMode {
    var hudIcon: String {
        switch self {
        case .pageHorizontal:  return "book.pages"
        case .mangaRTL:        return "arrow.right.to.line"
        case .pageTwoUp:       return "rectangle.split.2x1"
        case .panelNavigation: return "viewfinder"
        case .webtoonScroll:   return "arrow.down.doc"
        case .pageSlide:       return "rectangle.on.rectangle.slash"
        case .pageFade:        return "waveform.path.ecg"
        }
    }

    var hudLabel: String {
        switch self {
        case .pageHorizontal:  return "Standard (3D Curl)"
        case .mangaRTL:        return "Manga (Right-to-Left)"
        case .pageTwoUp:       return "Two-Page Spread"
        case .panelNavigation: return "Panel Navigation"
        case .webtoonScroll:   return "Webtoon Scroll"
        case .pageSlide:       return "Slide"
        case .pageFade:        return "Fade"
        }
    }

    var hudDescription: String {
        switch self {
        case .pageHorizontal:  return "Swipe left to advance pages"
        case .mangaRTL:        return "Swipe right to advance pages"
        case .pageTwoUp:       return "Side-by-side spreads (landscape)"
        case .panelNavigation: return "Auto-zoom per panel using Vision"
        case .webtoonScroll:   return "Continuous vertical strip"
        case .pageSlide:       return "Flat horizontal page slide"
        case .pageFade:        return "Crossfade between pages"
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
        }
    }
}
