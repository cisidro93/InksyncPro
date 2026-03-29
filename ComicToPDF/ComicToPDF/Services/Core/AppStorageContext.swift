import Foundation

/// Centralized abstraction for dynamic file system pathways.
/// Structurally separates the public "Inbox" (Documents) from the iCloud-immune "Vault" (Application Support)
public struct AppStorageContext {
    public static let shared = AppStorageContext()
    
    private init() {
        ensureDirectoriesExist()
    }
    
    /// The Public Inbox (Apple native "Documents" directory).
    /// Used ONLY for USB drops and native iOS Files App file sharing.
    public var inboxURL: URL {
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    
    /// The Secure iCloud-Immune Vault (Apple native "Application Support" directory).
    /// Used for persistent Library storage hidden from user tampering and cloud duplication.
    public var vaultURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("LibraryVault", isDirectory: true)
    }
    
    /// Diagnostic Log Dump Route
    public var logsURL: URL {
        return vaultURL.appendingPathComponent("Logs", isDirectory: true)
    }
    
    /// Pre-flight initialization to ensure the Vault physical structures exist
    public func ensureDirectoriesExist() {
        let fm = FileManager.default
        do {
            if !fm.fileExists(atPath: vaultURL.path) {
                try fm.createDirectory(at: vaultURL, withIntermediateDirectories: true)
            }
            if !fm.fileExists(atPath: logsURL.path) {
                try fm.createDirectory(at: logsURL, withIntermediateDirectories: true)
            }
        } catch {
            print("CRITICAL [AppStorageContext] Failed to provision Vault sandbox: \(error)")
        }
    }
}
