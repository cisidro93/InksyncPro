import Foundation
import ZIPFoundation
import SwiftUI

// ✅ NEW: structured Log Levels
enum LogType: String, CaseIterable, Codable {
    case info = "INFO"
    case warning = "WARNING"
    case error = "ERROR"
    case success = "SUCCESS"
    case system = "SYSTEM"
    
    var color: Color {
        switch self {
        case .info: return .primary
        case .warning: return .orange
        case .error: return .red
        case .success: return .green
        case .system: return .purple
        }
    }
    
    var icon: String {
        switch self {
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.octagon.fill"
        case .success: return "checkmark.circle"
        case .system: return "gear"
        }
    }
}

struct LogEntry: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let type: LogType
    let category: String
    let message: String
    
    // Helper to parse line: "[10:30:00] [INFO] [Category] Message"
    static func from(line: String) -> LogEntry? {
        // Very basic parsing for now to stay robust
        // Expected: [Time] [TYPE] [Category] Message
        // If we can't parse perfectly, we default to INFO
        
        let parts = line.split(separator: "]", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return nil }
        
        // 0: [Time
        // 1:  [TYPE
        // 2:  [Category
        // 3:  Message
        
        let typeStr = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " ["))
        let categoryStr = parts[2].trimmingCharacters(in: CharacterSet(charactersIn: " ["))
        let messageStr = parts[3].trimmingCharacters(in: .whitespaces)
        
        let type = LogType(rawValue: typeStr) ?? .info
        
        return LogEntry(id: UUID(), timestamp: Date(), type: type, category: categoryStr, message: messageStr)
    }
}

@MainActor
class Logger: ObservableObject {
    static let shared = Logger()
    
    private let logFileName = "debug.log"
    @Published var recentLogs: String = ""
    
    // ✅ NEW: Memory buffer for UI (Last 100 logs)
    // We don't want to read file every time for small updates
    @Published var parsedLogs: [LogEntry] = [] 
    
    private let queue = DispatchQueue(label: "com.comicvault.logger", qos: .utility)
    
    private init() {
        // Load initial logs on startup (async)
        Task {
            let logs = self.getLogs()
            self.parsedLogs = self.parseLogFile(content: logs)
        }
    }
    
    var logFileURL: URL {
        let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docDir.appendingPathComponent(logFileName)
    }
    
    func log(_ message: String, category: String = "INFO", type: LogType = .info) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        // Format: [12:00:00] [INFO] [Category] Message
        let logEntry = "[\(timestamp)] [\(type.rawValue)] [\(category)] \(message)\n"
        
        print("\(type.rawValue): \(message)") // Keep console output
        
        // Update UI Memory
        let entryObject = LogEntry(id: UUID(), timestamp: Date(), type: type, category: category, message: message)
        
        self.parsedLogs.insert(entryObject, at: 0)
        if self.parsedLogs.count > 500 { self.parsedLogs.removeLast() }
        
        // ✅ PHASE 8: Universal Alerts
        // Immediately broadcast critical failures to the SwiftUI View layer
        // so active bugs pop up on the user's screen instead of silently dropping.
        if type == .error {
            NotificationCenter.default.post(
                name: NSNotification.Name("GlobalErrorTriggered"),
                object: nil,
                userInfo: ["message": message, "category": category]
            )
        }
        
