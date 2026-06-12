import Foundation
import Security

// MARK: - Credential Model

/// Holds the authentication details for a single OPDS server.
/// For Kavita (May 2026 standard): `username` = email, `bearerToken` = JWT access token,
/// `refreshToken` = JWT refresh token. The login `password` is used only during the
/// initial JWT exchange and is NOT stored.
/// For Komga / Calibre: `username` + `password` are standard HTTP Basic Auth values.
struct OPDSCredential: Codable {
    var username: String
    var password: String       // Basic Auth password (Komga/Calibre) or login password for initial Kavita exchange
    var bearerToken: String?   // JWT access token — Kavita only, replaces API-key-in-path
    var refreshToken: String?  // JWT refresh token — Kavita only, for silent re-auth
}

// MARK: - Keychain Store

/// Static namespace for persisting `OPDSCredential` values in the iOS Keychain.
/// Keys are scoped to each server's UUID so deletion is safe and precise.
enum OPDSKeychainStore {

    private static let service = "com.inksyncpro.opds"

    // MARK: - Save

    static func save(_ credential: OPDSCredential, for serverID: UUID) {
        guard let data = try? JSONEncoder().encode(credential) else { return }

        // Delete any existing entry first to avoid kSecDuplicateItem errors
        delete(for: serverID)

        let query: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrService as String:      service,
            kSecAttrAccount as String:      serverID.uuidString,
            kSecValueData as String:        data,
            kSecAttrAccessible as String:   kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            Logger.shared.log(
                "OPDSKeychainStore: save failed for \(serverID) — OSStatus \(status)",
                category: "OPDS", type: .error
            )
        }
    }

    // MARK: - Load

    static func load(for serverID: UUID) -> OPDSCredential? {
        let query: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  serverID.uuidString,
            kSecReturnData as String:   true,
            kSecMatchLimit as String:   kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let credential = try? JSONDecoder().decode(OPDSCredential.self, from: data)
        else { return nil }

        return credential
    }

    // MARK: - Delete

    static func delete(for serverID: UUID) {
        let query: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  serverID.uuidString
        ]
        SecItemDelete(query as CFDictionary)
    }
}
