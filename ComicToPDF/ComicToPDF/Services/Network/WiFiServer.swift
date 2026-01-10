import Foundation
import Network

class WiFiServer: ObservableObject {
    private var listener: NWListener?
    @Published var isRunning = false
    @Published var serverURL: String = ""
    
    func start() {
        guard !isRunning else { return }
        
        do {
            let params = NWParameters.tcp
            let listener = try NWListener(using: params, on: 8080)
            
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    print("🚀 Server Ready on port 8080")
                    DispatchQueue.main.async {
                        self.isRunning = true
                        self.serverURL = "http://\(self.getIPAddress() ?? "localhost"):8080"
                    }
                case .failed(let error):
                    print("Server failed: \(error)")
                    self.stop()
                default: break
                }
            }
            
            listener.newConnectionHandler = { connection in
                self.handleConnection(connection)
            }
            
            listener.start(queue: .global(qos: .userInitiated))
            self.listener = listener
            
        } catch {
            print("Failed to start server: \(error)")
        }
    }
    
    func stop() {
        listener?.cancel()
        listener = nil
        DispatchQueue.main.async { self.isRunning = false }
    }
    
    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .global())
        receive(on: connection)
    }
    
    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            if let data = data, let request = String(data: data, encoding: .utf8) {
                // Simple HTTP Parsing
                let lines = request.components(separatedBy: "\r\n")
                if let firstLine = lines.first {
                    let parts = firstLine.components(separatedBy: " ")
                    if parts.count >= 2 {
                        let method = parts[0]
                        let path = parts[1].removingPercentEncoding ?? "/"
                        
                        if method == "GET" {
                            self.handleRequest(path: path, connection: connection)
                        }
                    }
                }
            }
            if error != nil { connection.cancel() }
        }
    }
    
    private func handleRequest(path: String, connection: NWConnection) {
        if path == "/" {
            // Serve HTML List
            let html = generateHTML()
            let response = """
            HTTP/1.1 200 OK\r
            Content-Type: text/html\r
            Content-Length: \(html.utf8.count)\r
            \r
            \(html)
            """
            connection.send(content: response.data(using: .utf8), completion: .contentProcessed({ _ in connection.cancel() }))
            
        } else {
            // Serve File
            let fileName = String(path.dropFirst()) // Remove slash
            let fileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(fileName)
            
            if FileManager.default.fileExists(atPath: fileURL.path) {
                do {
                    // Start File Transfer
                    let fileData = try Data(contentsOf: fileURL, options: .mappedIfSafe)
                    let header = """
                    HTTP/1.1 200 OK\r
                    Content-Type: application/octet-stream\r
                    Content-Disposition: attachment; filename="\(fileName)"\r
                    Content-Length: \(fileData.count)\r
                    \r
                    """
                    connection.send(content: header.data(using: .utf8), completion: .idempotent)
                    connection.send(content: fileData, completion: .contentProcessed({ _ in connection.cancel() }))
                } catch {
                    sendError(connection, 500)
                }
            } else {
                sendError(connection, 404)
            }
        }
    }
    
    private func sendError(_ connection: NWConnection, _ code: Int) {
        let response = "HTTP/1.1 \(code) Error\r\n\r\n"
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed({ _ in connection.cancel() }))
    }
    
    private func generateHTML() -> String {
        let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let files = (try? FileManager.default.contentsOfDirectory(at: docDir, includingPropertiesForKeys: nil)) ?? []
        
        let fileLinks = files
            .filter { ["pdf", "epub"].contains($0.pathExtension.lowercased()) }
            .map { "<li><a href=\"/\($0.lastPathComponent)\">\($0.lastPathComponent)</a> <span style='color:#888'>(\(formatBytes($0)))</span></li>" }
            .joined(separator: "\n")
        
        return """
        <html>
        <head>
            <title>Comic Transfer</title>
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <style>
                body { font-family: -apple-system, sans-serif; max-width: 800px; margin: 20px auto; padding: 20px; }
                h1 { color: #ff9500; }
                ul { list-style: none; padding: 0; }
                li { padding: 15px; border-bottom: 1px solid #eee; font-size: 18px; }
                a { text-decoration: none; color: #333; font-weight: 500; }
                a:hover { color: #ff9500; }
            </style>
        </head>
        <body>
            <h1>📚 Comic Transfer</h1>
            <p>Tap a file to download.</p>
            <ul>
                \(fileLinks.isEmpty ? "<li>No files found.</li>" : fileLinks)
            </ul>
        </body>
        </html>
        """
    }
    
    private func formatBytes(_ url: URL) -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
    
    // IP Helper
    private func getIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0 {
            var ptr = ifaddr
            while ptr != nil {
                defer { ptr = ptr?.pointee.ifa_next }
                let interface = ptr?.pointee
                let addrFamily = interface?.ifa_addr.pointee.sa_family
                if addrFamily == UInt8(AF_INET) || addrFamily == UInt8(AF_INET6) {
                    
                    // ✅ FIX: Safely unwrap the C-String pointer first
                    if let cString = interface?.ifa_name,
                       let name = String(cString: cString, encoding: .utf8),
                       name == "en0" {
                        
                        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        getnameinfo(interface?.ifa_addr, socklen_t(interface?.ifa_addr.pointee.sa_len ?? 0), &hostname, socklen_t(hostname.count), nil, socklen_t(0), NI_NUMERICHOST)
                        address = String(cString: hostname)
                    }
                }
            }
            freeifaddrs(ifaddr)
        }
        return address
    }
}
