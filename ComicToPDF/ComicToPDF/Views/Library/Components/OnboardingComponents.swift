import SwiftUI

struct OnboardingSlideView: View {
    let icon: String
    let title: String
    let headline: String
    let description: String
    let colors: [Color]
    let index: Int
    @Binding var currentIndex: Int
    
    @State private var isVisible = false
    
    var body: some View {
        VStack(spacing: 30) {
            Spacer().frame(height: 40)
            
            // Hero Icon
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 140, height: 140)
                    .blur(radius: 20)
                    .opacity(isVisible ? 0.6 : 0)
                
                Image(systemName: icon)
                    .font(.system(size: 70, weight: .light))
                    .foregroundStyle(LinearGradient(colors: [.white, colors.first ?? .white], startPoint: .top, endPoint: .bottom))
                    .shadow(color: colors.last?.opacity(0.5) ?? .clear, radius: 10, y: 5)
                    .scaleEffect(isVisible ? 1 : 0.5)
                    .opacity(isVisible ? 1 : 0)
            }
            .padding(.bottom, 20)
            
            // Typography
            VStack(spacing: 16) {
                Text(title)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .tracking(2)
                    .foregroundColor(colors.first)
                    .textCase(.uppercase)
                    .offset(y: isVisible ? 0 : 20)
                    .opacity(isVisible ? 1 : 0)
                
                Text(headline)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .foregroundColor(.white)
                    .offset(y: isVisible ? 0 : 20)
                    .opacity(isVisible ? 1 : 0)
                
                Text(description)
                    .font(.system(size: 16, weight: .regular, design: .rounded))
                    .multilineTextAlignment(.center)
                    .foregroundColor(Theme.textSecondary)
                    .padding(.horizontal, 32)
                    .lineSpacing(4)
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
    
    var body: some View {
        Button(action: {
            let generator = UIImpactFeedbackGenerator(style: .medium)
            generator.impactOccurred()
            action()
        }) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                if let ic = icon {
                    Image(systemName: ic)
                        .font(.system(size: 18, weight: .bold))
                }
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
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
