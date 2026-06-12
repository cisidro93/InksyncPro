import SwiftUI

struct ShelfLineView: View {
    let accentColor: Color
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        ZStack {
            // The shelf platform surface (projecting forward)
            UnevenRoundedRectangle(
                topLeadingRadius: 4,
                bottomLeadingRadius: 1,
                bottomTrailingRadius: 1,
                topTrailingRadius: 4,
                style: .continuous
            )
            .fill(
                LinearGradient(
                    colors: [
                        Color.white.opacity(colorScheme == .dark ? 0.08 : 0.25),
                        Color.black.opacity(colorScheme == .dark ? 0.35 : 0.08)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .background(.ultraThinMaterial)
            .frame(height: 8)
            .overlay(
                // Top highlight edge
                VStack {
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [accentColor.opacity(0.6), accentColor.opacity(0.2), .clear],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(height: 1)
                    Spacer()
                }
            )
            
            // Outer shadow below the shelf
            VStack {
                Spacer().frame(height: 8)
                LinearGradient(
                    colors: [.black.opacity(0.35), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 6)
            }
        }
        .padding(.horizontal, 4)
    }
}
