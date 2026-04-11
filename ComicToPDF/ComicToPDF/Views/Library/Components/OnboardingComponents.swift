import SwiftUI

struct OnboardingSlideView: View {
    let icon: String
    let title: String
    let headline: String
    let description: String
    let accentColor: Color
    let index: Int
    @Binding var currentIndex: Int
    @Environment(\.horizontalSizeClass) var sizeClass
    
    @State private var isVisible = false
    
    private var isPad: Bool {
        sizeClass == .regular || UIDevice.current.userInterfaceIdiom == .pad
    }
    
    var body: some View {
        VStack(spacing: isPad ? 50 : 30) {
            Spacer().frame(height: isPad ? 80 : 40)
            
            // MARK: Neo-Brutalist Icon Box
            ZStack {
                Rectangle()
                    .fill(Color(red: 0.1, green: 0.1, blue: 0.13))
                    .frame(width: isPad ? 200 : 120, height: isPad ? 200 : 120)
                    .border(accentColor, width: 4)
                    .shadow(color: accentColor.opacity(0.8), radius: 0, x: 8, y: 8)
                    .rotationEffect(.degrees(isVisible ? 0 : -10))
                
                Image(systemName: icon)
                    .font(.system(size: isPad ? 90 : 50, weight: .bold))
                    .foregroundColor(accentColor)
                    .scaleEffect(isVisible ? 1 : 0.5)
            }
            .padding(.bottom, 20)
            .opacity(isVisible ? 1 : 0)
            
            // MARK: Typography
            VStack(spacing: isPad ? 24 : 16) {
                Text(title)
                    .font(.system(size: isPad ? 18 : 14, weight: .black, design: .monospaced))
                    .tracking(4)
                    .foregroundColor(accentColor)
                    .background(accentColor.opacity(0.2))
                    .padding(.horizontal, 8)
                    .offset(x: isVisible ? 0 : -20)
                    .opacity(isVisible ? 1 : 0)
                
                Text(headline)
                    .font(.system(size: isPad ? 60 : 40, weight: .black, design: .default))
                    .multilineTextAlignment(.center)
                    .foregroundColor(.white)
                    .shadow(color: accentColor.opacity(0.5), radius: 0, x: 4, y: 4)
                    .offset(x: isVisible ? 0 : 20)
                    .opacity(isVisible ? 1 : 0)
                
                VStack {
                    Text(description)
                        .font(.system(size: isPad ? 20 : 14, weight: .medium, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .foregroundColor(.gray)
                        .lineSpacing(6)
                        .padding(20)
                }
                .border(Color.gray.opacity(0.3), width: 2)
                .background(Color.black.opacity(0.5))
                .padding(.horizontal, isPad ? 100 : 40)
                .offset(y: isVisible ? 0 : 20)
                .opacity(isVisible ? 1 : 0)
            }
            
            Spacer()
        }
        .padding()
        .onChange(of: currentIndex) {
            if currentIndex == index {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                    isVisible = true
                }
            } else {
                isVisible = false
            }
        }
        .onAppear {
            if currentIndex == index {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.7).delay(0.1)) {
                    isVisible = true
                }
            }
        }
    }
}

struct PremiumCTAButton: View {
    let title: String
    let icon: String?
    let accentColor: Color
    let action: () -> Void
    @Environment(\.horizontalSizeClass) var sizeClass
    
    private var isPad: Bool {
        sizeClass == .regular || UIDevice.current.userInterfaceIdiom == .pad
    }
    
    var body: some View {
        Button(action: {
            let generator = UIImpactFeedbackGenerator(style: .rigid)
            generator.impactOccurred()
            action()
        }) {
            HStack(spacing: isPad ? 12 : 8) {
                Text(title)
                    .font(.system(size: isPad ? 24 : 18, weight: .black, design: .monospaced))
                if let ic = icon {
                    Image(systemName: ic)
                        .font(.system(size: isPad ? 24 : 18, weight: .black))
                }
            }
            .foregroundColor(.black)
            .frame(maxWidth: isPad ? 400 : .infinity)
            .frame(height: isPad ? 68 : 56)
            .background(accentColor)
            .border(Color.white, width: 2)
            .shadow(color: accentColor.opacity(0.8), radius: 0, x: 6, y: 6)
        }
        .padding(.horizontal, 40)
    }
}
