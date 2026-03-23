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
        self.isVaultEnabled = KeychainHelper.get()
    }
    
    /// Toggle Vault protection preference securely
    func setVaultEnabled(_ enabled: Bool) {
        KeychainHelper.set(enabled)
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

// MARK: - Secure Storage

private struct KeychainHelper {
    static let service = "com.inksync.vault.secure"
    static let account = "isVaultEnabled"
    
    static func set(_ state: Bool) {
        let data = Data(String(state).utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        
        if status == errSecSuccess {
            let attributes: [String: Any] = [kSecValueData as String: data]
            SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        } else {
            var newQuery = query
            newQuery[kSecValueData as String] = data
            // Only accessible when device is unlocked
            newQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            SecItemAdd(newQuery as CFDictionary, nil)
        }
    }
    
    static func get() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, let str = String(data: data, encoding: .utf8) {
            return str == "true"
        }
        return false // Default 
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
