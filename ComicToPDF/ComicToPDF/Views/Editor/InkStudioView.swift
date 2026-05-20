import SwiftUI
import SwiftData

// MARK: - Studio Mode

enum StudioMode: String, CaseIterable {
    case reading  = "Reading"
    case research = "Research"
    case writing  = "Writing"

    var icon: String {
        switch self {
        case .reading:  return "book"
        case .research: return "text.badge.star"
        case .writing:  return "note.text"
        }
    }
    var activeIcon: String {
        switch self {
        case .reading:  return "book.fill"
        case .research: return "text.badge.star"
        case .writing:  return "note.text.badge.plus"
        }
    }
    // Accent colour matching each section's existing design language
    var tint: Color {
        switch self {
        case .reading:  return Color.inkAmber
        case .research: return Color(hex: "#7B5EA7")  // Zettelkasten violet
        case .writing:  return Color.inkAccentKnowledge
        }
    }
}

// MARK: - Ink Studio View

/// Unified creative-work hub that merges the Reading (Active Reader), Research (Zettelkasten / Highlights)
/// and Writing (Manuscript Studio) experiences into one cohesive tab.
///
/// Architecture:
///  - A thin shell with a frosted segmented picker at the top.
///  - Both child views are kept **live in the hierarchy** using `.studioVisible()`
///    so no scroll position or navigation state is lost on segment switch.
///  - Zero changes to the underlying views — they are inserted as-is.
struct InkStudioView: View {
    @State private var mode: StudioMode = .reading
    @Query private var allAnnotations: [SDAnnotation]

    var body: some View {
        VStack(spacing: 0) {

            // ── Frosted Segmented Picker ──────────────────────────────────
            studioSegmentPicker
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 10)

            Divider()
                .background(Color.inkBorderVisible)

            // ── Content — all views stay alive ──────────────────────────
            ZStack {
                // Reading segment (Active Reader Dashboard)
                ActiveReaderDashboardView()
                    .studioVisible(mode == .reading)

                // Research segment (Zettelkasten Hub)
                GlobalZettelkastenHubView()
                    .studioVisible(mode == .research)

                // Writing segment (Manuscript Projects)
                ManuscriptProjectsListView()
                    .studioVisible(mode == .writing)
            }
        }
        .background(Color.clear)
    }

    // MARK: - Segment Picker

    private var studioSegmentPicker: some View {
        HStack(spacing: 6) {
            ForEach(StudioMode.allCases, id: \.self) { segment in
                segmentPill(segment)
            }
        }
    }

    @ViewBuilder
    private func segmentPill(_ segment: StudioMode) -> some View {
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

                // Badge: annotation count on Research, nothing on Writing
                if segment == .research && allAnnotations.count > 0 {
                    Text("\(allAnnotations.count)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(isActive ? segment.tint : .white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            isActive
                                ? Color.white.opacity(0.25)
                                : segment.tint.opacity(0.8),
                            in: Capsule()
                        )
                }
            }
            .foregroundStyle(isActive ? .white : Color.inkTextSecondary)
            .padding(.horizontal, 20)
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

// MARK: - Visibility Helper (mirrors tabVisible in InkTabBar)

private extension View {
    /// Keeps a view live in the hierarchy but visually hidden and non-interactive
    /// when `isVisible` is false — preserving all navigation and scroll state.
    @ViewBuilder
    func studioVisible(_ isVisible: Bool) -> some View {
        self
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(isVisible ? 1 : 0)
            .allowsHitTesting(isVisible)
            .accessibilityHidden(!isVisible)
    }
}
