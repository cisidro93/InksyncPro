import SwiftUI
import Combine

struct DiagnosticsView: View {
    @State private var memoryUsage: Double = 0.0
    @State private var cacheSize: String = "Calculating..."
    @State private var isClearing: Bool = false
    @State private var cacheClearedMessage: String?
    
    // Timer to update memory usage every second
    let timer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()
    
    var body: some View {
        Form {
            Section(header: Text("Live Telemetry")) {
                HStack {
                    Text("Memory Footprint")
                    Spacer()
                    Text(String(format: "%.1f MB", memoryUsage))
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(memoryUsage > 1000 ? .red : (memoryUsage > 500 ? .orange : .green))
                }
                
                HStack {
                    Text("System Memory Limit")
                    Spacer()
                    Text("~ 2048 MB") // Approximate limit for Jetsam on modern devices
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            
            Section(header: Text("Storage & Caches")) {
                HStack {
                    Text("Disk Cache Size")
                    Spacer()
                    Text(cacheSize)
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                
                Button(role: .destructive) {
                    clearCaches()
                } label: {
                    HStack {
                        if isClearing {
                            ProgressView()
                                .padding(.trailing, 4)
                        } else {
                            Image(systemName: "trash")
                        }
                        Text("Emergency Cache Clear")
                    }
                }
                .disabled(isClearing)
                
                if let msg = cacheClearedMessage {
                    Text(msg)
                        .font(.caption)
                        .foregroundColor(.green)
                }
            }
            
            Section(header: Text("Reader Image Cache")) {
                Button(role: .destructive) {
                    PageBufferManager.shared.clearImageCache()
                    cacheClearedMessage = "In-memory Reader Cache cleared."
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        cacheClearedMessage = nil
                    }
                } label: {
                    Text("Clear Reader Buffer")
                }
                Text("This forcefully evicts all pre-decoded images from memory. Useful if you are mid-book and the app feels sluggish.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            updateMemory()
            calculateCacheSize()
        }
        .onReceive(timer) { _ in
            updateMemory()
        }
    }
    
    private func updateMemory() {
        self.memoryUsage = MemoryMonitor.reportMemoryUsage()
    }
    
    private func calculateCacheSize() {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
            var totalSize: Int64 = 0
            
            if let enumerator = FileManager.default.enumerator(at: cacheURL, includingPropertiesForKeys: [.fileSizeKey]) {
                for case let fileURL as URL in enumerator {
                    do {
                        let attr = try fileURL.resourceValues(forKeys: [.fileSizeKey])
                        if let size = attr.fileSize {
                            totalSize += Int64(size)
                        }
                    } catch {
                        continue
                    }
                }
            }
            
            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useMB, .useGB]
            formatter.countStyle = .file
            let formattedSize = formatter.string(fromByteCount: totalSize)
            
            DispatchQueue.main.async {
                self.cacheSize = formattedSize
            }
        }
    }
    
    private func clearCaches() {
        isClearing = true
        cacheClearedMessage = nil
        
        DispatchQueue.global(qos: .userInitiated).async {
            guard let cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
            
            do {
                let contents = try FileManager.default.contentsOfDirectory(at: cacheURL, includingPropertiesForKeys: nil)
                for fileURL in contents {
                    try? FileManager.default.removeItem(at: fileURL)
                }
            } catch {
                print("Failed to clear cache: \(error)")
            }
            
            DispatchQueue.main.async {
                self.isClearing = false
                self.cacheClearedMessage = "Disk cache successfully cleared."
                self.calculateCacheSize()
                
                // Clear the message after 3 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    self.cacheClearedMessage = nil
                }
            }
        }
    }
}
