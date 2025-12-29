import SwiftUI

struct SplashScreenView: View {
    @State private var isActive = false
    @State private var size: CGFloat = 0.8
    @State private var opacity: Double = 0.5
    
    // Environment object to pass down
    @EnvironmentObject var conversionManager: ConversionManager
    
    var body: some View {
        if isActive {
            ContentView()
        } else {
            ZStack {
                LinearGradient(
                    colors: [Color(.systemBackground), Color.orange.opacity(0.1)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
                
                VStack(spacing: 20) {
                    ZStack {
                        // Background glow
                        Circle()
                            .fill(Color.orange.opacity(0.2))
                            .frame(width: 150, height: 150)
                            .blur(radius: 20)
                        
                        Image(systemName: "book.closed.fill")
                            .font(.system(size: 80))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [.orange, .red],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    }
                    .scaleEffect(size)
                    .opacity(opacity)
                    
                    VStack(spacing: 5) {
                        Text("Comic to PDF")
                            .font(.title)
                            .fontWeight(.heavy)
                            .foregroundColor(.primary)
                        
                        Text("Optimized for Kindle")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .opacity(opacity)
                }
            }
            .onAppear {
                withAnimation(.easeIn(duration: 1.2)) {
                    self.size = 1.0
                    self.opacity = 1.0
                }
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    withAnimation {
                        self.isActive = true
                    }
                }
            }
        }
    }
}

#Preview {
    SplashScreenView()
        .environmentObject(ConversionManager())
}
