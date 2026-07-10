import Foundation
import LocalAuthentication
import SwiftUI
import Combine

/// Manages secure access to the Private Library "Vault"
/// Handles Biometric Authentication and App Privacy Blur
@MainActor
class SecurityManager: ObservableObject {
    static let shared = SecurityManager()
    
    // Published State
    @Published var isVaultLocked: Bool = true
    @Published var isVaultEnabled: Bool = false // User preference
    @Published var shouldBlurContent: Bool = false
    
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
        let context = LAContext()
        var error: NSError?
        
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
            do {
                // Strictly evaluate using biometrics first (prevents immediate passcode/PIN fallback)
                try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "Unlock your Comic Vault")
                self.isVaultLocked = false
                self.shouldBlurContent = false
                return true
            } catch let authError as NSError {
                // If biometrics are locked out, fall back to passcode (PIN)
                if authError.domain == LAErrorDomain && authError.code == LAError.biometryLockout.rawValue {
                    Logger.shared.log("Biometrics locked out. Falling back to passcode.", category: "System", type: .warning)
                    do {
                        try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock your Comic Vault")
                        self.isVaultLocked = false
                        self.shouldBlurContent = false
                        return true
                    } catch let passcodeError {
                        Logger.shared.log("Vault Passcode Authentication failed: \(passcodeError.localizedDescription)", category: "System", type: .error)
                        return false
                    }
                }
                Logger.shared.log("Vault Biometric Authentication failed: \(authError.localizedDescription)", category: "System", type: .error)
                return false
            }
        } else {
            // Biometrics are not enrolled or not supported (e.g. simulator without Face ID set up).
            // Fall back to device owner passcode.
            do {
                try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock your Comic Vault")
                self.isVaultLocked = false
                self.shouldBlurContent = false
                return true
            } catch let fallbackError {
                Logger.shared.log("Vault Authentication failed: \(fallbackError.localizedDescription)", category: "System", type: .error)
                return false
            }
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
            AppSettingsManager.shared.isVaultUnlocked = false
        }
    }
    
    /// Call when scene becomes active
    func handleAppForegrounding() {
        // Blur remains active until user successfully authenticates
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
