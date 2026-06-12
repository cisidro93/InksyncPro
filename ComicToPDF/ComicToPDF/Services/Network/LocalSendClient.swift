import Foundation
import Combine

/// A custom protocol client inspired by LocalSend.
/// Streams files directly to peer Inksync instances via chunked URLSession uploads,
/// keeping even large comic archives out of RAM.
@MainActor
class LocalSendClient: ObservableObject {
    static let shared = LocalSendClient()

    @Published private(set) var isTransferring: Bool = false
    @Published private(set) var currentFileName: String = ""
    @Published private(set) var progress: Double = 0.0

    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30.0
        config.timeoutIntervalForResource = 3600.0 // Allow up to an hour for huge transfers
        self.session = URLSession(configuration: config)
    }

    /// Starts a chunked upload sequence to a discovered peer.
    func transferFiles(_ files: [ConvertedPDF], to peer: PeerNode) async throws {
        guard !files.isEmpty else { return }
        guard let baseURL = URL(string: "http://\(peer.ipAddress):\(peer.port)") else {
            throw NSError(domain: "LocalSend", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid Peer URL"])
        }

        isTransferring = true
        progress = 0.0

        defer {
            isTransferring = false
            progress = 1.0
        }

        Logger.shared.log("LocalSendClient: Starting transfer of \(files.count) files to \(peer.name)", category: "Network")

        // Temp staging directory for linked-library files that need sandbox copies.
        // URLSession runs on OS threads with no inherited security scope — files on external
        // drives always produce EPERM unless first copied to the sandbox.
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("InksyncTransfer-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        for (index, file) in files.enumerated() {
            currentFileName = file.name
            progress = Double(index) / Double(files.count)

            let uploadURL: URL
            if case .linked(let bm) = file.sourceMode {
                // Linked file lives on external drive — stage a sandbox copy first.
                let sandboxCopy = tmpDir.appendingPathComponent(file.url.lastPathComponent)
                do {
                    try await BookmarkResolver.shared.withAccess(bm) { driveURL in
                        if FileManager.default.fileExists(atPath: sandboxCopy.path) {
                            try? FileManager.default.removeItem(at: sandboxCopy)
                        }
                        try FileManager.default.copyItem(at: driveURL, to: sandboxCopy)
                    }
                    uploadURL = sandboxCopy
                } catch {
                    Logger.shared.log("LocalSendClient: Could not stage linked file \(file.name) — skipping: \(error.localizedDescription)", category: "Network", type: .warning)
                    continue
                }
            } else {
                uploadURL = file.url
            }

            // Use percent-encoded filename in the URL path so the server correctly names
            // the file. Previously file.id.uuidString was used, producing unnamed/extensionless files.
            let encodedName = file.url.lastPathComponent
                .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file.url.lastPathComponent
            let endpoint = baseURL.appendingPathComponent("upload").appendingPathComponent(encodedName)

            try await uploadFileChunked(fileName: file.url.lastPathComponent, from: uploadURL, to: endpoint)
        }

        Logger.shared.log("LocalSendClient: Transfer complete (\(files.count) files)", category: "Network")
    }

    /// Streams a file via `URLSession.upload(for:fromFile:)` — OS-level disk streaming
    /// ensures the file is never fully loaded into RAM. Safe for 500 MB+ archives.
    private func uploadFileChunked(fileName: String, from localURL: URL, to endpoint: URL) async throws {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(fileName, forHTTPHeaderField: "X-File-Name")

        let (_, response) = try await session.upload(for: request, fromFile: localURL)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "LocalSend", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid server response"])
        }

        if !(200...299).contains(httpResponse.statusCode) {
            throw NSError(domain: "LocalSend", code: httpResponse.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "Upload rejected: HTTP \(httpResponse.statusCode)"])
        }
    }
}
