import Foundation
import Network
import UIKit
import ZIPFoundation
import SwiftData

@MainActor
final class WiFiServer: ObservableObject, Sendable {
    private var listener: NWListener?
    private var bonjourService: NetService?      // separate, non-fatal mDNS advertisement
    @Published var errorMessage: String?
    @Published var securityCode: String = ""
    @Published var activeConnections: Int = 0
    @Published var isRunning = false
    @Published var serverURL: String?
    
    // Session State
    private var validSessions: Set<String> = []
    private let sessionLock = NSLock()

    // IP Block List (5 failed PINs → block)
    private var blockedIPs: Set<String> = []
    private var failedAttempts: [String: Int] = [:]
    private let ipBlockThreshold = 5

    
    // ✅ NEW: Progress Tracking
    @Published var uploadProgress: Double = 0.0
    @Published var isUploading = false
    @Published var currentUploadFilename: String = ""
    
    // ✅ NEW: Background Task Support
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    
    // Tracks whether we've previously triggered the LAN permission dialog.
    // After the first successful trigger the permission entry appears in Settings,
    // so we never need to probe again — and probing while already-granted can
    // cause iOS to briefly revoke+recheck the grant, producing a false -6555.
    private var hasTriggeredLocalNetworkPermission: Bool {
        get { UserDefaults.standard.bool(forKey: "inksync.hasTriggeredLANPermission") }
        set { UserDefaults.standard.set(newValue, forKey: "inksync.hasTriggeredLANPermission") }
    }

    // How many times we've auto-retried the current start() attempt.
    private var bindRetryCount = 0
    private let maxBindRetries = 2

