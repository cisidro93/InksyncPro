import SwiftUI

enum ReadingFilterPreset: String, CaseIterable, Codable {
    case original = "Original"
    case vintage = "Vintage Tone"
    case eink = "E-Ink Clarity"
    case vibrant = "Vibrant Webtoon"
    case dark = "Manga Dark Mode"
    case amber = "Amber Mode"
    case sepia = "Sepia Theme"
    case custom = "Custom Adjust"
    
    var icon: String {
        switch self {
        case .original: return "photo"
        case .vintage: return "cup.and.saucer.fill"
        case .eink: return "newspaper.fill"
        case .vibrant: return "paintpalette.fill"
        case .dark: return "moon.stars.fill"
        case .amber: return "sun.max.fill"
        case .sepia: return "eye.fill"
        case .custom: return "slider.horizontal.3"
        }
    }
}

struct FilterHUDView: View {
    @Binding var activePreset: ReadingFilterPreset
    var onDismiss: () -> Void
    
    @AppStorage("customContrast") private var customContrast: Double = 1.0
    @AppStorage("customBrightness") private var customBrightness: Double = 0.0
    @AppStorage("customSaturation") private var customSaturation: Double = 1.0
    
    private var isPad: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }
    
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                InkSectionHeader("Premium Reading Filters")
                Spacer()
                Button(action: {
                    HapticEngine.selection()
                    onDismiss()
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(isPad ? .title2 : .title3)
                        .foregroundColor(Color.inkSecondary)
                }
            }
            .padding(.horizontal)
            .padding(.top, 16)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: isPad ? 20 : 16) {
                    ForEach(ReadingFilterPreset.allCases, id: \.self) { preset in
                        FilterPresetButton(
                            preset: preset,
                            isActive: activePreset == preset,
                            isPad: isPad,
                            action: {
                                HapticEngine.selection()
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                    activePreset = preset
                                }
                            }
                        )
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 16)
            }
            
            if activePreset == .custom {
                VStack(spacing: 12) {
                    Divider()
                        .background(Color.inkBorderSubtle)
                    
                    sliderRow(title: "Contrast", value: $customContrast, range: 0.5...2.0, format: "%.1fx", icon: "circle.lefthalf.filled")
                    sliderRow(title: "Brightness", value: $customBrightness, range: -0.4...0.4, format: "%+.2f", icon: "sun.max.fill")
                    sliderRow(title: "Saturation", value: $customSaturation, range: 0.0...2.0, format: "%.1fx", icon: "drop.fill")
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
        .frame(maxWidth: isPad ? 600 : .infinity)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.inkSurfaceRaised)
                .shadow(color: Color.black.opacity(0.2), radius: 20, x: 0, y: 10)
        )
        .inkSpecularBorder(cornerRadius: 24)
        .padding()
    }
    
    @ViewBuilder
    private func sliderRow(title: String, value: Binding<Double>, range: ClosedRange<Double>, format: String, icon: String) -> some View {
        VStack(spacing: 4) {
            HStack {
                Label(title, systemImage: icon)
                    .font(isPad ? .subheadline : .footnote)
                    .foregroundColor(Color.inkText)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .font(isPad ? .footnote : .caption)
                    .foregroundColor(Color.inkSecondary)
                    .monospacedDigit()
            }
            
            Slider(value: value, in: range)
                .tint(Color.inkBlue)
        }
    }
}

private struct FilterPresetButton: View {
    let preset: ReadingFilterPreset
    let isActive: Bool
    var isPad: Bool = false
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            let circleSize: CGFloat = isPad ? 64 : 54
            let iconSize: CGFloat = isPad ? 26 : 22
            let labelWidth: CGFloat = isPad ? 80 : 70

            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(isActive ? Color.inkBlue : Color.inkSurface.opacity(0.8))
                        .frame(width: circleSize, height: circleSize)
                    
                    Image(systemName: preset.icon)
                        .font(.system(size: iconSize, weight: .semibold))
                        .foregroundColor(isActive ? .white : Color.inkText)
                }
                .overlay(
                    Circle()
                        .stroke(isActive ? Color.white.opacity(0.4) : Color.clear, lineWidth: 1.5)
                )
                
                Text(preset.rawValue)
                    .font(.system(size: isPad ? 12 : 10, weight: isActive ? .semibold : .regular, design: .rounded))
                    .foregroundColor(isActive ? Color.inkText : Color.inkSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: labelWidth)
            }
        }
        .buttonStyle(.plain)
    }
}
