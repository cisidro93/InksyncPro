import SwiftUI

// ============================================================================
// LibraryFilterChipBar
// ============================================================================
// Interactive, glassmorphic horizontal filter bar for Library items.
// Allows instantaneous filtering by reading state (Unread, Reading, Completed)
// and storage location (On Drive, Cloud) with zero-delay responsive feedback.
// ============================================================================

struct LibraryFilterChipBar: View {
    @Binding var selectedFilter: LibraryFilterState
    let counts: [LibraryFilterState: Int]

    @Environment(\.horizontalSizeClass) private var hSizeClass

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(LibraryFilterState.allCases) { filter in
                    FilterChip(
                        filter: filter,
                        count: counts[filter] ?? 0,
                        isSelected: selectedFilter == filter
                    ) {
                        HapticEngine.selection()
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                            selectedFilter = filter
                        }
                    }
                }

                if selectedFilter != .all {
                    Button(action: {
                        HapticEngine.selection()
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                            selectedFilter = .all
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11, weight: .bold))
                            Text("Clear")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                        }
                        .foregroundColor(Color.inkSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                    }
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, hSizeClass == .regular ? 24 : 16)
            .padding(.vertical, 2)
        }
    }
}

// MARK: - Individual Filter Chip

private struct FilterChip: View {
    let filter: LibraryFilterState
    let count: Int
    let isSelected: Bool
    let onTap: () -> Void

    private var chipColor: Color {
        switch filter {
        case .all: return Color.inkBlue
        case .unread: return Color(hex: "#3b82f6")
        case .reading: return Color(hex: "#f59e0b")
        case .completed: return Color(hex: "#10b981")
        case .onDrive: return Color(hex: "#8b5cf6")
        case .cloudLibrary: return Color(hex: "#06b6d4")
        }
    }

    private var filterIcon: String {
        switch filter {
        case .all: return "line.3.horizontal.decrease.circle"
        case .unread: return "circle"
        case .reading: return "circle.lefthalf.filled"
        case .completed: return "checkmark.circle.fill"
        case .onDrive: return "externaldrive.fill"
        case .cloudLibrary: return "icloud.fill"
        }
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Image(systemName: filterIcon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isSelected ? .white : chipColor)

                Text(filter.rawValue)
                    .font(.system(size: 12, weight: isSelected ? .bold : .medium, design: .rounded))
                    .foregroundColor(isSelected ? .white : Color.inkTextPrimary)

                if count >= 1 { // swiftlint:disable:this empty_count
                    Text("\(count)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(isSelected ? chipColor : Color.inkSecondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(
                            isSelected ? Color.white.opacity(0.9) : Color.primary.opacity(0.07),
                            in: Capsule()
                        )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background {
                if isSelected {
                    Capsule()
                        .fill(chipColor.gradient)
                        .shadow(color: chipColor.opacity(0.35), radius: 6, y: 2)
                } else {
                    Capsule()
                        .fill(.ultraThinMaterial)
                        .overlay(Capsule().stroke(Color.inkBorderSubtle, lineWidth: 0.5))
                }
            }
        }
        .buttonStyle(FilterChipButtonStyle(isSelected: isSelected))
    }
}

private struct FilterChipButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
            .animation(.spring(response: 0.28, dampingFraction: 0.78), value: isSelected)
    }
}
