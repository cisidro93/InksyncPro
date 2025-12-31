import SwiftUI

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
            withAnimation(.easeInOut(duration: 0.4)) {
                circleProgress = 1.0
            }
            
            withAnimation(.spring(response: 0.4, dampingFraction: 0.6).delay(0.2)) {
                checkmarkScale = 1.0
            }
            
            // Fade out after a delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation(.easeOut(duration: 0.3)) {
                    opacity = 0
                }
            }
        }
    }
}

// Helper for blur effect
struct BlurView: UIViewRepresentable {
    var style: UIBlurEffect.Style = .systemMaterial
    
    func makeUIView(context: Context) -> UIVisualEffectView {
        return UIVisualEffectView(effect: UIBlurEffect(style: style))
    }
    
    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {
        uiView.effect = UIBlurEffect(style: style)
    }
}
