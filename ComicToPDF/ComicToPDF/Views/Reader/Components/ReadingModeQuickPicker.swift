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

    @State private var autoDismissTask: Task<Void, Never>? = nil

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
                    autoDismissTask?.cancel()
                    HapticEngine.selection()
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
                    autoDismissTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_200_000_000)
                        if !Task.isCancelled {
                            onDismiss()
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: mode.icon)
                            .font(.system(size: 12, weight: .semibold))
                        Text(mode.label)
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(currentMode == mode ? Color.white : Color.inkSecondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(
                        currentMode == mode
                            ? AnyShapeStyle(Color.inkOrange)
                            : AnyShapeStyle(Color.primary.opacity(0.06)),
                        in: Capsule()
                    )
                    .overlay(
                        Capsule()
                            .stroke(Color.primary.opacity(currentMode == mode ? 0 : 0.08), lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.inkSurfaceRaised.opacity(0.92))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        )
        .inkSpecularBorder(cornerRadius: 22)
        .shadow(color: .black.opacity(0.25), radius: 18, y: 6)
        .padding(.horizontal, 32)
        .padding(.bottom, 100)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .onAppear {
            autoDismissTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if !Task.isCancelled {
                    onDismiss()
                }
            }
        }
        .onDisappear {
            autoDismissTask?.cancel()
        }
    }
}
