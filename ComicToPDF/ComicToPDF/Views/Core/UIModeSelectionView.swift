import SwiftUI

struct UIModeSelectionView: View {
    @AppStorage("appUIMode") private var appUIMode: AppUIMode = .pro
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @Binding var showOnboarding: Bool
    
    var body: some View {
        VStack(spacing: 30) {
            Text("Choose Your Experience")
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .padding(.top, 40)
            
            Text("How would you like to build your library? You can always change this later in Settings.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            
            HStack(spacing: 20) {
                // Go Mode Card
                ModeCard(
                    title: "Go Mode",
                    description: "Fast, drag-and-drop conversion with intelligent auto-enhancements. Perfect for getting straight to reading.",
                    icon: "bolt.fill",
                    color: .orange,
                    isSelected: appUIMode == .go,
                    action: { appUIMode = .go }
                )
                
                // Pro Mode Card
                ModeCard(
                    title: "Pro Mode",
                    description: "Advanced library management, metadata editing, and deep conversion control. For the power user.",
                    icon: "slider.horizontal.3",
                    color: .blue,
                    isSelected: appUIMode == .pro,
                    action: { appUIMode = .pro }
                )
            }
            .padding(.horizontal)
            
            Spacer()
            
            Button {
                hasCompletedOnboarding = true
                showOnboarding = false
            } label: {
                Text("Start Converting")
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(appUIMode == .go ? Color.orange : Color.blue)
                    .cornerRadius(12)
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 40)
        }
        .background(Color(.systemBackground).ignoresSafeArea())
    }
}

struct ModeCard: View {
    let title: String
    let description: String
    let icon: String
    let color: Color
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(color.opacity(0.1))
                        .frame(width: 80, height: 80)
                    Image(systemName: icon)
                        .font(.system(size: 40))
                        .foregroundColor(color)
                }
                
                Text(title)
                    .font(.title2)
                    .bold()
                    .foregroundColor(.primary)
                
                Text(description)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                
                Spacer()
                
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title)
                        .foregroundColor(color)
                } else {
                    Image(systemName: "circle")
                        .font(.title)
                        .foregroundColor(.gray)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(20)
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(isSelected ? color : Color.clear, lineWidth: 3)
            )
        }
        .buttonStyle(.plain)
    }
}
