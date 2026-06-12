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
    /// Cache of resolved IPs keyed by endpoint string — prevents creating a new NWConnection
    /// on every mDNS TTL refresh for already-known peers.
    private var resolvedCache: [String: String] = [:]

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

                // If we already resolved this endpoint, update the peer list without
                // creating a new NWConnection (avoids connection proliferation on TTL refreshes).
                if let cachedIP = resolvedCache[endpointKey] {
                    let peer = PeerNode(id: UUID(), name: name, ipAddress: cachedIP, port: 8080,
                                       os: "Unknown", deviceModel: "Unknown", protocolType: "Inksync")
                    if !self.availablePeers.contains(peer) {
                        self.availablePeers.append(peer)
                        self.availablePeers.sort(by: { $0.name < $1.name })
                    }
                    continue
                }

                Task {
                    if let ip = await resolveIP(from: result.endpoint) {
                        self.resolvedCache[endpointKey] = ip

                        let peer = PeerNode(id: UUID(), name: name, ipAddress: ip, port: 8080,
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
    
    // Natively resolves the endpoint to an IP without requiring unencrypted broadcast text.
    private nonisolated func resolveIP(from endpoint: NWEndpoint) async -> String? {
        await withCheckedContinuation { continuation in
            let connection = NWConnection(to: endpoint, using: .tcp)
            let state = ResolveState(continuation: continuation, connection: connection)
            connection.stateUpdateHandler = { [weak state] connectionState in
                state?.handle(connectionState)
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
    }
    
    private final class ResolveState: @unchecked Sendable {
        private let lock = NSLock()
        private var hasCompleted = false
        private var continuation: CheckedContinuation<String?, Never>?
        private let connection: NWConnection
        
        init(continuation: CheckedContinuation<String?, Never>, connection: NWConnection) {
            self.continuation = continuation
            self.connection = connection
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
                if let remote = connection.currentPath?.remoteEndpoint,
                   case .hostPort(let host, _) = remote {
                    switch host {
                    case .ipv4(let ipv4):
                        ipAddress = "\(ipv4)".components(separatedBy: "%").first
                    case .ipv6(let ipv6):
                        ipAddress = "\(ipv6)".components(separatedBy: "%").first
                    default:
                        break
                    }
                    let finalIP = ipAddress ?? "\(host)".components(separatedBy: "%").first
                    cont?.resume(returning: finalIP)
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
