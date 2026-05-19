import SwiftUI

// MARK: - Reading Ruler Overlay
// A draggable horizontal guide line that spans the reader width.
// Helps readers track their current line, especially useful for dyslexia.

struct ReadingRulerOverlay: View {
    @ObservedObject private var prefs = EBookPreferences.shared
    @State private var isDragging = false

    private var rulerColor: Color {
        prefs.activeTheme.accent.opacity(isDragging ? 0.5 : 0.3)
    }

    var body: some View {
        GeometryReader { geo in
            let yPos = prefs.rulerYPosition * geo.size.height

            ZStack(alignment: .leading) {
                // Shadow line for contrast on light backgrounds
                Capsule()
                    .fill(Color.black.opacity(0.06))
                    .frame(height: 3)
                    .offset(y: 1.5)

                // Main ruler line
                Capsule()
                    .fill(rulerColor)
                    .frame(height: isDragging ? 4 : 2.5)
                    .animation(.spring(response: 0.2), value: isDragging)

                // Drag handle — left edge
                Circle()
                    .fill(prefs.activeTheme.accent)
                    .frame(width: isDragging ? 18 : 14, height: isDragging ? 18 : 14)
                    .shadow(color: prefs.activeTheme.accent.opacity(0.4), radius: 4, y: 2)
                    .offset(x: -7)
                    .animation(.spring(response: 0.2), value: isDragging)
            }
            .frame(maxWidth: .infinity)
            .position(x: geo.size.width / 2, y: yPos)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        isDragging = true
                        let newY = (value.location.y / geo.size.height)
                            .clamped(to: 0.05...0.95)
                        prefs.rulerYPosition = newY
                    }
                    .onEnded { _ in
                        isDragging = false
                        HapticEngine.selection()
                    }
            )
        }
        .allowsHitTesting(prefs.showReadingRuler)
        .ignoresSafeArea()
    }
}

// MARK: - Comparable clamp helper (if not already in project)
private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
