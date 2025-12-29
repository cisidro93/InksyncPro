import SwiftUI

struct SplashScreenView: View {
    @State private var isActive = false
    @State private var logoScale: CGFloat = 0.8
    @State private var logoOpacity: Double = 0
    
    // Environment object to pass down
    @EnvironmentObject var conversionManager: ConversionManager
    
    var body: some View {
        if isActive {
            ContentView()
        } else {
            ZStack {
                // Background gradient
                LinearGradient(
                    colors: [
                        Color(red: 24/255, green: 24/255, blue: 27/255),
                        Color(red: 39/255, green: 39/255, blue: 42/255)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
                
                VStack(spacing: 24) {
                    // Animated logo
                    AppLogoAnimated(size: 140)
                        .scaleEffect(logoScale)
                        .opacity(logoOpacity)
                    
                    // App name
                    Text("ComicToPDF")
                        .font(.title)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                        .opacity(logoOpacity)
                }
            }
            .onAppear {
                withAnimation(.easeOut(duration: 0.6)) {
                    logoScale = 1.0
                    logoOpacity = 1.0
                }
                
                // Transition to main app after delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        isActive = true
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
