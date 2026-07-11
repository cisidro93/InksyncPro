import Foundation
import Network
import Combine

/// Represents an active Inksync/LocalSend peer discovered on the local network.
struct PeerNode: Identifiable, Equatable {
    let id: UUID
    let name: String
    let ipAddress: String
    let port: Int
    let os: String
    let deviceModel: String
    // Determine the type: Inksync App vs Generic LocalSend
    let protocolType: String 
    
    // Conformance to Equatable
    static func == (lhs: PeerNode, rhs: PeerNode) -> Bool {
        return lhs.ipAddress == rhs.ipAddress && lhs.port == rhs.port
    }
}

/// Service Discovery Manager for Inksync Pro.
/// Scans the local network via mDNS (Bonjour) for `_inksync._tcp` services to facilitate seamless peer-to-peer 
/// LocalSend connections without manual IP entry.
@MainActor
class PeerManager: ObservableObject {
    static let shared = PeerManager()

    private var browser: NWBrowser?
    @Published private(set) var availablePeers: [PeerNode] = []
    @Published private(set) var isSearching = false
    /// Cache of resolved IP and port tuple keyed by endpoint string — prevents creating a new NWConnection
    /// on every mDNS TTL refresh for already-known peers.
    private var resolvedCache: [String: (ip: String, port: Int)] = [:]

    private init() {}
    
    /// Starts scanning for Inksync peers on the local network.
    func startDiscovery() {
        guard !isSearching else { return }
        
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        
        // Broadcast type for Inksync nodes
        let browser = NWBrowser(for: .bonjour(type: "_inksync._tcp", domain: "local."), using: parameters)
        
        browser.stateUpdateHandler = { state in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                switch state {
                case .ready:
                    self.isSearching = true
                    Logger.shared.log("PeerManager: Started scanning for _inksync._tcp", category: "Network")
                case .failed(let error):
                    self.isSearching = false
                    Logger.shared.log("PeerManager: Network discovery failed: \(error)", category: "Network", type: .error)
                case .cancelled:
                    self.isSearching = false
                    Logger.shared.log("PeerManager: Network discovery cancelled", category: "Network")
                default:
                    break
                }
            }
        }
        
