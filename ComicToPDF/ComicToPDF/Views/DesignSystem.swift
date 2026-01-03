import SwiftUI

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

// MARK: - View Modifiers

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
}

extension View {
    func hapticFeedback(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .medium) -> some View {
        self.simultaneousGesture(
            TapGesture().onEnded {
                let generator = UIImpactFeedbackGenerator(style: style)
                generator.impactOccurred()
            }
        )
    }
}
