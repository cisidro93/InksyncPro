import SwiftUI

struct OnboardingView: View {
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding: Bool = false
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var conversionManager: ConversionManager
    
    @State private var currentIndex: Int = 0
    @State private var startAnimation: Bool = false
    
    private let totalSlides = 4
    
    var body: some View {
        ZStack {
            // MARK: Premium Glass Background
            Color.black.ignoresSafeArea()
            
            // Dynamic Background Blobs bound to currentIndex
            Circle()
                .fill(LinearGradient(colors: currentColors(for: currentIndex), startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 400, height: 400)
                .blur(radius: 100)
                .offset(
                    x: startAnimation ? CGFloat(currentIndex * -30) + 50 : 0,
                    y: startAnimation ? CGFloat(currentIndex * 20) - 150 : -200
                )
                .animation(.easeInOut(duration: 4).repeatForever(autoreverses: true), value: startAnimation)
                .animation(.spring(response: 0.8, dampingFraction: 0.7), value: currentIndex)
            
            Circle()
                .fill(LinearGradient(colors: altColors(for: currentIndex), startPoint: .bottomLeading, endPoint: .topTrailing))
                .frame(width: 300, height: 300)
                .blur(radius: 80)
                .offset(
                    x: startAnimation ? CGFloat(currentIndex * 40) - 50 : 100,
                    y: startAnimation ? CGFloat(currentIndex * -20) + 200 : 250
                )
                .animation(.easeInOut(duration: 5).repeatForever(autoreverses: true), value: startAnimation)
                .animation(.spring(response: 0.8, dampingFraction: 0.7), value: currentIndex)
            
            VStack(spacing: 0) {
                // MARK: Paginated Feature Carousel
                TabView(selection: $currentIndex) {
                    
                    OnboardingSlideView(
                        icon: "wand.and.stars.inverse",
                        title: "WELCOME",
                        headline: "Inksync Pro",
                        description: "The ultimate workspace for Manga, Books, and PDFs natively optimized for Apple Silicon.",
                        colors: [Theme.blue, Color.purple],
                        index: 0,
                        currentIndex: $currentIndex
                    ).tag(0)
                    
                    OnboardingSlideView(
                        icon: "highlighter",
                        title: "SMART READER",
                        headline: "Zettelkasten Note-Taking",
                        description: "Drag native iOS highlights to capture knowledge and instantly sync Tags & Annotations to your Personal Cloud.",
                        colors: [Theme.orange, Color.red],
                        index: 1,
                        currentIndex: $currentIndex
                    ).tag(1)
                    
                    OnboardingSlideView(
                        icon: "sparkles.tv",
                        title: "NATIVE ENGINE",
                        headline: "Guided View Extraction",
                        description: "Our offline Neural Engine automatically slices CBZ/PDF comics directly into edge-to-edge Guided View EPUBs.",
                        colors: [Theme.blue, Color.teal],
                        index: 2,
                        currentIndex: $currentIndex
                    ).tag(2)
                    
                    OnboardingSlideView(
                        icon: "paintbrush.pointed",
                        title: "PRECISION CANVAS",
                        headline: "Pro Editor Suite",
                        description: "Merge split spreads, apply E-Ink contrast filters, and seamlessly orchestrate Metadata from local databases.",
                        colors: [Color.purple, Theme.orange],
                        index: 3,
                        currentIndex: $currentIndex
                    ).tag(3)
                    
                }
                .tabViewStyle(PageTabViewStyle(indexDisplayMode: .always))
                .animation(.easeInOut, value: currentIndex)
                
                // MARK: Persistent Sticky CTA
                VStack(spacing: 20) {
                    PremiumCTAButton(
                        title: currentIndex == totalSlides - 1 ? "Start Creating" : "Continue",
                        icon: currentIndex == totalSlides - 1 ? "arrow.right.circle.fill" : nil,
                        colors: currentColors(for: currentIndex),
                        action: handleCTA
                    )
                    
                    if currentIndex < totalSlides - 1 {
                        Button("Skip Intro") {
                            finishOnboarding()
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Theme.textSecondary)
                        .padding(.top, 4)
                    } else {
                        // Invisible spacer to maintain height
                        Text("Skip Intro").opacity(0).font(.system(size: 14)).padding(.top, 4)
                    }
                }
                .padding(.bottom, 40)
                .padding(.top, 20)
            }
        }
        .onAppear {
            self.startAnimation = true
        }
    }
    
    // MARK: - Handlers
    
    private func currentColors(for index: Int) -> [Color] {
        switch index {
        case 0: return [Theme.blue, Color.purple]
        case 1: return [Theme.orange, Color.red]
        case 2: return [Theme.blue, Color.teal]
        case 3: return [Color.purple, Theme.orange]
        default: return [Theme.blue, Color.purple]
        }
    }
    
    private func altColors(for index: Int) -> [Color] {
        switch index {
        case 0: return [Theme.orange, Theme.blue]
        case 1: return [Color.purple, Theme.orange]
        case 2: return [Color.teal, Color.purple]
        case 3: return [Theme.blue, Color.red]
        default: return [Theme.orange, Theme.blue]
        }
    }
    
    private func handleCTA() {
        if currentIndex < totalSlides - 1 {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                currentIndex += 1
            }
        } else {
            finishOnboarding()
        }
    }
    
    private func finishOnboarding() {
        let generator = UIImpactFeedbackGenerator(style: .heavy)
        generator.impactOccurred()
        
        UserDefaults.standard.set(true, forKey: "hasSeenOnboarding")
        withAnimation {
            hasSeenOnboarding = true
        }
        
        dismiss()
    }
}

// MARK: - Preview
struct OnboardingView_Previews: PreviewProvider {
    static var previews: some View {
        OnboardingView()
            .environmentObject(ConversionManager())
            .preferredColorScheme(.dark)
    }
}
