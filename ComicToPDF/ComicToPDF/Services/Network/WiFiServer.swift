import Foundation
import Network

class WiFiServer: ObservableObject {
    private var listener: NWListener?
    @Published var isRunning = false
    @Published var serverURL: String = ""
    
    func start() {
        guard !isRunning else { return }
        
        // ✅ TRICK: Force Local Network Permission Prompt
        triggerLocalNetworkPrivacyAlert()
        
        do {
            // ✅ Explicitly allow insecure HTTP (no TLS) and reuse address
            let params = NWParameters(tls: nil)
            params.allowLocalEndpointReuse = true
            params.includePeerToPeer = true
            
            let listener = try NWListener(using: params, on: 8080)
            
            // ✅ Advertise Service (Bonjour)
            listener.service = NWListener.Service(name: "ComicToPDF", type: "_http._tcp")
            
            listener.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
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
            

            
            listener.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
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
            if let data = data {
                // Attempt to parse text header (Latin1 preserves byte count better than UTF8 for mixed content, but headers are ASCII)
                // We peek for the header end.
                if let headerRange = data.range(of: Data("\r\n\r\n".utf8)) {
                    let headerData = data[..<headerRange.lowerBound]
                    if let headerString = String(data: headerData, encoding: .utf8) {
                        let lines = headerString.components(separatedBy: "\r\n")
                        if let firstLine = lines.first {
                            let parts = firstLine.components(separatedBy: " ")
                            if parts.count >= 2 {
                                let method = parts[0]
                                let path = parts[1].removingPercentEncoding ?? "/"
                                
                                if method == "GET" {
                                    self.handleRequest(path: path, connection: connection)
                                } else if method == "POST" {
                                    // Pass the full data (including body)
                                    self.handlePostRequest(connection: connection, header: firstLine, data: data)
                                }
                            }
                        }
                    }
                }
            }
            if error != nil { connection.cancel() }
        }
    }
    
    // ✅ NEW: POST Handler for Uploads
    private func handlePostRequest(connection: NWConnection, header: String, data: Data) {
        // Simple Raw Binary Upload Handler (Compatible with JS Fetch body=file)
        
        // 1. Parse Headers
        let lines = header.components(separatedBy: " ")
        guard lines.count >= 2 else { sendError(connection, 400); return }
        
        // Naive Filename Extraction
        let rawName = lines[1].replacingOccurrences(of: "/upload/", with: "").replacingOccurrences(of: "/", with: "")
        let fileName = rawName.removingPercentEncoding ?? "upload_\(Date().timeIntervalSince1970).cbz"
        
        guard !fileName.isEmpty && fileName != "upload" else { sendError(connection, 400); return }

        // 2. Find Body Start in Data
        guard let separatorRange = data.range(of: Data("\r\n\r\n".utf8)) else {
             sendError(connection, 400)
             return
        }
        
        let bodyStartIndex = separatorRange.upperBound
        guard bodyStartIndex < data.endIndex else { sendError(connection, 400); return }
        
        let bodyData = data[bodyStartIndex...]
        
        // 3. Write Data
        let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let destURL = docDir.appendingPathComponent(fileName)
        
        do {
            try bodyData.write(to: destURL)
            sendError(connection, 200) // Ack
            
            // Trigger Library Update
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                NotificationCenter.default.post(name: Notification.Name("LibraryUpdated"), object: nil)
            }
        } catch {
             sendError(connection, 500)
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
        // Removing getIPAddress call here as it's not strictly necessary for the HTML body and reduces complexity
        
        let fileLinks = files
            .filter { ["pdf", "epub", "cbz", "cbr"].contains($0.pathExtension.lowercased()) }
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
                .upload-box { background: #f9f9f9; padding: 20px; border-radius: 12px; border: 2px dashed #ccc; text-align: center; margin-bottom: 20px; }
                button { background: #ff9500; color: white; border: none; padding: 10px 20px; border-radius: 8px; font-size: 16px; cursor: pointer; }
                button:disabled { background: #ccc; }
            </style>
        </head>
        <body>
            <h1>📚 Comic Transfer</h1>
            
            <div class="upload-box">
                <h3>Upload Comic (CBZ/PDF)</h3>
                <input type="file" id="fileInput">
                <button onclick="uploadFile()">Upload</button>
                <div id="status" style="margin-top: 10px;"></div>
            </div>

            <script>
                async function uploadFile() {
                    let file = document.getElementById('fileInput').files[0];
                    if (!file) return;
                    
                    document.getElementById('status').innerText = "Uploading " + file.name + "...";
                    let btn = document.querySelector('button');
                    btn.disabled = true;
                    
                    try {
                        let response = await fetch('/upload/' + encodeURIComponent(file.name), {
                            method: 'POST',
                            body: file
                        });
                        
                        if (response.ok) {
                            document.getElementById('status').innerText = "✅ Upload Complete! Refreshing...";
                            setTimeout(() => location.reload(), 2000);
                        } else {
                            document.getElementById('status').innerText = "❌ Error: " + response.statusText;
                        }
                    } catch (e) {
                         document.getElementById('status').innerText = "❌ Network Error";
                    }
                    btn.disabled = false;
                }
            </script>
            
            <h3>Available Files</h3>
            <p style="color:#666; font-size: 14px;">Tap a file to download.</p>
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
    
    // ✅ Helper to force permission prompt
    private func triggerLocalNetworkPrivacyAlert() {
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: "_http._tcp", domain: nil), using: params)
        browser.stateUpdateHandler = { _ in }
        browser.start(queue: .global())
        
        // Stop after 5 seconds
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            browser.cancel()
        }
    }
}
