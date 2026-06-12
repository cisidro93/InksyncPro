import SwiftUI

/// An accessibility tool that dims the screen except for a focused reading window.
/// The user can drag the window up and down to isolate lines of text.
struct ReadingRulerOverlay: View {
    @ObservedObject var prefs = EBookPreferences.shared
    @Environment(\.colorScheme) var colorScheme
    
    @State private var dragOffset: CGFloat = 0
    
    var body: some View {
        GeometryReader { geo in
            let windowHeight: CGFloat = 120 // The clear reading window
            let yPos = (geo.size.height * prefs.rulerYPosition) + dragOffset
            
            // Constrain the yPos to stay within the screen bounds
            let safeY = max(windowHeight / 2, min(geo.size.height - (windowHeight / 2), yPos))
            
            ZStack {
                // Top dimmed area
                Rectangle()
                    .fill(Color.black.opacity(0.35))
                    .frame(height: safeY - (windowHeight / 2))
                    .frame(maxWidth: .infinity)
                    .position(x: geo.size.width / 2, y: (safeY - (windowHeight / 2)) / 2)
                    .allowsHitTesting(false)
                    
                // Bottom dimmed area
                Rectangle()
                    .fill(Color.black.opacity(0.35))
                    .frame(height: geo.size.height - (safeY + (windowHeight / 2)))
                    .frame(maxWidth: .infinity)
                    .position(
                        x: geo.size.width / 2,
                        y: safeY + (windowHeight / 2) + ((geo.size.height - (safeY + (windowHeight / 2))) / 2)
                    )
                    .allowsHitTesting(false)
                
                // The reading window borders (top and bottom lines)
                VStack(spacing: windowHeight) {
                    Rectangle()
                        .fill(prefs.activeTheme.accent)
                        .frame(height: 2)
                        .shadow(color: prefs.activeTheme.accent.opacity(0.5), radius: 4, y: 0)
                    Rectangle()
                        .fill(prefs.activeTheme.accent)
                        .frame(height: 2)
                        .shadow(color: prefs.activeTheme.accent.opacity(0.5), radius: 4, y: 0)
                }
                .position(x: geo.size.width / 2, y: safeY)
                
                // Drag handle and hit target
                Rectangle()
                    .fill(Color.white.opacity(0.01)) // Invisible hit target
                    .frame(height: windowHeight + 40) // Generous hit area
                    .position(x: geo.size.width / 2, y: safeY)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                self.dragOffset = value.translation.height
                            }
                            .onEnded { value in
                                // Calculate the new fractional Y position and save it
                                let newY = (geo.size.height * prefs.rulerYPosition) + value.translation.height
                                let safeNewY = max(windowHeight / 2, min(geo.size.height - (windowHeight / 2), newY))
                                
                                prefs.rulerYPosition = safeNewY / geo.size.height
                                self.dragOffset = 0
                            }
                    )
            }
        }
        .ignoresSafeArea()

    }
}
