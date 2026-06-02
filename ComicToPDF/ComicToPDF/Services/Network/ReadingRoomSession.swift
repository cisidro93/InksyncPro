import Foundation
import SwiftUI
import MultipeerConnectivity
import Combine
import UIKit

// MARK: - Swift 6 Sendable conformances for ObjC MC types
// MCPeerID is immutable after creation; MCNearbyServiceBrowser is an ObjC object
// safe to pass across concurrency domains when used with the care shown below.
extension MCPeerID: @retroactive Sendable {}
extension MCNearbyServiceBrowser: @retroactive Sendable {}

// MARK: - Data Packets

/// Every message sent between peers over the MCSession.
enum ReadingRoomPacket: Codable {
    case pageUpdate(pageIndex: Int, totalPages: Int)
    case reaction(emoji: String)
    case heartbeat(displayName: String)

    // MARK: Manual Codable (enum with associated values)
    private enum CodingKeys: String, CodingKey { case type, pageIndex, totalPages, emoji, displayName }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pageUpdate(let page, let total):
            try c.encode("pageUpdate", forKey: .type)
            try c.encode(page, forKey: .pageIndex)
            try c.encode(total, forKey: .totalPages)
        case .reaction(let emoji):
            try c.encode("reaction", forKey: .type)
            try c.encode(emoji, forKey: .emoji)
        case .heartbeat(let name):
            try c.encode("heartbeat", forKey: .type)
            try c.encode(name, forKey: .displayName)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "pageUpdate":
            let page  = try c.decode(Int.self, forKey: .pageIndex)
            let total = try c.decode(Int.self, forKey: .totalPages)
            self = .pageUpdate(pageIndex: page, totalPages: total)
        case "reaction":
            let emoji = try c.decode(String.self, forKey: .emoji)
            self = .reaction(emoji: emoji)
        default: // "heartbeat" or unknown
            let name = try c.decodeIfPresent(String.self, forKey: .displayName) ?? "Reader"
            self = .heartbeat(displayName: name)
        }
    }
}

// MARK: - Peer Model

struct RoomPeer: Identifiable, Equatable {
    let id: MCPeerID          // stable MC identity
    var displayName: String
    var currentPage: Int      // 0-based
    var totalPages: Int
    var avatarColor: Color
    var lastSeen: Date

    /// 0.0–1.0 progress fraction for scrubber positioning.
    var progressFraction: Double {
        guard totalPages > 1 else { return 0 }
        return Double(currentPage) / Double(totalPages - 1)
    }

    /// String initials for avatar bubble (up to 2 chars).
    var initials: String {
        let parts = displayName.components(separatedBy: " ")
        let first = parts.first?.prefix(1) ?? ""
        let last  = parts.count > 1 ? parts.last?.prefix(1) ?? "" : ""
        return (first + last).uppercased()
    }
}

// MARK: - Reaction Model

struct RoomReaction: Identifiable {
    let id = UUID()
    let emoji: String
    let senderName: String
    let timestamp: Date
}

// MARK: - Colour palette for avatar bubbles (deterministic per peer display name)

private let kAvatarPalette: [Color] = [
    Color(hex: "#FF6B6B"), Color(hex: "#4ECDC4"), Color(hex: "#45B7D1"),
    Color(hex: "#96CEB4"), Color(hex: "#FFEAA7"), Color(hex: "#DDA0DD"),
    Color(hex: "#98D8C8"), Color(hex: "#F7DC6F"), Color(hex: "#BB8FCE"),
    Color(hex: "#85C1E9")
]

private func avatarColor(for peerID: MCPeerID) -> Color {
    let hash = abs(peerID.displayName.hashValue)
    return kAvatarPalette[hash % kAvatarPalette.count]
}

// MARK: - ReadingRoomSession

/// Lightweight MultipeerConnectivity session for co-reading.
///
/// Design goals:
///  - Zero server infrastructure (offline-first, same Wi-Fi / BT)
///  - Zero UI friction: auto-discover + auto-connect anyone reading the same bookID
///  - Manual room code fallback for friends with different file UUIDs
///  - One-time purchase compatible (no subscription APIs)
@MainActor
final class ReadingRoomSession: NSObject, ObservableObject {

    // MARK: Public state (observed by the overlay and chrome)

    @Published var peers: [RoomPeer] = []
    @Published var reactions: [RoomReaction] = []
    @Published var isHosting: Bool = false
    @Published var isConnected: Bool = false   // true if ≥1 peer connected
    @Published var roomCode: String = ""        // 6-char human-readable code

