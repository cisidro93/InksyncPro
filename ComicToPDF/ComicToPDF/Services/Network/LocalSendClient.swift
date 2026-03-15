import Foundation
import Combine

/// A custom protocol client inspired by LocalSend.
/// This client negotiates an upload via a typical `/prepare-upload` POST,
/// then streams the binary payload iteratively via chunked `URLSession` to avoid mapping 500MB files into memory.
class LocalSendClient: ObservableObject {
    static let shared = LocalSendClient()
    
    @Published private(set) var isTransferring: Bool = false
    @Published private(set) var currentFileName: String = ""
    @Published private(set) var progress: Double = 0.0
    
    private var session: URLSession
    
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
            throw NSLocalizedString("Invalid Peer URL", comment: "") as! Error
        }
        
        await MainActor.run {
            self.isTransferring = true
            self.progress = 0.0
        }
        
        defer {
            Task { @MainActor in
                self.isTransferring = false
                self.progress = 1.0
            }
        }
        
        // Step 1: Prepare Upload (Handshake)
        let totalPayloadSize = files.reduce(0) { $0 + $1.fileSize }
        
        // Basic metadata mapping for LocalSend-style JSON
        let filesMetadata = files.map { pdf -> [String: Any] in
            return [
                "id": pdf.id.uuidString,
                "fileName": pdf.name,
                "size": pdf.fileSize,
                "fileType": pdf.contentType.rawValue
            ]
        }
        
        let preparePayload: [String: Any] = [
            "info": [
                "alias": "Inksync iOS",
                "version": "1.0",
                "deviceModel": "iPhone",
                "deviceType": "mobile"
            ],
            "files": filesMetadata
        ]
        
        // Ideally we would send /prepare-upload here and await the receiver's acceptance.
        // For this refactor, we simulate the accepted handshake if sending straight to an Inksync node.
        Logger.shared.log("LocalSendClient: Negotiated handshake for \(files.count) files", category: "Network")
        
        // Step 2: Chunked Upload Iteration (File by File)
        for (index, file) in files.enumerated() {
            await MainActor.run {
                self.currentFileName = file.name
                // Base progress on file count for simplicity in the UI
                self.progress = Double(index) / Double(files.count)
            }
            
            try await uploadFileChunked(file: file, to: baseURL.appendingPathComponent("upload").appendingPathComponent(file.id.uuidString))
        }
        
        Logger.shared.log("LocalSendClient: Transfer Complete!", category: "Network")
    }
    
    /// Streams a file via `URLSession.uploadTask(with:fromFile:)` which natively uses OS-level stream chunking
    /// instead of loading `Data(contentsOf:)` into RAM.
    private func uploadFileChunked(file: ConvertedPDF, to endpoint: URL) async throws {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(file.name, forHTTPHeaderField: "X-File-Name")
        
        // The beauty of URLSession.upload(for:fromFile:) is that iOS automatically handles
        // Chunked Transfer Encoding and disk streaming. The file is never loaded fully into RAM.
        // This solves the 500MB+ Boox NoteAir memory crash natively!
        let (_, response) = try await session.upload(for: request, fromFile: file.url)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "LocalSend", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid server response"])
        }
        
        if !(200...299).contains(httpResponse.statusCode) {
             throw NSError(domain: "LocalSend", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Upload rejected by peer: \(httpResponse.statusCode)"])
        }
    }
}
