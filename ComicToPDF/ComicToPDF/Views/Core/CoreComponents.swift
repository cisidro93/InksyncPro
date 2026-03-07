import SwiftUI
import UIKit

// MARK: - Design System
struct AppTheme {
    // MARK: - Colors
    static let primary = Color.orange
    static let secondary = Color.blue
    static let background = Color(UIColor.systemGroupedBackground)
    static let surface = Color(UIColor.secondarySystemGroupedBackground)
    
    // MARK: - Gradients
    static var mainGradient: LinearGradient {
        LinearGradient(
            colors: [Color.orange.opacity(0.1), Color.blue.opacity(0.05), Color.clear],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
    
    // MARK: - Shadows
    static let shadowRadius: CGFloat = 8
    static let shadowY: CGFloat = 4
    static let shadowColor = Color.black.opacity(0.1)
}

struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding()
            .background(AppTheme.surface)
            .cornerRadius(16)
            .shadow(color: AppTheme.shadowColor, radius: AppTheme.shadowRadius, x: 0, y: AppTheme.shadowY)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var isLoading: Bool = false
    
    func makeBody(configuration: Configuration) -> some View {
        ZStack {
            if isLoading {
                ProgressView().tint(.white)
            } else {
                configuration.label
                    .font(.headline)
                    .fontWeight(.bold)
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(AppTheme.primary)
        .foregroundColor(.white)
        .cornerRadius(14)
        .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
        .animation(.spring(), value: configuration.isPressed)
        .shadow(color: AppTheme.primary.opacity(0.3), radius: 10, x: 0, y: 5)
    }
}

extension View {
    func cardStyle() -> some View {
        modifier(CardStyle())
    }
    
    func hapticFeedback(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .medium) -> some View {
        self.simultaneousGesture(
            TapGesture().onEnded {
                let generator = UIImpactFeedbackGenerator(style: style)
                generator.impactOccurred()
            }
        )
    }
}

// MARK: - App Logo
struct AppLogo: View {
    var size: CGFloat = 120
    
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.18)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 253/255, green: 186/255, blue: 116/255),
                            Color(red: 249/255, green: 115/255, blue: 22/255),
                            Color(red: 194/255, green: 65/255, blue: 12/255)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: size, height: size)
            
            VStack(alignment: .leading, spacing: size * 0.02) {
                Text("CBZ")
                    .font(.system(size: size * 0.15, weight: .heavy, design: .default))
                    .foregroundColor(.white.opacity(0.95))
                
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(Color.white.opacity(0.4))
                        .frame(height: 2)
                    
                    Image(systemName: "arrowtriangle.right.fill")
                        .font(.system(size: size * 0.1))
                        .foregroundColor(.white.opacity(0.9))
                }
                .frame(width: size * 0.65)
                
                Text("PDF")
                    .font(.system(size: size * 0.2, weight: .heavy, design: .default))
                    .foregroundColor(.white)
            }
            .padding(.leading, size * 0.1)
            .frame(width: size, height: size, alignment: .leading)
        }
    }
}

struct AppLogoCircle: View {
    var size: CGFloat = 120
    
    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 249/255, green: 115/255, blue: 22/255),
                            Color(red: 220/255, green: 38/255, blue: 38/255)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: size, height: size)
            
            VStack(spacing: size * 0.02) {
                Text("CBZ")
                    .font(.system(size: size * 0.12, weight: .bold))
                    .foregroundColor(.white.opacity(0.8))
                
                Image(systemName: "arrow.down")
                    .font(.system(size: size * 0.1, weight: .semibold))
                    .foregroundColor(.white.opacity(0.6))
                
                Text("PDF")
                    .font(.system(size: size * 0.18, weight: .heavy))
                    .foregroundColor(.white)
            }
        }
    }
}

struct AppLogoDark: View {
    var size: CGFloat = 120
    
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.18)
                .fill(Color(red: 26/255, green: 26/255, blue: 46/255))
                .frame(width: size, height: size)
            
            VStack(alignment: .leading, spacing: size * 0.02) {
                Text("CBZ")
                    .font(.system(size: size * 0.15, weight: .heavy))
                    .foregroundColor(Color(red: 251/255, green: 146/255, blue: 60/255).opacity(0.9))
                
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(Color(red: 249/255, green: 115/255, blue: 22/255).opacity(0.4))
                        .frame(height: 2)
                    
                    Image(systemName: "arrowtriangle.right.fill")
                        .font(.system(size: size * 0.1))
                        .foregroundColor(Color(red: 249/255, green: 115/255, blue: 22/255).opacity(0.9))
                }
                .frame(width: size * 0.65)
                
                Text("PDF")
                    .font(.system(size: size * 0.2, weight: .heavy))
                    .foregroundColor(Color(red: 249/255, green: 115/255, blue: 22/255))
            }
            .padding(.leading, size * 0.1)
            .frame(width: size, height: size, alignment: .leading)
        }
    }
}

