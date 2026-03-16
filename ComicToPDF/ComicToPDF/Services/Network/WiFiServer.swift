import Foundation
import Network
import UIKit
import ZIPFoundation

class WiFiServer: ObservableObject {
    private var listener: NWListener?
    @Published var errorMessage: String?
    @Published var securityCode: String = "" // ✅ NEW: Security PIN
    @Published var activeConnections: Int = 0 // ✅ NEW: Monitoring
    @Published var isRunning = false
    @Published var serverURL: String?
    
    // Session State
    private var validSessions: Set<String> = []
    private let sessionLock = NSLock() // ✅ Fix: Thread Safety
    
    
    // ✅ NEW: Progress Tracking
    @Published var uploadProgress: Double = 0.0
    @Published var isUploading = false
    @Published var currentUploadFilename: String = ""
    
    // ✅ NEW: Background Task Support
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    
    func start() {
        guard !isRunning else { return }
        triggerLocalNetworkPrivacyAlert()
        
        // Reset State
        DispatchQueue.main.async { 
            self.errorMessage = nil 
            self.securityCode = String(format: "%04d", Int.random(in: 0...9999)) // Generate PIN
            self.activeConnections = 0
            
            self.sessionLock.lock()
            self.validSessions.removeAll()
            self.sessionLock.unlock()
        }
        
        do {
            // Use standard insecure TCP parameters to avoid implied TLS issues
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            params.includePeerToPeer = true
            
            // ✅ Fix: internal permission error often caused by trying to bind to Cellular/VPN
            params.requiredInterfaceType = .wifi
            
            let listener = try NWListener(using: params, on: 8080)
            
            // ✅ Hybrid P2P: Advertise the service so Inksync Boox/Mobile clients can discover it via mDNS
            listener.service = NWListener.Service(name: UIDevice.current.name, type: "_inksync._tcp")
            
            listener.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .ready:
                    let pin = self.securityCode
                    Logger.shared.log("WiFi Server Ready on port 8080. PIN: \(pin)", category: "Network")
                    DispatchQueue.main.async {
                        self.isRunning = true
                        let ip = self.getIPAddress() ?? "localhost"
                        self.serverURL = "http://\(ip):8080"
                    }
                case .failed(let error):
                    Logger.shared.log("Server failed: \(error.localizedDescription)", category: "Network", type: .error)
                    DispatchQueue.main.async {
                        // Check for specific permission denied codes
                        if error.debugDescription.contains("-65555") || error.localizedDescription.contains("NoAuth") {
                            self.errorMessage = "Local Network Permission Denied (Code: \(error)).\n\nPlease go to iOS Settings > Privacy & Security > Local Network, and ensure 'Inksync Pro' is enabled."
                        } else {
                            // ✅ Fix: Show full error details for debugging
                            self.errorMessage = "Failed to start server:\n\(error.localizedDescription)\n(Debug: \(error))"
                            Logger.shared.log("Server Start Failed: \(error)", category: "Network", type: .error)
                        }
                    }
                    if self.isRunning { self.stop() }
                default: break
                }
            }
            
