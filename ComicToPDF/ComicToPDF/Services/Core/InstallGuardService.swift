import Foundation
import UIKit

/// Manages fresh-install detection to wipe ghost data safely.
final class InstallGuardService: @unchecked Sendable {
    static let shared = InstallGuardService()
    
    private let userDefaults = UserDefaults.standard
    private let fileManager = FileManager.default
    
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

        // Check if library database files already exist from a previous install/update
        let dbURL = supportDir.appendingPathComponent("InkSyncPro/library.db")
        let swiftDataURL = supportDir.appendingPathComponent("default.store")
        var legacyJSONURL: URL? = nil
        if let docDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            legacyJSONURL = docDir.appendingPathComponent("inksync_pro_library.json")
        }
        
        let dbExists = fileManager.fileExists(atPath: dbURL.path) ||
                       fileManager.fileExists(atPath: swiftDataURL.path) ||
                       (legacyJSONURL != nil && fileManager.fileExists(atPath: legacyJSONURL!.path))

        let shouldNuke = !sentinelExists && !dbExists
        
        if shouldNuke {
            performNuke(supportDir: supportDir)
        }
        
        // Always write (or re-write) the sentinel containing the current container path
        writeSentinel(at: sentinelURL, supportDir: supportDir)
        
        // Auto-complete onboarding flags for clean runs
        userDefaults.set(true, forKey: "hasCompletedOnboarding")
        userDefaults.set(true, forKey: "hasSeenOnboarding")
        userDefaults.set(true, forKey: "isNotFreshInstall_v3")
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
        
        Logger.shared.log("InksyncProApp: Fresh install nuke complete. Ghost data eradicated.", category: "Migration", type: .warning)
    }
    
    private func writeSentinel(at url: URL, supportDir: URL) {
        let content = supportDir.path
        do {
            // Ensure the parent directory exists — on fresh Signulous-signed installs
            // iOS does NOT pre-create applicationSupportDirectory, so the write fails
            // silently and leaves the sentinel permanently absent. Every subsequent
            // crash would then trigger performNuke and wipe library.json.
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
