import Foundation
import AuthenticationServices
import CryptoKit

// MARK: - Internal Decodable Response Shapes

private struct DropboxListFolderResponse: Decodable {
    let entries: [DropboxEntry]
    let cursor: String
    let has_more: Bool
}

private struct DropboxEntry: Decodable {
    let tag: String
    let id: String?
    let name: String
    let size: Int64?
    let server_modified: String?
    let path_lower: String?

    enum CodingKeys: String, CodingKey {
        case tag = ".tag"
        case id, name, size, server_modified, path_lower
    }
}

private struct DropboxTemporaryLinkResponse: Decodable {
    let link: String
}

private struct DropboxTokenResponse: Decodable {
    let access_token: String
    let refresh_token: String?
    let expires_in: Int?
}

// MARK: - DropboxProvider

class DropboxProvider: NSObject, CloudStorageProvider, ObservableObject {
    static let shared = DropboxProvider()

    @Published var isConnected: Bool = false
    var providerName: String { "Dropbox" }

    // TODO: Replace with your values from https://www.dropbox.com/developers/apps
    private let clientID     = "v7dgt5q4j19mbha"
    private let redirectURI  = "inksyncpro://oauth/dropbox"

    private let keychainService = "com.antigravity.InksyncPro"

    private var accessToken: String? {
        get { keychainString(account: "dropboxAccessToken") }
        set { setKeychainString(newValue, account: "dropboxAccessToken") }
    }
    private var refreshToken: String? {
        get { keychainString(account: "dropboxRefreshToken") }
        set { setKeychainString(newValue, account: "dropboxRefreshToken") }
    }
    /// Expiry stored as unix timestamp string
    private var tokenExpiry: Date? {
        get {
            guard let s = keychainString(account: "dropboxTokenExpiry"), let ts = Double(s) else { return nil }
            return Date(timeIntervalSince1970: ts)
        }
        set {
            setKeychainString(newValue.map { String($0.timeIntervalSince1970) }, account: "dropboxTokenExpiry")
        }
    }

    /// Retained for the duration of the OAuth session.
    /// ASWebAuthenticationSession holds presentationContextProvider as WEAK —
    /// if we don't retain the anchor it gets deallocated immediately → error 2.
    private var _oauthAnchor: OAuthWindowAnchor?
    private var _oauthSession: ASWebAuthenticationSession?

    private override init() {
        super.init()
        self.isConnected = (accessToken != nil)
    }

    // MARK: - OAuth 2.0 PKCE Authentication

