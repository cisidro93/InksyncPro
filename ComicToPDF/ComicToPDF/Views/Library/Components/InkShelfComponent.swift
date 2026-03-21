import SwiftUI
import UniformTypeIdentifiers

struct InkShelfComponent: View {
    @Binding var isVisible: Bool
    @State private var shelfItems: [String] = [] // Will store UUID strings of Transferable models
    @Namespace private var shelfSpace
    
    var body: some View {
        VStack {
            Spacer()
            
            if isVisible {
                HStack(spacing: 12) {
                    if shelfItems.isEmpty {
                        Text("Drag items here to save to your local shelf...")
                            .foregroundColor(.white.opacity(0.6))
                            .font(.subheadline)
                            .padding()
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(shelfItems, id: \.self) { item in
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(.ultraThinMaterial)
                                        .frame(width: 80, height: 110)
                                        .overlay(
                                            Image(systemName: "book.closed")
                                                .foregroundColor(.white)
                                        )
                                        // ✅ iOS 18: Geometry Group for smooth structural animations
                                        .geometryGroup()
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                }
                .frame(height: 140)
                .frame(maxWidth: .infinity)
                // ✅ iOS 18 MeshGradient background for Liquid Glass aesthetic
                .background(
                    MeshGradient(
                        width: 3,
                        height: 3,
                        points: [
                            [0.0, 0.0], [0.5, 0.0], [1.0, 0.0],
                            [0.0, 0.5], [0.5, 0.5], [1.0, 0.5],
                            [0.0, 1.0], [0.5, 1.0], [1.0, 1.0]
                        ],
                        colors: [
                            .black.opacity(0.8), .purple.opacity(0.4), .black.opacity(0.8),
                            .blue.opacity(0.3), .black.opacity(0.9), .blue.opacity(0.3),
                            .black.opacity(0.8), .purple.opacity(0.4), .black.opacity(0.8)
                        ]
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .shadow(color: .black.opacity(0.5), radius: 20, y: 10)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.white.opacity(0.2), lineWidth: 1)
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 32) // Clears the home indicator
                .transition(.move(edge: .bottom).combined(with: .opacity))
                // ✅ iOS 16+ Drop Destination with Transferable
                .dropDestination(for: String.self) { items, location in
                    Haptics.shared.playImpact(style: .heavy)
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                        for item in items {
                            if !shelfItems.contains(item) {
                                shelfItems.append(item)
                            }
                        }
                    }
                    return true
                }
            }
        }
        .ignoresSafeArea(.all, edges: .bottom)
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: isVisible)
    }
}