    func start() {
        // Always tear down any stale listener first so port 8080 is guaranteed free.
        listener?.cancel()
        listener = nil

        errorMessage = nil
        securityCode = generateSecurePin()
        activeConnections = 0
        bindRetryCount = 0

        sessionLock.lock()
        validSessions.removeAll()
        blockedIPs.removeAll()
        failedAttempts.removeAll()
        sessionLock.unlock()

        scheduleAutoShutdown()

        if !hasTriggeredLocalNetworkPermission {
            // First ever run: fire the probe so iOS shows the permission dialog,
            // then wait 2 s for the user to respond before binding.
            triggerLocalNetworkPrivacyAlert()
            hasTriggeredLocalNetworkPermission = true
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self.bindListener()
            }
        } else {
            // Permission already granted — bind immediately, no probe delay needed.
            self.bindListener()
        }
    }

    private func bindListener() {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            params.includePeerToPeer = true

            let listener: NWListener
            do {
                listener = try NWListener(using: params, on: 8080)
            } catch {
                Logger.shared.log("Port 8080 busy, falling back to dynamic port: \(error.localizedDescription)", category: "Network", type: .warning)
                listener = try NWListener(using: params, on: .any)
            }

            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self = self else { return }
                    switch state {
                    case .ready:
                        let port = listener.port?.rawValue ?? 8080
                        Logger.shared.log("WiFi Server ready on port \(port). PIN: \(self.securityCode)", category: "Network")
                        self.bindRetryCount = 0
                        self.isRunning = true
                        let ip = Self.getIPAddress() ?? "localhost"
                        self.serverURL = "http://\(ip):\(port)"
                        self.advertiseBonjourService(port: port)

                    case .failed(let error):
                        let raw = "\(error)"
                        Logger.shared.log("WiFi Server failed: \(raw)", category: "Network", type: .error)

                        let isNetworkAuthError = raw.contains("NoAuth") || raw.contains("-6555")
                            || raw.contains("posix(EPERM)")

                        if isNetworkAuthError && self.bindRetryCount < self.maxBindRetries {
                            self.bindRetryCount += 1
                            Logger.shared.log("WiFi Server: retrying bind (attempt \(self.bindRetryCount))", category: "Network")
                            Task.detached {
                                try? await Task.sleep(nanoseconds: 1_500_000_000)
                                await MainActor.run { [weak self] in
                                    self?.bindListener()
                                }
                            }
                            return
                        }

                        if isNetworkAuthError {
                            self.errorMessage = "Wi-Fi server failed to start.\n\n"
                                + "Local Network access is enabled in Settings, but iOS briefly blocked the connection.\n\n"
                                + "① Force-quit the app and reopen it, then tap Start Server.\n"
                                + "② If it still fails: Settings › InksyncPro › Local Network → toggle OFF then back ON."
                        } else {
                            self.errorMessage = "Server failed: \(error.localizedDescription)\n\nRaw: \(raw)"
                        }
                        if self.isRunning { self.stop() }

                    default: break
                    }
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    self?.handleConnection(connection)
                }
            }

            listener.start(queue: .global(qos: .userInitiated))
            self.listener = listener

        } catch {
            let raw = "\(error)"
            Logger.shared.log("Failed to bind WiFi server: \(raw)", category: "Network", type: .error)
            let isNetworkAuthError = raw.contains("NoAuth") || raw.contains("-6555") || raw.contains("EPERM")

            if isNetworkAuthError && bindRetryCount < maxBindRetries {
                bindRetryCount += 1
                Task.detached {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    await MainActor.run { [weak self] in
                        self?.bindListener()
                    }
                }
                return
            }

            if isNetworkAuthError {
                self.errorMessage = "Wi-Fi server failed to start.\n\n"
                    + "Local Network access is enabled in Settings, but iOS briefly blocked the connection.\n\n"
                    + "① Force-quit the app and reopen it, then tap Start Server.\n"
                    + "② If it still fails: Settings › InksyncPro › Local Network → toggle OFF then back ON."
            } else {
                self.errorMessage = "Could not start server: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Bonjour Advertisement (non-fatal, separate from NWListener)

    private func advertiseBonjourService(port: UInt16) {
        bonjourService?.stop()
        bonjourService = nil

        let service = NetService(
            domain: "local.",
            type: "_inksync._tcp.",
            name: UIDevice.current.name,
            port: Int32(port)
        )
        // NetService delegate would be needed to handle errors, but since this
        // is non-fatal we just let it succeed or fail silently.
        service.publish()
        bonjourService = service
        Logger.shared.log("WiFi Server: Bonjour advertisement started on port \(port)", category: "Network")
    }
    
    func stop() {
        listener?.cancel()
        listener = nil
        bonjourService?.stop()
        bonjourService = nil
        autoShutdownTask?.cancel()
        autoShutdownTask = nil
        self.isRunning = false
        self.isUploading = false
        self.activeConnections = 0
        
        self.sessionLock.lock()
        self.validSessions.removeAll()
        self.sessionLock.unlock()
    }

    func revokeAllSessions() {
        sessionLock.lock()
        validSessions.removeAll()
        sessionLock.unlock()
        Logger.shared.log("WiFiServer: All sessions revoked", category: "Network")
    }

    // MARK: - Auto-Shutdown

    private var autoShutdownTask: Task<Void, Never>?

    private func scheduleAutoShutdown() {
        autoShutdownTask?.cancel()
        let minutes = UserDefaults.standard.object(forKey: "wifiServerAutoShutdownMinutes") as? Int ?? 30
        guard minutes > 0 else { return }
        autoShutdownTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(minutes) * 60_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.stop() }
        }
    }

    // MARK: - Cryptographic PIN generation

    private func generateSecurePin() -> String {
        var bytes = [UInt8](repeating: 0, count: 3)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let value = (Int(bytes[0]) << 16 | Int(bytes[1]) << 8 | Int(bytes[2])) % 1_000_000
        return String(format: "%06d", value)
    }

    // MARK: - Cryptographic session token generation

    private func generateSessionToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02hhx", $0) }.joined()
    }


    // Context to track state per connection
    @MainActor
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
        var remoteIP: String = ""
    }
    
    private func handleConnection(_ connection: NWConnection) {
        // Track Connection Start
        self.activeConnections += 1
        Logger.shared.log("New Connection from \(connection.endpoint)", category: "Network")
        
        // Track Connection End
        let context = ConnectionContext()
        if case let .hostPort(host, _) = connection.endpoint {
            context.remoteIP = "\(host)"
        }
        
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .cancelled, .failed:
                    self?.activeConnections = max(0, (self?.activeConnections ?? 1) - 1)
                    self?.cleanup(context: context)
                    self?.endBackgroundTask()
                default: break
                }
            }
        }
        
        connection.start(queue: .global(qos: .default))
        receive(on: connection, context: context)
    }
    
    private func receive(on connection: NWConnection, context: ConnectionContext) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
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
    }
    
    private func processData(_ data: Data, connection: NWConnection, context: ConnectionContext) {
        if !context.isHeaderParsed {
            context.buffer.append(data)
            
            // SECURITY: Limit headers to 32KB to prevent memory exhaustion DoS
            guard context.buffer.count <= 32768 else {
                Logger.shared.log("Connection Terminated - Header Payload Too Large", category: "Network", type: .warning)
                connection.cancel()
                return
            }
            
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
        let rawPath = parts[1]
        let path = rawPath.removingPercentEncoding ?? rawPath
        
        // Extract cleanPath and queryItems
        var cleanPath = path
        var queryItems: [URLQueryItem] = []
        if let components = URLComponents(string: rawPath) {
            cleanPath = components.path
            queryItems = components.queryItems ?? []
        } else if let qMarkIdx = path.firstIndex(of: "?") {
            cleanPath = String(path[..<qMarkIdx])
            let queryStr = String(path[path.index(after: qMarkIdx)...])
            let pairs = queryStr.components(separatedBy: "&")
            for pair in pairs {
                let kv = pair.components(separatedBy: "=")
                if kv.count == 2 {
                    queryItems.append(URLQueryItem(name: kv[0], value: kv[1].removingPercentEncoding ?? kv[1]))
                }
            }
        }
        
        // 2. Handle Login POST separately (Does not require auth)
        if method == "POST" && cleanPath == "/login" {
            handleLogin(lines: lines, bodyData: bodyData, connection: connection, remoteIP: context.remoteIP)
            return
        }
        
        // 3. Enforce Auth for everything else (except page_sync GET)
        let isPageSync = (method == "GET" && cleanPath == "/page_sync")
        guard context.isAuthenticated || isPageSync else {
            // Distinguish between API requests and Browser fallback requests
            if cleanPath.hasPrefix("/api/") {
                sendResponse(connection, 401, "{\"error\": \"Unauthorized. PIN required.\"}", contentType: "application/json")
            } else {
                // Serve Login Page to Web Browsers
                let html = generateLoginPage()
                sendResponse(connection, 200, html, contentType: "text/html")
            }
            return
        }
        
        // 4. Handle Requests
        if method == "GET" {
            handleGetRequest(cleanPath: cleanPath, queryItems: queryItems, connection: connection)
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
            
            let success = setupUpload(context: context)
            if !success {
                // Reject duplicate or errored uploads instantly
                sendResponse(connection, 409, "File already exists or cannot be created.")
                return
            }
            
            // Streaming Logic
            context.isHeaderParsed = true 
            
            if !bodyData.isEmpty {
                writeBodyData(bodyData, context: context)
                checkUploadCompletion(connection: connection, context: context)
            }
            
            context.buffer = Data()
        }
    }
    
    private func handleLogin(lines: [String], bodyData: Data, connection: NWConnection, remoteIP: String) {

        // Check if IP is blocked
        sessionLock.lock()
        let isBlocked = blockedIPs.contains(remoteIP)
        sessionLock.unlock()

        if isBlocked {
            Logger.shared.log("WiFiServer: Login blocked for IP \(remoteIP)", category: "Network", type: .warning)
            sendResponse(connection, 403, "Blocked: too many failed attempts.")
            return
        }

        // Parse "pin=123456" from body
        guard let bodyString = String(data: bodyData, encoding: .utf8) else {
            sendResponse(connection, 400, "Bad Request")
            return
        }
        
        let components = bodyString.components(separatedBy: "=")
        if components.count >= 2 && components[0].trimmingCharacters(in: .whitespacesAndNewlines) == "pin" {
            let submittedPin = components[1...].joined(separator: "=")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .removingPercentEncoding ?? ""
            
            if submittedPin == self.securityCode {
                let newToken = generateSessionToken()

                sessionLock.lock()
                validSessions.insert(newToken)
                failedAttempts[remoteIP] = 0
                sessionLock.unlock()
                
                Logger.shared.log("Authentication Successful", category: "Network")
                let response = "HTTP/1.1 302 Found\r\n"
                    + "Location: /\r\n"
                    + "Set-Cookie: session=\(newToken); Path=/; Max-Age=3600; HttpOnly; SameSite=Strict\r\n"
                    + "Content-Length: 0\r\n"
                    + "Connection: close\r\n"
                    + "\r\n"
                connection.send(content: response.data(using: .utf8),
                                completion: .contentProcessed({ _ in connection.cancel() }))
                
            } else {
                Logger.shared.log("Auth Failed: Incorrect PIN from \(remoteIP)", category: "Network", type: .error)

                sessionLock.lock()
                let current = failedAttempts[remoteIP, default: 0] + 1
                failedAttempts[remoteIP] = current
                if current >= ipBlockThreshold {
                    blockedIPs.insert(remoteIP)
                    Logger.shared.log("WiFiServer: IP \(remoteIP) blocked after \(current) failed attempts", category: "Network", type: .error)
                }
                sessionLock.unlock()

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
        <!DOCTYPE html>
        <html lang="en">
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>Inksync Pro | Authenticate</title>
            <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap" rel="stylesheet">
            <style>
                :root {
                    --bg-color: #0B0F19;
                    --card-bg: rgba(17, 24, 39, 0.7);
                    --card-border: rgba(255, 255, 255, 0.08);
                    --text-primary: #F3F4F6;
                    --text-secondary: #9CA3AF;
                    --accent-primary: #3B82F6;
                    --accent-secondary: #6366F1;
                    --accent-glow: rgba(59, 130, 246, 0.15);
                    --error-color: #EF4444;
                    --success-color: #10B981;
                }

                @media (prefers-color-scheme: light) {
                    :root {
                        --bg-color: #F3F4F6;
                        --card-bg: rgba(255, 255, 255, 0.85);
                        --card-border: rgba(0, 0, 0, 0.06);
                        --text-primary: #111827;
                        --text-secondary: #4B5563;
                        --accent-primary: #2563EB;
                        --accent-secondary: #4F46E5;
                        --accent-glow: rgba(37, 99, 235, 0.1);
                        --error-color: #DC2626;
                        --success-color: #059669;
                    }
                }

                * {
                    box-sizing: border-box;
                    margin: 0;
                    padding: 0;
                    font-family: 'Inter', -apple-system, sans-serif;
                    transition: background-color 0.3s, border-color 0.3s, color 0.3s;
                }

                body {
                    background-color: var(--bg-color);
                    color: var(--text-primary);
                    min-height: 100vh;
                    display: flex;
                    align-items: center;
                    justify-content: center;
                    overflow: hidden;
                    position: relative;
                }

                /* Ambient Glow Background Blobs */
                .glow-blob {
                    position: absolute;
                    width: 300px;
                    height: 300px;
                    border-radius: 50%;
                    filter: blur(80px);
                    z-index: 0;
                    opacity: 0.45;
                }
                .blob-1 {
                    background: linear-gradient(135deg, var(--accent-primary), var(--accent-secondary));
                    top: -50px;
                    left: -50px;
                }
                .blob-2 {
                    background: linear-gradient(135deg, var(--accent-secondary), #EC4899);
                    bottom: -50px;
                    right: -50px;
                }

                .container {
                    z-index: 10;
                    width: 100%;
                    max-width: 400px;
                    padding: 24px;
                }

                .card {
                    background: var(--card-bg);
                    backdrop-filter: blur(20px);
                    -webkit-backdrop-filter: blur(20px);
                    border: 1px solid var(--card-border);
                    border-radius: 24px;
                    padding: 32px;
                    box-shadow: 0 20px 25px -5px rgba(0, 0, 0, 0.1), 0 10px 10px -5px rgba(0, 0, 0, 0.04);
                    text-align: center;
                    animation: slideUp 0.6s cubic-bezier(0.16, 1, 0.3, 1);
                }

                @keyframes slideUp {
                    from { opacity: 0; transform: translateY(20px); }
                    to { opacity: 1; transform: translateY(0); }
                }

                .logo-container {
                    margin-bottom: 24px;
                    display: inline-flex;
                    align-items: center;
                    justify-content: center;
                    width: 64px;
                    height: 64px;
                    background: linear-gradient(135deg, var(--accent-primary), var(--accent-secondary));
                    border-radius: 18px;
                    box-shadow: 0 8px 16px rgba(59, 130, 246, 0.3);
                    color: white;
                    font-size: 32px;
                    font-weight: 700;
                }

                h1 {
                    font-size: 24px;
                    font-weight: 700;
                    margin-bottom: 8px;
                    letter-spacing: -0.025em;
                }

                p.subtitle {
                    font-size: 14px;
                    color: var(--text-secondary);
                    margin-bottom: 28px;
                    line-height: 1.5;
                }

                .pin-container {
                    display: flex;
                    gap: 8px;
                    justify-content: center;
                    margin-bottom: 24px;
                }

                .pin-input {
                    width: 44px;
                    height: 52px;
                    border-radius: 12px;
                    border: 1.5px solid var(--card-border);
                    background: rgba(0, 0, 0, 0.05);
                    color: var(--text-primary);
                    font-size: 24px;
                    font-weight: 700;
                    text-align: center;
                    outline: none;
                    transition: all 0.2s cubic-bezier(0.4, 0, 0.2, 1);
                }

                @media (prefers-color-scheme: dark) {
                    .pin-input {
                        background: rgba(255, 255, 255, 0.03);
                    }
                }

                .pin-input:focus {
                    border-color: var(--accent-primary);
                    box-shadow: 0 0 0 4px var(--accent-glow);
                    transform: scale(1.05);
                }

                button {
                    width: 100%;
                    height: 48px;
                    border-radius: 12px;
                    border: none;
                    background: linear-gradient(135deg, var(--accent-primary), var(--accent-secondary));
                    color: white;
                    font-size: 16px;
                    font-weight: 600;
                    cursor: pointer;
                    box-shadow: 0 4px 6px -1px rgba(0, 0, 0, 0.1), 0 2px 4px -1px rgba(0, 0, 0, 0.06);
                    transition: all 0.2s;
                }

                button:hover {
                    opacity: 0.95;
                    transform: translateY(-1px);
                    box-shadow: 0 10px 15px -3px rgba(59, 130, 246, 0.3);
                }

                button:active {
                    transform: translateY(0);
                }

                .error-banner {
                    background: rgba(239, 68, 68, 0.1);
                    border: 1px solid rgba(239, 68, 68, 0.2);
                    color: var(--error-color);
                    padding: 12px;
                    border-radius: 12px;
                    font-size: 14px;
                    font-weight: 500;
                    margin-bottom: 20px;
                    display: flex;
                    align-items: center;
                    justify-content: center;
                    gap: 8px;
                    animation: shake 0.4s ease-in-out;
                }

                @keyframes shake {
                    0%, 100% { transform: translateX(0); }
                    25% { transform: translateX(-6px); }
                    75% { transform: translateX(6px); }
                }
            </style>
        </head>
        <body>
            <div class="glow-blob blob-1"></div>
            <div class="glow-blob blob-2"></div>

            <div class="container">
                <div class="card">
                    <div class="logo-container">
                        ⚡
                    </div>
                    <h1>Inksync Pro</h1>
                    <p class="subtitle">Enter the 6-digit security code displayed in the app to authorize this connection.</p>

                    \(error != nil ? """
                    <div class="error-banner">
                        <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="10"/><line x1="12" y1="8" x2="12" y2="12"/><line x1="12" y1="16" x2="12.01" y2="16"/></svg>
                        <span>\\(error!)</span>
                    </div>
                    """ : "")

                    <form id="loginForm" method="POST" action="/login">
                        <input type="hidden" id="combinedPin" name="pin">
                        <div class="pin-container">
                            <input type="tel" class="pin-input" maxlength="1" pattern="[0-9]" inputmode="numeric" required autofocus>
                            <input type="tel" class="pin-input" maxlength="1" pattern="[0-9]" inputmode="numeric" required>
                            <input type="tel" class="pin-input" maxlength="1" pattern="[0-9]" inputmode="numeric" required>
                            <input type="tel" class="pin-input" maxlength="1" pattern="[0-9]" inputmode="numeric" required>
                            <input type="tel" class="pin-input" maxlength="1" pattern="[0-9]" inputmode="numeric" required>
                            <input type="tel" class="pin-input" maxlength="1" pattern="[0-9]" inputmode="numeric" required>
                        </div>
                        <button type="submit" id="submitBtn">Verify & Connect</button>
                    </form>
                </div>
            </div>

            <script>
                const digits = document.querySelectorAll('.pin-input');
                const combined = document.getElementById('combinedPin');
                const form = document.getElementById('loginForm');
                
                digits.forEach((input, index) => {
                    input.addEventListener('input', (e) => {
                        const val = input.value;
                        if (!/^[0-9]$/.test(val)) {
                            input.value = '';
                            return;
                        }
                        
                        if (val.length > 0) {
                            if (index < digits.length - 1) {
                                digits[index + 1].focus();
                            } else {
                                submitPin();
                            }
                        }
                    });
                    
                    input.addEventListener('keydown', (e) => {
                        if (e.key === 'Backspace') {
                            if (input.value.length === 0 && index > 0) {
                                digits[index - 1].focus();
                                digits[index - 1].value = '';
                            } else {
                                input.value = '';
                            }
                        }
                    });
                    
                    input.addEventListener('paste', (e) => {
                        e.preventDefault();
                        const pastedData = (e.clipboardData || window.clipboardData).getData('text').trim();
                        if (/^\\\\d{6}$/.test(pastedData)) {
                            for (let i = 0; i < 6; i++) {
                                digits[i].value = pastedData[i];
                            }
                            submitPin();
                        }
                    });
                });

                function submitPin() {
                    let pin = "";
                    digits.forEach(input => pin += input.value);
                    if (pin.length === 6) {
                        combined.value = pin;
                        form.submit();
                    }
                }
            </script>
        </body>
        </html>
        """
    }
    
    private func setupUpload(context: ConnectionContext) -> Bool {
        context.isHeaderParsed = true

        // Write incoming files to the InksyncVault Inbox directory so the library
        // scanner picks them up automatically. The old Documents/ destination was
        // invisible to the import pipeline — files arrived but never appeared in the app.
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return false }
        let inbox = appSupport.appendingPathComponent("InksyncVault/Inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)

        var destURL: URL

        if let relPathString = context.relativePath, !relPathString.isEmpty {
            // Reconstruct the nested folder structure under the inbox
            destURL = inbox.appendingPathComponent(relPathString).standardizedFileURL

            guard destURL.path.hasPrefix(inbox.standardizedFileURL.path) else {
                Logger.shared.log("WiFi Transfer - Rejected Traversal Upload Attempt: \(relPathString)", category: "Network", type: .error)
                return false
            }

            let directoryURL = destURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        } else {
            let sanitizedFileName = URL(fileURLWithPath: context.filename).lastPathComponent
            destURL = inbox.appendingPathComponent(sanitizedFileName).standardizedFileURL
        }

        context.destinationURL = destURL

        // Duplicate file prevention
        if FileManager.default.fileExists(atPath: destURL.path) {
            Logger.shared.log("WiFi Transfer - Rejected duplicate upload: \(destURL.lastPathComponent)", category: "Network", type: .warning)
            return false
        }

        FileManager.default.createFile(atPath: destURL.path, contents: nil, attributes: nil)
        Logger.shared.log("Starting Upload: \(destURL.lastPathComponent) -> \(destURL.path)", category: "Network")

        do {
            context.fileHandle = try FileHandle(forWritingTo: destURL)
            self.isUploading = true
            self.currentUploadFilename = destURL.lastPathComponent
            self.uploadProgress = 0.0
            self.startBackgroundTask()
            return true
        } catch {
            Logger.shared.log("WiFi Transfer Failed to open file for writing: \(error.localizedDescription)", category: "Network", type: .error)
            return false
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
            self.uploadProgress = progress
        }
    }
    
    private func checkUploadCompletion(connection: NWConnection, context: ConnectionContext) {
        if context.expectedLength > 0 && context.receivedLength >= context.expectedLength {
            Logger.shared.log("Upload Complete: \(context.filename) (\(context.receivedLength) bytes)", category: "Network")
            
            cleanup(context: context)
            sendResponse(connection, 200, "Upload Complete")
            
            let size = context.receivedLength
            let name = context.filename
            let ip = context.remoteIP
            WiFiTransferLog.shared.record(
                ip: ip,
                filename: name,
                sizeBytes: size,
                direction: .upload,
                succeeded: true
            )

            self.isUploading = false
            self.uploadProgress = 1.0
            self.endBackgroundTask()
            
            Task {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                NotificationCenter.default.post(name: Notification.Name("LibraryUpdated"), object: nil)
            }
        }
    }
    
    private func cleanup(context: ConnectionContext) {
        try? context.fileHandle?.close()
        context.fileHandle = nil
    }
    
    // MARK: - Handlers
    
    private func handleGetRequest(cleanPath: String, queryItems: [URLQueryItem], connection: NWConnection) {
        guard let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        
        if cleanPath == "/" {
            let html = generateHTML()
            sendResponse(connection, 200, html, contentType: "text/html")
        } else if cleanPath == "/api/library" {
            let files = getLibraryFilesList()
            if let data = try? JSONSerialization.data(withJSONObject: files, options: []),
               let jsonString = String(data: data, encoding: .utf8) {
                sendResponse(connection, 200, jsonString, contentType: "application/json")
            } else {
                sendResponse(connection, 500, "{\"error\": \"Failed to serialize library\"}", contentType: "application/json")
            }
        } else if cleanPath == "/api/sync" {
            // ✅ NEW: Full P2P SwiftData Cross-Device Payload Export
            Task { @MainActor in
                do {
                    // Extract monolithic SwiftData array into memory safely
                    let payload = try SyncCoordinator.shared.exportDatabase()
                    let data = try JSONEncoder().encode(payload)
                    
                    // Route bytes directly to client
                    self.sendResponse(connection, 200, data: data, contentType: "application/json", filename: "Inksync_Database.json")
                } catch {
                    Logger.shared.log("WiFi Transfer - Sync API Crash: \(error.localizedDescription)", category: "Network", type: .error)
                    self.sendResponse(connection, 500, "Internal Sync Formatting Error")
                }
            }
        } else if cleanPath == "/queue.zip" {
            // Hybrid P2P On-The-Fly ZIP Streaming
            // stagedFilesSnapshot() is nonisolated — safe to call from this background queue.
            let stagedFiles = TransferQueueManager.shared.stagedFilesSnapshot()
            
            guard !stagedFiles.isEmpty else {
                sendResponse(connection, 404, "No staged files in the Transfer Queue.")
                return
            }
            
            do {
                // Determine a safe intermediate temp file for the zip
                let tempZipURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
                defer { try? FileManager.default.removeItem(at: tempZipURL) }
                
                let newArchive: ZIPFoundation.Archive
                do {
                    newArchive = try ZIPFoundation.Archive(url: tempZipURL, accessMode: .create)
                } catch {
                    sendResponse(connection, 500, "Failed to create archive stream: \(error.localizedDescription)")
                    return
                }
                var archive: ZIPFoundation.Archive? = newArchive
                guard let validArchive = archive else {
                    sendResponse(connection, 500, "Failed to create archive stream.")
                    return
                }
                
                for file in stagedFiles {
                    try validArchive.addEntry(with: file.name, relativeTo: file.url.deletingLastPathComponent())
                }
                
                // FLUSH ZIP FOOTERS TO DISK!
                archive = nil
                
                let zipData = try Data(contentsOf: tempZipURL, options: .mappedIfSafe)
                sendResponse(connection, 200, data: zipData, contentType: "application/zip", filename: "Inksync_Queue.zip")
            } catch {
                Logger.shared.log("WiFi Transfer ZIP Error: \(error.localizedDescription)", category: "Network", type: .error)
                sendResponse(connection, 500, "Internal Server Error during ZIP creation.")
            }
        } else if cleanPath == "/page_sync" {
            handlePageSync(queryItems: queryItems, connection: connection)
        } else {
            // URL Decode the path (critical for filenames with spaces!)
            // e.g. /my%20comic.epub -> my comic.epub
            let fileName = cleanPath.hasPrefix("/") ? String(cleanPath.dropFirst()) : cleanPath
            
            guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { sendResponse(connection, 500, "Internal Server Error"); return }
            let inboxDir = appSupport.appendingPathComponent("InksyncVault/Inbox", isDirectory: true)
            
            let docFileURL = docDir.appendingPathComponent(fileName).standardizedFileURL
            let inboxFileURL = inboxDir.appendingPathComponent(fileName).standardizedFileURL
            
            let fileURL: URL
            if FileManager.default.fileExists(atPath: inboxFileURL.path) && inboxFileURL.path.hasPrefix(inboxDir.standardizedFileURL.path) {
                fileURL = inboxFileURL
            } else if FileManager.default.fileExists(atPath: docFileURL.path) && docFileURL.path.hasPrefix(docDir.standardizedFileURL.path) {
                fileURL = docFileURL
            } else {
                Logger.shared.log("WiFi Transfer - File not found or Path Traversal rejected: \(cleanPath)", category: "Network", type: .warning)
                sendResponse(connection, 404, "Not Found")
                return
            }
            
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
    
    private func handlePageSync(queryItems: [URLQueryItem], connection: NWConnection) {
        let bookIdStr = queryItems.first(where: { $0.name == "book_id" })?.value
        let pageStr = queryItems.first(where: { $0.name == "page" })?.value
        
        guard let bookIdStr = bookIdStr,
              let bookUUID = UUID(uuidString: bookIdStr) else {
            Logger.shared.log("Page sync failed: missing or invalid book_id", category: "Network", type: .warning)
            sendResponse(connection, 400, "Invalid book_id")
            return
        }
        
        guard let pageStr = pageStr,
              let pageNum = Int(pageStr),
              pageNum > 0 else {
            Logger.shared.log("Page sync failed: missing or invalid page number", category: "Network", type: .warning)
            sendResponse(connection, 400, "Invalid page")
            return
        }
        
        Logger.shared.log("Page sync request received: book \(bookUUID), page \(pageNum)", category: "Network")
        
        // 1x1 transparent PNG data
        let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="
        let pngData = Data(base64Encoded: pngBase64) ?? Data()
        
        sendResponse(connection, 200, data: pngData, contentType: "image/png")
        
        Task { @MainActor in
            let context = InksyncProApp.sharedModelContainer.mainContext
            let descriptor = FetchDescriptor<SDConvertedPDF>()
            
            let pdfs = try? context.fetch(descriptor)
            let pdf = pdfs?.first(where: { $0.id == bookUUID })
            
            let totalPages = pdf?.pageCount ?? 100
            let pageIndex = max(0, min(pageNum - 1, totalPages - 1))
            
            var progress = ReaderProgressTracker.shared.progress(for: bookUUID)
                ?? ReadingProgress(pdfID: bookUUID, lastOpenedAt: Date(), currentPageIndex: pageIndex, totalPagesRead: 1, completionFraction: 0.0, readingSessionDates: [])
            
            let isPageTurn = progress.currentPageIndex != pageIndex
            progress.lastOpenedAt = Date()
            progress.currentPageIndex = pageIndex
            
            if isPageTurn {
                progress.totalPagesRead += 1
            }
            
            progress.completionFraction = Double(pageIndex) / Double(max(1, totalPages - 1))
            
            if !progress.readingSessionDates.contains(where: { Calendar.current.isDateInToday($0) }) {
                progress.readingSessionDates.append(Date())
            }
            
            ReaderProgressTracker.shared.update(progress)
            Logger.shared.log("Page sync successful for \(pdf?.name ?? bookIdStr) -> pageIndex: \(pageIndex)", category: "Network", type: .success)
            
            NotificationCenter.default.post(name: Notification.Name("ReaderProgressUpdated"), object: nil, userInfo: ["pdfID": bookUUID, "currentPageIndex": pageIndex])
        }
    }

    private func sendResponse(_ connection: NWConnection, _ code: Int, _ body: String, contentType: String = "text/plain") {
        let bodyData = body.data(using: .utf8) ?? Data()
        let header = "HTTP/1.1 \(code) OK\r\n"
            + "Content-Type: \(contentType); charset=utf-8\r\n"
            + "Content-Length: \(bodyData.count)\r\n"
            + "Connection: close\r\n"
            + "\r\n"
        guard var response = header.data(using: .utf8) else { return }
        response.append(bodyData)
        connection.send(content: response, completion: .contentProcessed({ _ in connection.cancel() }))
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
    
    private func getLibraryFilesList() -> [[String: Any]] {
        let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.resolvingSymlinksInPath() ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.resolvingSymlinksInPath() ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let inboxDir = appSupport.appendingPathComponent("InksyncVault/Inbox", isDirectory: true)
        
        var files: [[String: Any]] = []
        let keys: [URLResourceKey] = [.nameKey, .isDirectoryKey, .fileSizeKey]
        
        for dir in [docDir, inboxDir] {
            if let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) {
                for case let rawFileURL as URL in enumerator {
                    let fileURL = rawFileURL.resolvingSymlinksInPath()
                    let ext = fileURL.pathExtension.lowercased()
                    
                    if ["pdf", "epub", "cbz"].contains(ext) {
                        var relativePath = fileURL.path.replacingOccurrences(of: dir.path, with: "")
                        if relativePath.hasPrefix("/") {
                            relativePath.removeFirst()
                        }
                        let linkPath = relativePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? relativePath
                        let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                        
                        files.append([
                            "name": fileURL.lastPathComponent,
                            "sizeBytes": size,
                            "link": "/\(linkPath)",
                            "type": ext
                        ])
                    }
                }
            }
        }
        
        return files.sorted {
            let name1 = $0["name"] as? String ?? ""
            let name2 = $1["name"] as? String ?? ""
            return name1.localizedCaseInsensitiveCompare(name2) == .orderedAscending
        }
    }

    private func generateHTML() -> String {
        let files = getLibraryFilesList()
        let filesJSONString: String
        if let data = try? JSONSerialization.data(withJSONObject: files, options: []),
           let str = String(data: data, encoding: .utf8) {
            filesJSONString = str
        } else {
            filesJSONString = "[]"
        }
        
        let stagedCount = TransferQueueManager.shared.stagedFilesSnapshot().count
        let queueButtonHTML = stagedCount > 0 ? "<a href='/queue.zip' class='zip-btn'>📦 Download \(stagedCount) Staged Files as ZIP</a>" : ""
        
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>Inksync Pro | WiFi Sharing</title>
            <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap" rel="stylesheet">
            <style>
                :root {
                    --bg-color: #080A10;
                    --card-bg: rgba(17, 22, 39, 0.7);
                    --card-border: rgba(255, 255, 255, 0.06);
                    --text-primary: #F3F4F6;
                    --text-secondary: #9CA3AF;
                    --accent-blue: #3B82F6;
                    --accent-purple: #8B5CF6;
                    --accent-cyan: #06B6D4;
                    --success-color: #10B981;
                    --warning-color: #F59E0B;
                    --error-color: #EF4444;
                    --cbz-color: #EC4899;
                    --epub-color: #10B981;
                    --pdf-color: #F97316;
                    --shadow: 0 10px 15px -3px rgba(0,0,0,0.3);
                    --glass-blur: blur(20px);
                }

                @media (prefers-color-scheme: light) {
                    :root {
                        --bg-color: #F3F4F6;
                        --card-bg: rgba(255, 255, 255, 0.85);
                        --card-border: rgba(0, 0, 0, 0.05);
                        --text-primary: #111827;
                        --text-secondary: #6B7280;
                        --accent-blue: #2563EB;
                        --accent-purple: #7C3AED;
                        --accent-cyan: #0891B2;
                        --success-color: #059669;
                        --warning-color: #D97706;
                        --error-color: #DC2626;
                        --cbz-color: #DB2777;
                        --epub-color: #059669;
                        --pdf-color: #EA580C;
                        --shadow: 0 10px 15px -3px rgba(0, 0, 0, 0.05);
                    }
                }

                * {
                    box-sizing: border-box;
                    margin: 0;
                    padding: 0;
                    font-family: 'Inter', -apple-system, sans-serif;
                }

                body {
                    background-color: var(--bg-color);
                    color: var(--text-primary);
                    min-height: 100vh;
                    padding: 40px 20px;
                    display: flex;
                    justify-content: center;
                    position: relative;
                }

                /* Background blur effects */
                .ambient-glow {
                    position: fixed;
                    width: 500px;
                    height: 500px;
                    border-radius: 50%;
                    filter: blur(120px);
                    opacity: 0.15;
                    z-index: -1;
                    pointer-events: none;
                }
                .glow-1 {
                    background: var(--accent-blue);
                    top: -100px;
                    left: -100px;
                }
                .glow-2 {
                    background: var(--accent-purple);
                    bottom: -100px;
                    right: -100px;
                }

                .dashboard-container {
                    width: 100%;
                    max-width: 900px;
                    z-index: 10;
                    display: flex;
                    flex-direction: column;
                    gap: 24px;
                }

                /* Glassmorphic header card */
                header {
                    background: var(--card-bg);
                    backdrop-filter: var(--glass-blur);
                    -webkit-backdrop-filter: var(--glass-blur);
                    border: 1px solid var(--card-border);
                    border-radius: 24px;
                    padding: 24px 32px;
                    display: flex;
                    justify-content: space-between;
                    align-items: center;
                    box-shadow: var(--shadow);
                    flex-wrap: wrap;
                    gap: 16px;
                }

                .header-left {
                    display: flex;
                    align-items: center;
                    gap: 16px;
                }

                .logo-icon {
                    font-size: 32px;
                    background: linear-gradient(135deg, var(--accent-blue), var(--accent-purple));
                    -webkit-background-clip: text;
                    -webkit-text-fill-color: transparent;
                    font-weight: 800;
                }

                h1 {
                    font-size: 20px;
                    font-weight: 700;
                    letter-spacing: -0.025em;
                }

                .subtitle {
                    font-size: 13px;
                    color: var(--text-secondary);
                }

                .header-right {
                    display: flex;
                    align-items: center;
                    gap: 12px;
                }

                /* ZIP Button */
                .zip-btn {
                    background: linear-gradient(135deg, var(--accent-purple), #EC4899);
                    color: white;
                    text-decoration: none;
                    padding: 10px 20px;
                    border-radius: 14px;
                    font-size: 14px;
                    font-weight: 600;
                    display: flex;
                    align-items: center;
                    gap: 8px;
                    box-shadow: 0 4px 6px -1px rgba(139, 92, 246, 0.2);
                    transition: all 0.2s;
                }

                .zip-btn:hover {
                    opacity: 0.95;
                    transform: translateY(-1px);
                }

                /* Dropzone layout */
                .dropzone {
                    background: var(--card-bg);
                    backdrop-filter: var(--glass-blur);
                    -webkit-backdrop-filter: var(--glass-blur);
                    border: 2px dashed var(--card-border);
                    border-radius: 24px;
                    padding: 40px;
                    text-align: center;
                    cursor: pointer;
                    box-shadow: var(--shadow);
                    transition: all 0.3s cubic-bezier(0.4, 0, 0.2, 1);
                    display: flex;
                    flex-direction: column;
                    align-items: center;
                    gap: 12px;
                }

                .dropzone:hover, .dropzone.dragover {
                    border-color: var(--accent-blue);
                    background: rgba(59, 130, 246, 0.04);
                    transform: scale(1.01);
                }

                .dropzone-icon {
                    font-size: 40px;
                    color: var(--accent-blue);
                    margin-bottom: 8px;
                    animation: pulse 2s infinite;
                }

                @keyframes pulse {
                    0%, 100% { transform: scale(1); opacity: 1; }
                    50% { transform: scale(1.08); opacity: 0.8; }
                }

                /* Full page drag overlay */
                #dragOverlay {
                    position: fixed;
                    top: 0;
                    left: 0;
                    width: 100vw;
                    height: 100vh;
                    background: rgba(8, 10, 16, 0.85);
                    backdrop-filter: blur(15px);
                    -webkit-backdrop-filter: blur(15px);
                    z-index: 1000;
                    display: none;
                    justify-content: center;
                    align-items: center;
                    border: 4px dashed var(--accent-blue);
                    margin: 0;
                    padding: 0;
                }

                .overlay-content {
                    text-align: center;
                    color: white;
                }

                .overlay-icon {
                    font-size: 72px;
                    color: var(--accent-blue);
                    margin-bottom: 24px;
                    animation: bounce 1s infinite;
                }

                @keyframes bounce {
                    0%, 100% { transform: translateY(0); }
                    50% { transform: translateY(-15px); }
                }

                /* Queue Card layout */
                .queue-card {
                    background: var(--card-bg);
                    backdrop-filter: var(--glass-blur);
                    -webkit-backdrop-filter: var(--glass-blur);
                    border: 1px solid var(--card-border);
                    border-radius: 24px;
                    padding: 24px;
                    box-shadow: var(--shadow);
                    display: none;
                    flex-direction: column;
                    gap: 16px;
                }

                .queue-header {
                    display: flex;
                    justify-content: space-between;
                    align-items: center;
                    border-bottom: 1px solid var(--card-border);
                    padding-bottom: 12px;
                }

                .queue-title {
                    font-size: 16px;
                    font-weight: 700;
                }

                .queue-items {
                    display: flex;
                    flex-direction: column;
                    gap: 12px;
                    max-height: 300px;
                    overflow-y: auto;
                }

                .queue-item {
                    background: rgba(0, 0, 0, 0.1);
                    padding: 12px 16px;
                    border-radius: 14px;
                    display: flex;
                    flex-direction: column;
                    gap: 8px;
                    position: relative;
                    border: 1px solid var(--card-border);
                }

                @media (prefers-color-scheme: dark) {
                    .queue-item {
                        background: rgba(255, 255, 255, 0.02);
                    }
                }

                .queue-item-meta {
                    display: flex;
                    justify-content: space-between;
                    font-size: 13px;
                }

                .queue-item-name {
                    font-weight: 500;
                    white-space: nowrap;
                    overflow: hidden;
                    text-overflow: ellipsis;
                    max-width: 60%;
                }

                .queue-item-stats {
                    color: var(--text-secondary);
                }

                .progress-bar-container {
                    width: 100%;
                    height: 6px;
                    background: rgba(255, 255, 255, 0.1);
                    border-radius: 3px;
                    overflow: hidden;
                    position: relative;
                }

                .progress-bar-fill {
                    height: 100%;
                    width: 0%;
                    background: linear-gradient(90deg, var(--accent-blue), var(--accent-cyan));
                    border-radius: 3px;
                    transition: width 0.2s ease-out;
                }

                .progress-bar-fill.completed {
                    background: var(--success-color);
                }

                .progress-bar-fill.failed {
                    background: var(--error-color);
                }

                /* Library card section */
                .library-section {
                    background: var(--card-bg);
                    backdrop-filter: var(--glass-blur);
                    -webkit-backdrop-filter: var(--glass-blur);
                    border: 1px solid var(--card-border);
                    border-radius: 24px;
                    padding: 32px;
                    box-shadow: var(--shadow);
                    display: flex;
                    flex-direction: column;
                    gap: 20px;
                }

                .library-toolbar {
                    display: flex;
                    gap: 16px;
                    flex-wrap: wrap;
                    align-items: center;
                    justify-content: space-between;
                }

                .search-wrapper {
                    position: relative;
                    flex: 1;
                    min-width: 280px;
                }

                .search-input {
                    width: 100%;
                    height: 44px;
                    background: rgba(0, 0, 0, 0.15);
                    border: 1px solid var(--card-border);
                    border-radius: 14px;
                    padding: 0 16px 0 44px;
                    color: var(--text-primary);
                    font-size: 14px;
                    outline: none;
                    transition: all 0.2s;
                }

                @media (prefers-color-scheme: dark) {
                    .search-input {
                        background: rgba(255, 255, 255, 0.03);
                    }
                }

                .search-input:focus {
                    border-color: var(--accent-blue);
                    box-shadow: 0 0 0 3px rgba(59, 130, 246, 0.1);
                }

                .search-icon {
                    position: absolute;
                    left: 16px;
                    top: 50%;
                    transform: translateY(-50%);
                    color: var(--text-secondary);
                    pointer-events: none;
                }

                .clear-search-btn {
                    position: absolute;
                    right: 16px;
                    top: 50%;
                    transform: translateY(-50%);
                    background: none;
                    border: none;
                    color: var(--text-secondary);
                    cursor: pointer;
                    outline: none;
                    display: none;
                    font-size: 16px;
                }

                .filter-tabs {
                    display: flex;
                    gap: 8px;
                    background: rgba(0, 0, 0, 0.1);
                    padding: 4px;
                    border-radius: 12px;
                    border: 1px solid var(--card-border);
                }

                @media (prefers-color-scheme: dark) {
                    .filter-tabs {
                        background: rgba(255, 255, 255, 0.02);
                    }
                }

                .filter-tab {
                    background: none;
                    border: none;
                    color: var(--text-secondary);
                    padding: 8px 16px;
                    font-size: 13px;
                    font-weight: 600;
                    border-radius: 8px;
                    cursor: pointer;
                    transition: all 0.2s;
                }

                .filter-tab:hover {
                    color: var(--text-primary);
                }

                .filter-tab.active {
                    background: var(--accent-blue);
                    color: white;
                    box-shadow: 0 2px 4px rgba(59, 130, 246, 0.2);
                }

                .library-header {
                    display: flex;
                    justify-content: space-between;
                    font-size: 14px;
                    color: var(--text-secondary);
                    border-bottom: 1px solid var(--card-border);
                    padding-bottom: 12px;
                }

                .library-list {
                    list-style: none;
                    display: flex;
                    flex-direction: column;
                    gap: 12px;
                    max-height: 600px;
                    overflow-y: auto;
                    padding-right: 4px;
                }

                .library-item {
                    background: rgba(0, 0, 0, 0.08);
                    border: 1px solid var(--card-border);
                    border-radius: 16px;
                    padding: 16px 20px;
                    display: flex;
                    justify-content: space-between;
                    align-items: center;
                    gap: 16px;
                    transition: all 0.2s;
                }

                @media (prefers-color-scheme: dark) {
                    .library-item {
                        background: rgba(255, 255, 255, 0.015);
                    }
                }

                .library-item:hover {
                    background: rgba(0, 0, 0, 0.12);
                    transform: translateY(-1px);
                }

                @media (prefers-color-scheme: dark) {
                    .library-item:hover {
                        background: rgba(255, 255, 255, 0.03);
                    }
                }

                .file-details {
                    display: flex;
                    align-items: center;
                    gap: 16px;
                    min-width: 0;
                    flex: 1;
                }

                .file-type-badge {
                    width: 48px;
                    height: 48px;
                    border-radius: 12px;
                    display: flex;
                    flex-direction: column;
                    align-items: center;
                    justify-content: center;
                    font-size: 11px;
                    font-weight: 700;
                    color: white;
                    flex-shrink: 0;
                    text-transform: uppercase;
                }

                .file-type-badge.cbz { background: var(--cbz-color); }
                .file-type-badge.epub { background: var(--epub-color); }
                .file-type-badge.pdf { background: var(--pdf-color); }

                .file-text {
                    min-width: 0;
                    display: flex;
                    flex-direction: column;
                    gap: 4px;
                }

                .file-name {
                    font-size: 15px;
                    font-weight: 600;
                    white-space: nowrap;
                    overflow: hidden;
                    text-overflow: ellipsis;
                }

                .file-size {
                    font-size: 12px;
                    color: var(--text-secondary);
                }

                .download-action-btn {
                    background: rgba(255, 255, 255, 0.1);
                    border: 1px solid var(--card-border);
                    color: var(--text-primary);
                    text-decoration: none;
                    padding: 8px 16px;
                    border-radius: 10px;
                    font-size: 13px;
                    font-weight: 600;
                    white-space: nowrap;
                    transition: all 0.2s;
                }

                @media (prefers-color-scheme: light) {
                    .download-action-btn {
                        background: rgba(0, 0, 0, 0.05);
                    }
                }

                .download-action-btn:hover {
                    background: var(--accent-blue);
                    color: white;
                    border-color: var(--accent-blue);
                }

                /* Notifications toast */
                .toast-container {
                    position: fixed;
                    bottom: 24px;
                    right: 24px;
                    display: flex;
                    flex-direction: column;
                    gap: 8px;
                    z-index: 2000;
                }

                .toast {
                    background: var(--card-bg);
                    backdrop-filter: var(--glass-blur);
                    -webkit-backdrop-filter: var(--glass-blur);
                    border: 1px solid var(--card-border);
                    border-left-width: 4px;
                    padding: 16px 20px;
                    border-radius: 12px;
                    box-shadow: 0 10px 15px -3px rgba(0, 0, 0, 0.2);
                    color: var(--text-primary);
                    font-size: 14px;
                    font-weight: 500;
                    display: flex;
                    align-items: center;
                    gap: 12px;
                    animation: toastIn 0.3s cubic-bezier(0.16, 1, 0.3, 1);
                    max-width: 350px;
                }

                @keyframes toastIn {
                    from { opacity: 0; transform: translateY(12px) scale(0.95); }
                    to { opacity: 1; transform: translateY(0) scale(1); }
                }

                .toast.success { border-left-color: var(--success-color); }
                .toast.error { border-left-color: var(--error-color); }
                .toast.warning { border-left-color: var(--warning-color); }
            </style>
        </head>
        <body>
            <div class="ambient-glow glow-1"></div>
            <div class="ambient-glow glow-2"></div>

            <div class="dashboard-container">
                <header>
                    <div class="header-left">
                        <div class="logo-icon">⚡</div>
                        <div>
                            <h1>Inksync Pro</h1>
                            <div class="subtitle">WiFi File Sharing Server</div>
                        </div>
                    </div>
                    <div class="header-right">
                        \(queueButtonHTML)
                    </div>
                </header>

                <!-- Staged upload queue -->
                <div class="queue-card" id="queueCard">
                    <div class="queue-header">
                        <span class="queue-title">Upload Progress</span>
                        <span class="subtitle" id="queueCount">0 files remaining</span>
                    </div>
                    <div class="queue-items" id="queueItems"></div>
                </div>

                <!-- Dropzone / File Select -->
                <div class="dropzone" id="dropzone" onclick="document.getElementById('fileInput').click()">
                    <div class="dropzone-icon">📥</div>
                    <h2>Drag & Drop Files Here</h2>
                    <p class="subtitle">Supports CBZ, EPUB, and PDF files. Or click to browse.</p>
                    <input type="file" id="fileInput" style="display:none" multiple onchange="handleFileSelect(event)">
                </div>

                <!-- Library Container -->
                <div class="library-section">
                    <div class="library-toolbar">
                        <div class="search-wrapper">
                            <span class="search-icon">🔍</span>
                            <input type="text" class="search-input" id="searchInput" placeholder="Search files by name..." oninput="handleSearch(event)">
                            <button class="clear-search-btn" id="clearSearchBtn" onclick="clearSearch()">✕</button>
                        </div>
                        <div class="filter-tabs">
                            <button class="filter-tab active" onclick="setFilter('all', event)">All</button>
                            <button class="filter-tab" onclick="setFilter('cbz', event)">CBZ</button>
                            <button class="filter-tab" onclick="setFilter('epub', event)">EPUB</button>
                            <button class="filter-tab" onclick="setFilter('pdf', event)">PDF</button>
                        </div>
                    </div>

                    <div class="library-header">
                        <span id="libraryTitle">Library Files</span>
                        <span id="libraryCount">Showing 0 files</span>
                    </div>

                    <ul class="library-list" id="libraryList">
                        <!-- Injected via JavaScript -->
                    </ul>
                </div>
            </div>

            <!-- Drag overlay -->
            <div id="dragOverlay">
                <div class="overlay-content">
                    <div class="overlay-icon">📥</div>
                    <h2>Drop Files Here</h2>
                    <p>Drop your CBZ, EPUB, or PDF files to start uploading them immediately.</p>
                </div>
            </div>

            <!-- Toast container -->
            <div class="toast-container" id="toastContainer"></div>

            <script>
                let libraryFiles = \(filesJSONString);
                let activeFilter = 'all';
                let searchQuery = '';

                const uploadQueue = [];
                let isUploading = false;
                let uploadStartTime = 0;

                document.addEventListener('DOMContentLoaded', () => {
                    renderLibrary();
                    setupDragAndDrop();
                });

                function formatBytes(bytes) {
                    if (bytes === 0) return '0 Bytes';
                    const k = 1024;
                    const sizes = ['Bytes', 'KB', 'MB', 'GB'];
                    const i = Math.floor(Math.log(bytes) / Math.log(k));
                    return parseFloat((bytes / Math.pow(k, i)).toFixed(1)) + ' ' + sizes[i];
                }

                function formatSpeed(bytesPerSec) {
                    return formatBytes(bytesPerSec) + '/s';
                }

                function formatTime(seconds) {
                    if (seconds < 60) return seconds + 's';
                    const mins = Math.floor(seconds / 60);
                    const secs = seconds % 60;
                    return mins + 'm ' + secs + 's';
                }

                function generateId() {
                    return Math.random().toString(36).substring(2, 9);
                }

                function renderLibrary() {
                    const list = document.getElementById('libraryList');
                    const countLabel = document.getElementById('libraryCount');
                    list.innerHTML = '';

                    const filtered = libraryFiles.filter(file => {
                        const matchesType = activeFilter === 'all' || file.type === activeFilter;
                        const matchesSearch = file.name.toLowerCase().includes(searchQuery.toLowerCase());
                        return matchesType && matchesSearch;
                    });

                    if (filtered.length === 0) {
                        list.innerHTML = '<li style="justify-content:center; padding: 40px; color: var(--text-secondary); font-size: 14px;">No files match your query.</li>';
                        countLabel.innerText = '0 files';
                        return;
                    }

                    filtered.forEach(file => {
                        const li = document.createElement('li');
                        li.className = 'library-item';
                        li.innerHTML = 
                            '<div class="file-details">' +
                                '<div class="file-type-badge ' + file.type + '">' + file.type + '</div>' +
                                '<div class="file-text">' +
                                    '<span class="file-name" title="' + file.name + '">' + file.name + '</span>' +
                                    '<span class="file-size">' + formatBytes(file.sizeBytes) + '</span>' +
                                '</div>' +
                            '</div>' +
                            '<a href="' + file.link + '" class="download-action-btn" download>Download</a>';
                        list.appendChild(li);
                    });

                    countLabel.innerText = 'Showing ' + filtered.length + ' of ' + libraryFiles.length + ' files';
                }

                function setFilter(type, event) {
                    document.querySelectorAll('.filter-tab').forEach(tab => tab.classList.remove('active'));
                    event.target.classList.add('active');
                    activeFilter = type;
                    renderLibrary();
                }

                function handleSearch(e) {
                    searchQuery = e.target.value;
                    const clearBtn = document.getElementById('clearSearchBtn');
                    clearBtn.style.display = searchQuery ? 'block' : 'none';
                    renderLibrary();
                }

                function clearSearch() {
                    const input = document.getElementById('searchInput');
                    input.value = '';
                    searchQuery = '';
                    document.getElementById('clearSearchBtn').style.display = 'none';
                    renderLibrary();
                }

                function setupDragAndDrop() {
                    const overlay = document.getElementById('dragOverlay');
                    const dropzone = document.getElementById('dropzone');

                    window.addEventListener('dragenter', (e) => {
                        e.preventDefault();
                        overlay.style.display = 'flex';
                    });

                    overlay.addEventListener('dragover', (e) => {
                        e.preventDefault();
                    });

                    overlay.addEventListener('dragleave', (e) => {
                        e.preventDefault();
                        if (e.clientX === 0 && e.clientY === 0) {
                            overlay.style.display = 'none';
                        }
                    });

                    overlay.addEventListener('drop', (e) => {
                        e.preventDefault();
                        overlay.style.display = 'none';
                        if (e.dataTransfer.files.length > 0) {
                            addFilesToQueue(e.dataTransfer.files);
                        }
                    });
                }

                function handleFileSelect(e) {
                    if (e.target.files.length > 0) {
                        addFilesToQueue(e.target.files);
                    }
                }

                function showNotification(message, type) {
                    const container = document.getElementById('toastContainer');
                    const toast = document.createElement('div');
                    toast.className = 'toast ' + type;
                    toast.innerText = message;
                    container.appendChild(toast);

                    setTimeout(() => {
                        toast.style.opacity = '0';
                        toast.style.transform = 'translateY(12px) scale(0.95)';
                        toast.style.transition = 'all 0.3s ease-out';
                        setTimeout(() => toast.remove(), 300);
                    }, 3000);
                }

                function addFilesToQueue(files) {
                    for (let i = 0; i < files.length; i++) {
                        const file = files[i];
                        const ext = file.name.split('.').pop().toLowerCase();
                        if (!['pdf', 'epub', 'cbz'].includes(ext)) {
                            showNotification('"' + file.name + '" ignored (unsupported file format).', 'error');
                            continue;
                        }

                        uploadQueue.push({
                            id: generateId(),
                            file: file,
                            status: 'queued',
                            progress: 0,
                            speed: '',
                            eta: ''
                        });
                    }
                    renderQueue();
                    processQueue();
                }

                function renderQueue() {
                    const container = document.getElementById('queueCard');
                    const itemsList = document.getElementById('queueItems');
                    const countLabel = document.getElementById('queueCount');

                    const activeItems = uploadQueue.filter(item => item.status === 'queued' || item.status === 'uploading');
                    
                    if (uploadQueue.length === 0) {
                        container.style.display = 'none';
                        return;
                    }

                    container.style.display = 'flex';
                    countLabel.innerText = activeItems.length + ' files remaining';
                    itemsList.innerHTML = '';

                    uploadQueue.forEach(item => {
                        const div = document.createElement('div');
                        div.className = 'queue-item';
                        div.id = 'queue-item-' + item.id;
                        
                        let statusColorClass = '';
                        if (item.status === 'completed') statusColorClass = 'completed';
                        if (item.status === 'failed') statusColorClass = 'failed';

                        div.innerHTML = 
                            '<div class="queue-item-meta">' +
                                '<span class="queue-item-name" title="' + item.file.name + '">' + item.file.name + '</span>' +
                                '<span class="queue-item-stats">' +
                                    (item.status === 'uploading' ? item.speed + ' • ' + item.eta : item.status.toUpperCase()) +
                                '</span>' +
                            '</div>' +
                            '<div class="progress-bar-container">' +
                                '<div class="progress-bar-fill ' + statusColorClass + '" style="width: ' + item.progress + '%"></div>' +
                            '</div>';
                        itemsList.appendChild(div);
                    });
                }

                function updateQueueProgress(item) {
                    const itemElement = document.getElementById('queue-item-' + item.id);
                    if (!itemElement) return;

                    const statsLabel = itemElement.querySelector('.queue-item-stats');
                    const barFill = itemElement.querySelector('.progress-bar-fill');

                    statsLabel.innerText = item.speed + ' • ' + item.eta;
                    barFill.style.width = item.progress + '%';
                }

                function processQueue() {
                    if (isUploading) return;

                    const nextItem = uploadQueue.find(item => item.status === 'queued');
                    if (!nextItem) {
                        return;
                    }

                    isUploading = true;
                    nextItem.status = 'uploading';
                    renderQueue();

                    const xhr = new XMLHttpRequest();
                    xhr.open("POST", '/upload/' + encodeURIComponent(nextItem.file.name), true);
                    
                    xhr.setRequestHeader("X-File-Name", nextItem.file.name);
                    if (nextItem.file.webkitRelativePath) {
                        xhr.setRequestHeader("X-Relative-Path", nextItem.file.webkitRelativePath);
                    }

                    let lastLoaded = 0;
                    let lastTime = Date.now();
                    uploadStartTime = Date.now();

                    xhr.upload.onprogress = function(e) {
                        if (e.lengthComputable) {
                            const currentTime = Date.now();
                            const timeDiff = (currentTime - lastTime) / 1000;

                            if (timeDiff >= 0.3 || e.loaded === e.total) {
                                const loadedDiff = e.loaded - lastLoaded;
                                const speed = loadedDiff / timeDiff;
                                
                                const percent = (e.loaded / e.total) * 100;
                                nextItem.progress = percent;

                                const avgSpeed = e.loaded / ((currentTime - uploadStartTime) / 1000);
                                nextItem.speed = formatSpeed(avgSpeed);

                                const remainingBytes = e.total - e.loaded;
                                const etaSeconds = Math.round(remainingBytes / avgSpeed);
                                nextItem.eta = isFinite(etaSeconds) && etaSeconds > 0 ? formatTime(etaSeconds) + ' left' : 'calculating...';

                                lastLoaded = e.loaded;
                                lastTime = currentTime;

                                updateQueueProgress(nextItem);
                            }
                        }
                    };

                    xhr.onload = function() {
                        isUploading = false;
                        if (xhr.status === 200) {
                            nextItem.status = 'completed';
                            nextItem.progress = 100;
                            nextItem.speed = '';
                            nextItem.eta = 'Complete';
                            showNotification('"' + nextItem.file.name + '" uploaded successfully.', 'success');
                            fetchLibraryUpdates();
                        } else if (xhr.status === 409) {
                            nextItem.status = 'failed';
                            nextItem.progress = 100;
                            nextItem.eta = 'Already Exists';
                            showNotification('"' + nextItem.file.name + '" already exists on device.', 'warning');
                        } else {
                            nextItem.status = 'failed';
                            nextItem.progress = 100;
                            nextItem.eta = 'Error: ' + xhr.statusText;
                            showNotification('Failed to upload "' + nextItem.file.name + '".', 'error');
                        }
                        renderQueue();
                        processQueue();
                    };

                    xhr.onerror = function() {
                        isUploading = false;
                        nextItem.status = 'failed';
                        nextItem.progress = 100;
                        nextItem.eta = 'Network Error';
                        showNotification('Network error uploading "' + nextItem.file.name + '".', 'error');
                        renderQueue();
                        processQueue();
                    };

                    xhr.send(nextItem.file);
                }

                function fetchLibraryUpdates() {
                    fetch('/api/library')
                        .then(res => res.json())
                        .then(data => {
                            libraryFiles = data;
                            renderLibrary();
                        })
                        .catch(err => {
                            console.error("Failed to load library updates dynamically:", err);
                        });
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
    nonisolated static func getIPAddress() -> String? {
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
                        
                        let ipString = hostname.withUnsafeBufferPointer { ptr in
                            String(cString: ptr.baseAddress!)
                        }
                        
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
        // iOS only shows the Local Network permission prompt when the app accesses a
        // service type declared in NSBonjourServices. Browse for _inksync._tcp (our type)
        // using TCP params so it matches the declared NSBonjourServices entry.
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: "_inksync._tcp", domain: "local."), using: params)
        browser.start(queue: .global())

        // Also send a UDP packet to the mDNS multicast address — this is the most
        // reliable way to trigger the system dialog on all iPadOS versions.
        let socket = socket(AF_INET, SOCK_DGRAM, 0)
        if socket >= 0 {
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = CFSwapInt16HostToBig(5353) // mDNS port
            addr.sin_addr.s_addr = inet_addr("224.0.0.251") // mDNS multicast group
            _ = "InksyncProTrigger".withCString { ptr in
                withUnsafeMutablePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                        sendto(socket, ptr, 17, 0, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            close(socket)
        }

        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            browser.cancel()
        }
    }
}
