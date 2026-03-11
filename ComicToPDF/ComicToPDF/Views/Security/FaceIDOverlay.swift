import SwiftUI

struct FaceIDOverlay: View {
    @ObservedObject var securityManager = SecurityManager.shared
    @State private var opactity: Double = 1.0
    
    var body: some View {
        ZStack {
            if securityManager.isVaultLocked {
                // Premium Blur Effect
                Rectangle()
                    .fill(.regularMaterial)
                    .ignoresSafeArea()
                
                VStack(spacing: 24) {
                    Image(systemName: "faceid")
                        .font(.system(size: 72, weight: .light))
                        .foregroundColor(.blue)
                        .padding(24)
                        .background(
                            Circle()
                                .fill(Color(UIColor.secondarySystemGroupedBackground))
                                .shadow(color: .black.opacity(0.1), radius: 20, x: 0, y: 10)
                        )
                    
                    VStack(spacing: 8) {
                        Text("App Locked")
                            .font(.title)
                            .fontWeight(.semibold)
                        
                        Text("Authenticate with Face ID\nto view your private collection.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }
                    
                    Button {
                        authenticate()
                    } label: {
                        Text("Unlock App")
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: 240)
                            .padding(.vertical, 16)
                            .background(Color.blue)
                            .clipShape(Capsule())
                            .shadow(color: .blue.opacity(0.3), radius: 8, y: 4)
                    }
                    .padding(.top, 10)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: securityManager.isVaultLocked)
    }
    
    private func authenticate() {
        Task {
            _ = await securityManager.authenticate()
        }
    }
}
