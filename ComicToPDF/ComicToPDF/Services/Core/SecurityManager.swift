import Foundation
import LocalAuthentication
import SwiftUI
import Combine

/// Manages secure access to the Private Library "Vault"
/// Handles Biometric Authentication and App Privacy Blur
class SecurityManager: ObservableObject {
    static let shared = SecurityManager()
    
    // Published State
    @Published var isVaultLocked: Bool = true
    @Published var isVaultEnabled: Bool = false // User preference
    @Published var shouldBlurContent: Bool = false
    
    private var context = LAContext()
    
    init() {
        // Load preference securely
        if let data = KeychainHelper.standard.read(service: "com.inksync.vault", account: "isVaultEnabled"),
           let str = String(data: data, encoding: .utf8), str == "true" {
            self.isVaultEnabled = true
        } else {
            self.isVaultEnabled = false
        }
    }
    
    /// Toggle Vault protection preference securely
    func setVaultEnabled(_ enabled: Bool) {
        let data = Data(String(enabled).utf8)
        KeychainHelper.standard.save(data, service: "com.inksync.vault", account: "isVaultEnabled")
        self.isVaultEnabled = enabled
        if enabled {
            self.lockVault()
        } else {
            self.isVaultLocked = false
        }
    }
    
    /// Attempt to unlock the vault using Device Authentication (FaceID/TouchID -> Passcode fallback)
    func authenticate() async -> Bool {
        context = LAContext() // Reset context
        
        do {
            // .deviceOwnerAuthentication natively tries Biometrics first, then automatically falls back to Passcode.
            // This prevents hard crashes on simulators or devices with disabled FaceID.
            try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock your Comic Vault")
            await MainActor.run {
                self.isVaultLocked = false
            }
            return true
        } catch {
            Logger.shared.log("Vault Authentication failed: \(error.localizedDescription)", category: "System", type: .error)
            return false
        }
    }
    
    func lockVault() {
        self.isVaultLocked = true
    }
    
    // MARK: - Privacy
    
    /// Call when scene enters background
    func handleAppBackgrounding() {
        if isVaultEnabled {
            shouldBlurContent = true
            lockVault() // Auto-lock on exit
        }
    }
    
    /// Call when scene becomes active
    func handleAppForegrounding() {
        shouldBlurContent = false
    }
}

// MARK: - View Modifier

struct PrivacyBlurModifier: ViewModifier {
    @ObservedObject var securityManager = SecurityManager.shared
    
    func body(content: Content) -> some View {
        ZStack {
            content
            
            if securityManager.shouldBlurContent {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .zIndex(999) // Always on top
            }
        }
        .animation(.default, value: securityManager.shouldBlurContent)
    }
}

extension View {
    func secureVaultPrivacy() -> some View {
        self.modifier(PrivacyBlurModifier())
    }
}
