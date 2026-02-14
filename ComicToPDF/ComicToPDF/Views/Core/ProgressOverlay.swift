import SwiftUI

struct ProgressOverlay: View {
    let progress: Double // 0.0 to 1.0
    let message: String
    
    var body: some View {
        if #available(iOS 18.0, *) {
            // iOS 18+ "Liquid Glass" Style
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

// MARK: - iOS 26 Modifiers Stubs (Mapped to iOS 18 for Compilation)
// These allow the code to compile while targeting future/latest architecture.
// We use iOS 18.0 as the "Liquid Glass" threshold for now.

enum TabBarMinimizeBehavior {
    case onScrollDown
}

extension View {
    @ViewBuilder
    func ios26_tabBarMinimizeBehavior(_ behavior: TabBarMinimizeBehavior) -> some View {
        if #available(iOS 18.0, *) {
            // "Liquid Glass" behavior simulation or native call if available
            self
        } else {
            self
        }
    }
    
    @ViewBuilder
    func ios26_tabViewBottomAccessory<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if #available(iOS 18.0, *) {
            // In the real implementation, we'd attach the accessory here.
            // For fallback/simulation, we overlay it manually.
            self.overlay(alignment: .bottom) {
                content()
                    .padding(.bottom, 60) // Manual offset for tab bar
            }
        } else {
            self.overlay(alignment: .bottom) {
                content()
                    .padding(.bottom, 50)
            }
        }
    }
}
