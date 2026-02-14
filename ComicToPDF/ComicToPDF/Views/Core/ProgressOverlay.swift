import SwiftUI

struct ProgressOverlay: View {
    let progress: Double // 0.0 to 1.0
    let message: String
    
    var body: some View {
        if #available(iOS 26.0, *) {
            // iOS 26 "Liquid Glass" Style
            HStack(spacing: 12) {
                ProgressView(value: progress)
                    .progressViewStyle(CircularProgressViewStyle(tint: .secondary))
                    .frame(width: 20, height: 20)
                
                Text(message)
                    .font(.caption.weight(.medium))
                    .fontDesign(.rounded)
                    .foregroundStyle(.secondary)
                
                Spacer()
                
                Text("\(Int(progress * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.thinMaterial, in: Capsule())
            .padding(.bottom, 4) // Lift slightly from tab bar
        } else {
            // iOS 17-25 Fallback
            HStack {
                ProgressView(value: progress)
                    .progressViewStyle(LinearProgressViewStyle())
                    .frame(width: 100)
                Text(message)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(Color(UIColor.systemBackground))
            .cornerRadius(12)
            .shadow(radius: 5)
        }
    }
}

// MARK: - iOS 26 Modifiers Stubs
// These allow the code to "compile" in older SDKs while targeting the future architecture.
// In a real iOS 26 environment, these extensions would be removed or just allow the native modifiers.

extension View {
    @ViewBuilder
    func ios26_tabBarMinimizeBehavior(_ behavior: Any) -> some View {
        if #available(iOS 26, *) {
            // We assume the strict SDK would allow this. 
            // Since we can't actually compile against iOS 26 SDK, we rely on the #available check blocking execution path,
            // but the compiler strictly checks existence. 
            // For this exercise, we assume the environment supports it or we return self.
            self
        } else {
            self
        }
    }
    
    @ViewBuilder
    func ios26_tabViewBottomAccessory<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if #available(iOS 26, *) {
            // In the real implementation, we'd attach the accessory here.
            // For fallback, we might overlay it manually in the ZStack.
            self.overlay(alignment: .bottom) {
                content()
                    .padding(.bottom, 60) // Manual offset for older iOS tabs
            }
        } else {
            self.overlay(alignment: .bottom) {
                content()
                    .padding(.bottom, 50)
            }
        }
    }
}
