import Foundation
import Network

// MARK: - Calibre Wireless Session State

enum CalibreSessionState: Equatable, Sendable {
    case idle
    case connecting
    case handshaking
    case connected(libraryName: String)
    case receivingBook(title: String, progress: Double)
    case disconnected
    case error(String)
}

// MARK: - Calibre Wireless Client

/// Implements the Calibre Smart Device App wireless protocol.
/// InksyncPro acts as the **device** (receiver) side.
///
/// Protocol: raw TCP sockets, length-prefixed JSON packets.
/// Packet format: [4-byte big-endian length][JSON bytes]
/// For SEND_BOOK the JSON is followed immediately by raw file bytes.
///
/// Reference: calibre/src/calibre/devices/smart_device_app/driver.py
/// Opcodes extracted from SMART_DEVICE_APP.opcodes dictionary.
actor CalibreWirelessClient {

    // MARK: - Opcodes (from Calibre source)

    private enum Opcode: Int {
        case ok                    = 0
        case setCalibreDeviceInfo  = 1
        case setCalibreDeviceName  = 2
        case getDeviceInformation  = 3
        case totalSpace            = 4
        case freeSpace             = 5
        case getBookCount          = 6
        case sendBooklists         = 7
        case sendBook              = 8
        case getInitializationInfo = 9
        case bookDone              = 11
        case noop                  = 12
        case deleteBook            = 13
        case getBookFileSegment    = 14
        case getBookMetadata       = 15
        case sendBookMetadata      = 16
        case displayMessage        = 17
        case calibreBusy           = 18
        case setLibraryInfo        = 19
        case error                 = 20
    }

    // MARK: - Constants

    private let protocolVersion = 1
    private let deviceName = "InksyncPro"
    private let deviceUID: String   // stable UUID stored in UserDefaults

    // MARK: - State

    private var connection: NWConnection?
    private var libraryName: String = ""
    private(set) var state: CalibreSessionState = .idle

    // Delegate / callback
    private var onStateChange: (@Sendable (CalibreSessionState) -> Void)?
    private var onBookReceived: (@Sendable (URL) -> Void)?

    // MARK: - Init

    init() {
        // Stable device UUID — persisted across launches so Calibre recognises us
        if let stored = UserDefaults.standard.string(forKey: "calibreDeviceUID") {
            deviceUID = stored
        } else {
            let uid = UUID().uuidString
            UserDefaults.standard.set(uid, forKey: "calibreDeviceUID")
            deviceUID = uid
        }
    }

    // MARK: - Public API

    func connect(
        to host: CalibreHost,
        onStateChange: @escaping @Sendable (CalibreSessionState) -> Void,
        onBookReceived: @escaping @Sendable (URL) -> Void
    ) {
        self.onStateChange = onStateChange
        self.onBookReceived = onBookReceived
        setState(.connecting)

        let connection = NWConnection(to: host.deviceURL, using: .tcp)
        self.connection = connection

        connection.stateUpdateHandler = { [weak self] state in
            Task {
                guard let self else { return }
                switch state {
                case .ready:
                    await self.setState(.handshaking)
                    await self.startReceiveLoop()
                case .failed(let error):
                    await self.setState(.error("Connection failed: \(error.localizedDescription)"))
                case .cancelled:
                    await self.setState(.disconnected)
                default: break
                }
            }
        }

        connection.start(queue: DispatchQueue(label: "com.inksynpro.calibre.socket"))
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        setState(.disconnected)
    }

    // MARK: - Receive Loop

    private func startReceiveLoop() async {
        while let connection, case .ready = connection.state {
            do {
                let (opcode, payload) = try await receivePacket()
                await handleOpcode(opcode, payload: payload)
            } catch {
                setState(.error("Read error: \(error.localizedDescription)"))
                break
            }
        }
    }

    // MARK: - Packet I/O

    /// Reads one length-prefixed JSON packet from the TCP connection.
    /// Returns (opcode integer, payload dictionary).
    private func receivePacket() async throws -> (Int, [String: Any]) {
        guard connection != nil else { throw CalibreError.notConnected }

        // Read 4-byte big-endian length prefix
        let lengthData = try await receive(exactly: 4)
        let length = Int(lengthData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
        guard length > 0, length < 1_000_000 else { throw CalibreError.badPacket }

        // Read JSON payload
        let jsonData = try await receive(exactly: length)
        guard let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let opInt = json["op"] as? Int
        else { throw CalibreError.badPacket }

        Logger.shared.log("CalibreClient: ← opcode \(opInt) (\(Opcode(rawValue: opInt).map(String.init(describing:)) ?? "?"))", category: "Calibre")
        return (opInt, json)
    }

    /// Sends a length-prefixed JSON packet.
    private func sendPacket(_ dict: [String: Any]) async throws {
        guard connection != nil else { throw CalibreError.notConnected }
        let data = try JSONSerialization.data(withJSONObject: dict)
        var length = UInt32(data.count).bigEndian
        var packet = Data(bytes: &length, count: 4)
        packet.append(data)
        Logger.shared.log("CalibreClient: → \(dict["op"] ?? "?")", category: "Calibre")
        try await send(data: packet)
    }

    /// Sends an OK response with optional extra fields.
    private func sendOK(extra: [String: Any] = [:]) async throws {
        var dict: [String: Any] = ["op": Opcode.ok.rawValue]
        dict.merge(extra) { _, new in new }
        try await sendPacket(dict)
    }

    // MARK: - Opcode Handlers

    private func handleOpcode(_ opInt: Int, payload: [String: Any]) async {
        guard let opcode = Opcode(rawValue: opInt) else {
            Logger.shared.log("CalibreClient: unknown opcode \(opInt)", category: "Calibre", type: .warning)
            return
        }

        do {
            switch opcode {
            case .getInitializationInfo:
                try await handleGetInitializationInfo(payload)

            case .setCalibreDeviceInfo:
                try await handleSetCalibreDeviceInfo(payload)

            case .setCalibreDeviceName:
                try await sendOK()

            case .getDeviceInformation:
                try await handleGetDeviceInformation()

            case .freeSpace, .totalSpace:
                let freeBytes = availableBytes()
                try await sendOK(extra: ["freeSpace": freeBytes, "totalSpace": freeBytes])

            case .getBookCount:
                try await handleGetBookCount()

            case .sendBooklists:
                try await handleSendBooklists(payload)

            case .sendBook:
                try await handleSendBook(payload)

            case .noop:
                try await sendOK()

            case .setLibraryInfo:
                if let name = payload["libraryName"] as? String { libraryName = name }
                try await sendOK()

            case .displayMessage:
                if let msg = payload["message"] as? String {
                    Logger.shared.log("Calibre says: \(msg)", category: "Calibre")
                }
                try await sendOK()

            case .deleteBook:
                // Not supported — send OK to keep session alive
                try await sendOK()

            case .ok:
                break   // Calibre acknowledged something we sent

            case .error:
                let msg = payload["message"] as? String ?? "Unknown error from Calibre"
                setState(.error(msg))

            default:
                // Gracefully acknowledge anything we don't explicitly handle
                try await sendOK()
            }
        } catch {
            Logger.shared.log("CalibreClient: error handling opcode \(opInt) — \(error)", category: "Calibre", type: .error)
            setState(.error(error.localizedDescription))
        }
    }

    // MARK: - Specific Handlers

    private func handleGetInitializationInfo(_ payload: [String: Any]) async throws {
        // Calibre sends its own version info; we respond with our device info
        let response: [String: Any] = [
            "op": Opcode.ok.rawValue,
            "appName": deviceName,
            "cacheUsesLpaths": true,
            "canAcceptLibraryInfo": true,
            "canDeleteMultiple": false,
            "canReceiveBookMetadata": false,
            "canSendOkToSendbook": true,
            "canStreambooks": false,
            "canStreamMetadata": false,
            "ccVersionNumber": 128,
            "coverHeight": 160,
            "deviceKind": "iOS",
            "deviceUID": deviceUID,
            "extensionPathLengths": [:],
            "externalSdCard": false,
            "passwordHash": "",
            "maxBookContentPacketLen": 4096,
            "useUuidFileNames": false,
            "versionOK": true
        ]
        try await sendPacket(response)
    }

    private func handleSetCalibreDeviceInfo(_ payload: [String: Any]) async throws {
        if let lib = payload["libraryName"] as? String { libraryName = lib }
        try await sendOK()
        setState(.connected(libraryName: libraryName.isEmpty ? "Calibre" : libraryName))
        Logger.shared.log("CalibreClient: connected to library '\(libraryName)'", category: "Calibre")
    }

    private func handleGetDeviceInformation() async throws {
        let free = availableBytes()
        let response: [String: Any] = [
            "op": Opcode.ok.rawValue,
            "info": [
                "device_info": [
                    "device_name": deviceName,
                    "device_store_uuid": deviceUID,
                    "prefix": ""
                ],
                "device_store_uuid": deviceUID,
                "prefix": "",
                "total_space": free,
                "free_space": free
            ]
        ]
        try await sendPacket(response)
    }

    private func handleGetBookCount() async throws {
        // Report 0 books for simplicity — we don't push our local library to Calibre
        try await sendOK(extra: ["count": 0, "willStream": false, "willScan": false])
    }

    private func handleSendBooklists(_ payload: [String: Any]) async throws {
        // Calibre sends us an empty or partial book list — we acknowledge
        try await sendOK()
    }

    /// Receives a book file from Calibre.
    /// Packet: JSON metadata { "lpath", "length", "metadata": {...} } followed by `length` raw bytes.
    private func handleSendBook(_ payload: [String: Any]) async throws {
        guard connection != nil else { throw CalibreError.notConnected }

        let title = (payload["metadata"] as? [String: Any])?["title"] as? String ?? "Unknown"
        let fileLength = payload["length"] as? Int ?? 0
        let lpath = payload["lpath"] as? String ?? "book.epub"
        let ext = URL(fileURLWithPath: lpath).pathExtension.isEmpty ? "epub" : URL(fileURLWithPath: lpath).pathExtension

        Logger.shared.log("CalibreClient: receiving '\(title)' (\(fileLength) bytes)", category: "Calibre")
        setState(.receivingBook(title: title, progress: 0))

        // Send OK to signal readiness to receive file bytes
        try await sendOK()

        // Stream file to a temp file
        let safeTitle = title.components(separatedBy: .init(charactersIn: "/:*?\"<>|\\")).joined(separator: "_")
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("\(safeTitle).\(ext)")
        try? FileManager.default.removeItem(at: dest)

        var bytesReceived = 0
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        guard let fileHandle = try? FileHandle(forWritingTo: dest) else {
            throw CalibreError.writeError
        }

        // Read file bytes in chunks
        while bytesReceived < fileLength {
            let remaining = fileLength - bytesReceived
            let chunkSize = min(remaining, 65536)
            let chunk = try await receive(exactly: chunkSize)
            fileHandle.write(chunk)
            bytesReceived += chunk.count
            let progress = Double(bytesReceived) / Double(max(1, fileLength))
            setState(.receivingBook(title: title, progress: progress))
        }
        try fileHandle.close()

        Logger.shared.log("CalibreClient: received '\(title)' → \(dest.lastPathComponent)", category: "Calibre")

        // Notify the app to import the file
        let receivedURL = dest
        let callback = onBookReceived
        DispatchQueue.main.async { callback?(receivedURL) }

        // Acknowledge book complete
        try await sendOK()

        // Restore connected state
        setState(.connected(libraryName: libraryName))
    }

    // MARK: - Low-Level I/O

    private func receive(exactly count: Int) async throws -> Data {
        guard let connection else { throw CalibreError.notConnected }
        return try await withCheckedThrowingContinuation { cont in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                if let error {
                    cont.resume(throwing: error)
                } else if let data, data.count == count {
                    cont.resume(returning: data)
                } else {
                    cont.resume(throwing: CalibreError.badPacket)
                }
            }
        }
    }

    private func send(data: Data) async throws {
        guard let connection else { throw CalibreError.notConnected }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            })
        }
    }

    // MARK: - Utilities

    private func availableBytes() -> Int64 {
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
           let free = attrs[.systemFreeSize] as? Int64 {
            return free
        }
        return 1_073_741_824  // 1 GB fallback
    }

    private func setState(_ newState: CalibreSessionState) {
        state = newState
        let callback = onStateChange
        DispatchQueue.main.async { callback?(newState) }
    }
}

// MARK: - Errors

enum CalibreError: LocalizedError {
    case notConnected
    case badPacket
    case writeError

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to Calibre."
        case .badPacket:    return "Received a malformed packet from Calibre."
        case .writeError:   return "Failed to write received book to disk."
        }
    }
}