            listener.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }
            
            listener.start(queue: .global(qos: .userInitiated))
            self.listener = listener
            
        } catch {
            Logger.shared.log("Failed to bind WiFi server to port 8080: \(error.localizedDescription)", category: "Network", type: .error)
            DispatchQueue.main.async {
                if error.localizedDescription.contains("NoAuth") || "\(error)".contains("-65555") {
                     self.errorMessage = "Local Network Permission Denied (Code: \(error)).\n\nPlease go to iOS Settings > Privacy & Security > Local Network, and ensure 'Inksync Pro' is enabled."
                } else {
                    // ✅ Fix: Show full error details for debugging
                    self.errorMessage = "Could not bind to port:\n\(error.localizedDescription)\n(Debug: \(error))"
                }
            }
        }
    }
    
    func stop() {
        listener?.cancel()
        listener = nil
        DispatchQueue.main.async {
            self.isRunning = false
            self.isUploading = false
            self.activeConnections = 0
            
            self.sessionLock.lock()
            self.validSessions.removeAll()
            self.sessionLock.unlock()
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
        var relativePath: String? = nil // ✅ NEW: Track folder structure
        var isAuthenticated = false // Track auth per request context
    }
    
    private func handleConnection(_ connection: NWConnection) {
        // Track Connection Start
        DispatchQueue.main.async { self.activeConnections += 1 }
        Logger.shared.log("New Connection from \(connection.endpoint)", category: "Network")
        
        // Track Connection End
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                DispatchQueue.main.async { self?.activeConnections = max(0, (self?.activeConnections ?? 1) - 1) }
            default: break
            }
        }
        
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
                connection.cancel()
            } else if let error = error {
                Logger.shared.log("Connection Error: \(error)", category: "Network", type: .error)
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
                let bodyData = context.buffer[range.upperBound...] // Remaining data is part of body or POST payload
                
                if let headerString = String(data: headerData, encoding: .utf8) {
                    parseHeaders(headerString, bodyData: bodyData, connection: connection, context: context)
                }
                
                // Note: We don't clear buffer here immediately because POST requests might need the body data we just split
            }
        } else {
            // Streaming Mode (Uploads)
            // Only write if we are authenticated and expecting a file
            if context.isAuthenticated && context.fileHandle != nil {
                writeBodyData(data, context: context)
                checkUploadCompletion(connection: connection, context: context)
            }
        }
    }
    
    private func parseHeaders(_ headerString: String, bodyData: Data, connection: NWConnection, context: ConnectionContext) {
        let lines = headerString.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else { return }
        
        let parts = firstLine.components(separatedBy: " ")
        guard parts.count >= 2 else { return }
        
        // 1. Check Authentication (Cookie)
        var sessionToken: String?
        for line in lines {
            if line.lowercased().hasPrefix("cookie:") {
                let components = line.components(separatedBy: ":")
                if components.count > 1 {
                    let cookies = components[1].components(separatedBy: ";")
                    for cookie in cookies {
                        let trimmed = cookie.trimmingCharacters(in: .whitespaces)
                        if trimmed.hasPrefix("session=") {
                            sessionToken = String(trimmed.dropFirst("session=".count))
                        }
                    }
                }
            }
        }
        
        // Validate Session
        if let token = sessionToken {
            sessionLock.lock()
            if validSessions.contains(token) {
                context.isAuthenticated = true
            }
            sessionLock.unlock()
        }
        
        let method = parts[0]
        let path = parts[1].removingPercentEncoding ?? "/"
        
        // 2. Handle Login POST separately (Does not require auth)
        if method == "POST" && path == "/login" {
            handleLogin(lines: lines, bodyData: bodyData, connection: connection)
            return
        }
        
        // 3. Enforce Auth for everything else
        guard context.isAuthenticated else {
            // Serve Login Page
            let html = generateLoginPage()
            sendResponse(connection, 200, html, contentType: "text/html")
            return
        }
        
        // 4. Handle Authorized Requests
        if method == "GET" {
            handleGetRequest(path: path, connection: connection)
        } else if method == "POST" {
            // Extract Headers
            var explicitFileName: String? = nil
            var relativePath: String? = nil
            for line in lines {
                if line.lowercased().hasPrefix("content-length:") {
                    let value = line.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces) ?? "0"
                    context.expectedLength = Int64(value) ?? 0
                }
                if line.lowercased().hasPrefix("x-file-name:") {
                    explicitFileName = line.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces)
                }
                if line.lowercased().hasPrefix("x-relative-path:") {
                    relativePath = line.components(separatedBy: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
                }
            }
            
            // Setup File Writing
            let rawName = parts[1].replacingOccurrences(of: "/upload/", with: "").replacingOccurrences(of: "/", with: "")
            let fallbackName = rawName.isEmpty || rawName == "upload" ? "upload_\(Date().timeIntervalSince1970).cbz" : rawName
            let fileName = explicitFileName ?? fallbackName
            
            context.filename = fileName
            context.relativePath = relativePath
            setupUpload(context: context)
            
            // Streaming Logic
            context.isHeaderParsed = true 
            
            if !bodyData.isEmpty {
                writeBodyData(bodyData, context: context)
                checkUploadCompletion(connection: connection, context: context)
            }
            
            context.buffer = Data()
        }
    }
    
    private func handleLogin(lines: [String], bodyData: Data, connection: NWConnection) {
        // Parse "pin=1234" from body
        guard let bodyString = String(data: bodyData, encoding: .utf8) else {
            sendResponse(connection, 400, "Bad Request")
            return
        }
        
        let components = bodyString.components(separatedBy: "=")
        if components.count == 2 && components[0] == "pin" {
            let submittedPin = components[1].trimmingCharacters(in: .whitespacesAndNewlines)
            
            if submittedPin == self.securityCode {
                // Success
                let newToken = UUID().uuidString
                
                sessionLock.lock()
                validSessions.insert(newToken)
                sessionLock.unlock()
                
                // Set Cookie and Redirect to /
                Logger.shared.log("Authentication Successful", category: "Network")
                let response = """
                HTTP/1.1 302 Found\r
                Location: /\r
                Set-Cookie: session=\(newToken); Path=/; Max-Age=3600\r
                Content-Length: 0\r
                Connection: close\r
                \r
                """
                connection.send(content: response.data(using: .utf8), completion: .contentProcessed({ _ in connection.cancel() }))
                
            } else {
                Logger.shared.log("Auth Failed: Incorrect PIN", category: "Network", type: .error)
                let html = generateLoginPage(error: "Invalid PIN")
                sendResponse(connection, 401, html, contentType: "text/html")
            }
        } else {
             let html = generateLoginPage(error: "Invalid Format")
             sendResponse(connection, 400, html, contentType: "text/html")
        }
    }

    private func generateLoginPage(error: String? = nil) -> String {
        return """
        <html>
        <head>
            <title>Login - Inksync Pro</title>
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <style>
                body { font-family: -apple-system, sans-serif; display: flex; justify-content: center; align-items: center; height: 100vh; background: #f2f2f7; margin: 0; }
                .card { background: white; padding: 40px; border-radius: 16px; box-shadow: 0 4px 12px rgba(0,0,0,0.1); text-align: center; width: 90%; max-width: 320px; }
                h1 { margin-bottom: 20px; color: #1c1c1e; }
                input { font-size: 24px; padding: 10px; text-align: center; letter-spacing: 5px; width: 100%; box-sizing: border-box; border: 1px solid #ddd; border-radius: 8px; margin-bottom: 20px; }
                button { background: #007aff; color: white; border: none; padding: 12px; width: 100%; border-radius: 8px; font-size: 16px; font-weight: 600; cursor: pointer; }
                .error { color: red; margin-bottom: 15px; }
            </style>
        </head>
        <body>
            <div class="card">
                <h1>Authentication</h1>
                \(error != nil ? "<div class='error'>\(error!)</div>" : "")
                <p>Enter the 4-digit PIN displayed in the app.</p>
                <form method="POST" action="/login">
                    <input type="tel" name="pin" maxlength="4" placeholder="0000" autofocus required>
                    <button type="submit">Connect</button>
                </form>
            </div>
        </body>
        </html>
        """
    }
    
    private func setupUpload(context: ConnectionContext) {
        context.isHeaderParsed = true
        
        let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var destURL: URL
        
        if let relPathString = context.relativePath, !relPathString.isEmpty {
            // Reconstruct the nested folder structure
            destURL = docDir.appendingPathComponent(relPathString)
            let directoryURL = destURL.deletingLastPathComponent()
            do {
                try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
            } catch {
                Logger.shared.log("Failed to create intermediate P2P directory: \(error.localizedDescription)", category: "Network", type: .error)
            }
        } else {
            destURL = docDir.appendingPathComponent(context.filename)
        }
        
        context.destinationURL = destURL
        
        // Create file
        FileManager.default.createFile(atPath: destURL.path, contents: nil, attributes: nil)
        Logger.shared.log("Starting Upload: \(destURL.lastPathComponent) to path: \(destURL.path)", category: "Network")
        
        do {
            context.fileHandle = try FileHandle(forWritingTo: destURL)
            
            // Start Background Task
            DispatchQueue.main.async {
                self.isUploading = true
                self.currentUploadFilename = destURL.lastPathComponent
                self.uploadProgress = 0.0
                self.startBackgroundTask()
            }
        } catch {
            Logger.shared.log("WiFi Transfer Failed to open file for writing: \(error.localizedDescription)", category: "Network", type: .error)
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
            Logger.shared.log("Upload Complete: \(context.filename) (\(context.receivedLength) bytes)", category: "Network")
            
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
        } else if path == "/queue.zip" {
            // ✅ NEW: Hybrid P2P On-The-Fly ZIP Streaming
            let stagedFiles = TransferQueueManager.shared.stagedFiles
            
            guard !stagedFiles.isEmpty else {
                sendResponse(connection, 404, "No staged files in the Transfer Queue.")
                return
            }
            
            do {
                // Determine a safe intermediate temp file for the zip
                let tempZipURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
                defer { try? FileManager.default.removeItem(at: tempZipURL) }
                
                guard let archive = Archive(url: tempZipURL, accessMode: .create) else {
                    sendResponse(connection, 500, "Failed to create archive stream.")
                    return
                }
                
                for file in stagedFiles {
                    try archive.addEntry(with: file.name, relativeTo: file.url.deletingLastPathComponent())
                }
                
                let zipData = try Data(contentsOf: tempZipURL, options: .mappedIfSafe)
                sendResponse(connection, 200, data: zipData, contentType: "application/zip", filename: "Inksync_Queue.zip")
            } catch {
                Logger.shared.log("WiFi Transfer ZIP Error: \(error.localizedDescription)", category: "Network", type: .error)
                sendResponse(connection, 500, "Internal Server Error during ZIP creation.")
            }
        } else {
            // URL Decode the path (critical for filenames with spaces!)
            // e.g. /my%20comic.epub -> my comic.epub
            let rawFileName = String(path.dropFirst())
            let fileName = rawFileName.removingPercentEncoding ?? rawFileName
            
            let fileURL = docDir.appendingPathComponent(fileName)
            
            if FileManager.default.fileExists(atPath: fileURL.path) {
                // Standard Content Type Strategy
                let ext = fileURL.pathExtension.lowercased()
                let contentType: String
                if ext == "html" {
                     contentType = "text/html"
                } else {
                     contentType = "application/octet-stream"
                }
                
                let downloadFilename = fileURL.lastPathComponent
                
                do {
                    // Mapped memory for large files
                    let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
                     sendResponse(connection, 200, data: data, contentType: contentType, filename: downloadFilename)
                } catch {
                    Logger.shared.log("WiFi Transfer Internal Mapping Error: \(error.localizedDescription)", category: "Network", type: .error)
                    sendResponse(connection, 500, "Internal Server Error")
                }
            } else {
                Logger.shared.log("WiFi Transfer - File not found: \(fileURL.lastPathComponent)", category: "Network", type: .warning)
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
        let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].resolvingSymlinksInPath()
        
        // Relies on FileManager enumerator for recursive scan
        var fileLinks: [String] = []
        let keys: [URLResourceKey] = [.nameKey, .isDirectoryKey, .fileSizeKey]
        
        // Recursive Scan to find files in subfolders (Library structure)
        if let enumerator = FileManager.default.enumerator(at: docDir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) {
            for case let rawFileURL as URL in enumerator {
                let fileURL = rawFileURL.resolvingSymlinksInPath()
                let ext = fileURL.pathExtension.lowercased()
                
                if ["pdf", "epub", "cbz"].contains(ext) {
                    // Calculate Relative Path for Link
                    var relativePath = fileURL.path.replacingOccurrences(of: docDir.path, with: "")
                    
                    // Remove leading slash to prevent "//hostname" interpretation
                    if relativePath.hasPrefix("/") {
                        relativePath.removeFirst()
                    }
                    
                    // Safe encoding
                    let linkPath = relativePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? relativePath
                    
                    let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
                    
                    fileLinks.append("""
                        <li>
                            <div class="file-info">
                                <span class="name">\(fileURL.lastPathComponent)</span>
                                <span class="meta">\(sizeStr)</span>
                            </div>
                            <!-- Ensure single slash -->
                            <a href="/\(linkPath)" class="download-btn" download>Download</a>
                        </li>
                    """)
                }
            }
        }
        
        let fileListHTML = fileLinks.isEmpty ? "<li style='justify-content:center; color:#999;'>No files found in Library</li>" : fileLinks.joined(separator: "\n")
        
        let stagedCount = TransferQueueManager.shared.stagedFiles.count
        let queueButtonHTML = stagedCount > 0 ? "<div style='margin-bottom: 20px;'><a href='/queue.zip' class='download-btn' style='display:block; text-align:center; padding: 12px; background: #34c759;'>Download \(stagedCount) Staged Files as ZIP</a></div>" : ""
        
        // HTML Response
        return """
        <html>
        <head>
            <title>Inksync Pro Transfer</title>
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <style>
                body { font-family: -apple-system, sans-serif; max-width: 800px; margin: 20px auto; padding: 20px; background: #f2f2f7; color: #1c1c1e; }
                .card { background: white; padding: 25px; border-radius: 16px; box-shadow: 0 4px 12px rgba(0,0,0,0.05); margin-bottom: 20px; }
                h1 { color: #ff9f0a; font-size: 28px; margin-bottom: 10px; }
                p { color: #666; margin-top: 5px; }
                h3 { margin-top: 0; }
                ul { list-style: none; padding: 0; }
                li { padding: 15px 0; border-bottom: 1px solid #eee; display: flex; justify-content: space-between; align-items: center; }
                li:last-child { border-bottom: none; }
                .file-info { display: flex; flex-direction: column; }
                .name { font-weight: 500; font-size: 16px; margin-bottom: 4px; }
                .meta { font-size: 13px; color: #888; }
                .download-btn { background: #007aff; color: white; text-decoration: none; padding: 6px 14px; border-radius: 16px; font-size: 14px; font-weight: 600; transition: 0.2s; }
                .download-btn:hover { background: #005bb5; }
                
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
                <p>Transfer comics directly to and from your device.</p>
                \(queueButtonHTML)
                
                <div class="upload-area" onclick="document.getElementById('fileInput').click()">
                    <h3>Tap to Upload</h3>
                    <p style="color:#888; font-size: 14px;">Select CBZ, PDF, or EPUB files</p>
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
                <h3>Library Files (Download)</h3>
                <p style="font-size: 13px; color: #888; margin-bottom: 15px;">
                    Files are served as-is. Use the <strong>Pro Panel</strong> export in the app to generate EPUB files for Kindle sideload.
                </p>
                <ul>
                    \(fileListHTML)
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
    
    // Removed duplicate errorMessage declaration
    
    // ... (Existing properties)

    // Robust IP Address Detection
    private func getIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        
        if getifaddrs(&ifaddr) == 0 {
            var ptr = ifaddr
            while ptr != nil {
                guard let interface = ptr?.pointee else { break }
                let addrFamily = interface.ifa_addr.pointee.sa_family
                
                // Check for IPv4 or IPv6
                if addrFamily == UInt8(AF_INET) || addrFamily == UInt8(AF_INET6) {
                    
                    if let cString = interface.ifa_name,
                       let name = String(cString: cString, encoding: .utf8) {
                        
                        // Ignore Loopback
                        if name == "lo0" {
                             ptr = interface.ifa_next
                             continue
                        }
                        
                        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len), &hostname, socklen_t(hostname.count), nil, socklen_t(0), NI_NUMERICHOST)
                        
                        let ipString = String(cString: hostname)
                        
                        // Prioritize "en0" (WiFi)
                        if name == "en0" {
                            address = ipString
                            if addrFamily == UInt8(AF_INET) {
                                freeifaddrs(ifaddr)
                                return ipString
                            }
                        } else if address == nil && addrFamily == UInt8(AF_INET) {
                            // Fallback
                            address = ipString
                        }
                    }
                }
                
                // Move to next - explicit pointer arithmetic without defer
                ptr = interface.ifa_next
            }
            freeifaddrs(ifaddr)
        }
        return address
    }
    
    func triggerLocalNetworkPrivacyAlert() {
        // 1. Legacy Trigger (NSNetService)
        let service = NetService(domain: "local.", type: "_http._tcp", name: "InksyncTrigger", port: 8080)
        service.publish()
        
        // 2. Modern Trigger (NWBrowser)
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: "_http._tcp", domain: nil), using: params)
        browser.start(queue: .global())
        
        // 3. UDP Multicast Trigger (Most Reliable)
        // Sending a packet to a multicast address (224.0.0.1) forces the OS to check Local Network permissions immediately.
        let multicastAddress = NWEndpoint.Host("224.0.0.1")
        guard let multicastPort = try? NWEndpoint.Port(rawValue: 9999) else { return }
        
        let udpConnection = NWConnection(host: multicastAddress, port: multicastPort, using: .udp)
        udpConnection.start(queue: .global())
        udpConnection.send(content: "Trigger".data(using: .utf8), completion: .contentProcessed { _ in
            udpConnection.cancel()
        })
        
        // Cleanup
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            browser.cancel()
            service.stop()
        }
    }
}
