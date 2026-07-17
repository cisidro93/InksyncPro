import SwiftUI

struct LibrarySkeletonView: View {
    var body: some View {
        VStack(spacing: 20) {
            // Simulated Top Navigation Bar
            HStack {
                // Spacer for the morphed logo (width matches the logo + padding)
                Spacer().frame(width: 48)
                
                // Search bar skeleton
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color.white.opacity(0.03))
                    .frame(width: 240, height: 36)
                    .shimmer()
                
                Spacer()
                
                // Settings/Filter button skeleton
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(0.03))
                    .frame(width: 36, height: 32)
                    .shimmer()
            }
            .padding(.top, 8)
            .padding(.horizontal, 16)
            
            // Category filter shelf skeleton
            HStack(spacing: 12) {
                ForEach(0..<4) { index in
                    Capsule()
                        .fill(Color.white.opacity(0.03))
                        .frame(width: index == 1 ? 110 : (index == 2 ? 70 : 80), height: 28)
                        .shimmer()
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            
            // Book cards grid skeleton
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 20) {
                    ForEach(0..<8) { _ in
                        VStack(alignment: .leading, spacing: 8) {
                            // Cover shape matching 2:3 book ratio
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.white.opacity(0.03))
                                .aspectRatio(2/3, contentMode: .fit)
                                .shimmer()
                            
                            // Title line placeholder
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.white.opacity(0.03))
                                .frame(width: 100, height: 12)
                                .shimmer()
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            .disabled(true) // Disable scroll interaction during loading
        }
        .background(Color(hex: "#0e0e13"))
    }
}

// MARK: - Shimmer Modifier for Premium Loading Feedback

struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = -1.0
    
    func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { geo in
                    LinearGradient(
                        colors: [Color.clear, Color.white.opacity(0.08), Color.clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .frame(width: geo.size.width * 2)
                    .offset(x: (phase * geo.size.width))
                }
            )
            .mask(content)
            .onAppear {
                withAnimation(.linear(duration: 1.8).repeatForever(autoreverses: false)) {
                    phase = 1.0
                }
            }
    }
}

extension View {
    func shimmer() -> some View {
        modifier(ShimmerModifier())
    }
}
