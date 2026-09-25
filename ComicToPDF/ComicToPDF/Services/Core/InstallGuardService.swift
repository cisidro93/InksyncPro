import Foundation
import UIKit

/// Manages fresh-install detection to wipe ghost data safely.
final class InstallGuardService: @unchecked Sendable {
    static let shared = InstallGuardService()
    
    private let userDefaults = UserDefaults.standard
    private let fileManager = FileManager.default
    private let keychainService = "com.antigravity.InksyncPro.installguard"
    private let keychainAccount = "sentinel"
    
    private init() {}
    
    func executeGuard() {
        let supportDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let sentinelURL = supportDir.appendingPathComponent(".inksync_install_sentinel_v1", isDirectory: false)
        let sentinelExists = fileManager.fileExists(atPath: sentinelURL.path)
        
        // Note: Documents directory is intentionally backup-eligible to protect user libraries (App Store Guideline 5.1.1).
        excludeDirectoryFromBackup(url: supportDir)

        let shouldNuke = !sentinelExists
        if shouldNuke {
            performNuke(supportDir: supportDir)
        }
        
        // Always write (or re-write) the sandbox sentinel file
        writeSentinel(at: sentinelURL, supportDir: supportDir)
        
        // Always write the Keychain sentinel so subsequent runs/updates are tracked
        if let data = "exists".data(using: .utf8) {
            KeychainHelper.standard.save(data, service: keychainService, account: keychainAccount)
        }
        
        // Track fresh install completion
        userDefaults.set(true, forKey: "isNotFreshInstall_v3")
    }

    func runDeferredCleanup() async {
        // Safe no-op: Protect active user documents and inbox from background deletion
    }
    
    private func excludeDirectoryFromBackup(url: URL) {
        var mutableURL = url
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? mutableURL.setResourceValues(resourceValues)
    }
    
    private func performNuke(supportDir: URL) {
        // 1. User documents in Documents/ are SACRED and MUST NEVER be deleted.
        // We strictly protect user files, vaults, and custom imports.
        
        // 2. Clear stale lock files and ephemeral database artifacts in Application Support
        if let items = try? fileManager.contentsOfDirectory(at: supportDir, includingPropertiesForKeys: nil) {
            let protectedDirectories = ["InksyncVault", "progress", "ThumbnailCache"]
            for item in items {
                let name = item.lastPathComponent
                if name.hasPrefix(".inksync_install_sentinel") { continue }
                if protectedDirectories.contains(name) { continue }
                // Only clean legacy ephemeral database or cache files on clean install
                if name.hasSuffix(".sqlite") || name.hasSuffix(".sqlite-shm") || name.hasSuffix(".sqlite-wal") || name.hasPrefix("tmp_") {
                    try? fileManager.removeItem(at: item)
                }
            }
        }
        
        // 3. Clear App Group transient caches if present
        let groupSuiteName = "group.com.antigravity.inksync"
        if let groupDefaults = UserDefaults(suiteName: groupSuiteName) {
            groupDefaults.removePersistentDomain(forName: groupSuiteName)
            groupDefaults.synchronize()
        }
        
        Logger.shared.log("InksyncProApp: Clean install guard verified. User documents protected.", category: "Migration", type: .info)
    }
    
    private func writeSentinel(at url: URL, supportDir: URL) {
        let content = supportDir.path
        do {
            // Ensure the parent directory exists — on fresh Signulous-signed installs
            // iOS does NOT pre-create applicationSupportDirectory, so the write fails
            // silently and leaves the sentinel permanently absent.
            let parentDir = url.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: parentDir.path) {
                try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
            }
            try content.write(to: url, atomically: true, encoding: .utf8)
            var mutableSentinelURL = url
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            try mutableSentinelURL.setResourceValues(resourceValues)
            Logger.shared.log("InstallGuard: Sentinel written successfully.", category: "Migration")
        } catch {
            Logger.shared.log("InstallGuard: Failed to write sentinel or set resource values: \(error.localizedDescription)", category: "Migration", type: .error)
        }
    }
}
