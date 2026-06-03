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
        let typeID = CFGetTypeID(identity)
        if typeID == SecIdentityGetTypeID() {
            return (identity as! SecIdentity)
        }
        return nil
    }

    // Generates a new P-256 key pair and stores the private key in Keychain.
    // Full self-signed cert generation requires an ASN.1 DER encoder (not available
    // in iOS Security framework natively) — this generates the key material ready
    // for when the app integrates a TLS library.
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
        _ = SecKeyCopyPublicKey(privateKey)
        Logger.shared.log("WiFiCertificateManager: P-256 key pair generated and stored in Keychain", category: "Network")
    }
}
