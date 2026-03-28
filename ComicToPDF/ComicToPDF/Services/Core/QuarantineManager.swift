import Foundation
import UIKit
import Combine

/// Advanced Service to intercept orphaned iCloud Drive documents on a fresh app installation,
/// migrating them into an isolated Quarantine Vault before LibraryScanner can silently import them.
class QuarantineManager: ObservableObject {
    static let shared = QuarantineManager()
    
    @Published var quarantinedFileCount: Int = 0
    @Published var quarantinedTotalSize: Int64 = 0
    @Published var isVaultActive: Bool = false
    
    private let quarantineFolderName = "Recovered_Vault"
    
    private init() {
        checkVaultStatus()
    }
    
    var quarantineURL: URL? {
        guard let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        return docDir.appendingPathComponent(quarantineFolderName, isDirectory: true)
    }
    
    /// Called at `App.onAppear` explicitly before `LibraryScanner` runs
    @MainActor
    func assessFirstLaunchOrphans() async {
        let hasLaunched = UserDefaults.standard.bool(forKey: "hasLaunchedBefore_v2")
        
        guard !hasLaunched else {
            // Already launched, but let's make sure our Published vars are awake
            checkVaultStatus()
            return
        }
        
        Logger.shared.log("First Launch Detected: Executing iCloud Orphan Quarantine Sweep...", category: "System")
        
        guard let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        
        do {
            let files = try FileManager.default.contentsOfDirectory(at: docDir, includingPropertiesForKeys: [.fileSizeKey])
            let mediaFiles = files.filter { url in
                let ext = url.pathExtension.lowercased()
                return ["pdf", "epub", "cbz", "cb7", "zip"].contains(ext) && !url.lastPathComponent.hasPrefix(".")
            }
            
            if !mediaFiles.isEmpty {
                Logger.shared.log("Found \(mediaFiles.count) orphaned iCloud files. Isolating to Vault...", category: "System", type: .warning)
                
                guard let vaultURL = quarantineURL else { return }
                if !FileManager.default.fileExists(atPath: vaultURL.path) {
                    try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
                }
                
                for file in mediaFiles {
                    let dest = vaultURL.appendingPathComponent(file.lastPathComponent)
                    if FileManager.default.fileExists(atPath: dest.path) {
                        try FileManager.default.removeItem(at: dest)
                    }
                    try FileManager.default.moveItem(at: file, to: dest)
                }
            }
            
            // Mark complete so it explicitly never runs again
            UserDefaults.standard.set(true, forKey: "hasLaunchedBefore_v2")
            
            checkVaultStatus()
            
        } catch {
            Logger.shared.log("Quarantine Error: \(error.localizedDescription)", category: "System", type: .error)
        }
    }
    
    /// Evaluates if the Vault has active ghosts
    func checkVaultStatus() {
        guard let vaultURL = quarantineURL, FileManager.default.fileExists(atPath: vaultURL.path) else {
            DispatchQueue.main.async { self.isVaultActive = false; self.quarantinedFileCount = 0 }
            return
        }
        
        do {
            let items = try FileManager.default.contentsOfDirectory(at: vaultURL, includingPropertiesForKeys: [.fileSizeKey])
            let validItems = items.filter { !($0.lastPathComponent == ".DS_Store" || $0.lastPathComponent.hasPrefix(".")) }
            
            var totalSize: Int64 = 0
            for item in validItems {
                let attr = try? FileManager.default.attributesOfItem(atPath: item.path)
                totalSize += attr?[.size] as? Int64 ?? 0
            }
            
            let count = validItems.count
            
            DispatchQueue.main.async {
                self.quarantinedFileCount = count
                self.quarantinedTotalSize = totalSize
                self.isVaultActive = count > 0
            }
            
        } catch {
            DispatchQueue.main.async { self.isVaultActive = false }
        }
    }
    
    // MARK: - Resolution Actions
    
    /// User selected "Purge": Deletes Vault completely.
    func purgeVault() {
        guard let vaultURL = quarantineURL else { return }
        do {
            try FileManager.default.removeItem(at: vaultURL)
            Logger.shared.log("Quarantine Vault Purged Successfully.", category: "System", type: .success)
            checkVaultStatus()
        } catch {
            Logger.shared.log("Failed to purge Vault: \(error.localizedDescription)", category: "System", type: .error)
        }
    }
    
    /// User selected "Restore": Moves Vault files to Documents, triggering `importFilesAsSeries`
    @MainActor
    func restoreVault(manager: ConversionManager) async {
        guard let vaultURL = quarantineURL else { return }
        guard let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        
        do {
            let files = try FileManager.default.contentsOfDirectory(at: vaultURL, includingPropertiesForKeys: nil)
            var copiedFiles: [URL] = []
            
            for file in files {
                guard !file.lastPathComponent.hasPrefix(".") else { continue }
                let ext = file.pathExtension.lowercased()
                
                // For direct DB integration, we just move it to Documents
                let dest = docDir.appendingPathComponent(file.lastPathComponent)
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.moveItem(at: file, to: dest)
                copiedFiles.append(dest)
            }
            
            // Clean up empty vault
            try FileManager.default.removeItem(at: vaultURL)
            checkVaultStatus()
            
            Logger.shared.log("Vault Restored \(copiedFiles.count) files. Executing deep library ingest...", category: "System")
            
            // Trigger LibraryScanner manually since files are now physically in root
            await LibraryScanner.shared.scanLibrary(addedByMode: .system, manager: manager)
            
        } catch {
            Logger.shared.log("Failed to restore Vault: \(error.localizedDescription)", category: "System", type: .error)
        }
    }
}
