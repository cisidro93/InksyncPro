import SwiftUI

struct OnboardingFeatureRow: View {
    let icon: String
    let title: String
    let description: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 36, weight: .light))
                .foregroundColor(Theme.blue)
                .frame(width: 44, alignment: .center)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundColor(Theme.text)
                
                Text(description)
                    .font(.subheadline)
                    .foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct OnboardingView: View {
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding: Bool = false
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var conversionManager: ConversionManager
    
    // Animate UI elements on load
    @State private var startAnimation: Bool = false
    
    var body: some View {
        ZStack {
            // MARK: Premium Glass Background
            Color.black.ignoresSafeArea()
            
            // Large ambient background blobs
            Circle()
                .fill(LinearGradient(colors: [Theme.blue.opacity(0.3), Color.purple.opacity(0.3)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 400, height: 400)
                .blur(radius: 100)
                .offset(x: startAnimation ? -50 : 50, y: startAnimation ? -150 : -200)
                .animation(.easeInOut(duration: 8).repeatForever(autoreverses: true), value: startAnimation)
            
            Circle()
                .fill(LinearGradient(colors: [Theme.orange.opacity(0.2), Theme.blue.opacity(0.2)], startPoint: .bottomLeading, endPoint: .topTrailing))
                .frame(width: 300, height: 300)
                .blur(radius: 80)
                .offset(x: startAnimation ? 100 : -50, y: startAnimation ? 200 : 250)
                .animation(.easeInOut(duration: 6).repeatForever(autoreverses: true), value: startAnimation)
                
            ScrollView {
                VStack(spacing: 40) {
                    
                    // MARK: Header
                    VStack(spacing: 12) {
                        Image(systemName: "wand.and.stars.inverse")
                            .font(.system(size: 80))
                            .foregroundStyle(
                                LinearGradient(colors: [Theme.blue, Color.purple], startPoint: .topLeading, endPoint: .bottomTrailing)
                            )
                            .shadow(color: Theme.blue.opacity(0.5), radius: 20)
                            .padding(.top, 40)
                            
                        Text("Welcome to\nInksync Pro")
                            .font(.system(size: 42, weight: .bold, design: .rounded))
                            .multilineTextAlignment(.center)
                            .foregroundColor(.white)
                            .layoutPriority(1)
                    }
                    .opacity(startAnimation ? 1 : 0)
                    .offset(y: startAnimation ? 0 : 20)
                    .animation(.easeOut(duration: 0.8).delay(0.1), value: startAnimation)
                    
                    // MARK: Feature List
                    VStack(alignment: .leading, spacing: 32) {
                        OnboardingFeatureRow(
                            icon: "wand.and.rays",
                            title: "Magic Panel Extraction",
                            description: "Our offline Neural Engine automatically slices your CBZ/PDF comics natively into Guided View EPUBs for Kindle."
                        )
                        
                        OnboardingFeatureRow(
                            icon: "cpu",
                            title: "E-Ink Hardware Optimization",
                            description: "Automatically downsamples, strips color, and boosts contrast to perfectly match your Kobo, Boox, or Scribe resolution."
                        )
                        
                        OnboardingFeatureRow(
                            icon: "sparkles",
                            title: "AI & Interactive Planners",
                            description: "Generate 90-day trackers, calendars, or journals with native hyperlinking using local AI templates."
                        )
                        
                        OnboardingFeatureRow(
                            icon: "scissors",
                            title: "Pro Precision Canvas",
                            description: "Edit bounding boxes, merge split pages, filter margins, and re-order manga directly on your device."
                        )
                    }
                    .padding(.horizontal, 30)
                    .opacity(startAnimation ? 1 : 0)
                    .offset(y: startAnimation ? 0 : 30)
                    .animation(.easeOut(duration: 0.8).delay(0.3), value: startAnimation)
                    
                    Spacer()
                    
                    // MARK: Call to Action
                    Button(action: {
                        finishOnboarding()
                    }) {
                        Text("Start Creating")
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(
                                LinearGradient(colors: [Theme.blue, Color.purple], startPoint: .leading, endPoint: .trailing)
                            )
                            .cornerRadius(16)
                            .shadow(color: Theme.blue.opacity(0.3), radius: 10, y: 5)
                    }
                    .padding(.horizontal, 40)
                    .padding(.bottom, 40)
                    .opacity(startAnimation ? 1 : 0)
                    .scaleEffect(startAnimation ? 1 : 0.95)
                    .animation(.easeOut(duration: 0.8).delay(0.5), value: startAnimation)
                }
            }
        }
        .onAppear {
            self.startAnimation = true
        }
    }
    
    private func finishOnboarding() {
        // Run a haptic feedback click
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
        
        // 1. Mark as seen
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
