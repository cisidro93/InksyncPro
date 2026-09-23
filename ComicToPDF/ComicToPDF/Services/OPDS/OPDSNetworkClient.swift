import Foundation
import UIKit

// MARK: - OPDS Network Client

/// Actor-isolated, high-efficiency network client for OPDS catalogs and direct book downloads.
public actor OPDSNetworkClient {
    public static let shared = OPDSNetworkClient()

    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        config.httpAdditionalHeaders = [
            "User-Agent": "InkSyncPro/1.0 (iOS; iPadOS) OPDS-Client",
            "Accept": "application/atom+xml,application/xml,application/json,application/opds+json,*/*"
        ]
        self.session = URLSession(configuration: config)
    }

    /// Fetches and parses an OPDS feed from the specified URL, applying server authentication if required.
    public func fetchFeed(from url: URL, server: OPDSServer) async throws -> OPDSFeed {
        var request = URLRequest(url: url)
        applyAuth(to: &request, server: server)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OPDSNetworkError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw OPDSNetworkError.unauthorized
            }
            throw OPDSNetworkError.httpError(httpResponse.statusCode)
        }

        return try NativeOPDSParser.parse(data: data, baseURL: url)
    }

    /// Downloads a publication file (EPUB, PDF, CBZ) directly into the InksyncVault/Inbox directory.
    public func downloadPublication(
        entry: OPDSEntry,
        link: OPDSLink,
        server: OPDSServer,
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        guard let downloadURL = link.resolvedURL(relativeTo: server.url) else {
            throw OPDSNetworkError.invalidDownloadURL
        }

        var request = URLRequest(url: downloadURL)
        applyAuth(to: &request, server: server)

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let inboxDir = appSupport.appendingPathComponent("InksyncVault/Inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inboxDir, withIntermediateDirectories: true)

        let (tempLocalURL, response) = try await session.download(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 500
            throw OPDSNetworkError.httpError(code)
        }

        // Determine destination filename
        let ext = link.formatBadge.lowercased()
        let rawTitle = entry.title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: " -")
        let cleanTitle = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let filename = "\(cleanTitle).\(ext)"
        let destinationURL = inboxDir.appendingPathComponent(filename)

        try? FileManager.default.removeItem(at: destinationURL)
        try FileManager.default.moveItem(at: tempLocalURL, to: destinationURL)

        Logger.shared.log("OPDS: Downloaded publication '\(filename)' to InksyncVault/Inbox", category: "OPDS", type: .success)

        // Hand over to SharedImportCoordinator on MainActor for direct library registration and auto-open
        Task { @MainActor in
            _ = await SharedImportCoordinator.shared.handleDirectFileOpen(url: destinationURL, autoOpen: true)
        }

        return destinationURL
    }

    private func applyAuth(to request: inout URLRequest, server: OPDSServer) {
        if let user = server.username, let pass = server.password, !user.isEmpty {
            let authString = "\(user):\(pass)"
            if let authData = authString.data(using: .utf8) {
                let base64 = authData.base64EncodedString()
                request.setValue("Basic \(base64)", forHTTPHeaderField: "Authorization")
            }
        }
    }
}

public enum OPDSNetworkError: LocalizedError, Sendable {
    case invalidResponse
    case unauthorized
    case httpError(Int)
    case invalidDownloadURL

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Received invalid network response from OPDS catalog."
        case .unauthorized: return "Authentication required. Please check your username and password for this server."
        case .httpError(let code): return "OPDS server returned HTTP error code \(code)."
        case .invalidDownloadURL: return "The acquisition URL for this book could not be resolved."
        }
    }
}
