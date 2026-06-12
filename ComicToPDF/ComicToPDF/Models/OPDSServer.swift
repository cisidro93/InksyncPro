import Foundation
import SwiftData
import SwiftUI

// MARK: - Server Type

/// Describes the flavour of OPDS server so the client and UI can adapt per-server.
enum OPDSServerType: String, Codable, CaseIterable, Identifiable {
    case kavita  = "Kavita"
    case komga   = "Komga"
    case calibre = "Calibre"

    var id: String { rawValue }

    /// SF Symbol used in the server list and type picker.
    var sfSymbol: String {
        switch self {
        case .kavita:  return "books.vertical.fill"
        case .komga:   return "server.rack"
        case .calibre: return "book.closed.fill"
        }
    }

    /// Brand-adjacent tint color for each server type.
    var tint: Color {
        switch self {
        case .kavita:  return Color(hex: "#1ED0A0")   // Kavita green
        case .komga:   return Color(hex: "#4C7EF4")   // Komga blue
        case .calibre: return Color(hex: "#E8823B")   // Calibre orange
        }
    }

    /// Short marketing description shown in AddOPDSServerSheet type picker.
    var description: String {
        switch self {
        case .kavita:
            return "Comic & manga server. Uses an API key — no password needed."
        case .komga:
            return "Comic & manga server. Uses your Komga username and password."
        case .calibre:
            return "E-book server built on Calibre. Supports download of any format."
        }
    }

    /// Supports OPDS Page Streaming Extension (PSE) — read without downloading.
    var supportsStreaming: Bool {
        switch self {
        case .kavita, .komga: return true
        case .calibre:        return false
        }
    }

    /// Label shown in the credentials section of AddOPDSServerSheet.
    var credentialLabel: String {
        switch self {
        case .kavita:  return "API KEY"
        case .komga:   return "PASSWORD"
        case .calibre: return "PASSWORD"
        }
    }

    /// Whether a username field should be shown in AddOPDSServerSheet.
    var requiresUsername: Bool {
        switch self {
        case .kavita:  return false
        case .komga, .calibre: return true
        }
    }

    /// Example URL shown as a hint in AddOPDSServerSheet.
    var exampleURL: String {
        switch self {
        case .kavita:  return "http://192.168.1.100:5000"
        case .komga:   return "http://192.168.1.100:8080"
        case .calibre: return "http://192.168.1.100:8080"
        }
    }

    /// Assembles the OPDS root feed URL from a base URL and optional API key (Kavita only).
    func rootFeedURL(base: URL, apiKey: String) -> URL {
        switch self {
        case .kavita:
            // JWT Bearer auth — token sent in header, NOT in the URL path.
            // The old `/api/opds/{apiKey}` pattern is deprecated (exposes key in logs).
            return base.appendingPathComponent("api/opds")
        case .komga:
            return base.appendingPathComponent("opds/v1.2/catalog")
        case .calibre:
            return base.appendingPathComponent("opds")
        }
    }
}

// MARK: - SwiftData Model

/// Persists the connection details for a single OPDS media server.
/// Credentials are stored in the Keychain (via `OPDSKeychainStore`), never here.
@Model
final class SDOPDSServer: Identifiable, Equatable {

    var id: UUID = UUID()

    /// Display name chosen by the user (e.g. "Home Kavita", "Calibre Library").
    var name: String

    /// Raw string backing for the `serverType` enum — SwiftData can't persist enums directly.
    var rawServerType: String

    /// The base URL string (scheme + host + port, no trailing slash).
    var baseURLString: String

    /// `Date` the server was added, used for default sort order.
    var createdAt: Date

    // MARK: Derived properties

    var serverType: OPDSServerType {
        get { OPDSServerType(rawValue: rawServerType) ?? .komga }
        set { rawServerType = newValue.rawValue }
    }

    var baseURL: URL? { URL(string: baseURLString) }

    /// Constructs the correct OPDS root feed URL using the server type's path convention.
    /// Kavita needs the API key (stored in Keychain as `credential.password`).
    func opdsRootURL(credential: OPDSCredential?) -> URL? {
        guard let base = baseURL else { return nil }
        let apiKey = (serverType == .kavita) ? (credential?.password ?? "") : ""
        return serverType.rootFeedURL(base: base, apiKey: apiKey)
    }

    // MARK: Init

    init(
        id: UUID = UUID(),
        name: String,
        serverType: OPDSServerType,
        baseURLString: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.rawServerType = serverType.rawValue
        self.baseURLString = baseURLString
        self.createdAt = createdAt
    }

    // MARK: Equatable

    static func == (lhs: SDOPDSServer, rhs: SDOPDSServer) -> Bool {
        lhs.id == rhs.id
    }
}
