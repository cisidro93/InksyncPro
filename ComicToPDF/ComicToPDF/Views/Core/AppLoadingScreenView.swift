import SwiftUI

struct AppLoadingScreenView: View {
    @Binding var isAppLoading: Bool
    
    @State private var textOpacity: Double = 0.0
    @State private var textOffset: CGFloat = 20
    @State private var ambientScale: CGFloat = 0.8
    @State private var ambientOpacity: Double = 0.3
    @State private var loadingStatus = "Initializing library workspace..."
    
    var body: some View {
        ZStack {
            // 1. Shimmering Skeleton View underneath (blurred during load)
            LibrarySkeletonView()
                .blur(radius: isAppLoading ? 10 : 0)
                .opacity(isAppLoading ? 0.3 : 1.0)
            
            // 2. Velvet Dark Overlay (Fades out when loaded)
            if isAppLoading {
                Color(hex: "#0e0e13")
                    .opacity(0.85)
                    .ignoresSafeArea()
                    .transition(.opacity)
                
                // Glowing ambient backdrops
                RadialGradient(
                    colors: [Color.orange.opacity(0.12), Color.clear],
                    center: .center,
                    startRadius: 0,
                    endRadius: 280
                )
                .scaleEffect(ambientScale)
                .opacity(ambientOpacity)
                .ignoresSafeArea()
                .transition(.opacity)
                
                VStack(spacing: 24) {
                    // Spacer to push branding down, leaving top space for the breathing logo
                    Spacer().frame(height: 160)
                    
                    // Brand text & dynamic logs
                    VStack(spacing: 6) {
                        Text("INKSYNC PRO")
                            .font(.system(size: 22, weight: .black, design: .rounded))
                            .tracking(4)
                            .foregroundColor(.white)
                        
                        Text("Your Personal Library Engine")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.4))
                        
                        Text(loadingStatus)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(.gray)
                            .padding(.top, 8)
                    }
                    .opacity(textOpacity)
                    .offset(y: textOffset)
                    
                    Spacer()
                    
                    // Build identification badge for instant test verification
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 6, height: 6)
                        Text(AppBuildInfo.formattedBadge)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.6))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(.ultraThinMaterial)
                            .overlay(
                                Capsule()
                                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
                            )
                    )
                    .opacity(textOpacity)
                    .padding(.bottom, 28)
                }
                .transition(.opacity)
            }
        }
        .onAppear {
            // Status logs updates:
            loadingStatus = "Scanning local storage directories..."
            
            withAnimation(.easeInOut(duration: 0.8)) {
                ambientScale = 1.1
                ambientOpacity = 0.4
                textOpacity = 1.0
                textOffset = 0
            }
            
            Task {
                try? await Task.sleep(for: .seconds(0.6))
                loadingStatus = "Resolving books, comics and manga..."
                
                try? await Task.sleep(for: .seconds(0.5))
                loadingStatus = "Prewarming page highlights indexes..."
                
                try? await Task.sleep(for: .seconds(0.5))
                loadingStatus = "Initializing workspace Hand-off..."
                
                try? await Task.sleep(for: .seconds(0.4))
                loadingStatus = "Optimizing database indexes..."
                
                try? await Task.sleep(for: .seconds(0.3))
                loadingStatus = "Launching InkSync engine..."
            }
        }
    }
}
