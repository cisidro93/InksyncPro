import Foundation
import SwiftData

/// Daemon responsible for migrating massive amounts of legacy Documents/ sandbox data into the hidden AppStorageContext Vault.
@MainActor
class LibraryVaultMigrator {
    static let shared = LibraryVaultMigrator()
    
    private init() {}
    
    /// Called once during app initialization to physically evacuate files from iCloud visibility
    func executeVaultEvacuation(manager: ConversionManager) {
        let fm = FileManager.default
        let docDir = AppStorageContext.shared.inboxURL
        let vaultURL = AppStorageContext.shared.vaultURL
        var updated = false
        
        for index in manager.convertedPDFs.indices {
            let pdf = manager.convertedPDFs[index]
            let filename = pdf.url.lastPathComponent
            
            let legacyPublicPath = docDir.appendingPathComponent(filename)
            let secureVaultPath = vaultURL.appendingPathComponent(filename)
            
            // 1. If file physically exists in Documents, evacuate it immediately!
            if fm.fileExists(atPath: legacyPublicPath.path) {
                do {
                    // Prevent clone collisions
                    if fm.fileExists(atPath: secureVaultPath.path) {
                        try fm.removeItem(at: secureVaultPath)
                    }
                    
                    try fm.moveItem(at: legacyPublicPath, to: secureVaultPath)
                    
                    // Rewrite in-memory pointer
                    manager.convertedPDFs[index].url = secureVaultPath
                    updated = true
                    Logger.shared.log("Evacuated \(filename) to Vault Sandbox.", category: "System")
                } catch {
                    Logger.shared.log("Vault Migration Failed for \(filename): \(error)", category: "System", type: .error)
                }
            } 
            // 2. If the URL points somewhere invalid, but the file exists perfectly fine in the Vault (Absolute Path Rotation Bug on iOS)
            else if !fm.fileExists(atPath: pdf.url.path) && fm.fileExists(atPath: secureVaultPath.path) {
                manager.convertedPDFs[index].url = secureVaultPath
                updated = true
                Logger.shared.log("Healed absolute sandbox bounds for \(filename)", category: "System")
            }
        }
        
        if updated {
            manager.saveLibrary()
        }
    }
}
