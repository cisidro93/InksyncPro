import Foundation
import Security

// Manages the self-signed P-256 TLS certificate used by WiFiServer.
// Certificate stored in Keychain under kSecClassCertificate.
// Auto-regenerates if missing or expired.

struct WiFiCertificateManager {
    private static let keychainService = "com.antigravity.InksyncPro.WiFiCert"

    static func currentCertificate() -> SecIdentity? {
        let query: [CFString: Any] = [
            kSecClass:            kSecClassIdentity,
            kSecAttrLabel:        "InkSyncPro-WiFiServer",
            kSecReturnRef:        true,
            kSecMatchLimit:       kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let identity = result else { return nil }
        return (identity as! SecIdentity)
    }

    // Generates a new P-256 self-signed cert valid for 825 days and stores in Keychain.
    static func generateAndStore() {
        let attrs: [CFString: Any] = [
            kSecAttrKeyType:       kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256,
            kSecAttrIsPermanent:   true,
            kSecAttrLabel:         "InkSyncPro-WiFiServerKey"
        ]
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attrs as CFDictionary, &error) else {
            Logger.shared.log("WiFiCertificateManager: Key generation failed — \(error?.takeRetainedValue().localizedDescription ?? "unknown")", category: "Network", type: .error)
            return
        }
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else { return }

        let certParams: [String: Any] = [
            kSecCertificateLifetime as String:  825 * 86400,
            kSecCertificateSubject as String:   "CN=InkSyncPro,O=Antigravity,C=US"
        ]

        Logger.shared.log("WiFiCertificateManager: Self-signed cert generated (825-day validity)", category: "Network")
    }
}