struct AppLogoAnimated: View {
    var size: CGFloat = 120
    @State private var showCBZ = false
    @State private var showArrow = false
    @State private var showPDF = false
    
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.18)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 253/255, green: 186/255, blue: 116/255),
                            Color(red: 249/255, green: 115/255, blue: 22/255),
                            Color(red: 194/255, green: 65/255, blue: 12/255)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: size, height: size)
            
            VStack(alignment: .leading, spacing: size * 0.02) {
                Text("CBZ")
                    .font(.system(size: size * 0.15, weight: .heavy))
                    .foregroundColor(.white.opacity(0.95))
                    .opacity(showCBZ ? 1 : 0)
                    .offset(x: showCBZ ? 0 : -20)
                
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(Color.white.opacity(0.4))
                        .frame(height: 2)
                    
                    Image(systemName: "arrowtriangle.right.fill")
                        .font(.system(size: size * 0.1))
                        .foregroundColor(.white.opacity(0.9))
                }
                .frame(width: size * 0.65)
                .opacity(showArrow ? 1 : 0)
                .scaleEffect(x: showArrow ? 1 : 0, anchor: .leading)
                
                Text("PDF")
                    .font(.system(size: size * 0.2, weight: .heavy))
                    .foregroundColor(.white)
                    .opacity(showPDF ? 1 : 0)
                    .offset(x: showPDF ? 0 : -20)
            }
            .padding(.leading, size * 0.1)
            .frame(width: size, height: size, alignment: .leading)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.4).delay(0.2)) { showCBZ = true }
            withAnimation(.easeOut(duration: 0.3).delay(0.5)) { showArrow = true }
            withAnimation(.easeOut(duration: 0.4).delay(0.7)) { showPDF = true }
        }
    }
}

// MARK: - Success Checkmark
struct SuccessCheckmarkView: View {
    @State private var circleProgress: CGFloat = 0.0
    @State private var checkmarkScale: CGFloat = 0.0
    @State private var opacity: Double = 1.0
    
    var body: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .opacity(opacity)
            
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.2), lineWidth: 6)
                    .frame(width: 100, height: 100)
                
                Circle()
                    .trim(from: 0, to: circleProgress)
                    .stroke(Color.green, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .frame(width: 100, height: 100)
                    .rotationEffect(.degrees(-90))
                
                Image(systemName: "checkmark")
                    .font(.system(size: 50, weight: .bold))
                    .foregroundColor(.white)
                    .scaleEffect(checkmarkScale)
            }
            .padding(40)
            .background(BlurView(style: .systemThinMaterial).clipShape(RoundedRectangle(cornerRadius: 20)))
            .shadow(radius: 10)
            .opacity(opacity)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.4)) { circleProgress = 1.0 }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.6).delay(0.2)) { checkmarkScale = 1.0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation(.easeOut(duration: 0.3)) { opacity = 0 }
            }
        }
    }
}

struct BlurView: UIViewRepresentable {
    var style: UIBlurEffect.Style = .systemMaterial
    func makeUIView(context: Context) -> UIVisualEffectView { UIVisualEffectView(effect: UIBlurEffect(style: style)) }
    func updateUIView(_ uiView: UIVisualEffectView, context: Context) { uiView.effect = UIBlurEffect(style: style) }
}

// MARK: - Splash Screen
struct SplashScreenView: View {
    // Track if user has completed onboarding (default: false = not seen yet)
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var isActive = false
    @State private var logoScale: CGFloat = 0.8
    @State private var logoOpacity: Double = 0
    @State private var showOnboarding = false
    @EnvironmentObject var conversionManager: ConversionManager
    
    var body: some View {
        Group {
            if showOnboarding {
                // First Launch: Show Onboarding
                OnboardingView(showOnboarding: $showOnboarding)
                    .environmentObject(conversionManager)
            } else if isActive {
                // Main App
                ContentView()
            } else {
                // Quick Splash (Returning Users)
                ZStack {
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
                        AppLogoAnimated(size: 140)
                            .scaleEffect(logoScale)
                            .opacity(logoOpacity)
                        
                        Text("InkSync Pro")
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
                    
                    // Check if user has completed onboarding
                    if !hasCompletedOnboarding {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                showOnboarding = true
                            }
                        }
                    } else {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                isActive = true
                            }
                        }
                    }
                }
            }
        }
        .onChange(of: hasCompletedOnboarding) { _, completed in
            // When onboarding is completed, go straight to main app
            if completed {
                withAnimation(.easeInOut(duration: 0.3)) {
                    showOnboarding = false
                    isActive = true
                }
            }
        }
    }
}

