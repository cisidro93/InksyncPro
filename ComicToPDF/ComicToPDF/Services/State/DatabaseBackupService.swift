import Foundation
import SwiftData
import SQLite3

final class DatabaseBackupService: Sendable {
    static let shared = DatabaseBackupService()
    private init() {}
    
    private let compactionQueue = DispatchQueue(label: "com.inksyncpro.compaction")
    private let compactionState = CompactionState()
    
    private final class CompactionState: @unchecked Sendable {
        var workItem: DispatchWorkItem?
    }
    
    func scheduleCompaction() {
        compactionQueue.async {
            self.compactionState.workItem?.cancel()
            
            let workItem = DispatchWorkItem {
                self.executeCompaction()
            }
            self.compactionState.workItem = workItem
            self.compactionQueue.asyncAfter(deadline: .now() + 3.0, execute: workItem)
        }
    }
    
    private func executeCompaction() {
        let container = InksyncProApp.sharedModelContainer
        guard let storeURL = container.configurations.first?.url else {
            Logger.shared.log("Compaction: Store URL configuration not found.", category: "Database", type: .warning)
            return
        }
        
        var db: OpaquePointer?
        if sqlite3_open_v2(storeURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK {
            var errorMsg: UnsafeMutablePointer<Int8>?
            if sqlite3_exec(db, "VACUUM;", nil, nil, &errorMsg) == SQLITE_OK {
                Logger.shared.log("Compaction: Database compacted and pages defragmented (VACUUM completed).", category: "Database", type: .success)
            } else {
                let errMsg = errorMsg.flatMap { String(cString: $0) } ?? "unknown error"
                Logger.shared.log("Compaction: Failed to execute VACUUM: \(errMsg)", category: "Database", type: .error)
                if let errorMsg = errorMsg {
                    sqlite3_free(errorMsg)
                }
            }
            sqlite3_close(db)
        } else {
            Logger.shared.log("Compaction: Failed to open SQLite store at \(storeURL.lastPathComponent)", category: "Database", type: .error)
        }
    }
    
    private let maxBackupCount = 5
    private let minBackupInterval: TimeInterval = 300 // 5 minutes cooldown
    private static let lastBackupKey = "lastDatabaseBackupTimestamp"
    
    func performBackup() {
        let now = Date()
        if let lastTime = UserDefaults.standard.object(forKey: Self.lastBackupKey) as? Date,
           now.timeIntervalSince(lastTime) < minBackupInterval {
            // Throttled
            return
        }
        
        UserDefaults.standard.set(now, forKey: Self.lastBackupKey)
        
        // Run on background thread to prevent UI freezing
        DispatchQueue.global(qos: .background).async {
            self.executeBackupSync()
        }
    }
    
    private func executeBackupSync() {
        let fileManager = FileManager.default
        let container = InksyncProApp.sharedModelContainer
        
        guard let storeURL = container.configurations.first?.url else {
            Logger.shared.log("Backup: Store URL configuration not found.", category: "Database", type: .warning)
            return
        }
        
        // Find SQLite auxiliary file URLs
        let shmURL = storeURL.deletingPathExtension().appendingPathExtension("store-shm")
        let walURL = storeURL.deletingPathExtension().appendingPathExtension("store-wal")
        
        guard fileManager.fileExists(atPath: storeURL.path) else {
            Logger.shared.log("Backup: Database store file does not exist at path: \(storeURL.path)", category: "Database", type: .info)
            return
        }
        
        // Setup backups directory inside Documents folder
        guard let documentsDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            Logger.shared.log("Backup: Documents directory not resolved.", category: "Database", type: .error)
            return
        }
        
        let backupsDir = documentsDir.appendingPathComponent("DatabaseBackups", isDirectory: true)
        
        do {
            try fileManager.createDirectory(at: backupsDir, withIntermediateDirectories: true)
            
            // Create timestamped directory for this snapshot
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy_MM_dd_HH_mm_ss"
            let timestamp = formatter.string(from: Date())
            let snapshotDir = backupsDir.appendingPathComponent("backup_\(timestamp)", isDirectory: true)
            try fileManager.createDirectory(at: snapshotDir, withIntermediateDirectories: true)
            
            // Copy main store file
            let destStore = snapshotDir.appendingPathComponent(storeURL.lastPathComponent)
            try fileManager.copyItem(at: storeURL, to: destStore)
            
            // Copy shm file if it exists
            if fileManager.fileExists(atPath: shmURL.path) {
                let destShm = snapshotDir.appendingPathComponent(shmURL.lastPathComponent)
                try fileManager.copyItem(at: shmURL, to: destShm)
            }
            
            // Copy wal file if it exists
            if fileManager.fileExists(atPath: walURL.path) {
                let destWal = snapshotDir.appendingPathComponent(walURL.lastPathComponent)
                try fileManager.copyItem(at: walURL, to: destWal)
            }
            
            Logger.shared.log("Backup: Database backup successfully created at \(snapshotDir.lastPathComponent)", category: "Database", type: .success)
            
            // Prune older backups
            self.pruneOldBackups(in: backupsDir)
            
        } catch {
            Logger.shared.log("Backup: Failed to create database backup: \(error.localizedDescription)", category: "Database", type: .error)
        }
    }
    
    private func pruneOldBackups(in backupsDir: URL) {
        let fileManager = FileManager.default
        do {
            let keys: [URLResourceKey] = [.isDirectoryKey, .creationDateKey]
            let contents = try fileManager.contentsOfDirectory(at: backupsDir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
            
            // Filter directories only and sort by creation date ascending (oldest first)
            let backupDirs = contents.filter { url in
                let resourceValues = try? url.resourceValues(forKeys: Set(keys))
                return resourceValues?.isDirectory ?? false
            }.sorted { url1, url2 in
                let date1 = (try? url1.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date.distantPast
                let date2 = (try? url2.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date.distantPast
                return date1 < date2
            }
            
            // If backup count exceeds max count, remove the oldest ones
            if backupDirs.count > maxBackupCount {
                let overflowCount = backupDirs.count - maxBackupCount
                for i in 0..<overflowCount {
                    let oldDir = backupDirs[i]
                    try fileManager.removeItem(at: oldDir)
                    Logger.shared.log("Backup: Pruned oldest backup snapshot: \(oldDir.lastPathComponent)", category: "Database", type: .info)
                }
            }
        } catch {
            Logger.shared.log("Backup: Failed to prune old database backups: \(error.localizedDescription)", category: "Database", type: .warning)
        }
    }
}
