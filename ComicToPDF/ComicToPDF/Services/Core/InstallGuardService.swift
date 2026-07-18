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
        
        // Exclude Documents and Application Support folders from iCloud Backup to prevent database restore on reinstall
        if let docDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            excludeDirectoryFromBackup(url: docDir)
        }
        excludeDirectoryFromBackup(url: supportDir)

        // Check if our install sentinel exists in the Keychain
        let keychainSentinelExists = KeychainHelper.standard.read(service: keychainService, account: keychainAccount) != nil

        // We nuke ONLY if the sandbox sentinel file is missing (indicating the app sandbox was deleted)
        // BUT the keychain sentinel is present (indicating it was previously run on this device).
        // This represents a clean reinstall on the same device.
        // On simulator, since the keychain is wiped on app delete, we always nuke if the sandbox sentinel is missing.
        // On both simulator and device, we always nuke if the sandbox sentinel file is missing.
        // This guarantees a clean slate on any app delete-and-reinstall, wiping any iCloud-restored database skeletons.
        let shouldNuke = !sentinelExists
        
        if shouldNuke {
            performNuke(supportDir: supportDir)
            userDefaults.set(true, forKey: "pendingFreshInstallCleanup")
            startDeferredCleanupTask()
        }
        
        // Always write (or re-write) the sandbox sentinel file
        writeSentinel(at: sentinelURL, supportDir: supportDir)
        
        // Always write the Keychain sentinel so subsequent runs/updates are tracked
        if let data = "exists".data(using: .utf8) {
            KeychainHelper.standard.save(data, service: keychainService, account: keychainAccount)
        }
        
        // Auto-complete onboarding flags for clean runs
        userDefaults.set(true, forKey: "hasCompletedOnboarding")
        userDefaults.set(true, forKey: "hasSeenOnboarding")
        userDefaults.set(true, forKey: "isNotFreshInstall_v3")
    }

    private func startDeferredCleanupTask() {
        Task { @MainActor in
            // Run a periodic cleanup loop for the first 10 seconds of app launch
            // to catch files/folders that sync down asynchronously from iCloud Drive.
            for _ in 0..<10 {
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                await runDeferredCleanup()
            }
            userDefaults.set(false, forKey: "pendingFreshInstallCleanup")
        }
    }
    
    func runDeferredCleanup() async {
        await Task.detached(priority: .background) { [fileManager] in
            let docDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            let supportDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            
            // 1. Delete local documents
            if let docDir = docDir {
                if let items = try? fileManager.contentsOfDirectory(at: docDir, includingPropertiesForKeys: nil) {
                    for item in items {
                        try? fileManager.removeItem(at: item)
                    }
                }
            }
            
            // 2. Delete local sandbox Inbox directory
            if let supportDir = supportDir {
                let inboxDir = supportDir.appendingPathComponent("InksyncVault/Inbox", isDirectory: true)
                if let items = try? fileManager.contentsOfDirectory(at: inboxDir, includingPropertiesForKeys: nil) {
                    for item in items {
                        try? fileManager.removeItem(at: item)
                    }
                }
            }
            
            // 3. Vaporize iCloud Ubiquity container Documents if available
            if let iCloudDocDir = FileManager.default.url(forUbiquityContainerIdentifier: nil)?.appendingPathComponent("Documents") {
                if let items = try? fileManager.contentsOfDirectory(at: iCloudDocDir, includingPropertiesForKeys: nil) {
                    for item in items {
                        try? fileManager.removeItem(at: item)
                    }
                }
            }
        }.value
    }
    
    private func excludeDirectoryFromBackup(url: URL) {
        var mutableURL = url
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? mutableURL.setResourceValues(resourceValues)
    }
    
    private func performNuke(supportDir: URL) {
        // 1. Vaporize Documents Directory Contents (Nukes all ghost CBZs/PDFs automatically synced by iCloud)
        if let docDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            if let items = try? fileManager.contentsOfDirectory(at: docDir, includingPropertiesForKeys: nil) {
                for item in items { try? fileManager.removeItem(at: item) }
            }
        }
        
        // 2. Vaporize Application Support Directory Contents (Wipes SQLite database and SwiftData stores)
        if let items = try? fileManager.contentsOfDirectory(at: supportDir, includingPropertiesForKeys: nil) {
            for item in items {
                // Skip the sentinel itself — it shouldn't exist yet but be safe.
                if item.lastPathComponent.hasPrefix(".inksync_install_sentinel") { continue }
                try? fileManager.removeItem(at: item)
            }
        }
        
        // 3. Vaporize restored UserDefaults to prevent backup configuration from dirtying the clean install
        if let bundleID = Bundle.main.bundleIdentifier {
            userDefaults.removePersistentDomain(forName: bundleID)
            userDefaults.synchronize()
        }
        
        // 4. Vaporize App Group UserDefaults (wipes widgets cache/metadata)
        let groupSuiteName = "group.com.antigravity.inksync"
        if let groupDefaults = UserDefaults(suiteName: groupSuiteName) {
            groupDefaults.removePersistentDomain(forName: groupSuiteName)
            groupDefaults.synchronize()
        }
        
        // 5. Vaporize all secure Keychain items for a fresh start
        wipeKeychain()
        
        Logger.shared.log("InksyncProApp: Fresh install nuke complete. Ghost data eradicated.", category: "Migration", type: .warning)
    }
    
    private func wipeKeychain() {
        let secClasses = [
            kSecClassGenericPassword,
            kSecClassInternetPassword,
            kSecClassCertificate,
            kSecClassKey,
            kSecClassIdentity
        ]
        for secClass in secClasses {
            let query = [kSecClass: secClass] as [String: Any]
            SecItemDelete(query as CFDictionary)
        }
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
