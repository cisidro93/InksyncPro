import SwiftUI

struct OnboardingSlideView: View {
    let icon: String
    let title: String
    let headline: String
    let description: String
    let colors: [Color]
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
            
            // Hero Icon
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: isPad ? 240 : 140, height: isPad ? 240 : 140)
                    .blur(radius: isPad ? 40 : 20)
                    .opacity(isVisible ? 0.6 : 0)
                
                Image(systemName: icon)
                    .font(.system(size: isPad ? 110 : 70, weight: .light))
                    .foregroundStyle(LinearGradient(colors: [.white, colors.first ?? .white], startPoint: .top, endPoint: .bottom))
                    .shadow(color: colors.last?.opacity(0.5) ?? .clear, radius: 10, y: 5)
                    .scaleEffect(isVisible ? 1 : 0.5)
                    .opacity(isVisible ? 1 : 0)
            }
            .padding(.bottom, 20)
            
            // Typography
            VStack(spacing: isPad ? 24 : 16) {
                Text(title)
                    .font(.system(size: isPad ? 18 : 14, weight: .bold, design: .rounded))
                    .tracking(2)
                    .foregroundColor(colors.first)
                    .textCase(.uppercase)
                    .offset(y: isVisible ? 0 : 20)
                    .opacity(isVisible ? 1 : 0)
                
                Text(headline)
                    .font(.system(size: isPad ? 56 : 34, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .foregroundColor(.white)
                    .offset(y: isVisible ? 0 : 20)
                    .opacity(isVisible ? 1 : 0)
                
                Text(description)
                    .font(.system(size: isPad ? 24 : 16, weight: .regular, design: .rounded))
                    .multilineTextAlignment(.center)
                    .foregroundColor(Theme.textSecondary)
                    .padding(.horizontal, isPad ? 80 : 32)
                    .lineSpacing(isPad ? 8 : 4)
                    .offset(y: isVisible ? 0 : 20)
                    .opacity(isVisible ? 1 : 0)
            }
            
            Spacer()
        }
        .padding()
        .onChange(of: currentIndex) {
            if currentIndex == index {
                withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
                    isVisible = true
                }
            } else {
                isVisible = false
            }
        }
        .onAppear {
            if currentIndex == index {
                withAnimation(.spring(response: 0.6, dampingFraction: 0.8).delay(0.2)) {
                    isVisible = true
                }
            }
        }
    }
}

struct PremiumCTAButton: View {
    let title: String
    let icon: String?
    let colors: [Color]
    let action: () -> Void
    @Environment(\.horizontalSizeClass) var sizeClass
    
    private var isPad: Bool {
        sizeClass == .regular || UIDevice.current.userInterfaceIdiom == .pad
    }
    
    var body: some View {
        Button(action: {
            let generator = UIImpactFeedbackGenerator(style: .medium)
            generator.impactOccurred()
            action()
        }) {
            HStack(spacing: isPad ? 12 : 8) {
                Text(title)
                    .font(.system(size: isPad ? 22 : 18, weight: .bold, design: .rounded))
                if let ic = icon {
                    Image(systemName: ic)
                        .font(.system(size: isPad ? 22 : 18, weight: .bold))
                }
            }
            .foregroundColor(.white)
            .frame(maxWidth: isPad ? 400 : .infinity)
            .frame(height: isPad ? 68 : 56)
            .background(
                LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
            )
            .cornerRadius(16)
            .shadow(color: colors.first?.opacity(0.4) ?? .clear, radius: 10, y: 5)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.white.opacity(0.2), lineWidth: 1)
            )
        }
        .padding(.horizontal, 32)
    }
}
