import Foundation
import AuthenticationServices
import CryptoKit

// MARK: - Internal Decodable Response Shapes

private struct DriveFileListResponse: Decodable {
    let files: [DriveFile]
    let nextPageToken: String?
}

private struct DriveFile: Decodable {
    let id: String
    let name: String
    let mimeType: String
    let size: String?
    let modifiedTime: String?
}

private struct DriveTokenResponse: Decodable {
    let access_token: String
    let refresh_token: String?
    let expires_in: Int?
}

// MARK: - GoogleDriveProvider

@MainActor
class GoogleDriveProvider: NSObject, CloudStorageProvider, ObservableObject {
    static let shared = GoogleDriveProvider()

    @Published var isConnected: Bool = false
    var providerName: String { "Google Drive" }

    // TODO: Replace with your values from https://console.cloud.google.com/
    // Required scopes: https://www.googleapis.com/auth/drive.readonly
    private let clientID    = "YOUR_GOOGLE_CLIENT_ID.apps.googleusercontent.com"
    private let redirectURI = "inksyncpro://oauth/googledrive"
    private let scopes      = "https://www.googleapis.com/auth/drive.readonly"

    private let keychainService = "com.antigravity.InksyncPro"

    private var accessToken: String? {
        get { keychainString(account: "googleAccessToken") }
        set { setKeychainString(newValue, account: "googleAccessToken") }
    }
    private var refreshToken: String? {
        get { keychainString(account: "googleRefreshToken") }
        set { setKeychainString(newValue, account: "googleRefreshToken") }
    }
    private var tokenExpiry: Date? {
        get {
            guard let s = keychainString(account: "googleTokenExpiry"), let ts = Double(s) else { return nil }
            return Date(timeIntervalSince1970: ts)
        }
        set { setKeychainString(newValue.map { String($0.timeIntervalSince1970) }, account: "googleTokenExpiry") }
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
        let verifier  = generateCodeVerifier()
        let challenge = codeChallenge(for: verifier)

        var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        comps.queryItems = [
            URLQueryItem(name: "client_id",             value: clientID),
            URLQueryItem(name: "redirect_uri",          value: redirectURI),
            URLQueryItem(name: "response_type",         value: "code"),
            URLQueryItem(name: "scope",                 value: scopes),
            URLQueryItem(name: "code_challenge",        value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type",           value: "offline"),
            URLQueryItem(name: "prompt",                value: "consent") // Force refresh_token to be issued
        ]

        guard let authURL = comps.url else { throw URLError(.badURL) }

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
                        domain: "GoogleDrive", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "No key window available for OAuth presentation"]
                    ))
                    return
                }
                let anchor = OAuthWindowAnchor(window: window)
                self._oauthAnchor = anchor    // strong retain prevents error 2
                self._oauthSession = session  // strong retain prevents early dealloc
                session.presentationContextProvider = anchor
                session.start()
            }
        }

        guard let comps2 = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              let code = comps2.queryItems?.first(where: { $0.name == "code" })?.value else {
            throw NSError(domain: "GoogleDrive", code: 3, userInfo: [NSLocalizedDescriptionKey: "Authorization code not found in callback URL"])
        }

        try await exchangeCode(code, verifier: verifier)
    }

    private func exchangeCode(_ code: String, verifier: String) async throws {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let params = [
            "code":          code,
            "grant_type":    "authorization_code",
            "client_id":     clientID,
            "redirect_uri":  redirectURI,
            "code_verifier": verifier
        ]
        request.httpBody = params.map { "\($0.key)=\($0.value)" }.joined(separator: "&").data(using: .utf8)

        let (data, _) = try await URLSession.shared.data(for: request)
        let tokenResponse = try JSONDecoder().decode(DriveTokenResponse.self, from: data)

        accessToken = tokenResponse.access_token
        refreshToken = tokenResponse.refresh_token
        if let expiresIn = tokenResponse.expires_in {
            tokenExpiry = Date().addingTimeInterval(TimeInterval(expiresIn))
        }
        self.isConnected = true
    }

    private func refreshAccessTokenIfNeeded() async throws {
        guard let expiry = tokenExpiry, expiry < Date().addingTimeInterval(60) else { return }
        guard let rToken = refreshToken else {
            throw NSError(domain: "GoogleDrive", code: 401, userInfo: [NSLocalizedDescriptionKey: "No refresh token — please reconnect your Google Drive account"])
        }

        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let params = ["grant_type": "refresh_token", "refresh_token": rToken, "client_id": clientID]
        request.httpBody = params.map { "\($0.key)=\($0.value)" }.joined(separator: "&").data(using: .utf8)

        let (data, _) = try await URLSession.shared.data(for: request)
        let tokenResponse = try JSONDecoder().decode(DriveTokenResponse.self, from: data)
        accessToken = tokenResponse.access_token
        if let expiresIn = tokenResponse.expires_in {
            tokenExpiry = Date().addingTimeInterval(TimeInterval(expiresIn))
        }
    }

    // MARK: - Sign Out

    func signOut() {
        accessToken = nil
        refreshToken = nil
        tokenExpiry = nil
        self.isConnected = false
    }

    // MARK: - Directory Listing

    func listDirectory(folderID: String?) async throws -> [CloudFile] {
        try await refreshAccessTokenIfNeeded()
        guard let token = accessToken else {
            throw NSError(domain: "GoogleDrive", code: 401, userInfo: [NSLocalizedDescriptionKey: "Not authenticated"])
        }

        let parent = folderID ?? "root"
        var comps = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        comps.queryItems = [
            URLQueryItem(name: "q",         value: "'\(parent)' in parents and trashed = false"),
            URLQueryItem(name: "fields",    value: "files(id,name,mimeType,size,modifiedTime)"),
            URLQueryItem(name: "pageSize",  value: "200")
        ]

        var request = URLRequest(url: comps.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, _) = try await URLSession.shared.data(for: request)
        let parsed = try JSONDecoder().decode(DriveFileListResponse.self, from: data)

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        return parsed.files.map { file in
            let isDir = file.mimeType == "application/vnd.google-apps.folder"
            return CloudFile(
                id: file.id,
                name: file.name,
                isDirectory: isDir,
                size: Int64(file.size ?? "0") ?? 0,
                modifiedDate: file.modifiedTime.flatMap { iso.date(from: $0) } ?? Date(),
                downloadURL: nil
            )
        }
    }

    // MARK: - Streaming Download URL
    // Google Drive does not issue temporary public links like Dropbox.
    // Instead, byte-range requests must include the live Authorization header.
    // We return the authenticated media URL; HTTPRangeZipExtractor must receive
    // the "Bearer <token>" header to pass alongside each Range request.

    func getDownloadURL(fileID: String) async throws -> URL {
        try await refreshAccessTokenIfNeeded()
        var comps = URLComponents(string: "https://www.googleapis.com/drive/v3/files/\(fileID)")!
        comps.queryItems = [URLQueryItem(name: "alt", value: "media")]
        guard let url = comps.url else { throw URLError(.badURL) }
        return url
    }

    /// Returns the current bearer token for use by HTTPRangeZipExtractor's auth header.
    func currentAuthHeader() async throws -> String {
        try await refreshAccessTokenIfNeeded()
        guard let token = accessToken else {
            throw NSError(domain: "GoogleDrive", code: 401, userInfo: [NSLocalizedDescriptionKey: "Not authenticated"])
        }
        return "Bearer \(token)"
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
