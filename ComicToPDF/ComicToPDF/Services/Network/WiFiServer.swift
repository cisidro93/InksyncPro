import Foundation
import Network
import UIKit

class WiFiServer: ObservableObject {
    private var listener: NWListener?
    @Published var isRunning = false
    @Published var serverURL: String = ""
    
    // ✅ NEW: Progress Tracking
    @Published var uploadProgress: Double = 0.0
    @Published var isUploading = false
    @Published var currentUploadFilename: String = ""
    
    // ✅ NEW: Background Task Support
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    
    func start() {
        guard !isRunning else { return }
        triggerLocalNetworkPrivacyAlert()
        
        do {
            let params = NWParameters(tls: nil)
            params.allowLocalEndpointReuse = true
            params.includePeerToPeer = true
            
            let listener = try NWListener(using: params, on: 8080)
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
        DispatchQueue.main.async {
            self.isRunning = false
            self.isUploading = false
        }
    }
    
    // MARK: - Connection Handling
    
    // Context to track state per connection
    private class ConnectionContext {
        var buffer = Data()
        var isHeaderParsed = false
        var expectedLength: Int64 = 0
        var receivedLength: Int64 = 0
        var fileHandle: FileHandle?
        var destinationURL: URL?
        var filename: String = ""
    }
    
    private func handleConnection(_ connection: NWConnection) {
        let context = ConnectionContext()
        connection.start(queue: .global(qos: .default))
        receive(on: connection, context: context)
    }
    
    private func receive(on connection: NWConnection, context: ConnectionContext) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            
            if let data = data, !data.isEmpty {
                self.processData(data, connection: connection, context: context)
            }
            
            if isComplete {
                print("Connection closed by client.")
                self.cleanup(context: context)
                connection.cancel()
            } else if let error = error {
                print("Connection error: \(error)")
                self.cleanup(context: context)
                connection.cancel()
            } else {
                // Continue reading
                self.receive(on: connection, context: context)
            }
        }
    }
    
    private func processData(_ data: Data, connection: NWConnection, context: ConnectionContext) {
        if !context.isHeaderParsed {
            context.buffer.append(data)
            
            // Look for Double CRLF (End of Headers)
            if let range = context.buffer.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = context.buffer[..<range.lowerBound]
                let bodyData = context.buffer[range.upperBound...] // Remaining data is part of body
                
                if let headerString = String(data: headerData, encoding: .utf8) {
                    parseHeaders(headerString, connection: connection, context: context)
                }
                
                // If we successfully parsed headers and are in streaming mode, write the remainder
                if context.isHeaderParsed && !bodyData.isEmpty {
                    writeBodyData(bodyData, context: context)
                    checkUploadCompletion(connection: connection, context: context)
                }
                
                // Clear buffer as we are now streaming
                context.buffer = Data() 
            }
        } else {
            // Streaming Mode
            writeBodyData(data, context: context)
            checkUploadCompletion(connection: connection, context: context)
        }
    }
    
    private func parseHeaders(_ headerString: String, connection: NWConnection, context: ConnectionContext) {
        let lines = headerString.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else { return }
        
        // Debug
        // print("Headers: \(headerString)")
        
        let parts = firstLine.components(separatedBy: " ")
        guard parts.count >= 2 else { return }
        
        let method = parts[0]
        let path = parts[1].removingPercentEncoding ?? "/"
        
        if method == "GET" {
            handleGetRequest(path: path, connection: connection)
        } else if method == "POST" {
            // Extract Content-Length
            for line in lines {
                if line.lowercased().hasPrefix("content-length:") {
                    let value = line.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces) ?? "0"
                    context.expectedLength = Int64(value) ?? 0
                }
            }
            
            // Setup File Writing
            let rawName = parts[1].replacingOccurrences(of: "/upload/", with: "").replacingOccurrences(of: "/", with: "")
            let fileName = rawName.isEmpty || rawName == "upload" ? "upload_\(Date().timeIntervalSince1970).cbz" : rawName
            
            context.filename = fileName
            setupUpload(context: context)
        }
    }
    
    private func setupUpload(context: ConnectionContext) {
        context.isHeaderParsed = true
        
        let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let destURL = docDir.appendingPathComponent(context.filename)
        context.destinationURL = destURL
        
        // Create file
        FileManager.default.createFile(atPath: destURL.path, contents: nil, attributes: nil)
        
        do {
            context.fileHandle = try FileHandle(forWritingTo: destURL)
            
            // Start Background Task
            DispatchQueue.main.async {
                self.isUploading = true
                self.currentUploadFilename = context.filename
                self.uploadProgress = 0.0
                self.startBackgroundTask()
            }
        } catch {
            print("Failed to open file for writing: \(error)")
        }
    }
    
    private func writeBodyData(_ data: Data, context: ConnectionContext) {
        guard let fileHandle = context.fileHandle else { return }
        
        // Write to disk
        fileHandle.write(data)
        context.receivedLength += Int64(data.count)
        
        // Update Progress
        if context.expectedLength > 0 {
            let progress = Double(context.receivedLength) / Double(context.expectedLength)
            // Throttle UI updates slightly
            DispatchQueue.main.async {
                self.uploadProgress = progress
            }
        }
    }
    
    private func checkUploadCompletion(connection: NWConnection, context: ConnectionContext) {
        // Simple check: if we got all expected bytes
        if context.expectedLength > 0 && context.receivedLength >= context.expectedLength {
            print("Upload Complete: \(context.filename)")
            
            cleanup(context: context)
            sendResponse(connection, 200, "Upload Complete")
            
            DispatchQueue.main.async {
                self.isUploading = false
                self.uploadProgress = 1.0
                self.endBackgroundTask()
                
                // Notify App
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    NotificationCenter.default.post(name: Notification.Name("LibraryUpdated"), object: nil)
                }
            }
        }
    }
    
    private func cleanup(context: ConnectionContext) {
        try? context.fileHandle?.close()
        context.fileHandle = nil
    }
    
    // MARK: - Handlers
    
    private func handleGetRequest(path: String, connection: NWConnection) {
        let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        
        if path == "/" {
            let html = generateHTML()
            sendResponse(connection, 200, html, contentType: "text/html")
        } else {
            let fileName = String(path.dropFirst())
            let fileURL = docDir.appendingPathComponent(fileName)
            
            if FileManager.default.fileExists(atPath: fileURL.path) {
                // Determine Content Type
                let ext = fileURL.pathExtension.lowercased()
                let type = (ext == "html") ? "text/html" : "application/octet-stream"
                
                do {
                    let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
                     sendResponse(connection, 200, data: data, contentType: type, filename: fileName)
                } catch {
                    sendResponse(connection, 500, "Internal Server Error")
                }
            } else {
                sendResponse(connection, 404, "Not Found")
            }
        }
    }
    
    private func sendResponse(_ connection: NWConnection, _ code: Int, _ body: String, contentType: String = "text/plain") {
        let response = """
        HTTP/1.1 \(code) OK\r
        Content-Type: \(contentType)\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed({ _ in connection.cancel() }))
    }
    
    private func sendResponse(_ connection: NWConnection, _ code: Int, data: Data, contentType: String, filename: String? = nil) {
        var header = "HTTP/1.1 \(code) OK\r\nContent-Type: \(contentType)\r\nContent-Length: \(data.count)\r\n"
        if let filename = filename {
            header += "Content-Disposition: attachment; filename=\"\(filename)\"\r\n"
        }
        header += "Connection: close\r\n\r\n"
        
        connection.send(content: header.data(using: .utf8), completion: .idempotent)
        connection.send(content: data, completion: .contentProcessed({ _ in connection.cancel() }))
    }
    
    // MARK: - Background Task
    
    private func startBackgroundTask() {
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "WiFiUpload") {
            self.endBackgroundTask()
        }
    }
    
    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }
    
    // MARK: - HTML Generator
    
    private func generateHTML() -> String {
        let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let files = (try? FileManager.default.contentsOfDirectory(at: docDir, includingPropertiesForKeys: nil)) ?? []
        
        let fileLinks = files
            .filter { ["pdf", "epub", "cbz", "cbr"].contains($0.pathExtension.lowercased()) }
            .map { "<li><a href=\"/\($0.lastPathComponent)\">\($0.lastPathComponent)</a> <span style='color:#888'>(\(formatBytes($0)))</span></li>" }
            .joined(separator: "\n")
        
        // Embedded JavaScript handles the upload progress on the client side
        // But our server now handles the POST properly too
        return """
        <html>
        <head>
            <title>Inksync Pro Transfer</title>
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <style>
                body { font-family: -apple-system, sans-serif; max-width: 800px; margin: 20px auto; padding: 20px; background: #f2f2f7; color: #1c1c1e; }
                .card { background: white; padding: 25px; border-radius: 16px; box-shadow: 0 4px 12px rgba(0,0,0,0.05); margin-bottom: 20px; }
                h1 { color: #ff9f0a; font-size: 28px; margin-bottom: 10px; }
                h3 { margin-top: 0; }
                ul { list-style: none; padding: 0; }
                li { padding: 15px 0; border-bottom: 1px solid #eee; display: flex; justify-content: space-between; }
                li:last-child { border-bottom: none; }
                a { text-decoration: none; color: #1c1c1e; font-weight: 500; }
                .upload-area { border: 2px dashed #ddd; padding: 40px; text-align: center; border-radius: 12px; cursor: pointer; transition: 0.2s; }
                .upload-area:hover { border-color: #ff9f0a; background: #fff8eb; }
                button { background: #ff9f0a; color: white; border: none; padding: 12px 24px; border-radius: 8px; font-size: 16px; font-weight: 600; cursor: pointer; margin-top: 15px; }
                button:disabled { background: #ccc; }
                #progressBar { width: 100%; height: 6px; background: #eee; border-radius: 3px; margin-top: 15px; overflow: hidden; display: none; }
                #progressFill { height: 100%; background: #ff9f0a; width: 0%; transition: width 0.2s; }
            </style>
        </head>
        <body>
            <div class="card">
                <h1>Inksync Pro</h1>
                <p>Transfer comics directly to your device.</p>
                
                <div class="upload-area" onclick="document.getElementById('fileInput').click()">
                    <h3>Tap to Upload</h3>
                    <p style="color:#888; font-size: 14px;">Select CBZ, PDF, CBR, or EPUB files</p>
                    <input type="file" id="fileInput" style="display:none" onchange="handleFileSelect()">
                </div>
                
                <div id="fileDetails" style="display:none; margin-top: 20px; text-align: center;">
                    <strong id="fileName"></strong>
                    <div id="progressBar"><div id="progressFill"></div></div>
                    <div id="status" style="margin-top: 10px; color: #666;">Ready</div>
                    <button onclick="uploadFile()">Start Transfer</button>
                </div>
            </div>
            
            <div class="card">
                <h3>Device Files</h3>
                <ul>
                    \(fileLinks.isEmpty ? "<li style='justify-content:center; color:#999;'>No files found</li>" : fileLinks)
                </ul>
            </div>

            <script>
                function handleFileSelect() {
                    let file = document.getElementById('fileInput').files[0];
                    if (file) {
                        document.getElementById('fileDetails').style.display = 'block';
                        document.getElementById('fileName').innerText = file.name;
                    }
                }

                async function uploadFile() {
                    let file = document.getElementById('fileInput').files[0];
                    if (!file) return;
                    
                    let btn = document.querySelector('button');
                    let status = document.getElementById('status');
                    let bar = document.getElementById('progressBar');
                    let fill = document.getElementById('progressFill');
                    
                    btn.disabled = true;
                    bar.style.display = 'block';
                    status.innerText = "Uploading...";
                    
                    let xhr = new XMLHttpRequest();
                    xhr.open("POST", '/upload/' + encodeURIComponent(file.name), true);
                    
                    xhr.upload.onprogress = function(e) {
                        if (e.lengthComputable) {
                            let percent = (e.loaded / e.total) * 100;
                            fill.style.width = percent + "%";
                            status.innerText = Math.round(percent) + "% Uploaded";
                        }
                    };
                    
                    xhr.onload = function() {
                        if (xhr.status == 200) {
                            status.innerText = "✅ Complete!";
                            fill.style.background = "#34c759";
                            setTimeout(() => location.reload(), 1500);
                        } else {
                            status.innerText = "❌ Error: " + xhr.statusText;
                            btn.disabled = false;
                        }
                    };
                    
                    xhr.onerror = function() {
                        status.innerText = "❌ Network Error";
                        btn.disabled = false;
                    };
                    
                    xhr.send(file);
                }
            </script>
        </body>
        </html>
        """
    }
    
    // MARK: - Utilities
    
    private func formatBytes(_ url: URL) -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
    
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
    
    private func triggerLocalNetworkPrivacyAlert() {
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: "_http._tcp", domain: nil), using: params)
        browser.stateUpdateHandler = { _ in }
        browser.start(queue: .global())
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { browser.cancel() }
    }
}