        browser.browseResultsChangedHandler = { results, changes in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.processBrowseResults(results)
            }
        }
        
        browser.start(queue: .global(qos: .userInitiated))
        self.browser = browser
    }
    
    /// Stops the network discovery service.
    func stopDiscovery() {
        browser?.cancel()
        browser = nil
        resolvedCache.removeAll()
        self.isSearching = false
        self.availablePeers.removeAll()
    }
    
    /// Maps generic NWBrowser.Result items into concrete PeerNode structures.
    private func processBrowseResults(_ results: Set<NWBrowser.Result>) {
        for result in results {
            if case .service(let name, _, _, _) = result.endpoint {
                let endpointKey = "\(result.endpoint)"
 
                if let cached = resolvedCache[endpointKey] {
                    let peer = PeerNode(id: UUID(), name: name, ipAddress: cached.ip, port: cached.port,
                                       os: "Unknown", deviceModel: "Unknown", protocolType: "Inksync")
                    if !self.availablePeers.contains(peer) {
                        self.availablePeers.append(peer)
                        self.availablePeers.sort(by: { $0.name < $1.name })
                    }
                    continue
                }

                Task {
                    if let resolved = await resolveIP(from: result.endpoint) {
                        self.resolvedCache[endpointKey] = resolved

                        let peer = PeerNode(id: UUID(), name: name, ipAddress: resolved.ip, port: resolved.port,
                                           os: "Unknown", deviceModel: "Unknown", protocolType: "Inksync")
                        if !self.availablePeers.contains(peer) {
                            self.availablePeers.append(peer)
                            self.availablePeers.sort(by: { $0.name < $1.name })
                        }
                    }
                }
            }
        }
    }
    
    // Natively resolves the endpoint to an IP and port with a 2.0-second connection timeout.
    private nonisolated func resolveIP(from endpoint: NWEndpoint) async -> (ip: String, port: Int)? {
        await withCheckedContinuation { continuation in
            let connection = NWConnection(to: endpoint, using: .tcp)
            let state = ResolveState(continuation: continuation, connection: connection)
            
            connection.stateUpdateHandler = { [weak state] connectionState in
                state?.handle(connectionState)
            }
            
            connection.start(queue: .global(qos: .userInitiated))
            
            // 2.0s connection timeout guard to prevent unreachable nodes from stalling discovery
            DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) { [weak state] in
                state?.timeout()
            }
        }
    }
    
    private final class ResolveState: @unchecked Sendable {
        private let lock = NSLock()
        private var hasCompleted = false
        private var continuation: CheckedContinuation<(ip: String, port: Int)?, Never>?
        private let connection: NWConnection
        
        init(continuation: CheckedContinuation<(ip: String, port: Int)?, Never>, connection: NWConnection) {
            self.continuation = continuation
            self.connection = connection
        }
        
        func timeout() {
            lock.lock()
            guard !hasCompleted else {
                lock.unlock()
                return
            }
            hasCompleted = true
            let cont = self.continuation
            self.continuation = nil
            lock.unlock()
            
            cont?.resume(returning: nil)
            connection.cancel()
            Logger.shared.log("PeerManager: Resolve IP/Port timed out after 2s", category: "Network", type: .warning)
        }
        
        func handle(_ state: NWConnection.State) {
            lock.lock()
            guard !hasCompleted else {
                lock.unlock()
                return
            }
            
            switch state {
            case .ready:
                hasCompleted = true
                let cont = self.continuation
                self.continuation = nil
                lock.unlock()
                
                var ipAddress: String? = nil
                var portNumber = 8080
                if let remote = connection.currentPath?.remoteEndpoint,
                   case .hostPort(let host, let port) = remote {
                    switch host {
                    case .ipv4(let ipv4):
                        ipAddress = "\(ipv4)".components(separatedBy: "%").first
                    case .ipv6(let ipv6):
                        ipAddress = "\(ipv6)".components(separatedBy: "%").first
                    default:
                        break
                    }
                    let finalIP = ipAddress ?? "\(host)".components(separatedBy: "%").first
                    portNumber = Int(port.rawValue)
                    
                    if let finalIP = finalIP {
                        cont?.resume(returning: (ip: finalIP, port: portNumber))
                    } else {
                        cont?.resume(returning: nil)
                    }
                } else {
                    cont?.resume(returning: nil)
                }
                connection.cancel()
                
            case .failed, .cancelled:
                hasCompleted = true
                let cont = self.continuation
                self.continuation = nil
                lock.unlock()
                cont?.resume(returning: nil)
                connection.cancel()
                
            default:
                lock.unlock()
            }
        }
    }
    
    // MARK: - Device Reachability (Deep Module UX)
    func isReachable(deviceName: String) -> Bool {
        availablePeers.contains {
            $0.name.localizedCaseInsensitiveContains(deviceName)
        }
    }
}

extension PeerManager {
    /// Attempts to authenticate with a peer's server using the provided PIN.
    /// Returns the session token cookie string if successful, or throws an error.
    func authenticate(ipAddress: String, port: Int, pin: String) async throws -> String? {
        let host = ipAddress.contains(":") ? "[\(ipAddress)]" : ipAddress
        guard let loginURL = URL(string: "http://\(host):\(port)/login") else {
            throw NSError(domain: "InksyncPeer", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid Peer URL"])
        }
        var request = URLRequest(url: loginURL)
        request.httpMethod = "POST"
        request.httpBody = "pin=\(pin)".data(using: .utf8)
        request.timeoutInterval = 10.0
        
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "InksyncPeer", code: 500, userInfo: [NSLocalizedDescriptionKey: "Invalid server response"])
        }
        
        if httpResponse.statusCode == 401 || httpResponse.statusCode == 400 {
            throw NSError(domain: "InksyncPeer", code: 401, userInfo: [NSLocalizedDescriptionKey: "Incorrect PIN"])
        }
        
        if let setCookieHeader = httpResponse.value(forHTTPHeaderField: "Set-Cookie") {
            let parts = setCookieHeader.components(separatedBy: ";")
            for part in parts {
                let trimmed = part.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("session=") {
                    return trimmed
                }
            }
        }
        return nil
    }
}

