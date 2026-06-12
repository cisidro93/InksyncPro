import SwiftUI

/// A high-performance, dynamic neural mesh gradient view.
/// Animates multiple blurred, overlapping color blobs to create a breathing "AI aura" background.
struct NeuralExpressiveBackground: View {
    @State private var animate = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Base background color
                Color.inkBackground

                // Aura Blob 1: Cobalt Blue
                Circle()
                    .fill(Color.inkBlue.opacity(0.18))
                    .frame(width: geo.size.width * 0.7, height: geo.size.width * 0.7)
                    .offset(
                        x: animate ? -geo.size.width * 0.15 : -geo.size.width * 0.35,
                        y: animate ? -geo.size.height * 0.1 : -geo.size.height * 0.25
                    )

                // Aura Blob 2: Deep Violet
                Circle()
                    .fill(Color.inkViolet.opacity(0.18))
                    .frame(width: geo.size.width * 0.8, height: geo.size.width * 0.8)
                    .offset(
                        x: animate ? geo.size.width * 0.2 : geo.size.width * 0.05,
                        y: animate ? geo.size.height * 0.15 : -geo.size.height * 0.05
                    )

                // Aura Blob 3: Electric Cyan (Vibrant Accent)
                Circle()
                    .fill(Color(hex: "#00d2ff").opacity(0.12))
                    .frame(width: geo.size.width * 0.5, height: geo.size.width * 0.5)
                    .offset(
                        x: animate ? -geo.size.width * 0.1 : geo.size.width * 0.15,
                        y: animate ? geo.size.height * 0.2 : geo.size.height * 0.05
                    )
            }
            .blur(radius: 64)
            .drawingGroup() // Optimises rendering on iOS GPUs
            .onAppear {
                withAnimation(
                    .easeInOut(duration: 8.0)
                    .repeatForever(autoreverses: true)
                ) {
                    animate = true
                }
            }
        }
        .ignoresSafeArea()
    }
}

/// Dynamic neural glow border modifier for text inputs and focused active cards.
struct NeuralGlowBorder: ViewModifier {
    let isActive: Bool
    @State private var phase: Double = 0.0

    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [Color.inkBlue, Color.inkViolet, Color(hex: "#00d2ff"), Color.inkBlue],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: isActive ? 1.5 : 1.0
                    )
                    .opacity(isActive ? 1.0 : 0.0)
            )
            .shadow(
                color: Color.inkBlue.opacity(isActive ? 0.25 : 0.0),
                radius: isActive ? 8 : 0,
                x: 0, y: 0
            )
    }
}

extension View {
    /// Applies a neural glowing border to a card or input element when active.
    func neuralGlowBorder(isActive: Bool) -> some View {
        self.modifier(NeuralGlowBorder(isActive: isActive))
    }
}
