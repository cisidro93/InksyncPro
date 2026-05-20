import SwiftUI

// ============================================================================
// ContentShelfSelector
// ============================================================================
// Apple Books-style shelf tab strip — All / Comics / Manga / Books.
// Each tab shows: icon + label + live item count badge.
// Selected tab has a filled background in the shelf's accent color.
// Selection is spring-animated and persisted across launches.
// ============================================================================

struct ContentShelfSelector: View {
    @Binding var selected: ContentShelf
    let counts: [ContentShelf: Int]

    @Environment(\.horizontalSizeClass) private var hSizeClass

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ContentShelf.allCases) { shelf in
                    ShelfTab(
                        shelf: shelf,
                        count: counts[shelf] ?? 0,
                        isSelected: selected == shelf
                    ) {
                        selected = shelf
                    }
                }
            }
            .padding(.horizontal, hSizeClass == .regular ? 20 : 16)
            .padding(.vertical, 4)
        }
    }
}

// MARK: - Individual Tab

private struct ShelfTab: View {
    let shelf: ContentShelf
    let count: Int
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 7) {
                Image(systemName: shelf.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isSelected ? .white : shelf.accentColor)

                Text(shelf.rawValue)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(isSelected ? .white : Theme.text)

                // Count badge — only when there's content and not "All"
                if shelf != .all && count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundColor(isSelected ? shelf.accentColor : .white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            isSelected
                                ? Color.white.opacity(0.25)
                                : shelf.accentColor.opacity(0.85),
                            in: Capsule()
                        )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background {
                if isSelected {
                    Capsule()
                        .fill(shelf.accentColor.gradient)
                        .shadow(color: shelf.accentColor.opacity(0.4), radius: 8, y: 3)
                } else {
                    Capsule()
                        .fill(.ultraThinMaterial)
                        .overlay(Capsule().stroke(shelf.accentColor.opacity(0.2), lineWidth: 0.5))
                }
            }
        }
        .buttonStyle(ShelfTabButtonStyle(isSelected: isSelected))
    }
}

private struct ShelfTabButtonStyle: ButtonStyle {
    let isSelected: Bool
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
            .animation(.spring(response: 0.32, dampingFraction: 0.75), value: isSelected)
    }
}