        let fileURL = self.logFileURL
        queue.async {
            // Append to file
            if let data = logEntry.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    if let fileHandle = try? FileHandle(forWritingTo: fileURL) {
                        _ = try? fileHandle.seekToEnd()
                        try? fileHandle.write(contentsOf: data)
                        try? fileHandle.close()
                    }
                } else {
                    try? data.write(to: fileURL)
                }
            }
        }
    }
    
    func getLogs() -> String {
        return (try? String(contentsOf: logFileURL, encoding: .utf8)) ?? ""
    }
    
    func clearLogs() {
        try? FileManager.default.removeItem(at: logFileURL)
        Task { @MainActor in self.parsedLogs.removeAll() }
        log("Logs Cleared", category: "SYSTEM", type: .system)
    }
    
    // ✅ NEW: Dynamic Domain Tracker
    // Scans memory array to figure out which domains are currently actively failing or reporting.
    var availableCategories: [String] {
        let uniqueCategories = Set(parsedLogs.map { $0.category })
        return Array(uniqueCategories).sorted()
    }
    
    // ✅ NEW: Smart Domain/Level Targeted Exporter
    // Generates a tailored textual stack-trace based heavily on what the user explicitly selects.
    func generateSmartLog(categories: [String]? = nil, types: [LogType]? = nil) -> URL? {
        var filteredLogs = parsedLogs
        
        if let targetTypes = types {
            filteredLogs = filteredLogs.filter { targetTypes.contains($0.type) }
        }
        
        if let targetCategories = categories {
            filteredLogs = filteredLogs.filter { targetCategories.contains($0.category) }
        }
        
        var logString = "--- Inksync Pro Smart Forensic Log ---\n"
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .medium)
        logString += "Generated: \(timestamp)\n"
        
        if let filters = categories {
            logString += "Domains: \(filters.joined(separator: ", "))\n"
        } else {
            logString += "Domains: All\n"
        }
        
        if let types = types {
            logString += "Levels: \(types.map { $0.rawValue }.joined(separator: ", "))\n"
        } else {
            logString += "Levels: All\n"
        }
        logString += "--------------------------------------\n\n"
        
        for entry in filteredLogs.reversed() { // Newest first
            let time = DateFormatter.localizedString(from: entry.timestamp, dateStyle: .none, timeStyle: .medium)
            logString += "[\(time)] [\(entry.type.rawValue)] [\(entry.category)] \(entry.message)\n"
        }
        
        let tempDir = FileManager.default.temporaryDirectory
        let safeName = (categories?.first ?? "System").replacingOccurrences(of: " ", with: "_").lowercased()
        let smartLogURL = tempDir.appendingPathComponent("inksync_\(safeName)_diagnostic.txt")
        
        do {
            try logString.write(to: smartLogURL, atomically: true, encoding: .utf8)
            return smartLogURL
        } catch {
            log("Failed to write smart log file to disk.", category: "System", type: .error)
            return nil
        }
    }
    
    // ✅ NEW: Generate a condensed error log for email support
    func generateErrorLogFile() -> URL? {
        let errorEntries = parsedLogs.filter { $0.type == .error || $0.type == .warning }
        var errorString = "--- Inksync Pro Condensed Error Log ---\n"
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .medium)
        errorString += "Generated: \(timestamp)\n\n"
        
        for entry in errorEntries.reversed() { // Newest first
            let time = DateFormatter.localizedString(from: entry.timestamp, dateStyle: .none, timeStyle: .medium)
            errorString += "[\(time)] [\(entry.type.rawValue)] [\(entry.category)] \(entry.message)\n"
        }
        
        let tempDir = FileManager.default.temporaryDirectory
        let errorLogURL = tempDir.appendingPathComponent("inksync_error_log.txt")
        
        do {
            try errorString.write(to: errorLogURL, atomically: true, encoding: .utf8)
            return errorLogURL
        } catch {
            log("Failed to write condensed error log", category: "System", type: .error)
            return nil
        }
    }
    
    // Helper to backfill from file
    private func parseLogFile(content: String) -> [LogEntry] {
        var entries: [LogEntry] = []
        let lines = content.components(separatedBy: .newlines)
        for line in lines.reversed() { // Newest first
            if let entry = LogEntry.from(line: line) {
                entries.append(entry)
            }
        }
        return entries
    }
    
    // ✅ DEBUG: Flight Recorder (Moved here to avoid Actor Isolation issues)
    func logEPUBStructure(at url: URL) {
        log("🔍 [Flight Recorder] Analyzing EPUB Structure: \(url.lastPathComponent)", category: "Debug", type: .info)
        
        guard let archive = try? Archive(url: url, accessMode: .read, pathEncoding: .utf8) else {
            log("Could not open archive for analysis", category: "Debug", type: .error)
            return
        }
        
        var i = 0
        for entry in archive {
            log("[\(i)] \(entry.path) Size: \(entry.uncompressedSize)", category: "Debug")
            
            // Check Mimetype
            if i == 0 {
                if entry.path != "mimetype" {
                    log("CRITICAL: First file is NOT mimetype! Found: \(entry.path)", category: "Debug", type: .error)
                }
            }
            // Check Container
            if entry.path == "META-INF/container.xml" {
                if i != 1 {
                     log("WARNING: container.xml is at index \(i)", category: "Debug", type: .warning)
                }
            }
            i += 1
        }
        log("Analysis Complete. Total Files: \(i)", category: "Debug", type: .success)
    }
}
