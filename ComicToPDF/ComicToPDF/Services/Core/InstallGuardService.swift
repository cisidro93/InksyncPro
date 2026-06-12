import Foundation
import UIKit

/// Manages fresh-install detection to wipe ghost data safely.
final class InstallGuardService: @unchecked Sendable {
    static let shared = InstallGuardService()
    
    private let userDefaults = UserDefaults.standard
    private let fileManager = FileManager.default
    
    private init() {}
    
    func executeGuard() {
        // Migration Shim: if user saw legacy onboarding but never set the new completed key
        let hasSeenOnboarding = userDefaults.bool(forKey: "hasSeenOnboarding")
        let hasCompletedOnboarding = userDefaults.bool(forKey: "hasCompletedOnboarding")
        
        if hasSeenOnboarding && !hasCompletedOnboarding {
            userDefaults.set(true, forKey: "hasCompletedOnboarding")
            Logger.shared.log("InstallGuard: Migrated hasSeenOnboarding -> hasCompletedOnboarding", category: "Migration")
        }
        
        // Ensure variable holds latest state after potential migration
        let isCompleted = userDefaults.bool(forKey: "hasCompletedOnboarding")
        let isNotFreshInstall = userDefaults.bool(forKey: "isNotFreshInstall_v3")
        
        let supportDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let sentinelURL = supportDir.appendingPathComponent(".inksync_install_sentinel_v1", isDirectory: false)
        let sentinelExists = fileManager.fileExists(atPath: sentinelURL.path)
        
        let shouldNuke: Bool
        
        if sentinelExists {
            // Sentinel is present — this is either an update or a normal re-launch.
            shouldNuke = false
        } else if isCompleted {
            // Onboarding completed, meaning it is an existing user.
            shouldNuke = false
        } else if isNotFreshInstall {
            // isNotFreshInstall is set, but sentinel is missing and onboarding isn't completed.
            // This flag alone means the app was run previously. Skip nuke to be safe.
            shouldNuke = false
        } else {
            // Neither sentinel nor onboarding/install flags — true first launch after a clean install.
            shouldNuke = true
        }
        
        if shouldNuke {
            #if DEBUG
            let isNukeEnabled = userDefaults.bool(forKey: "inksync_nuke_enabled")
            if !isNukeEnabled {
                Logger.shared.log("⚠️ DEBUG: Nuke would have fired. Files NOT deleted. Set 'inksync_nuke_enabled' to true to enable.", category: "Migration", type: .warning)
            } else {
                performNuke(supportDir: supportDir)
            }
            #else
            performNuke(supportDir: supportDir)
            #endif
        }
        
        // Always write (or re-write) the sentinel after every launch so it is always present
        // for the lifetime of the install. The file content is irrelevant; existence is the signal.
        writeSentinel(at: sentinelURL)
        
        // Keep the legacy UserDefaults flag set for backwards compatibility with any code
        // that may still read it.
        if !isNotFreshInstall {
            userDefaults.set(true, forKey: "isNotFreshInstall_v3")
        }
        
        // Auto-complete onboarding
        userDefaults.set(true, forKey: "hasCompletedOnboarding")
        userDefaults.set(true, forKey: "hasSeenOnboarding")
    }
    
    private func performNuke(supportDir: URL) {
        // 1. Vaporize Documents Directory Contents (Nukes all ghost CBZs automatically synced by iCloud)
        if let docDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            if let items = try? fileManager.contentsOfDirectory(at: docDir, includingPropertiesForKeys: nil) {
                for item in items { try? fileManager.removeItem(at: item) }
            }
        }
        
        // 2. Vaporize Application Support Directory Contents
        if let items = try? fileManager.contentsOfDirectory(at: supportDir, includingPropertiesForKeys: nil) {
            for item in items {
                // Skip the sentinel itself — it shouldn't exist yet but be safe.
                if item.lastPathComponent.hasPrefix(".inksync_install_sentinel") { continue }
                try? fileManager.removeItem(at: item)
            }
        }
        
        Logger.shared.log("InksyncProApp: Fresh install nuke complete. Ghost data eradicated.", category: "Migration", type: .warning)
    }
    
    private func writeSentinel(at url: URL) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        do {
            // Ensure the parent directory exists — on fresh Signulous-signed installs
            // iOS does NOT pre-create applicationSupportDirectory, so the write fails
            // silently and leaves the sentinel permanently absent. Every subsequent
            // crash would then trigger performNuke and wipe library.json.
            let parentDir = url.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: parentDir.path) {
                try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
            }
            try timestamp.write(to: url, atomically: true, encoding: .utf8)
            var mutableSentinelURL = url
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            try mutableSentinelURL.setResourceValues(resourceValues)
            Logger.shared.log("InstallGuard: Sentinel written successfully.", category: "Migration")
        } catch {
            // Fixed: was \\( which printed literal \(error.localizedDescription) instead of the value
            Logger.shared.log("InstallGuard: Failed to write sentinel or set resource values: \(error.localizedDescription)", category: "Migration", type: .error)
        }
    }
}
