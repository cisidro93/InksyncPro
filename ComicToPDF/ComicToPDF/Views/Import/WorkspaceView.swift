import SwiftUI

enum WorkspaceMode: String, CaseIterable {
    case inbox = "Inbox"
    case convert = "Convert"

    var icon: String {
        switch self {
        case .inbox: return "tray"
        case .convert: return "arrow.triangle.2.circlepath"
        }
    }
    var activeIcon: String {
        switch self {
        case .inbox: return "tray.fill"
        case .convert: return "arrow.triangle.2.circlepath.circle.fill"
        }
    }
    var tint: Color {
        switch self {
        case .inbox: return Color.inkAmber
        case .convert: return Color.inkBlue
        }
    }
}

struct WorkspaceView: View {
    @State private var mode: WorkspaceMode = .inbox
    @EnvironmentObject var conversionManager: ConversionManager
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // ── Frosted Segmented Picker ──────────────────────────────────
                workspaceSegmentPicker
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 10)

                Divider()
                    .background(Color.inkBorderVisible)

                // ── Content — all views stay alive ────────────────────────────
                ZStack {
                    InboxReviewView()
                        .workspaceVisible(mode == .inbox)

                    GoConvertView()
                        .workspaceVisible(mode == .convert)
                }
            }
            .background(Color.clear)
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .bold()
                }
            }
        }
    }

    private var navigationTitle: String {
        switch mode {
        case .inbox: return "Inbox Review"
        case .convert: return "Go Convert"
        }
    }

    private var workspaceSegmentPicker: some View {
        HStack(spacing: 6) {
            ForEach(WorkspaceMode.allCases, id: \.self) { segment in
                segmentPill(segment)
            }
        }
    }

    @ViewBuilder
    private func segmentPill(_ segment: WorkspaceMode) -> some View {
        let isActive = mode == segment

        Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                mode = segment
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: isActive ? segment.activeIcon : segment.icon)
                    .font(.system(size: 13, weight: .semibold))
                Text(segment.rawValue)
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(isActive ? .white : Color.inkTextSecondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(
                isActive
                    ? AnyShapeStyle(
                        LinearGradient(
                            colors: [segment.tint, segment.tint.opacity(0.75)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                      )
                    : AnyShapeStyle(.regularMaterial),
                in: Capsule()
            )
            .overlay(
                Capsule().stroke(
                    isActive
                        ? Color.clear
                        : Color.inkBorderVisible.opacity(0.5),
                    lineWidth: 0.75
                )
            )
            .shadow(
                color: isActive ? segment.tint.opacity(0.35) : .clear,
                radius: 8, y: 3
            )
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: mode)
    }
}

private extension View {
    @ViewBuilder
    func workspaceVisible(_ isVisible: Bool) -> some View {
        self
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(isVisible ? 1 : 0)
            .allowsHitTesting(isVisible)
            .accessibilityHidden(!isVisible)
    }
}