    // MARK: Internal MC objects

    private var myPeerID: MCPeerID
    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?

    /// The service type is derived from bookID — limits auto-discovery to same book.
    /// MC service types must be ≤15 chars, lowercase, alphanumeric + hyphens.
    private var serviceType: String = "ink-room"

    private var heartbeatTask: Task<Void, Never>?
    private var bookID: String = ""

    // MARK: Init

    override init() {
        let name = UIDevice.current.name
            .components(separatedBy: " ")
            .first ?? "Reader"
        myPeerID = MCPeerID(displayName: name)
        super.init()
    }

    // MARK: - Room Code

    /// Derives a stable 6-char alphanumeric room code from bookID.
    /// Used as the MC serviceType suffix so only same-book peers auto-connect.
    /// Can also be shared verbally for manual join when UUIDs differ.
    private static func roomCode(from bookID: String) -> String {
        let hash = abs(bookID.hashValue)
        let chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789" // 32 unambiguous chars
        var result = ""
        var h = hash
        for _ in 0..<6 {
            result.append(chars[chars.index(chars.startIndex, offsetBy: h % chars.count)])
            h /= chars.count
        }
        return result
    }

    /// MC service type from a room code (must be ≤15 chars, no uppercase).
    private static func serviceType(for code: String) -> String {
        "ink-" + code.lowercased()  // "ink-" + 6 chars = 10 chars ✓
    }

    // MARK: - Start / Stop

    func startHosting(bookID: String) {
        self.bookID = bookID
        let code = Self.roomCode(from: bookID)
        self.roomCode = code
        let svcType = Self.serviceType(for: code)
        self.serviceType = svcType

        tearDownMC()
        let sess = MCSession(peer: myPeerID, securityIdentity: nil, encryptionPreference: .required)
        sess.delegate = self
        self.session = sess

        let adv = MCNearbyServiceAdvertiser(peer: myPeerID, discoveryInfo: nil, serviceType: svcType)
        adv.delegate = self
        adv.startAdvertisingPeer()
        self.advertiser = adv

        let brw = MCNearbyServiceBrowser(peer: myPeerID, serviceType: svcType)
        brw.delegate = self
        brw.startBrowsingForPeers()
        self.browser = brw

        isHosting = true
        startHeartbeat()
        Logger.shared.log("ReadingRoom: hosting started. code=\(code), svc=\(svcType)", category: "Room", type: .info)
    }

    /// Join using a manual 6-char room code (for friends with different file UUIDs).
    func joinWithCode(_ code: String) {
        let cleanCode = code.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        self.roomCode = cleanCode
        let svcType = Self.serviceType(for: cleanCode)
        self.serviceType = svcType

        tearDownMC()
        let sess = MCSession(peer: myPeerID, securityIdentity: nil, encryptionPreference: .required)
        sess.delegate = self
        self.session = sess

        let brw = MCNearbyServiceBrowser(peer: myPeerID, serviceType: svcType)
        brw.delegate = self
        brw.startBrowsingForPeers()
        self.browser = brw

        let adv = MCNearbyServiceAdvertiser(peer: myPeerID, discoveryInfo: nil, serviceType: svcType)
        adv.delegate = self
        adv.startAdvertisingPeer()
        self.advertiser = adv

        isHosting = true
        startHeartbeat()
        Logger.shared.log("ReadingRoom: joined via code \(cleanCode)", category: "Room", type: .info)
    }

    func stop() {
        tearDownMC()
        isHosting = false
        isConnected = false
        peers.removeAll()
        reactions.removeAll()
        heartbeatTask?.cancel()
        Logger.shared.log("ReadingRoom: stopped", category: "Room", type: .info)
    }

    // MARK: - Broadcast

    func broadcastPage(_ pageIndex: Int, totalPages: Int) {
        send(.pageUpdate(pageIndex: pageIndex, totalPages: totalPages))
    }

    func sendReaction(_ emoji: String) {
        send(.reaction(emoji: emoji))
        // Also show locally
        let local = RoomReaction(emoji: emoji, senderName: "You", timestamp: Date())
        withAnimation { reactions.append(local) }
        scheduleReactionCleanup()
    }

    // MARK: - Private helpers

    private func send(_ packet: ReadingRoomPacket) {
        guard let session = session, !session.connectedPeers.isEmpty else { return }
        guard let data = try? JSONEncoder().encode(packet) else { return }
        try? session.send(data, toPeers: session.connectedPeers, with: .reliable)
    }

