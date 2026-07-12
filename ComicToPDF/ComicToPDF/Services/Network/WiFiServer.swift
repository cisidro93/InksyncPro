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
    
    private var lastSeenIPs: [String: Date] = [:]
    private var connections: [NWConnection] = []
    
    private func updateActiveConnectionsCount() {
        let now = Date()
        lastSeenIPs = lastSeenIPs.filter { now.timeIntervalSince($0.value) < 15.0 }
        let count = lastSeenIPs.count
        if activeConnections != count {
            activeConnections = count
        }
    }
    
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

        ActiveUploadRegistry.shared.clear()
        scheduleAutoShutdown()
        cleanStagingDirectory()

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
                        let cleanIP = ip.components(separatedBy: "%").first ?? ip
                        let host = cleanIP.contains(":") ? "[\(cleanIP)]" : cleanIP
                        self.serverURL = "http://\(host):\(port)"
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
                    guard let self = self else { return }
                    self.connections.append(connection)
                    self.handleConnection(connection)
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
        
        // Explicitly cancel all active connections so the port is released instantly
        for connection in connections {
            connection.cancel()
        }
        connections.removeAll()
        
        cleanStagingDirectory()
        ActiveUploadRegistry.shared.clear()
        self.endBackgroundTaskImmediately()
    }
    
    private func cleanStagingDirectory() {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let stagingDir = appSupport.appendingPathComponent("InksyncVault/Staging", isDirectory: true)
        if let files = try? FileManager.default.contentsOfDirectory(at: stagingDir, includingPropertiesForKeys: nil) {
            for fileURL in files {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
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
    private final class ConnectionContext: @unchecked Sendable {
        private let lock = NSLock()
        private var _buffer = Data()
        private var _isHeaderParsed = false
        private var _isInitialBodyWritten = false
        private var _expectedLength: Int64 = 0
        private var _receivedLength: Int64 = 0
        private var _fileHandle: FileHandle?
        private var _destinationURL: URL?
        private var _filename: String = ""
        private var _relativePath: String? = nil
        
        var buffer: Data {
            get { lock.lock(); defer { lock.unlock() }; return _buffer }
            set { lock.lock(); defer { lock.unlock() }; _buffer = newValue }
        }
        
        var isHeaderParsed: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _isHeaderParsed }
            set { lock.lock(); defer { lock.unlock() }; _isHeaderParsed = newValue }
        }
        
        var isInitialBodyWritten: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _isInitialBodyWritten }
            set { lock.lock(); defer { lock.unlock() }; _isInitialBodyWritten = newValue }
        }
        
        var expectedLength: Int64 {
            get { lock.lock(); defer { lock.unlock() }; return _expectedLength }
            set { lock.lock(); defer { lock.unlock() }; _expectedLength = newValue }
        }
        
        var receivedLength: Int64 {
            get { lock.lock(); defer { lock.unlock() }; return _receivedLength }
            set { lock.lock(); defer { lock.unlock() }; _receivedLength = newValue }
        }
        
        var fileHandle: FileHandle? {
            get { lock.lock(); defer { lock.unlock() }; return _fileHandle }
            set { lock.lock(); defer { lock.unlock() }; _fileHandle = newValue }
        }
        
        var destinationURL: URL? {
            get { lock.lock(); defer { lock.unlock() }; return _destinationURL }
            set { lock.lock(); defer { lock.unlock() }; _destinationURL = newValue }
        }
        
        var filename: String {
            get { lock.lock(); defer { lock.unlock() }; return _filename }
            set { lock.lock(); defer { lock.unlock() }; _filename = newValue }
        }
        
        var relativePath: String? {
            get { lock.lock(); defer { lock.unlock() }; return _relativePath }
            set { lock.lock(); defer { lock.unlock() }; _relativePath = newValue }
        }
        
        private var _finalDestinationURL: URL?
        var finalDestinationURL: URL? {
            get { lock.lock(); defer { lock.unlock() }; return _finalDestinationURL }
            set { lock.lock(); defer { lock.unlock() }; _finalDestinationURL = newValue }
        }
        
        private var _requestOrigin: String = "*"
        var requestOrigin: String {
            get { lock.lock(); defer { lock.unlock() }; return _requestOrigin }
            set { lock.lock(); defer { lock.unlock() }; _requestOrigin = newValue }
        }
        
        var isAuthenticated = false
        var remoteIP: String = ""
        
        func appendToBuffer(_ data: Data) {
            lock.lock()
            defer { lock.unlock() }
            _buffer.append(data)
        }
        
        func extractBuffer() -> Data {
            lock.lock()
            defer { lock.unlock() }
            let data = _buffer
            _buffer = Data()
            return data
        }
    }
    
    private func handleConnection(_ connection: NWConnection) {
        let context = ConnectionContext()
        let cleanIP: String
        if case let .hostPort(host, _) = connection.endpoint {
            let ipStr = "\(host)".components(separatedBy: "%").first ?? "\(host)"
            cleanIP = ipStr
            context.remoteIP = ipStr
            
            lastSeenIPs[ipStr] = Date()
            updateActiveConnectionsCount()
        } else {
            cleanIP = ""
        }
        
        Logger.shared.log("New Connection from \(connection.endpoint)", category: "Network")
        
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .cancelled, .failed:
                    self?.cleanup(context: context)
                    if let self = self {
                        if let idx = self.connections.firstIndex(where: { $0 === connection }) {
                            self.connections.remove(at: idx)
                        }
                    }
                    self?.endBackgroundTask()
                    self?.updateActiveConnectionsCount()
                default: break
                }
            }
        }
        
        connection.start(queue: .global(qos: .default))
        receive(on: connection, context: context)
    }
    
    nonisolated private func receive(on connection: NWConnection, context: ConnectionContext) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            
            if let data = data, !data.isEmpty {
                if context.isHeaderParsed && context.isInitialBodyWritten {
                    // Streaming Mode: High-performance background write
                    if let fileHandle = context.fileHandle {
                        try? fileHandle.write(contentsOf: data)
                        context.receivedLength += Int64(data.count)
                        
                        if context.expectedLength > 0 {
                            let progress = Double(context.receivedLength) / Double(context.expectedLength)
                            Task { @MainActor in
                                self.uploadProgress = progress
                            }
                            
                            // Immediately complete upload if all bytes are received, breaking TCP deadlock
                            if context.receivedLength >= context.expectedLength {
                                Task { @MainActor in
                                    self.checkUploadCompletion(connection: connection, context: context)
                                }
                                return
                            }
                        }
                    }
                } else if context.isHeaderParsed {
                    // Headers are parsed, but initial body has not been written yet on MainActor.
                    // Append to thread-safe buffer to prevent packet loss or out-of-order writes.
                    context.appendToBuffer(data)
                } else {
                    // Headers not parsed yet: check synchronously on the background queue
                    context.appendToBuffer(data)
                    
                    let currentBuffer = context.buffer
                    if let headerEndRange = currentBuffer.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) {
                        // Found boundary! Set parsed flag synchronously to block racing packets
                        context.isHeaderParsed = true
                        
                        let headerData = currentBuffer.subdata(in: 0..<headerEndRange.lowerBound)
                        // Retain only body bytes in the buffer
                        context.buffer = currentBuffer.subdata(in: headerEndRange.upperBound..<currentBuffer.count)
                        
                        if let headerString = String(data: headerData, encoding: .utf8) {
                            Task { @MainActor in
                                self.parseHeaders(headerString, connection: connection, context: context)
                            }
                        }
                    } else {
                        // Limit headers to 32KB to prevent memory exhaustion DoS
                        if currentBuffer.count > 32768 {
                            Logger.shared.log("Connection Terminated - Header Payload Too Large", category: "Network", type: .warning)
                            connection.cancel()
                            return
                        }
                    }
                }
            }
            
            if isComplete {
                Task { @MainActor in
                    self.checkUploadCompletion(connection: connection, context: context)
                    connection.cancel()
                }
            } else if let error = error {
                Task { @MainActor in
                    if case .posix(let code) = error, code == .ECANCELED {
                        // Silent cleanup on expected connection close
                    } else {
                        Logger.shared.log("Connection Error: \(error)", category: "Network", type: .error)
                    }
                    connection.cancel()
                }
            } else {
                // Continue reading on the background queue
                self.receive(on: connection, context: context)
            }
        }
    }
    
    private func parseHeaders(_ headerString: String, connection: NWConnection, context: ConnectionContext) {
        let lines = headerString.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else { return }
        
        let parts = firstLine.components(separatedBy: " ")
        guard parts.count >= 2 else { return }
        
        // 1. Check Authentication (Cookie / Custom Headers)
        var sessionToken: String?
        var pinHeader: String?
        for line in lines {
            if line.lowercased().hasPrefix("cookie:") {
                let cookiesString = line.dropFirst("cookie:".count).trimmingCharacters(in: .whitespaces)
                let cookies = cookiesString.components(separatedBy: ";")
                for cookie in cookies {
                    let trimmed = cookie.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("session=") {
                        sessionToken = String(trimmed.dropFirst("session=".count))
                    }
                }
            } else if line.lowercased().hasPrefix("x-session-token:") {
                sessionToken = line.dropFirst("x-session-token:".count).trimmingCharacters(in: .whitespaces)
            } else if line.lowercased().hasPrefix("x-wifi-pin:") {
                pinHeader = line.dropFirst("x-wifi-pin:".count).trimmingCharacters(in: .whitespaces)
            } else if line.lowercased().hasPrefix("origin:") {
                context.requestOrigin = line.dropFirst("origin:".count).trimmingCharacters(in: .whitespaces)
            }
        }
        
        // Validate Session or Direct PIN
        if let token = sessionToken {
            sessionLock.lock()
            if validSessions.contains(token) {
                context.isAuthenticated = true
            }
            sessionLock.unlock()
        }
        
        if let pin = pinHeader, pin == self.securityCode {
            context.isAuthenticated = true
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
            let loginBody = context.extractBuffer()
            handleLogin(lines: lines, bodyData: loginBody, connection: connection, remoteIP: context.remoteIP)
            return
        }
        
        // Handle OPTIONS preflight CORS requests (pre-authentication)
        if method == "OPTIONS" {
            let response = "HTTP/1.1 204 No Content\r\n"
                + "Access-Control-Allow-Origin: \(context.requestOrigin)\r\n"
                + "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
                + "Access-Control-Allow-Headers: Content-Type, X-File-Name, X-Relative-Path, X-Session-Token, X-WiFi-PIN\r\n"
                + "Access-Control-Allow-Credentials: true\r\n"
                + "Connection: close\r\n"
                + "\r\n"
            connection.send(content: response.data(using: .utf8), completion: .contentProcessed({ _ in connection.cancel() }))
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
            handleGetRequest(cleanPath: cleanPath, queryItems: queryItems, connection: connection, origin: context.requestOrigin)
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
            let decodedName = rawName.removingPercentEncoding ?? rawName
            let fallbackName = decodedName.isEmpty || decodedName == "upload" ? "upload_\(Date().timeIntervalSince1970).cbz" : decodedName
            let fileName = explicitFileName ?? fallbackName
            
            context.filename = fileName
            context.relativePath = relativePath
            
            let success = setupUpload(context: context)
            if !success {
                // Reject duplicate or errored uploads instantly
                sendResponse(connection, 409, "File already exists or cannot be created.", origin: context.requestOrigin)
                return
            }
            
            // Streaming Logic
            context.isHeaderParsed = true 
            
            let queue = connection.queue ?? .global()
            queue.async { [weak self] in
                guard let self = self else { return }
                
                // Write any initial body data that got buffered on the background queue
                let initialBody = context.extractBuffer()
                if !initialBody.isEmpty {
                    if let fileHandle = context.fileHandle {
                        try? fileHandle.write(contentsOf: initialBody)
                        context.receivedLength += Int64(initialBody.count)
                    }
                }
                
                // Set flag so subsequent packets can be written on background queue
                context.isInitialBodyWritten = true
                
                // Check if any additional packets arrived and were buffered while we were writing the initial body
                let extraBody = context.extractBuffer()
                if !extraBody.isEmpty {
                    if let fileHandle = context.fileHandle {
                        try? fileHandle.write(contentsOf: extraBody)
                        context.receivedLength += Int64(extraBody.count)
                    }
                }
                
                // Check if upload is already complete
                Task { @MainActor in
                    self.checkUploadCompletion(connection: connection, context: context)
                }
            }
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
                        <span>\(error!)</span>
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

        // Reconstruct final target destination path in the Inbox folder
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return false }
        let inbox = appSupport.appendingPathComponent("InksyncVault/Inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)

        var finalDestURL: URL

        if let relPathString = context.relativePath, !relPathString.isEmpty {
            finalDestURL = inbox.appendingPathComponent(relPathString).standardizedFileURL

            guard finalDestURL.path.hasPrefix(inbox.standardizedFileURL.path) else {
                Logger.shared.log("WiFi Transfer - Rejected Traversal Upload Attempt: \(relPathString)", category: "Network", type: .error)
                return false
            }
        } else {
            let sanitizedFileName = URL(fileURLWithPath: context.filename).lastPathComponent
            finalDestURL = inbox.appendingPathComponent(sanitizedFileName).standardizedFileURL
        }

        context.finalDestinationURL = finalDestURL

        // Write the active uploading file to a staging directory (completely hidden from the scanner)
        let stagingDir = appSupport.appendingPathComponent("InksyncVault/Staging", isDirectory: true)
        try? FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        
        let stagingUUID = UUID().uuidString
        let stagingURL = stagingDir.appendingPathComponent("\(stagingUUID).tmp").standardizedFileURL
        
        context.destinationURL = stagingURL

        // Duplicate final file prevention: delete existing final file to allow overwrite
        if FileManager.default.fileExists(atPath: finalDestURL.path) {
            Logger.shared.log("WiFi Transfer - File already exists. Removing existing file to overwrite/retry: \(finalDestURL.lastPathComponent)", category: "Network")
            try? FileManager.default.removeItem(at: finalDestURL)
        }

        // Track both staging and final paths in the active uploads registry
        ActiveUploadRegistry.shared.register(stagingURL)
        ActiveUploadRegistry.shared.register(finalDestURL)
        
        FileManager.default.createFile(atPath: stagingURL.path, contents: nil, attributes: nil)
        Logger.shared.log("Starting Staged Upload: \(context.filename) -> \(stagingURL.lastPathComponent)", category: "Network")

        do {
            context.fileHandle = try FileHandle(forWritingTo: stagingURL)
            self.isUploading = true
            self.currentUploadFilename = context.filename
            self.uploadProgress = 0.0
            self.startBackgroundTask()
            return true
        } catch {
            ActiveUploadRegistry.shared.unregister(stagingURL)
            ActiveUploadRegistry.shared.unregister(finalDestURL)
            Logger.shared.log("WiFi Transfer Failed to open staging file for writing: \(error.localizedDescription)", category: "Network", type: .error)
            return false
        }
    }
    
    private func writeBodyData(_ data: Data, context: ConnectionContext) {
        guard let fileHandle = context.fileHandle else { return }
        
        // Write to disk
        try? fileHandle.write(contentsOf: data)
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
            Logger.shared.log("Staged Upload Complete: \(context.filename) (\(context.receivedLength) bytes)", category: "Network")
            
            // 1. Close file handle first so the file is locked and flushed
            try? context.fileHandle?.close()
            context.fileHandle = nil
            
            // 2. Move file from staging to final Inbox destination atomically
            if let tempURL = context.destinationURL, let finalURL = context.finalDestinationURL {
                // Ensure parent directory exists for final URL
                let parentDir = finalURL.deletingLastPathComponent()
                try? FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
                
                do {
                    try FileManager.default.moveItem(at: tempURL, to: finalURL)
                    Logger.shared.log("WiFi Transfer - Atomically moved completed file to Inbox: \(finalURL.lastPathComponent)", category: "Network")
                } catch {
                    Logger.shared.log("WiFi Transfer - Failed to move completed file to Inbox: \(error.localizedDescription)", category: "Network", type: .error)
                    try? FileManager.default.removeItem(at: tempURL)
                }
            }
            
            // 3. Perform cleanup of connection and registry
            cleanup(context: context)
            sendResponse(connection, 200, "Upload Complete", origin: context.requestOrigin)
            
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
                NotificationCenter.default.post(name: .libraryUpdated, object: nil)
            }
        }
    }
    
    private func cleanup(context: ConnectionContext) {
        try? context.fileHandle?.close()
        context.fileHandle = nil
        
        if let url = context.destinationURL {
            ActiveUploadRegistry.shared.unregister(url)
            
            // Delete partial or corrupted upload file if connection was aborted/cancelled mid-transfer
            if context.expectedLength > 0 && context.receivedLength < context.expectedLength {
                try? FileManager.default.removeItem(at: url)
                Logger.shared.log("WiFi Transfer - Deleted partial/corrupted upload: \(url.lastPathComponent)", category: "Network", type: .warning)
            }
        }
        if let finalURL = context.finalDestinationURL {
            ActiveUploadRegistry.shared.unregister(finalURL)
        }
        self.isUploading = false
    }
    
    // MARK: - Handlers
    
    private func handleGetRequest(cleanPath: String, queryItems: [URLQueryItem], connection: NWConnection, origin: String) {
        if case let .hostPort(host, _) = connection.endpoint {
            let ipStr = "\(host)".components(separatedBy: "%").first ?? "\(host)"
            lastSeenIPs[ipStr] = Date()
            updateActiveConnectionsCount()
        }
        
        guard let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        
        if cleanPath == "/" {
            let count = LibraryService.shared.items.count
            Logger.shared.log("WiFiServer - handleGetRequest: serving dashboard HTML. Staged items in memory: \(count)", category: "Network")
            let html = generateHTML()
            sendResponse(connection, 200, html, contentType: "text/html", origin: origin)
        } else if cleanPath == "/api/library" {
            let files = getLibraryFilesList()
            Logger.shared.log("WiFiServer - handleGetRequest: /api/library requested. Returning \(files.count) serialized files.", category: "Network")
            if let data = try? JSONSerialization.data(withJSONObject: files, options: []),
               let jsonString = String(data: data, encoding: .utf8) {
                sendResponse(connection, 200, jsonString, contentType: "application/json", origin: origin)
            } else {
                Logger.shared.log("WiFiServer - handleGetRequest: /api/library JSON serialization failed!", category: "Network", type: .error)
                sendResponse(connection, 500, "{\"error\": \"Failed to serialize library\"}", contentType: "application/json", origin: origin)
            }
        } else if cleanPath == "/api/logs" {
            Task { @MainActor in
                let logs = Logger.shared.parsedLogs
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                if let data = try? encoder.encode(logs),
                   let jsonString = String(data: data, encoding: .utf8) {
                    self.sendResponse(connection, 200, jsonString, contentType: "application/json", origin: origin)
                } else {
                    self.sendResponse(connection, 500, "{\"error\": \"Failed to serialize logs\"}", contentType: "application/json", origin: origin)
                }
            }
        } else if cleanPath == "/api/sync" {
            // ✅ NEW: Full P2P SwiftData Cross-Device Payload Export
            Task { @MainActor in
                do {
                    // Extract monolithic SwiftData array into memory safely
                    let payload = try SyncCoordinator.shared.exportDatabase()
                    let data = try JSONEncoder().encode(payload)
                    
                    // Route bytes directly to client
                    self.sendResponse(connection, 200, data: data, contentType: "application/json", filename: "Inksync_Database.json", origin: origin)
                } catch {
                    Logger.shared.log("WiFi Transfer - Sync API Crash: \(error.localizedDescription)", category: "Network", type: .error)
                    self.sendResponse(connection, 500, "Internal Sync Formatting Error", origin: origin)
                }
            }
        } else if cleanPath == "/queue.zip" {
            // Hybrid P2P On-The-Fly ZIP Streaming
            // stagedFilesSnapshot() is nonisolated — safe to call from this background queue.
            let stagedFiles = TransferQueueManager.shared.stagedFilesSnapshot()
            
            guard !stagedFiles.isEmpty else {
                sendResponse(connection, 404, "No staged files in the Transfer Queue.", origin: origin)
                return
            }
            
            do {
                // Determine a safe intermediate temp file for the zip
                let tempZipURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
                
                let newArchive: ZIPFoundation.Archive
                do {
                    newArchive = try ZIPFoundation.Archive(url: tempZipURL, accessMode: .create)
                } catch {
                    sendResponse(connection, 500, "Failed to create archive stream: \(error.localizedDescription)", origin: origin)
                    return
                }
                var archive: ZIPFoundation.Archive? = newArchive
                guard let validArchive = archive else {
                    sendResponse(connection, 500, "Failed to create archive stream.", origin: origin)
                    return
                }
                
                for file in stagedFiles {
                    try validArchive.addEntry(with: file.name, relativeTo: file.url.deletingLastPathComponent())
                }
                
                // FLUSH ZIP FOOTERS TO DISK!
                archive = nil
                
                sendFileResponse(connection, fileURL: tempZipURL, contentType: "application/zip", filename: "Inksync_Queue.zip", deleteAfterSend: true)
            } catch {
                Logger.shared.log("WiFi Transfer ZIP Error: \(error.localizedDescription)", category: "Network", type: .error)
                sendResponse(connection, 500, "Internal Server Error during ZIP creation.", origin: origin)
            }
        } else if cleanPath == "/page_sync" {
            handlePageSync(queryItems: queryItems, connection: connection)
        } else {
            // URL Decode the path (critical for filenames with spaces!)
            // e.g. /my%20comic.epub -> my comic.epub
            let decodedPath = cleanPath.removingPercentEncoding ?? cleanPath
            let fileName = decodedPath.hasPrefix("/") ? String(decodedPath.dropFirst()) : decodedPath
            
            var fileURL: URL? = nil
            
            // 1. Look up in active library items first (supports external/linked files too!)
            let activeItems = LibraryService.shared.items
            for item in activeItems {
                let itemURL = item.url
                
                var relativePath = itemURL.lastPathComponent
                if itemURL.path.hasPrefix(docDir.path) {
                    relativePath = itemURL.path.replacingOccurrences(of: docDir.path, with: "")
                } else if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
                    let inboxDir = appSupport.appendingPathComponent("InksyncVault/Inbox", isDirectory: true)
                    if itemURL.path.hasPrefix(inboxDir.path) {
                        relativePath = itemURL.path.replacingOccurrences(of: inboxDir.path, with: "")
                    }
                }
                if relativePath.hasPrefix("/") {
                    relativePath.removeFirst()
                }
                
                if relativePath == fileName || itemURL.lastPathComponent == fileName {
                    fileURL = itemURL
                    break
                }
            }
            
            // 2. Fallback to physical lookup in standard sandboxed directories
            if fileURL == nil {
                guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { sendResponse(connection, 500, "Internal Server Error"); return }
                let inboxDir = appSupport.appendingPathComponent("InksyncVault/Inbox", isDirectory: true)
                let docFileURL = docDir.appendingPathComponent(fileName).standardizedFileURL
                let inboxFileURL = inboxDir.appendingPathComponent(fileName).standardizedFileURL
                
                if FileManager.default.fileExists(atPath: inboxFileURL.path) && inboxFileURL.path.hasPrefix(inboxDir.standardizedFileURL.path) {
                    fileURL = inboxFileURL
                } else if FileManager.default.fileExists(atPath: docFileURL.path) && docFileURL.path.hasPrefix(docDir.standardizedFileURL.path) {
                    fileURL = docFileURL
                }
            }
            
            guard let finalURL = fileURL, FileManager.default.fileExists(atPath: finalURL.path) else {
                Logger.shared.log("WiFi Transfer - File not found: \(fileName)", category: "Network", type: .warning)
                sendResponse(connection, 404, "Not Found")
                return
            }
            
            // Access security scoped resource if external/linked file
            let isSandbox = PhysicalFileSystemRouter.isSandboxURL(finalURL)
            let isSecScoped = !isSandbox && finalURL.startAccessingSecurityScopedResource()
            defer {
                if isSecScoped {
                    finalURL.stopAccessingSecurityScopedResource()
                }
            }
            
            let ext = finalURL.pathExtension.lowercased()
            let contentType = (ext == "html") ? "text/html" : "application/octet-stream"
            let downloadFilename = finalURL.lastPathComponent
            
            sendFileResponse(connection, fileURL: finalURL, contentType: contentType, filename: downloadFilename)
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

    private func sendResponse(_ connection: NWConnection, _ code: Int, _ body: String, contentType: String = "text/plain", origin: String = "*") {
        let bodyData = body.data(using: .utf8) ?? Data()
        let header = "HTTP/1.1 \(code) OK\r\n"
            + "Content-Type: \(contentType); charset=utf-8\r\n"
            + "Content-Length: \(bodyData.count)\r\n"
            + "Access-Control-Allow-Origin: \(origin)\r\n"
            + "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
            + "Access-Control-Allow-Headers: Content-Type, X-File-Name, X-Relative-Path, X-Session-Token, X-WiFi-PIN\r\n"
            + "Access-Control-Allow-Credentials: true\r\n"
            + "Cache-Control: no-store, no-cache, must-revalidate\r\n"
            + "Pragma: no-cache\r\n"
            + "Expires: 0\r\n"
            + "Connection: close\r\n"
            + "\r\n"
        guard var response = header.data(using: .utf8) else { return }
        response.append(bodyData)
        connection.send(content: response, completion: .contentProcessed({ _ in connection.cancel() }))
    }
    
    private func sendResponse(_ connection: NWConnection, _ code: Int, data: Data, contentType: String, filename: String? = nil, origin: String = "*") {
        var header = "HTTP/1.1 \(code) OK\r\n"
            + "Content-Type: \(contentType)\r\n"
            + "Content-Length: \(data.count)\r\n"
            + "Access-Control-Allow-Origin: \(origin)\r\n"
            + "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
            + "Access-Control-Allow-Headers: Content-Type, X-File-Name, X-Relative-Path, X-Session-Token, X-WiFi-PIN\r\n"
            + "Access-Control-Allow-Credentials: true\r\n"
        if let filename = filename {
            header += "Content-Disposition: attachment; filename=\"\(filename)\"\r\n"
        }
        header += "Connection: close\r\n\r\n"
        
        connection.send(content: header.data(using: .utf8), completion: .idempotent)
        connection.send(content: data, completion: .contentProcessed({ _ in connection.cancel() }))
    }
    
    private func sendFileResponse(_ connection: NWConnection, fileURL: URL, contentType: String, filename: String, deleteAfterSend: Bool = false) {
        guard let fileHandle = try? FileHandle(forReadingFrom: fileURL) else {
            sendResponse(connection, 500, "Internal Server Error - Cannot open file")
            return
        }
        
        let fileSize: UInt64
        if let attr = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let size = attr[.size] as? UInt64 {
            fileSize = size
        } else {
            fileSize = 0
        }
        
        let header = "HTTP/1.1 200 OK\r\n"
            + "Content-Type: \(contentType)\r\n"
            + "Content-Length: \(fileSize)\r\n"
            + "Content-Disposition: attachment; filename=\"\(filename)\"\r\n"
            + "Connection: close\r\n"
            + "\r\n"
        
        guard let headerData = header.data(using: .utf8) else {
            try? fileHandle.close()
            connection.cancel()
            return
        }
        
        connection.send(content: headerData, completion: .idempotent)
        streamFileChunks(connection: connection, fileHandle: fileHandle, fileURL: fileURL, deleteAfterSend: deleteAfterSend)
    }
    
    nonisolated private func streamFileChunks(connection: NWConnection, fileHandle: FileHandle, fileURL: URL?, deleteAfterSend: Bool) {
        let chunkSize = 65536 // 64KB chunks
        let data: Data
        do {
            if #available(iOS 13.4, *) {
                if let chunk = try fileHandle.read(upToCount: chunkSize) {
                    data = chunk
                } else {
                    data = Data()
                }
            } else {
                data = fileHandle.readData(ofLength: chunkSize)
            }
        } catch {
            Logger.shared.log("Error reading file chunk: \(error)", category: "Network", type: .error)
            try? fileHandle.close()
            if deleteAfterSend, let fileURL = fileURL {
                try? FileManager.default.removeItem(at: fileURL)
            }
            connection.cancel()
            return
        }
        
        if data.isEmpty {
            try? fileHandle.close()
            if deleteAfterSend, let fileURL = fileURL {
                try? FileManager.default.removeItem(at: fileURL)
                Logger.shared.log("Cleaned up temp archive: \(fileURL.lastPathComponent)", category: "Network")
            }
            connection.send(content: nil, contentContext: .defaultStream, isComplete: true, completion: .contentProcessed({ _ in
                connection.cancel()
            }))
        } else {
            connection.send(content: data, contentContext: .defaultMessage, isComplete: false, completion: .contentProcessed({ [weak self] error in
                if let error = error {
                    Logger.shared.log("Error sending chunk: \(error)", category: "Network", type: .error)
                    try? fileHandle.close()
                    if deleteAfterSend, let fileURL = fileURL {
                        try? FileManager.default.removeItem(at: fileURL)
                    }
                    connection.cancel()
                } else {
                    self?.streamFileChunks(connection: connection, fileHandle: fileHandle, fileURL: fileURL, deleteAfterSend: deleteAfterSend)
                }
            }))
        }
    }
    
    // MARK: - Background Task
    
    private var endTaskWorkItem: DispatchWorkItem?

    private func startBackgroundTask() {
        // Cancel any pending end task work item since we have active transfer/connection activity
        endTaskWorkItem?.cancel()
        endTaskWorkItem = nil
        
        if backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "WiFiUpload") { [weak self] in
                self?.endBackgroundTaskImmediately()
            }
            Logger.shared.log("WiFiServer - Background Task Started", category: "Network")
        }
    }
    
    private func endBackgroundTask() {
        // Only end the background task if we are not currently uploading
        guard !isUploading else {
            endTaskWorkItem?.cancel()
            endTaskWorkItem = nil
            return
        }
        
        // Delay ending the background task by 15 seconds to allow the browser 
        // to query library updates and start the next file in the queue without 
        // iOS suspending the app in the 1-2 second gap between uploads.
        endTaskWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self, !self.isUploading else { return }
            self.endBackgroundTaskImmediately()
        }
        endTaskWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 15.0, execute: workItem)
    }
    
    private func endBackgroundTaskImmediately() {
        endTaskWorkItem?.cancel()
        endTaskWorkItem = nil
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
            Logger.shared.log("WiFiServer - Background Task Ended", category: "Network")
        }
    }
    
    // MARK: - HTML Generator
    
    private func getLibraryFilesList() -> [[String: Any]] {
        let items = LibraryService.shared.items
        Logger.shared.log("WiFiServer - getLibraryFilesList: found \(items.count) items in LibraryService.shared.items", category: "Network")
        if !items.isEmpty {
            let samples = items.prefix(3).map { "\($0.name) (size: \($0.fileSize))" }.joined(separator: ", ")
            Logger.shared.log("WiFiServer - getLibraryFilesList sample: \(samples)", category: "Network")
        }
        var files: [[String: Any]] = []
        
        let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.resolvingSymlinksInPath() ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.resolvingSymlinksInPath() ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let inboxDir = appSupport.appendingPathComponent("InksyncVault/Inbox", isDirectory: true)
        
        for item in items {
            let fileURL = item.url
            let ext = fileURL.pathExtension.lowercased()
            let size = item.fileSize
            
            var relativePath = fileURL.lastPathComponent
            if fileURL.path.hasPrefix(docDir.path) {
                relativePath = fileURL.path.replacingOccurrences(of: docDir.path, with: "")
            } else if fileURL.path.hasPrefix(inboxDir.path) {
                relativePath = fileURL.path.replacingOccurrences(of: inboxDir.path, with: "")
            }
            
            if relativePath.hasPrefix("/") {
                relativePath.removeFirst()
            }
            let linkPath = relativePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? relativePath
            let fileType = ext.isEmpty ? "pdf" : ext
            
            files.append([
                "name": item.name,
                "filename": fileURL.lastPathComponent,
                "relativePath": relativePath,
                "sizeBytes": size,
                "link": "/\(linkPath)",
                "type": fileType
            ])
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
                    display: flex;
                    align-items: center;
                    justify-content: center;
                    width: 40px;
                    height: 40px;
                }
                .logo-svg path, .logo-svg circle {
                    transition: stroke 0.2s, fill 0.2s;
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

                #dragOverlay * {
                    pointer-events: none;
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

                .queue-actions {
                    display: flex;
                    gap: 8px;
                }

                .queue-action-btn-global {
                    background: rgba(255, 255, 255, 0.08);
                    border: 1px solid var(--card-border);
                    color: var(--text-primary);
                    padding: 6px 12px;
                    border-radius: 8px;
                    font-size: 12px;
                    font-weight: 600;
                    cursor: pointer;
                    transition: all 0.2s ease;
                }

                .queue-action-btn-global:hover {
                    background: rgba(255, 255, 255, 0.15);
                    border-color: var(--text-secondary);
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
                .file-type-badge.cbr { background: var(--cbz-color); }
                .file-type-badge.cb7 { background: var(--cbz-color); }
                .file-type-badge.cbt { background: var(--cbz-color); }
                .file-type-badge.zip { background: var(--accent-purple); }

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

                /* Retry button in queue */
                .retry-action-btn {
                    background: linear-gradient(135deg, var(--accent-blue), var(--accent-purple));
                    color: white;
                    border: none;
                    border-radius: 6px;
                    padding: 4px 10px;
                    font-size: 11px;
                    font-weight: 600;
                    cursor: pointer;
                    margin-left: 10px;
                    display: inline-block;
                    transition: all 0.2s ease-in-out;
                    box-shadow: 0 2px 4px rgba(0, 0, 0, 0.2);
                }
                .retry-action-btn:hover {
                    opacity: 0.9;
                    transform: translateY(-1px);
                    box-shadow: 0 4px 6px rgba(0, 0, 0, 0.3);
                }
                .retry-action-btn:active {
                    transform: translateY(0);
                }

                /* High-Contrast E-Ink Mode Styles */
                body.eink-mode {
                    --bg-color: #FFFFFF !important;
                    --card-bg: #FFFFFF !important;
                    --card-border: #000000 !important;
                    --text-primary: #000000 !important;
                    --text-secondary: #222222 !important;
                    --accent-blue: #000000 !important;
                    --accent-purple: #000000 !important;
                    --accent-cyan: #000000 !important;
                    --success-color: #000000 !important;
                    --warning-color: #000000 !important;
                    --error-color: #000000 !important;
                    --cbz-color: #000000 !important;
                    --epub-color: #000000 !important;
                    --pdf-color: #000000 !important;
                    --shadow: none !important;
                    --glass-blur: none !important;
                }

                body.eink-mode .logo-svg path {
                    stroke: #000000 !important;
                    fill: none !important;
                    filter: none !important;
                }
                body.eink-mode .logo-svg circle {
                    fill: #000000 !important;
                    filter: none !important;
                }

                body.eink-mode .ambient-glow {
                    display: none !important;
                }

                body.eink-mode .dashboard-container {
                    max-width: 900px !important;
                }

                body.eink-mode .queue-card,
                body.eink-mode .dropzone,
                body.eink-mode .library-section,
                body.eink-mode #debugLogContainer {
                    background: #FFFFFF !important;
                    border: 2px solid #000000 !important;
                    border-radius: 4px !important;
                    box-shadow: none !important;
                    backdrop-filter: none !important;
                    -webkit-backdrop-filter: none !important;
                }

                body.eink-mode .dropzone {
                    border-style: dashed !important;
                }

                body.eink-mode .library-item {
                    border: 1px solid #000000 !important;
                    background: #FFFFFF !important;
                    border-radius: 4px !important;
                    margin-bottom: 8px !important;
                    box-shadow: none !important;
                }

                body.eink-mode .file-type-badge {
                    background: #000000 !important;
                    color: #FFFFFF !important;
                    border: 1px solid #000000 !important;
                    border-radius: 2px !important;
                }

                body.eink-mode .download-action-btn,
                body.eink-mode .retry-action-btn,
                body.eink-mode .zip-btn {
                    background: #FFFFFF !important;
                    color: #000000 !important;
                    border: 2px solid #000000 !important;
                    border-radius: 4px !important;
                    box-shadow: none !important;
                    text-decoration: none !important;
                }
                
                body.eink-mode .download-action-btn:hover,
                body.eink-mode .retry-action-btn:hover,
                body.eink-mode .zip-btn:hover {
                    background: #000000 !important;
                    color: #FFFFFF !important;
                }
                
                body.eink-mode #debugLogContainer {
                    color: #000000 !important;
                    background: #FFFFFF !important;
                    border: 2px solid #000000 !important;
                }
            </style>
        </head>
        <body>
            <div class="ambient-glow glow-1"></div>
            <div class="ambient-glow glow-2"></div>

            <div class="dashboard-container">
                <header>
                    <div class="header-left">
                        <div class="logo-icon">
                            <svg class="logo-svg" viewBox="0 0 100 100" fill="none" xmlns="http://www.w3.org/2000/svg" style="width:40px; height:40px;">
                                <defs>
                                    <linearGradient id="logoGrad" x1="0%" y1="0%" x2="100%" y2="100%">
                                        <stop offset="0%" stop-color="#3B82F6"/>
                                        <stop offset="50%" stop-color="#6366F1"/>
                                        <stop offset="100%" stop-color="#EC4899"/>
                                    </linearGradient>
                                    <filter id="logoGlow" x="-20%" y="-20%" width="140%" height="140%">
                                        <feGaussianBlur stdDeviation="3" result="coloredBlur"/>
                                        <feMerge>
                                            <feMergeNode in="coloredBlur"/>
                                            <feMergeNode in="SourceGraphic"/>
                                        </feMerge>
                                    </filter>
                                </defs>
                                <path d="M50 15L32 48C32 48 45 52 50 52C55 52 68 48 68 48L50 15Z" fill="url(#logoGrad)" filter="url(#logoGlow)"/>
                                <path d="M50 15V38" stroke="#0B0F19" stroke-width="3" stroke-linecap="round"/>
                                <circle cx="50" cy="38" r="3" fill="#0B0F19"/>
                                <path d="M22 68C22 75 32 82 45 84" stroke="url(#logoGrad)" stroke-width="3.5" stroke-linecap="round"/>
                                <path d="M45 80L49 84L45 88" stroke="url(#logoGrad)" stroke-width="3.5" stroke-linecap="round" stroke-linejoin="round" fill="none"/>
                                <path d="M78 52C78 45 68 38 55 36" stroke="url(#logoGrad)" stroke-width="3.5" stroke-linecap="round"/>
                                <path d="M55 40L51 36L55 32" stroke="url(#logoGrad)" stroke-width="3.5" stroke-linecap="round" stroke-linejoin="round" fill="none"/>
                            </svg>
                        </div>
                        <div>
                            <h1>Inksync Pro</h1>
                            <div class="subtitle">WiFi File Sharing Server</div>
                        </div>
                    </div>
                    <div class="header-right" style="display:flex; gap:12px; align-items:center;">
                        <button onclick="toggleEInkMode()" id="einkToggleBtn" style="background:var(--card-bg); border:1px solid var(--card-border); color:var(--text-primary); padding:8px 16px; border-radius:12px; font-size:13px; font-weight:600; cursor:pointer; display:flex; align-items:center; gap:6px; transition:all 0.2s;">
                            <span>\u{1F311}</span> High-Contrast E-Ink
                        </button>
                        \(queueButtonHTML)
                    </div>
                </header>

                <!-- Offline Settings Panel -->
                <div class="card" id="offlineSettings" style="display:none; margin-bottom: 20px; background: rgba(59, 130, 246, 0.05); border: 1px solid var(--accent-blue); padding: 20px; border-radius: 16px;">
                    <div style="font-weight: 700; font-size: 15px; margin-bottom: 8px; color: var(--accent-blue); display:flex; align-items:center; gap:6px;">
                        <span>🌐</span> Offline Mode Settings
                    </div>
                    <div style="font-size: 13px; color: var(--text-secondary); margin-bottom: 16px;">You are running this page from a local file. Set your target iPad's IP address and Security PIN code to enable remote transfers:</div>
                    <div style="display: flex; gap: 12px; align-items: center; flex-wrap: wrap;">
                        <input type="text" id="ipadIp" placeholder="iPad IP Address (e.g. 192.168.1.17:8080)" style="background: rgba(0,0,0,0.15); border: 1px solid var(--card-border); color: var(--text-primary); padding: 10px 14px; border-radius: 10px; font-size: 14px; flex: 2; min-width: 200px;">
                        <input type="text" id="ipadPin" placeholder="PIN Code" style="background: rgba(0,0,0,0.15); border: 1px solid var(--card-border); color: var(--text-primary); padding: 10px 14px; border-radius: 10px; font-size: 14px; flex: 1; min-width: 100px;">
                        <button class="queue-action-btn-global" onclick="saveOfflineSettings()" style="padding: 11px 20px; border-radius: 10px; background: var(--accent-blue); color:#fff; border:none; font-weight:700; cursor:pointer;">Apply Connection</button>
                    </div>
                </div>

                <!-- Memory Warning Banner -->
                <div class="warning-banner" id="memoryWarningBanner" style="display:none; background:#FFFBEB; border:2px solid #D97706; color:#B45309; padding:16px; border-radius:12px; font-size:14px; margin-bottom:20px; font-weight:600; text-align:center; box-shadow: 0 4px 6px rgba(0,0,0,0.05);">
                    \u{26A0}\u{FE0F} Low System Memory: The browser reloaded while you were selecting files. Please close other open tabs or use drag-and-drop to upload files.
                </div>

                <!-- Staged upload queue -->
                <div class="queue-card" id="queueCard">
                    <div class="queue-header">
                        <div style="display:flex; flex-direction:column; gap:4px;">
                            <span class="queue-title">Upload Progress</span>
                            <span class="subtitle" id="queueCount" style="margin-left:0;">0 files remaining</span>
                        </div>
                        <div class="queue-actions">
                            <button class="queue-action-btn-global" onclick="retryAllFailed()">Retry Failed</button>
                            <button class="queue-action-btn-global" onclick="clearCompleted()">Clear Completed</button>
                        </div>
                    </div>
                    <div class="queue-items" id="queueItems"></div>
                </div>

                <!-- Dropzone / File Select -->
                <div class="dropzone" id="dropzone" onclick="document.getElementById('fileInput').click();">
                    <div class="dropzone-icon">📥</div>
                    <h2>Drag & Drop Files Here</h2>
                    <p class="subtitle">Supports CBZ, CBR, EPUB, PDF, and ZIP files. Or click to browse.</p>
                </div>
                <input type="file" id="fileInput" style="display:none" multiple accept=".pdf,.epub,.cbz,.cbr,.cb7,.cbt,.zip" onchange="handleFileSelect(event)" onclick="try { sessionStorage.setItem('upload_initiated', 'true'); } catch(e) {}">

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
                
                <!-- Diagnostics Section -->
                <div class="library-section" style="margin-top: 16px;">
                    <div style="display:flex; justify-content:space-between; align-items:center;">
                        <span style="font-size:14px; font-weight:600; color:var(--text-secondary);">🔧 System Diagnostics & Activity Log</span>
                        <button onclick="toggleDebugLog()" style="background:none; border:1px solid var(--card-border); color:var(--text-secondary); padding:4px 8px; border-radius:6px; font-size:11px; cursor:pointer;">Toggle Log</button>
                    </div>
                    <div id="debugLogContainer" style="display:block; max-height:200px; overflow-y:auto; background:rgba(0,0,0,0.3); border:1px solid var(--card-border); border-radius:10px; padding:12px; margin-top:8px;">
                        <!-- Logs will populate here -->
                    </div>
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
                const MAX_LOGS = 100;
                
                // Keep local logs in memory as fallback, and try loading from sessionStorage
                const localClientLogs = [];

                // Offline support & dynamic routing
                function getTargetUrl(path) {
                    const localIp = localStorage.getItem('ipad_ip');
                    if (localIp) {
                        const cleanPath = path.startsWith('/') ? path : '/' + path;
                        return 'http://' + localIp + cleanPath;
                    }
                    return path;
                }

                function getHeaders(customHeaders = {}) {
                    const pin = localStorage.getItem('ipad_pin');
                    if (pin) {
                        customHeaders['X-WiFi-PIN'] = pin;
                    }
                    return customHeaders;
                }

                // IndexedDB local queue persistence
                let db;
                const DB_NAME = 'inksynpro_uploads';
                const STORE_NAME = 'files';

                function initDB(callback) {
                    try {
                        const request = indexedDB.open(DB_NAME, 1);
                        request.onupgradeneeded = (e) => {
                            db = e.target.result;
                            db.createObjectStore(STORE_NAME, { keyPath: 'id' });
                        };
                        request.onsuccess = (e) => {
                            db = e.target.result;
                            if (callback) callback();
                        };
                        request.onerror = (e) => {
                            logDebug("IndexedDB failed to initialize", 'error');
                            if (callback) callback();
                        };
                    } catch (err) {
                        logDebug("IndexedDB check ignored: " + err.message, 'warning');
                        if (callback) callback();
                    }
                }

                function saveFileToIndexedDB(item) {
                    if (!db) return;
                    try {
                        const tx = db.transaction(STORE_NAME, 'readwrite');
                        const store = tx.objectStore(STORE_NAME);
                        store.put({
                            id: item.id,
                            file: item.file,
                            relativePath: item.file.customRelativePath || item.file.webkitRelativePath || ''
                        });
                    } catch (e) {
                        logDebug("Failed to save file to IndexedDB: " + e.message, 'warning');
                    }
                }

                function removeFileFromIndexedDB(id) {
                    if (!db) return;
                    try {
                        const tx = db.transaction(STORE_NAME, 'readwrite');
                        const store = tx.objectStore(STORE_NAME);
                        store.delete(id);
                    } catch (e) {}
                }

                function loadQueueFromIndexedDB() {
                    if (!db) return;
                    try {
                        const tx = db.transaction(STORE_NAME, 'readonly');
                        const store = tx.objectStore(STORE_NAME);
                        const request = store.getAll();
                        request.onsuccess = (e) => {
                            const items = e.target.result || [];
                            if (items.length > 0) {
                                logDebug(`Restored ${items.length} files from local IndexedDB storage.`);
                                items.forEach(item => {
                                    item.file.customRelativePath = item.relativePath;
                                    uploadQueue.push({
                                        id: item.id,
                                        file: item.file,
                                        status: 'queued',
                                        progress: 0,
                                        speed: '',
                                        eta: ''
                                    });
                                });
                                renderQueue();
                            }
                        };
                    } catch (e) {}
                }

                // Dynamic Status & Library Polling timers based on E-Ink Mode
                let logsTimer = null;
                let libraryTimer = null;

                function startIntervals() {
                    if (logsTimer) clearInterval(logsTimer);
                    if (libraryTimer) clearInterval(libraryTimer);

                    const isEink = document.body.classList.contains('eink-mode');
                    const logsDelay = isEink ? 20000 : 4000;
                    const libraryDelay = isEink ? 15000 : 5000;

                    logsTimer = setInterval(refreshLogs, logsDelay);
                    libraryTimer = setInterval(fetchLibraryUpdates, libraryDelay);
                    logDebug(`Dynamic status intervals loaded. Logs: ${logsDelay}ms, Library: ${libraryDelay}ms.`);
                }
                try {
                    const raw = sessionStorage.getItem('inksync_logs');
                    if (raw) {
                        const parsed = JSON.parse(raw);
                        if (Array.isArray(parsed)) {
                            localClientLogs.push(...parsed);
                        }
                    }
                } catch (e) {}

                let serverLogs = [];

                // Diagnostic log helper
                function logDebug(message, type = 'info') {
                    const timestamp = new Date().toISOString();
                    const entryObj = { timestamp: timestamp, message: message, type: type };
                    
                    localClientLogs.push(entryObj);
                    if (localClientLogs.length > MAX_LOGS) {
                        localClientLogs.shift();
                    }
                    
                    // Attempt persisting in sessionStorage, but degrade gracefully if blocked
                    try {
                        sessionStorage.setItem('inksync_logs', JSON.stringify(localClientLogs));
                    } catch (e) {}

                    console.log(`[DEBUG] [${type.toUpperCase()}] ${message}`);
                    refreshLogs();
                }

                function refreshLogs() {
                    const logContainer = document.getElementById('debugLogContainer');
                    if (!logContainer) return;

                    fetch(getTargetUrl('/api/logs'), { 
                        credentials: 'include',
                        headers: getHeaders()
                    })
                        .then(res => res.ok ? res.json() : [])
                        .then(data => {
                            serverLogs = data.map(entry => ({
                                timestamp: entry.timestamp,
                                type: entry.type.toLowerCase(),
                                message: `[${entry.category}] ${entry.message}`
                            }));
                            renderLogs();
                        })
                        .catch(err => {
                            console.error("Failed to fetch server logs:", err);
                            renderLogs(); // fallback to render local logs only
                        });
                }

                function renderLogs() {
                    const logContainer = document.getElementById('debugLogContainer');
                    if (!logContainer) return;

                    const clientLogs = localClientLogs.map(entry => ({
                        timestamp: entry.timestamp,
                        type: entry.type,
                        message: `[Client] ${entry.message}`
                    }));

                    const combined = [...serverLogs, ...clientLogs];
                    // Sort oldest first (chronological order)
                    combined.sort((a, b) => a.timestamp.localeCompare(b.timestamp));

                    logContainer.innerHTML = '';
                    
                    // Display last MAX_LOGS
                    const toDisplay = combined.slice(-MAX_LOGS);
                    toDisplay.forEach(entry => {
                        const div = document.createElement('div');
                        div.style.color = entry.type === 'error' ? 'var(--error-color)' : (entry.type === 'warning' ? 'var(--warning-color)' : 'var(--text-secondary)');
                        div.style.fontSize = '12px';
                        div.style.fontFamily = 'monospace';
                        div.style.marginBottom = '4px';
                        div.style.borderBottom = '1px solid rgba(255,255,255,0.03)';
                        div.style.paddingBottom = '4px';
                        
                        let timeStr = '';
                        try {
                            timeStr = new Date(entry.timestamp).toLocaleTimeString();
                        } catch (e) {
                            timeStr = entry.timestamp;
                        }

                        div.innerText = `[${timeStr}] [${entry.type.toUpperCase()}] ${entry.message}`;
                        logContainer.appendChild(div);
                    });
                    
                    logContainer.scrollTop = logContainer.scrollHeight;
                }

                // Global Error Hooking
                window.onerror = function(message, source, lineno, colno, error) {
                    const errStr = `${message} at ${source}:${lineno}:${colno}`;
                    logDebug(errStr, 'error');
                    return false;
                };

                window.onunhandledrejection = function(event) {
                    const reason = event.reason ? (event.reason.message || event.reason) : 'Unknown reason';
                    logDebug(`Unhandled Promise Rejection: ${reason}`, 'error');
                };

                function toggleDebugLog() {
                    const el = document.getElementById('debugLogContainer');
                    if (el) {
                        el.style.display = el.style.display === 'none' ? 'block' : 'none';
                    }
                }

                function toggleEInkMode() {
                    try {
                        const body = document.body;
                        const btn = document.getElementById('einkToggleBtn');
                        const isEInk = body.classList.toggle('eink-mode');
                        
                        localStorage.setItem('eink_mode_enabled', isEInk ? 'true' : 'false');
                        
                        if (btn) {
                            btn.innerHTML = isEInk ? '<span>\u{2600}\u{FE0F}</span> Disable E-Ink' : '<span>\u{1F311}</span> High-Contrast E-Ink';
                            btn.style.background = isEInk ? '#FFFFFF' : 'var(--card-bg)';
                            btn.style.color = isEInk ? '#000000' : 'var(--text-primary)';
                            btn.style.border = isEInk ? '2px solid #000000' : '1px solid var(--card-border)';
                        }
                        
                        logDebug(`E-Ink High-Contrast Mode ${isEInk ? 'enabled' : 'disabled'}`);
                        startIntervals();
                    } catch (e) {
                        console.error("Error toggling E-Ink: ", e);
                    }
                }

                function initEInkSettings() {
                    try {
                        const ua = navigator.userAgent.toLowerCase();
                        const isOnyxBoox = ua.includes('boox') || ua.includes('onyx') || ua.includes('ereader');
                        const savedPref = localStorage.getItem('eink_mode_enabled');
                        
                        if (savedPref === 'true' || (savedPref === null && isOnyxBoox)) {
                            const body = document.body;
                            body.classList.add('eink-mode');
                            const btn = document.getElementById('einkToggleBtn');
                            if (btn) {
                                btn.innerHTML = '<span>\u{2600}\u{FE0F}</span> Disable E-Ink';
                                btn.style.background = '#FFFFFF';
                                btn.style.color = '#000000';
                                btn.style.border = '2px solid #000000';
                            }
                            logDebug("Auto-detected E-Ink device / user preference. High-contrast theme loaded.");
                        }
                    } catch (e) {
                        console.error("Error initializing E-Ink settings: ", e);
                    }
                }

                let libraryFiles = \(filesJSONString);
                let activeFilter = 'all';
                let searchQuery = '';

                const uploadQueue = [];
                let isUploading = false;
                let uploadStartTime = 0;
                let isPaused = false;
                let reconnectTimer = null;

                document.addEventListener('DOMContentLoaded', () => {
                    // Initialize theme preferences and E-Ink checks
                    try {
                        initEInkSettings();
                    } catch (err) {
                        console.error("Error setting up e-ink: ", err);
                    }

                    // Start dynamic timers
                    try {
                        refreshLogs();
                        fetchLibraryUpdates();
                        startIntervals();
                    } catch (e) {}

                    // Staging settings for offline file origin
                    if (location.protocol === 'file:') {
                        const panel = document.getElementById('offlineSettings');
                        if (panel) {
                            panel.style.display = 'block';
                            document.getElementById('ipadIp').value = localStorage.getItem('ipad_ip') || '';
                            document.getElementById('ipadPin').value = localStorage.getItem('ipad_pin') || '';
                        }
                    }

                    // Restore staging queue from IndexedDB
                    initDB(() => {
                        loadQueueFromIndexedDB();
                    });

                    logDebug("Initializing Inksync Sharing Server Web Interface...");

                    // Check for memory-pressure reloads
                    try {
                        if (sessionStorage.getItem('upload_initiated') === 'true') {
                            sessionStorage.removeItem('upload_initiated');
                            const banner = document.getElementById('memoryWarningBanner');
                            if (banner) {
                                banner.style.display = 'block';
                            }
                            logDebug("\u{26A0}\u{FE0F} System memory pressure detected. The page reloaded while the file picker was open.", "warning");
                        }
                    } catch (err) {
                        console.error("Error checking reload: ", err);
                    }

                    try {
                        renderLibrary();
                        logDebug("Library files list rendered successfully.");
                    } catch (err) {
                        logDebug("Error rendering library files: " + err.message, 'error');
                    }
                    try {
                        setupDragAndDrop();
                        logDebug("Drag-and-drop systems initialized.");
                    } catch (err) {
                        logDebug("Error setting up drag-and-drop systems: " + err.message, 'error');
                    }
                });

                function saveOfflineSettings() {
                    try {
                        const ip = document.getElementById('ipadIp').value.trim();
                        const pin = document.getElementById('ipadPin').value.trim();
                        
                        localStorage.setItem('ipad_ip', ip);
                        localStorage.setItem('ipad_pin', pin);
                        
                        showNotification("Connection settings updated! Reloading...", "success");
                        setTimeout(() => location.reload(), 1200);
                    } catch (e) {
                        console.error("Error saving offline settings:", e);
                    }
                }

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
                    logDebug(`Filter changed to: ${type}`);
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
                    let dragCounter = 0;

                    window.addEventListener('dragenter', (e) => {
                        e.preventDefault();
                        dragCounter++;
                        overlay.style.display = 'flex';
                    });

                    window.addEventListener('dragover', (e) => {
                        e.preventDefault();
                    });

                    window.addEventListener('dragleave', (e) => {
                        e.preventDefault();
                        dragCounter--;
                        if (dragCounter === 0) {
                            overlay.style.display = 'none';
                        }
                    });

                    window.addEventListener('drop', (e) => {
                        e.preventDefault();
                        dragCounter = 0;
                        overlay.style.display = 'none';
                    });

                    overlay.addEventListener('drop', (e) => {
                        e.preventDefault();
                        dragCounter = 0;
                        overlay.style.display = 'none';

                        const items = e.dataTransfer.items;
                        if (items && items.length > 0) {
                            logDebug(`Dropped ${items.length} items onto drop zone`);
                            for (let i = 0; i < items.length; i++) {
                                const item = items[i];
                                if (item.kind === 'file') {
                                    const entry = item.webkitGetAsEntry();
                                    if (entry) {
                                        traverseFileTree(entry);
                                    }
                                }
                            }
                        } else if (e.dataTransfer.files.length > 0) {
                            logDebug(`Fallback: Dropped ${e.dataTransfer.files.length} files onto drop zone`);
                            addFilesToQueue(e.dataTransfer.files);
                        }
                    });
                }

                function traverseFileTree(item, path) {
                    path = path || "";
                    if (item.isFile) {
                        item.file((file) => {
                            file.customRelativePath = path + item.name;
                            addFilesToQueue([file]);
                        });
                    } else if (item.isDirectory) {
                        const dirReader = item.createReader();
                        const readEntries = () => {
                            dirReader.readEntries((entries) => {
                                if (entries.length > 0) {
                                    for (let i = 0; i < entries.length; i++) {
                                        traverseFileTree(entries[i], path + item.name + "/");
                                    }
                                    readEntries();
                                }
                            });
                        };
                        readEntries();
                    }
                }

                function handleFileSelect(e) {
                    logDebug("File input change event triggered");
                    if (e.target.files.length > 0) {
                        logDebug(`Selected ${e.target.files.length} files from picker`);
                        addFilesToQueue(e.target.files);
                    } else {
                        logDebug("No files selected in file picker");
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
                    logDebug(`Adding ${files.length} files to queue...`);
                    let skippedCount = 0;
                    for (let i = 0; i < files.length; i++) {
                        const file = files[i];
                        const ext = file.name.split('.').pop().toLowerCase();
                        logDebug(`Checking file: ${file.name} (extension: ${ext}, size: ${file.size} bytes)`);
                        if (!['pdf', 'epub', 'cbz', 'cbr', 'cb7', 'cbt', 'zip'].includes(ext)) {
                            logDebug(`Rejected file: ${file.name} (unsupported format)`, 'warning');
                            showNotification('"' + file.name + '" ignored (unsupported file format).', 'error');
                            continue;
                        }

                        const exists = libraryFiles.some(f => {
                            const sizeMatches = f.sizeBytes === file.size;
                            if (!sizeMatches) return false;
                            
                            const fileRelPath = (file.customRelativePath || file.webkitRelativePath || '').toLowerCase();
                            if (fileRelPath) {
                                return f.relativePath.toLowerCase() === fileRelPath;
                            } else {
                                return (f.filename || f.name).toLowerCase() === file.name.toLowerCase();
                            }
                        });
                        if (exists) {
                            skippedCount++;
                        }

                        const item = {
                            id: generateId(),
                            file: file,
                            status: exists ? 'completed' : 'queued',
                            progress: exists ? 100 : 0,
                            speed: '',
                            eta: exists ? 'Already on device' : ''
                        };
                        uploadQueue.push(item);
                        if (!exists) {
                            saveFileToIndexedDB(item);
                        }
                        logDebug(`Queued: ${file.name} (exists: ${exists})`);
                    }
                    if (skippedCount > 0) {
                        showNotification(`Skipped ${skippedCount} file(s) already present on the iPad.`, 'success');
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
                        let retryBtn = '';
                        if (item.status === 'completed') statusColorClass = 'completed';
                        if (item.status === 'failed') {
                            statusColorClass = 'failed';
                            retryBtn = ' <button class="retry-action-btn" onclick="retryUpload(\\\'' + item.id + '\\\')">Retry</button>';
                        }

                        div.innerHTML = 
                            '<div class="queue-item-meta">' +
                                '<span class="queue-item-name" title="' + item.file.name + '">' + item.file.name + '</span>' +
                                '<span class="queue-item-stats">' +
                                    (item.status === 'uploading' ? item.speed + ' • ' + item.eta : item.status.toUpperCase()) +
                                    retryBtn +
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
                    if (isPaused) {
                        logDebug("Queue processing deferred (queue is paused due to network error)");
                        return;
                    }
                    if (isUploading) {
                        logDebug("Queue processing deferred (already uploading)");
                        return;
                    }

                    const nextItem = uploadQueue.find(item => item.status === 'queued');
                    if (!nextItem) {
                        logDebug("Queue processing completed (no queued items remaining)");
                        return;
                    }

                    isUploading = true;
                    nextItem.status = 'uploading';
                    logDebug(`Starting upload for: ${nextItem.file.name}`);
                    renderQueue();

                    const xhr = new XMLHttpRequest();
                    xhr.open("POST", getTargetUrl('/upload/' + encodeURIComponent(nextItem.file.name)), true);
                    xhr.withCredentials = true;
                    
                    xhr.setRequestHeader("X-File-Name", nextItem.file.name);
                    if (nextItem.file.customRelativePath) {
                        xhr.setRequestHeader("X-Relative-Path", nextItem.file.customRelativePath);
                    } else if (nextItem.file.webkitRelativePath) {
                        xhr.setRequestHeader("X-Relative-Path", nextItem.file.webkitRelativePath);
                    }

                    const customHeaders = getHeaders();
                    for (const key in customHeaders) {
                        xhr.setRequestHeader(key, customHeaders[key]);
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
                        logDebug(`Upload request returned status: ${xhr.status} ${xhr.statusText}`);
                        if (xhr.status === 200) {
                            nextItem.status = 'completed';
                            nextItem.progress = 100;
                            nextItem.speed = '';
                            nextItem.eta = 'Complete';
                            logDebug(`Upload success: ${nextItem.file.name}`);
                            showNotification('"' + nextItem.file.name + '" uploaded successfully.', 'success');
                            removeFileFromIndexedDB(nextItem.id);
                            fetchLibraryUpdates();
                        } else if (xhr.status === 409) {
                            nextItem.status = 'failed';
                            nextItem.progress = 100;
                            nextItem.eta = 'Already Exists';
                            logDebug(`Upload duplicate: ${nextItem.file.name}`, 'warning');
                            showNotification('"' + nextItem.file.name + '" already exists on device.', 'warning');
                            removeFileFromIndexedDB(nextItem.id);
                        } else {
                            nextItem.status = 'failed';
                            nextItem.progress = 100;
                            nextItem.eta = 'Error: ' + xhr.statusText;
                            logDebug(`Upload failed: ${nextItem.file.name} (${xhr.statusText})`, 'error');
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
                        logDebug(`Upload network error for: ${nextItem.file.name}`, 'error');
                        showNotification('Network error uploading "' + nextItem.file.name + '".', 'error');
                        renderQueue();
                        
                        // Auto-pause the queue and start polling for reconnection
                        handleConnectionLoss();
                    };

                    logDebug(`Sending payload request for: ${nextItem.file.name} (size: ${formatBytes(nextItem.file.size)})`);
                    xhr.send(nextItem.file);
                }

                function retryAllFailed() {
                    logDebug("Retrying all failed queue items...");
                    uploadQueue.forEach(item => {
                        if (item.status === 'failed') {
                            item.status = 'queued';
                            item.progress = 0;
                            item.speed = '';
                            item.eta = '';
                        }
                    });
                    renderQueue();
                    processQueue();
                }

                function clearCompleted() {
                    logDebug("Clearing completed queue items...");
                    uploadQueue.splice(0, uploadQueue.length, ...uploadQueue.filter(item => item.status !== 'completed'));
                    renderQueue();
                }

                function handleConnectionLoss() {
                    if (reconnectTimer) return;
                    isPaused = true;
                    showNotification("Connection lost. Queue paused. Retrying to connect...", "warning");
                    
                    reconnectTimer = setInterval(() => {
                        fetch(getTargetUrl('/page_sync'), { headers: getHeaders() })
                            .then(res => {
                                if (res.ok) {
                                    clearInterval(reconnectTimer);
                                    reconnectTimer = null;
                                    isPaused = false;
                                    showNotification("Connection restored! Resuming uploads...", "success");
                                    uploadQueue.forEach(item => {
                                        if (item.status === 'failed') {
                                            item.status = 'queued';
                                            item.progress = 0;
                                            item.speed = '';
                                            item.eta = '';
                                        }
                                    });
                                    renderQueue();
                                    processQueue();
                                }
                            })
                            .catch(err => {
                                logDebug("Reconnect attempt failed (server still offline)...");
                            });
                    }, 5000);
                }

                function fetchLibraryUpdates() {
                    logDebug("Fetching library updates dynamically...");
                    fetch(getTargetUrl('/api/library'), { 
                        credentials: 'include',
                        headers: getHeaders()
                    })
                        .then(res => {
                            logDebug(`Library API returned status: ${res.status}`);
                            return res.json();
                        })
                        .then(data => {
                            libraryFiles = data;
                            logDebug(`Retrieved library details. Render list showing ${data.length} files.`);
                            renderLibrary();
                        })
                        .catch(err => {
                            logDebug("Failed to load library updates dynamically: " + err.message, 'error');
                            console.error("Failed to load library updates dynamically:", err);
                        });
                }

                function retryUpload(id) {
                    const item = uploadQueue.find(x => x.id === id);
                    if (item) {
                        logDebug(`Retrying upload for: ${item.file.name}`);
                        item.status = 'queued';
                        item.progress = 0;
                        item.speed = '';
                        item.eta = '';
                        renderQueue();
                        processQueue();
                    }
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
