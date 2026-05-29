import SwiftUI

struct BlueprintGrid: View {
    @State private var offset: CGFloat = 0
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                let width = geometry.size.width
                let height = geometry.size.height
                let spacing: CGFloat = 40
                
                for x in stride(from: 0, through: width, by: spacing) {
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: height))
                }
                for y in stride(from: 0, through: height, by: spacing) {
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: width, y: y))
                }
            }
            .stroke(Color.cyan.opacity(0.15), lineWidth: 1)
            .offset(y: offset)
            .animation(.linear(duration: 20).repeatForever(autoreverses: false), value: offset)
            .onAppear { offset = 40 }
        }
        .ignoresSafeArea()
    }
}

struct NeoBrutalistStripe: View {
    var body: some View {
        GeometryReader { proxy in
            Path { path in
                let width = proxy.size.width
                let height = proxy.size.height
                for i in stride(from: -height, to: width, by: 20) {
                    path.move(to: CGPoint(x: i, y: 0))
                    path.addLine(to: CGPoint(x: i + height, y: height))
                }
            }
            .stroke(Color.yellow.opacity(0.8), lineWidth: 10)
        }
    }
}

struct OnboardingView: View {
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding: Bool = false
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var conversionManager: ConversionManager
    
    @State private var currentIndex: Int = 0
    private let totalSlides = 4
    
    var body: some View {
        ZStack {
            // MARK: Blueprint Base
            Color(red: 0.05, green: 0.05, blue: 0.1).ignoresSafeArea()
            BlueprintGrid()
            
            // MARK: Hazard Accent Stripes
            VStack {
                HStack {
                    NeoBrutalistStripe()
                        .frame(width: 150, height: 150)
                        .rotationEffect(.degrees(45))
                        .offset(x: -50, y: -50)
                        .opacity(currentIndex % 2 == 0 ? 1 : 0)
                        .animation(.spring(), value: currentIndex)
                    Spacer()
                }
                Spacer()
                HStack {
                    Spacer()
                    NeoBrutalistStripe()
                        .frame(width: 200, height: 200)
                        .rotationEffect(.degrees(225))
                        .offset(x: 80, y: 80)
                        .opacity(currentIndex % 2 != 0 ? 1 : 0)
                        .animation(.spring(), value: currentIndex)
                }
            }
            .ignoresSafeArea()
            
            VStack(spacing: 0) {
                // MARK: Paginated Feature Carousel
                TabView(selection: $currentIndex) {
                    
                    OnboardingSlideView(
                        icon: "cpu",
                        title: "SYSTEM REBOOT",
                        headline: "INKSYNC PRO",
                        description: "The ultimate edge-to-edge workspace natively hyper-threaded for Apple Silicon.",
                        accentColor: .cyan,
                        index: 0,
                        currentIndex: $currentIndex
                    ).tag(0)
                    
                    OnboardingSlideView(
                        icon: "terminal",
                        title: "NEURAL ENGINE",
                        headline: "LOCAL PARSING",
                        description: "Our offline Neural Engine strips CBZs and automatically reconstructs metadata without a central server.",
                        accentColor: .yellow,
                        index: 1,
                        currentIndex: $currentIndex
                    ).tag(1)
                    
                    OnboardingSlideView(
                        icon: "bolt.fill",
                        title: "ZETTELKASTEN",
                        headline: "SMART HIGHLIGHTS",
                        description: "Extract raw highlight data directly into your personal PKM environment like Readwise & Notion.",
                        accentColor: .green,
                        index: 2,
                        currentIndex: $currentIndex
                    ).tag(2)
                    
                    OnboardingSlideView(
                        icon: "slider.horizontal.3",
                        title: "E-INK CANVAS",
                        headline: "PRO EDITOR SUITE",
                        description: "Merge aggressive split layouts and blast pure black & white E-Ink contrast filtering instantly.",
                        accentColor: .orange,
                        index: 3,
                        currentIndex: $currentIndex
                    ).tag(3)
                    
                }
                .tabViewStyle(PageTabViewStyle(indexDisplayMode: .always))
                .animation(.easeInOut, value: currentIndex)
                
                // MARK: Persistent Sticky CTA
                VStack(spacing: 20) {
                    PremiumCTAButton(
                        title: currentIndex == totalSlides - 1 ? "INITIALIZE" : "NEXT SEQUENCE",
                        icon: currentIndex == totalSlides - 1 ? "checkmark.circle.fill" : "chevron.right.square.fill",
                        accentColor: currentAccent(for: currentIndex),
                        action: handleCTA
                    )
                    
                    if currentIndex < totalSlides - 1 {
                        Button("ABORT / SKIP INTRO") {
                            finishOnboarding()
                        }
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(.gray)
                        .padding(.top, 4)
                    } else {
                        // Keep layout height consistent without polluting the accessibility tree.
                        // An opacity-0 Text is still read by VoiceOver; a Spacer frame is not.
                        Spacer().frame(height: 22)
                    }
                }
                .padding(.bottom, 40)
                .padding(.top, 20)
            }
        }
    }
    
    // MARK: - Handlers
    private func currentAccent(for index: Int) -> Color {
        switch index {
        case 0: return .cyan
        case 1: return .yellow
        case 2: return .green
        case 3: return .orange
        default: return .cyan
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
        let generator = UIImpactFeedbackGenerator(style: .rigid)
        generator.impactOccurred()
        
        UserDefaults.standard.set(true, forKey: "hasSeenOnboarding")
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
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
