import Foundation
import Security

// Stable per-device UUID persisted in iCloud Keychain.
// Survives app reinstall when iCloud Keychain is enabled.
// Generated once as UUID().uuidString on first launch.

final class DeviceIdentity: Sendable {
    static let shared = DeviceIdentity()

    private let service = "com.antigravity.InksyncPro"
    private let account = "deviceIdentityUUID"

    var deviceID: String {
        if let existing = readFromKeychain() { return existing }
        let newID = UUID().uuidString
        writeToKeychain(newID)
        return newID
    }

    private init() {}

    private func readFromKeychain() -> String? {
        let query: [CFString: Any] = [
            kSecClass:            kSecClassGenericPassword,
            kSecAttrService:      service,
            kSecAttrAccount:      account,
            kSecReturnData:       true,
            kSecMatchLimit:       kSecMatchLimitOne,
            kSecAttrSynchronizable: kSecAttrSynchronizableAny
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func writeToKeychain(_ id: String) {
        guard let data = id.data(using: .utf8) else { return }
        let query: [CFString: Any] = [
            kSecClass:             kSecClassGenericPassword,
            kSecAttrService:       service,
            kSecAttrAccount:       account,
            kSecValueData:         data,
            kSecAttrSynchronizable: true,
            kSecAttrAccessible:    kSecAttrAccessibleAfterFirstUnlock
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }
}
