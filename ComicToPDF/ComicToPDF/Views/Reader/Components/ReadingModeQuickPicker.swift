import SwiftUI

// MARK: - Reading Mode Quick Picker
// Appears as a bottom-anchored frosted capsule when the user swipes up
// from the bottom of the reader while chrome is hidden.
// Tapping a mode switches instantly and saves per-book preferences.
// Auto-dismisses after 3 seconds of inactivity.

struct ReadingModeQuickPicker: View {
    @Binding var isMangaMode: Bool
    @Binding var isVerticalScroll: Bool
    var onDismiss: () -> Void
    var onSave: () -> Void

    private enum Mode: CaseIterable {
        case normal, manga, webtoon

        var label: String {
            switch self {
            case .normal:  return "Normal"
            case .manga:   return "Manga"
            case .webtoon: return "Webtoon"
            }
        }

        var icon: String {
            switch self {
            case .normal:  return "book.fill"
            case .manga:   return "book.closed.fill"
            case .webtoon: return "scroll.fill"
            }
        }
    }

    private var currentMode: Mode {
        if isVerticalScroll { return .webtoon }
        if isMangaMode      { return .manga }
        return .normal
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Mode.allCases, id: \.label) { mode in
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                        switch mode {
                        case .normal:
                            isMangaMode = false
                            isVerticalScroll = false
                        case .manga:
                            isMangaMode = true
                            isVerticalScroll = false
                        case .webtoon:
                            isMangaMode = false
                            isVerticalScroll = true
                        }
                    }
                    onSave()
                    // Auto-dismiss after selection
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { onDismiss() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: mode.icon)
                            .font(.system(size: 12, weight: .semibold))
                        Text(mode.label)
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(currentMode == mode ? Color.white : Color.white.opacity(0.55))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(
                        currentMode == mode
                            ? AnyShapeStyle(Theme.orange)
                            : AnyShapeStyle(Color.white.opacity(0.08)),
                        in: Capsule()
                    )
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(currentMode == mode ? 0 : 0.15), lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            .ultraThinMaterial,
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.35), radius: 20, y: 8)
        .padding(.horizontal, 32)
        .padding(.bottom, 100)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
