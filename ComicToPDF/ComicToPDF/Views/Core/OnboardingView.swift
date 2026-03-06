import SwiftUI

// MARK: - Onboarding Page Model
struct OnboardingPage: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let description: String
    let gradient: [Color]
}

// MARK: - Onboarding View
struct OnboardingView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var currentPage = 0
    @State private var isAnimating = false
    @State private var showingModeSelection = false
    @Binding var showOnboarding: Bool
    
    let pages: [OnboardingPage] = [
        OnboardingPage(
            icon: "book.pages",
            title: "Welcome to InkSync Pro",
            description: "Transform your CBZ comics into beautiful, Kindle-optimized EPUBs with industry-leading conversion quality.",
            gradient: [Color(red: 249/255, green: 115/255, blue: 22/255), Color(red: 194/255, green: 65/255, blue: 12/255)]
        ),
        OnboardingPage(
            icon: "rectangle.split.3x1",
            title: "Guided View for Kindle",
            description: "Enable panel-by-panel reading on your Kindle device. Perfect for enjoying comics with precise navigation through each frame.",
            gradient: [Color.blue, Color.cyan]
        ),
        OnboardingPage(
            icon: "arrow.left.arrow.right",
            title: "Manga Mode Support",
            description: "Full Right-to-Left reading support for manga. Page progression and panel order automatically optimized for authentic manga experience.",
            gradient: [Color.purple, Color.pink]
        ),
        OnboardingPage(
            icon: "icloud.and.arrow.up",
            title: "Quick Send to Kindle",
            description: "Easy delivery to your Kindle library via Send to Kindle. Share your converted files and they'll appear in your library within minutes.",
            gradient: [Color.green, Color.mint]
        ),
        OnboardingPage(
            icon: "sparkles",
            title: "Ready to Start",
            description: "Import your first comic and experience professional-grade conversion. Tap below to begin your journey!",
            gradient: [Color(red: 249/255, green: 115/255, blue: 22/255), Color.orange]
        )
    ]
    
    var body: some View {
        ZStack {
            if showingModeSelection {
                UIModeSelectionView(showOnboarding: $showOnboarding)
                    .transition(.move(edge: .trailing))
            } else {
                // Background Gradient
                LinearGradient(
                    colors: pages[currentPage].gradient,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.5), value: currentPage)
            
            VStack(spacing: 0) {
                // Skip Button
                HStack {
                    Spacer()
                    Button(action: skipOnboarding) {
                        Text("Skip")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())
                    }
                    .padding(.top, 20)
                    .padding(.trailing, 20)
                }
                
                // Content
                TabView(selection: $currentPage) {
                    ForEach(0..<pages.count, id: \.self) { index in
                        OnboardingPageView(page: pages[index], isAnimating: $isAnimating)
                            .tag(index)
                    }
                }
                .tabViewStyle(PageTabViewStyle(indexDisplayMode: .always))
                .indexViewStyle(PageIndexViewStyle(backgroundDisplayMode: .always))
                .animation(.easeInOut, value: currentPage)
                
                // Bottom Button
                VStack(spacing: 16) {
                    if currentPage == pages.count - 1 {
                        Button(action: skipOnboarding) {
                            HStack {
                                Text("Get Started")
                                    .font(.title3)
                                    .fontWeight(.bold)
                                Image(systemName: "arrow.right.circle.fill")
                                    .font(.title2)
                            }
                            .foregroundColor(pages.last?.gradient.first ?? .orange)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color.white)
                            .clipShape(Capsule())
                            .shadow(color: .black.opacity(0.15), radius: 10, y: 5)
                        }
                        .transition(.scale.combined(with: .opacity))
                    } else {
                        Button(action: { withAnimation(.spring()) { currentPage += 1 } }) {
                            HStack {
                                Text("Next")
                                    .font(.headline)
                                    .fontWeight(.semibold)
                                Image(systemName: "arrow.right")
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())
                        }
                    }
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 40)
            }
            }
        }
        .onAppear {
            withAnimation(.easeIn(duration: 0.3).delay(0.2)) {
                isAnimating = true
            }
        }
    }
    
    private func skipOnboarding() {
        withAnimation(.easeOut(duration: 0.3)) {
            showingModeSelection = true
        }
    }
}

// MARK: - Individual Page View
struct OnboardingPageView: View {
    let page: OnboardingPage
    @Binding var isAnimating: Bool
    
    var body: some View {
        VStack(spacing: 30) {
            Spacer()
            
            // Icon
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.2))
                    .frame(width: 120, height: 120)
                
                Image(systemName: page.icon)
                    .font(.system(size: 60, weight: .medium))
                    .foregroundColor(.white)
            }
            .scaleEffect(isAnimating ? 1.0 : 0.8)
            .opacity(isAnimating ? 1.0 : 0.3)
            .animation(.spring(response: 0.6, dampingFraction: 0.7), value: isAnimating)
            
            // Title
            Text(page.title)
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
                .opacity(isAnimating ? 1.0 : 0)
                .offset(y: isAnimating ? 0 : 20)
                .animation(.easeOut(duration: 0.4).delay(0.2), value: isAnimating)
            
            // Description
            Text(page.description)
                .font(.system(size: 17, weight: .regular))
                .foregroundColor(.white.opacity(0.9))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 50)
                .lineSpacing(6)
                .opacity(isAnimating ? 1.0 : 0)
                .offset(y: isAnimating ? 0 : 20)
                .animation(.easeOut(duration: 0.4).delay(0.3), value: isAnimating)
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