    private func tearDownMC() {
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        session?.disconnect()
        advertiser = nil
        browser = nil
        session = nil
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000) // 10s
                send(.heartbeat(displayName: myPeerID.displayName))
                pruneStalepeers()
            }
        }
    }

    private func pruneStalepeers() {
        let cutoff = Date().addingTimeInterval(-30) // 30s timeout
        let before = peers.count
        peers.removeAll { $0.lastSeen < cutoff }
        if peers.count != before {
            isConnected = !peers.isEmpty
        }
    }

    private func scheduleReactionCleanup() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000) // reactions visible for 4s
            withAnimation(.easeOut(duration: 0.3)) {
                reactions.removeAll { Date().timeIntervalSince($0.timestamp) > 3.8 }
            }
        }
    }

    private func handlePacket(_ packet: ReadingRoomPacket, from peerID: MCPeerID) {
        switch packet {
        case .pageUpdate(let page, let total):
            if let idx = peers.firstIndex(where: { $0.id == peerID }) {
                peers[idx].currentPage = page
                peers[idx].totalPages  = total
                peers[idx].lastSeen    = Date()
            } else {
                let newPeer = RoomPeer(
                    id: peerID,
                    displayName: peerID.displayName,
                    currentPage: page,
                    totalPages: total,
                    avatarColor: avatarColor(for: peerID),
                    lastSeen: Date()
                )
                peers.append(newPeer)
                isConnected = true
            }

        case .reaction(let emoji):
            let senderName = peers.first(where: { $0.id == peerID })?.displayName ?? peerID.displayName
            let r = RoomReaction(emoji: emoji, senderName: senderName, timestamp: Date())
            withAnimation { reactions.append(r) }
            scheduleReactionCleanup()
            HapticEngine.light()

        case .heartbeat(let name):
            if let idx = peers.firstIndex(where: { $0.id == peerID }) {
                peers[idx].displayName = name
                peers[idx].lastSeen    = Date()
            }
        }
    }
}

// MARK: - MCSessionDelegate

extension ReadingRoomSession: MCSessionDelegate {

    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        // Extract Sendable-safe primitives before hopping to the main actor
        let name = peerID.displayName
        Task { @MainActor in
            switch state {
            case .connected:
                Logger.shared.log("ReadingRoom: peer connected — \(name)", category: "Room", type: .success)
                if !peers.contains(where: { $0.id == peerID }) {
                    let newPeer = RoomPeer(
                        id: peerID,
                        displayName: name,
                        currentPage: 0,
                        totalPages: 0,
                        avatarColor: avatarColor(for: peerID),
                        lastSeen: Date()
                    )
                    self.peers.append(newPeer)
                }
                self.isConnected = true
                HapticEngine.success()

            case .notConnected:
                Logger.shared.log("ReadingRoom: peer disconnected — \(name)", category: "Room", type: .warning)
                self.peers.removeAll { $0.id == peerID }
                self.isConnected = !self.peers.isEmpty

            case .connecting:
                break
            @unknown default:
                break
            }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let packet = try? JSONDecoder().decode(ReadingRoomPacket.self, from: data) else { return }
        Task { @MainActor in self.handlePacket(packet, from: peerID) }
    }

    // Unused required protocol stubs
    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

// MARK: - MCNearbyServiceAdvertiserDelegate

extension ReadingRoomSession: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        // invitationHandler is @escaping but not @Sendable — mark nonisolated(unsafe) so
        // we can carry it into the @MainActor Task without a data-race warning.
        // MC invitation callbacks are safe to call from any thread.
        nonisolated(unsafe) let handler = invitationHandler
        Task { @MainActor in
            handler(true, self.session)
        }
    }
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        Logger.shared.log("ReadingRoom advertiser error: \(error.localizedDescription)", category: "Room", type: .error)
    }
}

// MARK: - MCNearbyServiceBrowserDelegate

extension ReadingRoomSession: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        // browser is @unchecked Sendable (ObjC object); capture it explicitly so the
        // compiler doesn't treat it as a task-isolated value crossing an actor boundary.
        let b = browser
        let name = peerID.displayName
        Task { @MainActor in
            guard let session = self.session else { return }
            b.invitePeer(peerID, to: session, withContext: nil, timeout: 30)
            Logger.shared.log("ReadingRoom: found peer \(name), inviting…", category: "Room", type: .info)
        }
    }
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Logger.shared.log("ReadingRoom: lost peer \(peerID.displayName)", category: "Room", type: .warning)
    }
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        Logger.shared.log("ReadingRoom browser error: \(error.localizedDescription)", category: "Room", type: .error)
    }
}
