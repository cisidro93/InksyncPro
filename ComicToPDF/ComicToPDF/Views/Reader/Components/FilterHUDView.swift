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
    
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Premium Reading Filters")
                    .font(.headline)
                    .foregroundColor(.primary)
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal)
            .padding(.top, 16)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(ReadingFilterPreset.allCases, id: \.self) { preset in
                        FilterPresetButton(
                            preset: preset,
                            isActive: activePreset == preset,
                            action: {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                    activePreset = preset
                                }
                            }
                        )
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 20)
            }
            
            if activePreset == .custom {
                VStack(spacing: 12) {
                    Divider()
                        .background(Color.white.opacity(0.15))
                    
                    sliderRow(title: "Contrast", value: $customContrast, range: 0.5...2.0, format: "%.1fx", icon: "circle.lefthalf.filled")
                    sliderRow(title: "Brightness", value: $customBrightness, range: -0.4...0.4, format: "%+.2f", icon: "sun.max.fill")
                    sliderRow(title: "Saturation", value: $customSaturation, range: 0.0...2.0, format: "%.1fx", icon: "drop.fill")
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 24)
                .fill(.ultraThinMaterial)
                .shadow(color: Color.black.opacity(0.2), radius: 20, x: 0, y: 10)
        )
        // Add subtle specular highlight border
        .overlay(
            RoundedRectangle(cornerRadius: 24)
                .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
        )
        .padding()
    }
    
    @ViewBuilder
    private func sliderRow(title: String, value: Binding<Double>, range: ClosedRange<Double>, format: String, icon: String) -> some View {
        VStack(spacing: 4) {
            HStack {
                Label(title, systemImage: icon)
                    .font(.footnote)
                    .foregroundColor(.white.opacity(0.8))
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.6))
                    .monospacedDigit()
            }
            
            Slider(value: value, in: range)
                .tint(.blue)
        }
    }
}

private struct FilterPresetButton: View {
    let preset: ReadingFilterPreset
    let isActive: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(isActive ? Color.blue : Color.secondary.opacity(0.2))
                        .frame(width: 56, height: 56)
                    
                    Image(systemName: preset.icon)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundColor(isActive ? .white : .primary)
                }
                
                Text(preset.rawValue)
                    .font(.caption2)
                    .fontWeight(isActive ? .semibold : .regular)
                    .foregroundColor(isActive ? .primary : .secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: 72)
            }
        }
        .buttonStyle(.plain)
    }
}
