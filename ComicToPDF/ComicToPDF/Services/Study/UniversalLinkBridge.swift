import Foundation

// MARK: - Deep Link Target Destination Model

/// Represents a parsed deep-link navigation destination in InkSync Pro.
public struct DeepLinkDestination: Sendable, Equatable {
    public let documentID: UUID
    public let pageIndex: Int
    public let anchorBlockHash: String?
    
    public init(documentID: UUID, pageIndex: Int, anchorBlockHash: String? = nil) {
        self.documentID = documentID
        self.pageIndex = pageIndex
        self.anchorBlockHash = anchorBlockHash
    }
}

// MARK: - Universal Deep Link Bridge

/// Bidirectional universal URI bridge handling `inksync://open` deep-links,
/// enabling seamless cross-application jumping from Obsidian, Bear, and Notion.
public final class UniversalLinkBridge: Sendable {
    
    public static let shared = UniversalLinkBridge()
    public static let customScheme = "inksync"
    
    public init() {}
    
    // MARK: - URI Generation
    
    /// Generates a universal URI for a specific document, page index, and semantic block anchor.
    public func generateUniversalLink(
        documentID: UUID,
        pageIndex: Int,
        anchorBlockHash: String? = nil
    ) -> URL {
        var components = URLComponents()
        components.scheme = Self.customScheme
        components.host = "open"
        
        var queryItems = [
            URLQueryItem(name: "doc", value: documentID.uuidString),
            URLQueryItem(name: "page", value: "\(pageIndex)")
        ]
        
        if let anchor = anchorBlockHash, !anchor.isEmpty {
            queryItems.append(URLQueryItem(name: "anchor", value: anchor))
        }
        
        components.queryItems = queryItems
        return components.url ?? URL(string: "inksync://open?doc=\(documentID.uuidString)&page=\(pageIndex)")!
    }
    
    // MARK: - URI Parsing & Dispatch
    
    /// Parses an incoming URL to determine if it is a valid InkSync Pro deep-link.
    public func parse(url: URL) -> DeepLinkDestination? {
        guard let scheme = url.scheme?.lowercased(),
              scheme == Self.customScheme || scheme == "inksyncpro",
              let host = url.host?.lowercased(),
              host == "open" || host == "reader" else {
            return nil
        }
        
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else {
            return nil
        }
        
        guard let docString = queryItems.first(where: { $0.name == "doc" || $0.name == "id" })?.value,
              let docUUID = UUID(uuidString: docString) else {
            return nil
        }
        
        let pageIndexStr = queryItems.first(where: { $0.name == "page" || $0.name == "p" })?.value ?? "0"
        let pageIndex = Int(pageIndexStr) ?? 0
        let anchor = queryItems.first(where: { $0.name == "anchor" || $0.name == "hash" })?.value
        
        return DeepLinkDestination(
            documentID: docUUID,
            pageIndex: max(0, pageIndex),
            anchorBlockHash: anchor
        )
    }
    
    /// Dispatches deep-link navigation across the application.
    @MainActor
    public func handleDeepLink(_ destination: DeepLinkDestination) {
        Logger.shared.log("UniversalLinkBridge: Navigating to Doc \(destination.documentID) Page \(destination.pageIndex)", category: "Router")
        
        NotificationCenter.default.post(
            name: .readerJumpToDeepLink,
            object: nil,
            userInfo: [
                "documentID": destination.documentID,
                "pageIndex": destination.pageIndex,
                "anchor": destination.anchorBlockHash as Any
            ]
        )
    }
}

public extension Notification.Name {
    static let readerJumpToDeepLink = Notification.Name("com.inksyncpro.readerJumpToDeepLink")
}
