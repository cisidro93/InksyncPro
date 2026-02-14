import SwiftUI

struct FaceIDOverlay: View {
    @ObservedObject var securityManager = SecurityManager.shared
    @State private var opactity: Double = 1.0
    
    var body: some View {
        ZStack {
            if securityManager.isVaultLocked {
                // Blur Effect
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .ignoresSafeArea()
                
                VStack(spacing: 20) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 60))
                        .foregroundColor(.blue)
                        .padding()
                        .background(
                            Circle()
                                .fill(.ultraThinMaterial)
                                .shadow(radius: 10)
                        )
                    
                    Text("Vault Locked")
                        .font(.title2)
                        .bold()
                    
                    Text("Authentication required to access private content.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    
                    Button {
                        authenticate()
                    } label: {
                        HStack {
                            Image(systemName: "faceid")
                            Text("Unlock with FaceID")
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(25)
                    }
                }
                .transition(.opacity)
            }
        }
        .animation(.default, value: securityManager.isVaultLocked)
    }
    
    private func authenticate() {
        Task {
            _ = await securityManager.authenticate()
        }
    }
}
