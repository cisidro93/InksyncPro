import Foundation

class Logger: ObservableObject {
    static let shared = Logger()
    
    private let logFileName = "debug.log"
    @Published var recentLogs: String = ""
    
    private init() {}
    
    private var logFileURL: URL {
        let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docDir.appendingPathComponent(logFileName)
    }
    
    func log(_ message: String, category: String = "INFO") {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let logEntry = "[\(timestamp)] [\(category)] \(message)\n"
        
        print("\(logEntry.trimmingCharacters(in: .whitespacesAndNewlines))") // Keep console output
        
        // Append to file
        if let data = logEntry.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFileURL.path) {
                if let fileHandle = try? FileHandle(forWritingTo: logFileURL) {
                    fileHandle.seekToEndOfFile()
                    fileHandle.write(data)
                    fileHandle.closeFile()
                }
            } else {
                try? data.write(to: logFileURL)
            }
        }
    }
    
    func getLogs() -> String {
        return (try? String(contentsOf: logFileURL, encoding: .utf8)) ?? "No logs found."
    }
    
    func clearLogs() {
        try? FileManager.default.removeItem(at: logFileURL)
        log("Logs Cleared", category: "SYSTEM")
    }
    
    // ✅ DEBUG: Flight Recorder (Moved here to avoid Actor Isolation issues)
    func logEPUBStructure(at url: URL) {
        log("🔍 [Flight Recorder] Analyzing EPUB Structure: \(url.lastPathComponent)", category: "Debug")
        
        guard let archive = try? Archive(url: url, accessMode: .read) else {
            log("❌ Could not open archive for analysis", category: "Debug")
            return
        }
        
        var i = 0
        for entry in archive {
            log("[\(i)] \(entry.path) Size: \(entry.uncompressedSize)", category: "Debug")
            
            // Check Mimetype
            if i == 0 {
                if entry.path != "mimetype" {
                    log("❌ CRITICAL: First file is NOT mimetype! Found: \(entry.path)", category: "Debug")
                } else {
                     log("✅ Mimetype is first file", category: "Debug")
                }
                
                // Dump Content
                var data = Data()
                _ = try? archive.extract(entry) { data.append($0) }
                if let str = String(data: data, encoding: .ascii) {
                     log("📄 Mimetype Content: '\(str)'", category: "Debug")
                }
            }
            
            // Check Container
            if entry.path == "META-INF/container.xml" {
                if i != 1 {
                     log("⚠️ WARNING: container.xml is at index \(i)", category: "Debug")
                }
                var data = Data()
                _ = try? archive.extract(entry) { data.append($0) }
                if let str = String(data: data, encoding: .utf8) {
                     log("📄 Container.xml Content:\n\(str)", category: "Debug")
                }
            }
            
            // OPF
            if entry.path.hasSuffix(".opf") {
                 var data = Data()
                _ = try? archive.extract(entry) { data.append($0) }
                if let str = String(data: data, encoding: .utf8) {
                     log("📄 OPF Content:\n\(str)", category: "Debug")
                }
            }
            
            i += 1
        }
        log("🔍 [Flight Recorder] Analysis Complete. Total Files: \(i)", category: "Debug")
    }
}
