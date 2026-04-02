import SwiftUI

enum ReadingFilterPreset: String, CaseIterable, Codable {
    case original = "Original"
    case vintage = "Vintage Tone"
    case eink = "E-Ink Clarity"
    case vibrant = "Vibrant Webtoon"
    case dark = "Manga Dark Mode"
    
    var icon: String {
        switch self {
        case .original: return "photo"
        case .vintage: return "cup.and.saucer.fill"
        case .eink: return "newspaper.fill"
        case .vibrant: return "paintpalette.fill"
        case .dark: return "moon.stars.fill"
        }
    }
}

struct FilterHUDView: View {
    @Binding var activePreset: ReadingFilterPreset
    var onDismiss: () -> Void
    
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
