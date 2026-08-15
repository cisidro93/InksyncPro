import Foundation

/// Enterprise diagnostic logger for iCloud transfers, cloud streaming, and sandbox security-scoped file access.
/// Outputs directly to `Logger.shared` under Category "Cloud".
enum CloudSyncDiagnosticLogger {
    
    enum Direction: String {
        case download = "⬇️ DOWNLOAD"
        case upload = "⬆️ UPLOAD"
        case backup = "📦 BACKUP"
    }
    
    static func logTransferStart(fileName: String, bytes: Int64, direction: Direction) {
        let formatted = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        Logger.shared.log("\(direction.rawValue) START — '\(fileName)' (\(formatted))", category: "Cloud", type: .info)
    }
    
    static func logTransferProgress(fileName: String, bytesTransferred: Int64, totalBytes: Int64, speedMBps: Double) {
        let pct = totalBytes > 0 ? Int((Double(bytesTransferred) / Double(totalBytes)) * 100) : 0
        let speedStr = speedMBps > 0 ? String(format: " (%.1f MB/s)", speedMBps) : ""
        Logger.shared.log("☁️ Progress '\(fileName)': \(pct)%\(speedStr)", category: "Cloud", type: .debug)
    }
    
    static func logTransferCompletion(fileName: String, bytes: Int64, durationSeconds: Double, success: Bool, errorMsg: String? = nil) {
        let formatted = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        if success {
            Logger.shared.log("✅ TRANSFER SUCCESS — '\(fileName)' (\(formatted)) in \(String(format: "%.1f", durationSeconds))s", category: "Cloud", type: .success)
        } else {
            Logger.shared.log("❌ TRANSFER FAILED — '\(fileName)': \(errorMsg ?? "Unknown error")", category: "Cloud", type: .error)
        }
    }
    
    static func logSecurityScopedResolution(url: URL, success: Bool, isLinked: Bool) {
        let status = success ? "✅ RESOLVED" : "❌ EXPIRED/DENIED"
        let linkedStr = isLinked ? " [Security-Scoped Bookmark]" : " [Local URL]"
        Logger.shared.log("🔒 Sandbox Access \(status)\(linkedStr) → \(url.lastPathComponent)", category: "Cloud", type: success ? .info : .warning)
    }
    
    static func logUbiquitousSync(key: String, payloadSize: Int, success: Bool) {
        let status = success ? "✅ SYNCED" : "⚠️ RETRYING"
        Logger.shared.log("☁️ Ubiquitous KVS \(status) — Key '\(key)' (\(payloadSize) bytes)", category: "Cloud", type: .info)
    }
}
