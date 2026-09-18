import SwiftUI

/// A precision 2.5x magnifier reticle that floats above the touch location.
/// Solves thumb occlusion during panel edge adjustments by projecting
/// an unobstructed view of the ink border directly into a glassmorphic circular HUD.
struct MagnifierLoupeView: View {
    let image: UIImage
    let touchPoint: CGPoint // Point in displayedRect space
    let displayedRect: CGRect
    var isSnapped: Bool = false

    private let loupeDiameter: CGFloat = 104
    private let zoomFactor: CGFloat = 2.4

    var body: some View {
        let radius = loupeDiameter / 2.0
        // Clamp loupe position so it never overflows screen bounds
        let loupeX = min(max(displayedRect.minX + radius + 12, touchPoint.x), displayedRect.maxX - radius - 12)
        // Position 75pt above the touch point (or below if touching near top margin)
        let prefersAbove = (touchPoint.y - 80) >= (displayedRect.minY + radius)
        let loupeY = prefersAbove ? (touchPoint.y - 78) : (touchPoint.y + 78)

        ZStack {
            // 1. Zoomed Sub-Region of Page
            magnifiedImageView
                .frame(width: loupeDiameter, height: loupeDiameter)
                .clipShape(Circle())

            // 2. Reticle Hairline Crosshairs (Center Guide)
            reticleCrosshairs

            // 3. Central Target Dot
            Circle()
                .fill(isSnapped ? Color.cyan : Color.yellow)
                .frame(width: 4.5, height: 4.5)
                .shadow(color: .black.opacity(0.8), radius: 1)

            // 4. Snapped Feedback Ring
            if isSnapped {
                Circle()
                    .strokeBorder(Color.cyan.opacity(0.8), lineWidth: 2)
                    .frame(width: loupeDiameter, height: loupeDiameter)
            }

            // 5. Outer Glassmorphic Bezel
            Circle()
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.85),
                            Color.white.opacity(0.25)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 2.5
                )
                .frame(width: loupeDiameter, height: loupeDiameter)
                .shadow(color: Color.black.opacity(0.5), radius: 10, x: 0, y: 5)
        }
        .position(x: loupeX, y: loupeY)
        .transition(.scale(scale: 0.85).combined(with: .opacity))
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var magnifiedImageView: some View {
        let radius = loupeDiameter / 2.0
        let relX = touchPoint.x - displayedRect.minX
        let relY = touchPoint.y - displayedRect.minY
        let scaledW = displayedRect.width * zoomFactor
        let scaledH = displayedRect.height * zoomFactor
        let centerX = radius - (relX * zoomFactor) + (scaledW / 2.0)
        let centerY = radius - (relY * zoomFactor) + (scaledH / 2.0)

        GeometryReader { _ in
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: scaledW, height: scaledH)
                .position(x: centerX, y: centerY)
        }
    }

    @ViewBuilder
    private var reticleCrosshairs: some View {
        let mid = loupeDiameter / 2.0
        let armLength: CGFloat = 16.0
        Path { path in
            // Horizontal crosshair
            path.move(to: CGPoint(x: mid - armLength, y: mid))
            path.addLine(to: CGPoint(x: mid + armLength, y: mid))
            // Vertical crosshair
            path.move(to: CGPoint(x: mid, y: mid - armLength))
            path.addLine(to: CGPoint(x: mid, y: mid + armLength))
        }
        .stroke(isSnapped ? Color.cyan : Color.white.opacity(0.9), lineWidth: 1.5)
        .shadow(color: .black.opacity(0.7), radius: 2)
    }
}
