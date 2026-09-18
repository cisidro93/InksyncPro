import SwiftUI

/// Floating glassmorphic HUD pill anchored directly above a selected comic panel.
/// Offers instant 1-tap actions: Auto-Split along detected internal gutters,
/// Merge with neighboring panel, or Delete.
struct PanelQuickActionHUDView: View {
    let panelIndex: Int
    let panelRect: CGRect
    let displayedRect: CGRect
    let canMerge: Bool
    let onSplit: () -> Void
    let onMerge: () -> Void
    let onDelete: () -> Void

    var body: some View {
        let hudX = min(max(displayedRect.minX + 110, panelRect.midX), displayedRect.maxX - 110)
        let prefersAbove = (panelRect.minY - 36) >= (displayedRect.minY + 16)
        let hudY = prefersAbove ? (panelRect.minY - 28) : min(displayedRect.maxY - 30, panelRect.minY + 28)

        HStack(spacing: 8) {
            // Panel Badge
            Text("#\(panelIndex + 1)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.8))
                .padding(.leading, 4)

            Divider()
                .frame(height: 14)
                .background(Color.white.opacity(0.3))

            // 1-Tap Auto-Split Button
            Button(action: onSplit) {
                HStack(spacing: 4) {
                    Image(systemName: "scissors")
                        .font(.system(size: 11, weight: .bold))
                    Text("Split")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(Color.blue.opacity(0.65))
                )
            }
            .buttonStyle(.plain)

            // Merge Button
            if canMerge {
                Button(action: onMerge) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.merge")
                            .font(.system(size: 11, weight: .bold))
                        Text("Merge")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        Capsule()
                            .fill(Color.purple.opacity(0.65))
                    )
                }
                .buttonStyle(.plain)
            }

            // Delete Button
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(hex: "#FF6B6B"))
                    .padding(6)
                    .background(
                        Circle()
                            .fill(Color.red.opacity(0.2))
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
        )
        .overlay(
            Capsule()
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.35), Color.white.opacity(0.1)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: Color.black.opacity(0.4), radius: 8, x: 0, y: 4)
        .position(x: hudX, y: hudY)
        .transition(.scale(scale: 0.85).combined(with: .opacity))
        .zIndex(100)
    }
}