    func authenticate() async throws {
        // 1. Generate PKCE pair
        let verifier = generateCodeVerifier()
        let challenge = codeChallenge(for: verifier)

        // 2. Build auth URL
        var comps = URLComponents(string: "https://www.dropbox.com/oauth2/authorize")!
        comps.queryItems = [
            URLQueryItem(name: "client_id",             value: clientID),
            URLQueryItem(name: "redirect_uri",          value: redirectURI),
            URLQueryItem(name: "response_type",         value: "code"),
            URLQueryItem(name: "code_challenge",        value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "token_access_type",     value: "offline") // Get refresh token
        ]

        guard let authURL = comps.url else { throw URLError(.badURL) }

        // 3. Launch in-app browser via ASWebAuthenticationSession.
        //    IMPORTANT: retain both the session AND the anchor as instance properties.
        //    ASWebAuthenticationSession holds presentationContextProvider as WEAK;
        //    local variables go out of scope immediately, causing error 2.
        let callbackURL: URL = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: URLError(.cancelled))
                    return
                }
                let session = ASWebAuthenticationSession(
                    url: authURL,
                    callbackURLScheme: "inksyncpro"
                ) { [weak self] callbackURL, error in
                    self?._oauthSession = nil
                    self?._oauthAnchor = nil
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else if let callbackURL = callbackURL {
                        continuation.resume(returning: callbackURL)
                    } else {
                        continuation.resume(throwing: URLError(.cancelled))
                    }
                }
                // Grab the key window safely, falling back to the first available window
                let activeScene = UIApplication.shared.connectedScenes
                    .compactMap({ $0 as? UIWindowScene })
                    .first(where: { $0.activationState == .foregroundActive })
                    
                let keyWindow = activeScene?.windows.first(where: { $0.isKeyWindow })
                    ?? activeScene?.windows.first
                    ?? UIApplication.shared.connectedScenes
                        .compactMap({ $0 as? UIWindowScene })
                        .flatMap({ $0.windows })
                        .first
                guard let window = keyWindow else {
                    continuation.resume(throwing: NSError(
                        domain: "Dropbox", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "No key window available for OAuth presentation"]
                    ))
                    return
                }
                let anchor = OAuthWindowAnchor(window: window)
                self._oauthAnchor = anchor    // strong retain
                self._oauthSession = session  // strong retain
                session.presentationContextProvider = anchor
                session.start()
            }
        }

        // 4. Extract code from callback
        guard let comps2 = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              let code = comps2.queryItems?.first(where: { $0.name == "code" })?.value else {
            throw NSError(domain: "Dropbox", code: 3, userInfo: [NSLocalizedDescriptionKey: "Authorization code not found in callback URL"])
        }

        // 5. Exchange code for tokens
        try await exchangeCode(code, verifier: verifier)
    }

    private func exchangeCode(_ code: String, verifier: String) async throws {
        var request = URLRequest(url: URL(string: "https://api.dropboxapi.com/oauth2/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let params = [
            "code":           code,
            "grant_type":     "authorization_code",
            "client_id":      clientID,
            "redirect_uri":   redirectURI,
            "code_verifier":  verifier
        ]
        request.httpBody = params.map { "\($0.key)=\($0.value)" }.joined(separator: "&").data(using: .utf8)

        let (data, _) = try await URLSession.shared.data(for: request)
        let tokenResponse = try JSONDecoder().decode(DropboxTokenResponse.self, from: data)

        accessToken = tokenResponse.access_token
        refreshToken = tokenResponse.refresh_token
        if let expiresIn = tokenResponse.expires_in {
            tokenExpiry = Date().addingTimeInterval(TimeInterval(expiresIn))
        }
        await MainActor.run { self.isConnected = true }
    }

    private func refreshAccessTokenIfNeeded() async throws {
        guard let expiry = tokenExpiry, expiry < Date().addingTimeInterval(60) else { return }
        guard let rToken = refreshToken else {
            await MainActor.run { self.isConnected = false }
            throw NSError(domain: "Dropbox", code: 401, userInfo: [NSLocalizedDescriptionKey: "No refresh token — please reconnect"])
        }

        var request = URLRequest(url: URL(string: "https://api.dropboxapi.com/oauth2/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let params = ["grant_type": "refresh_token", "refresh_token": rToken, "client_id": clientID]
        request.httpBody = params.map { "\($0.key)=\($0.value)" }.joined(separator: "&").data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode >= 400 {
            await MainActor.run { self.isConnected = false }
            self.accessToken = nil
            self.refreshToken = nil
            throw NSError(domain: "Dropbox", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Refresh token rejected by Dropbox. Please reconnect."])
        }
        let tokenResponse = try JSONDecoder().decode(DropboxTokenResponse.self, from: data)
        accessToken = tokenResponse.access_token
        if let expiresIn = tokenResponse.expires_in {
            tokenExpiry = Date().addingTimeInterval(TimeInterval(expiresIn))
        }
        await MainActor.run { self.isConnected = true }
    }

    // MARK: - Sign Out

    // Exposes current token for use by CloudCoverExtractor (read-only).
    var currentAccessToken: String? { accessToken }

    // Authenticated URLSession for cloud cover byte-range requests.
    var authenticatedSession: URLSession {
        guard let token = accessToken else { return .shared }
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = ["Authorization": "Bearer \(token)"]
        return URLSession(configuration: config)
    }

    func signOut() {
        accessToken = nil
        refreshToken = nil
        tokenExpiry = nil
        DispatchQueue.main.async { self.isConnected = false }
    }

    // MARK: - Directory Listing

    func listDirectory(folderID: String?) async throws -> [CloudFile] {
        try await refreshAccessTokenIfNeeded()
        guard let token = accessToken else { throw NSError(domain: "Dropbox", code: 401, userInfo: [NSLocalizedDescriptionKey: "Not authenticated"]) }

        var request = URLRequest(url: URL(string: "https://api.dropboxapi.com/2/files/list_folder")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["path": folderID ?? "", "recursive": false])

        let (data, _) = try await URLSession.shared.data(for: request)
        let parsed = try JSONDecoder().decode(DropboxListFolderResponse.self, from: data)

        let iso = ISO8601DateFormatter()
        return parsed.entries.compactMap { entry -> CloudFile? in
            let isDir = entry.tag == "folder"
            return CloudFile(
                id: entry.path_lower ?? entry.name,
                name: entry.name,
                isDirectory: isDir,
                size: entry.size ?? 0,
                modifiedDate: entry.server_modified.flatMap { iso.date(from: $0) } ?? Date(),
                downloadURL: nil
            )
        }
    }

    // MARK: - Download URL (for Byte-Range Streaming)

    func getDownloadURL(fileID: String) async throws -> URL {
        try await refreshAccessTokenIfNeeded()
        guard let token = accessToken else { throw NSError(domain: "Dropbox", code: 401, userInfo: [NSLocalizedDescriptionKey: "Not authenticated"]) }

        var request = URLRequest(url: URL(string: "https://api.dropboxapi.com/2/files/get_temporary_link")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["path": fileID])

        let (data, response) = try await URLSession.shared.data(for: request)

        // Validate HTTP status before attempting JSON decode.
        // A deleted or moved file returns a 409 with a JSON error_summary, not a TemporaryLinkResponse.
        if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
            // Attempt to surface Dropbox's own error_summary if present
            let summary = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { $0["error_summary"] as? String } ?? "HTTP \(httpResponse.statusCode)"
            throw NSError(
                domain: "Dropbox",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Dropbox error: \(summary)"]
            )
        }

        let linkResponse = try JSONDecoder().decode(DropboxTemporaryLinkResponse.self, from: data)
        guard let url = URL(string: linkResponse.link) else {
            throw NSError(domain: "Dropbox", code: 5, userInfo: [NSLocalizedDescriptionKey: "Invalid temporary link returned from Dropbox"])
        }
        // Dropbox temporary links support byte-range requests directly — no auth header needed
        return url
    }

    // MARK: - Recursive Folder Enumeration

    /// Returns ALL files (not folders) inside a given Dropbox folder, recursively.
    /// Handles Dropbox cursor-based pagination automatically.
    /// Used by CloudFileBrowserView when the user selects an entire folder to add.
    func listAllFiles(inFolderID folderID: String, onProgress: ((Int) -> Void)? = nil) async throws -> [CloudFile] {
        try await refreshAccessTokenIfNeeded()
        guard let token = accessToken else {
            throw NSError(domain: "Dropbox", code: 401, userInfo: [NSLocalizedDescriptionKey: "Not authenticated"])
        }

        let supported: Set<String> = ["cbz", "cbr", "epub", "zip", "pdf", "cb7", "cbt"]
        var allFiles: [CloudFile] = []
        var cursor: String? = nil
        var hasMore = true

        // First page
        var request = URLRequest(url: URL(string: "https://api.dropboxapi.com/2/files/list_folder")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "path": folderID,
            "recursive": true,          // spider the entire subtree in one API call
            "include_deleted": false
        ])

        let (firstData, _) = try await URLSession.shared.data(for: request)
        let firstPage = try JSONDecoder().decode(DropboxListFolderResponse.self, from: firstData)
        cursor = firstPage.cursor
        hasMore = firstPage.has_more

        let iso = ISO8601DateFormatter()
        func mapEntry(_ entry: DropboxEntry) -> CloudFile? {
            guard entry.tag == "file",
                  let ext = (entry.name as NSString).pathExtension.lowercased() as String?,
                  supported.contains(ext) else { return nil }
            return CloudFile(
                id: entry.path_lower ?? entry.name,
                name: entry.name,
                isDirectory: false,
                size: entry.size ?? 0,
                modifiedDate: entry.server_modified.flatMap { iso.date(from: $0) } ?? Date(),
                downloadURL: nil
            )
        }

        allFiles.append(contentsOf: firstPage.entries.compactMap(mapEntry))
        onProgress?(allFiles.count)

        // Continue with cursor pagination
        while hasMore, let currentCursor = cursor {
            var contRequest = URLRequest(url: URL(string: "https://api.dropboxapi.com/2/files/list_folder/continue")!)
            contRequest.httpMethod = "POST"
            contRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            contRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            contRequest.httpBody = try JSONSerialization.data(withJSONObject: ["cursor": currentCursor])

            let (contData, _) = try await URLSession.shared.data(for: contRequest)
            let page = try JSONDecoder().decode(DropboxListFolderResponse.self, from: contData)
            allFiles.append(contentsOf: page.entries.compactMap(mapEntry))
            onProgress?(allFiles.count)
            cursor = page.cursor
            hasMore = page.has_more
        }

        Logger.shared.log(
            "DropboxProvider: recursive scan of \(folderID) → \(allFiles.count) supported file(s)",
            category: "Cloud"
        )
        return allFiles
    }


    // MARK: - Keychain Helpers

    private func keychainString(account: String) -> String? {
        guard let data = KeychainHelper.standard.read(service: keychainService, account: account) else { return nil }
        return String(data: data, encoding: .utf8)
    }
    private func setKeychainString(_ value: String?, account: String) {
        if let v = value {
            KeychainHelper.standard.save(Data(v.utf8), service: keychainService, account: account)
        } else {
            KeychainHelper.standard.delete(service: keychainService, account: account)
        }
    }

    // MARK: - PKCE Helpers

    private func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func codeChallenge(for verifier: String) -> String {
        let data = Data(verifier.utf8)
        let hash = SHA256.hash(data: data)
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
