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
class PeerManager: ObservableObject {
    static let shared = PeerManager()
    
    private var browser: NWBrowser?
    @Published private(set) var availablePeers: [PeerNode] = []
    @Published private(set) var isSearching = false
    
    private init() {}
    
    /// Starts scanning for Inksync peers on the local network.
    func startDiscovery() {
        guard !isSearching else { return }
        
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        
        // Broadcast type for Inksync nodes
        let browser = NWBrowser(for: .bonjour(type: "_inksync._tcp", domain: "local."), using: parameters)
        
        browser.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    self?.isSearching = true
                    Logger.shared.log("PeerManager: Started scanning for _inksync._tcp", category: "Network")
                case .failed(let error):
                    self?.isSearching = false
                    Logger.shared.log("PeerManager: Network discovery failed: \(error)", category: "Network", type: .error)
                case .cancelled:
                    self?.isSearching = false
                    Logger.shared.log("PeerManager: Network discovery cancelled", category: "Network")
                default:
                    break
                }
            }
        }
        
        browser.browseResultsChangedHandler = { [weak self] results, changes in
            self?.processBrowseResults(results)
        }
        
        browser.start(queue: .global(qos: .userInitiated))
        self.browser = browser
    }
    
    /// Stops the network discovery service.
    func stopDiscovery() {
        browser?.cancel()
        browser = nil
        DispatchQueue.main.async {
            self.isSearching = false
            self.availablePeers.removeAll()
        }
    }
    
    /// Maps generic NWBrowser.Result items into concrete PeerNode structures.
    private func processBrowseResults(_ results: Set<NWBrowser.Result>) {
        var discoveredPeers: [PeerNode] = []
        
        for result in results {
            if case .service(let name, _, _, _) = result.endpoint {
                resolveIP(from: result.endpoint) { [weak self] resolvedIP in
                    guard let self = self, let ip = resolvedIP else { return }
                    
                    let peer = PeerNode(
                        id: UUID(),
                        name: name,
                        ipAddress: ip,
                        port: 8080,
                        os: "Unknown",
                        deviceModel: "Unknown",
                        protocolType: "Inksync"
                    )
                    
                    DispatchQueue.main.async {
                        if !self.availablePeers.contains(peer) {
                            var newPeers = self.availablePeers
                            newPeers.append(peer)
                            self.availablePeers = newPeers.sorted(by: { $0.name < $1.name })
                        }
                    }
                }
            }
        }
    }
    
    // Natively resolves the endpoint to an IP without requiring unencrypted broadcast text.
    private func resolveIP(from endpoint: NWEndpoint, completion: @escaping (String?) -> Void) {
        let connection = NWConnection(to: endpoint, using: .tcp)
        var hasCompleted = false
        connection.stateUpdateHandler = { state in
            guard !hasCompleted else { return }
            switch state {
            case .ready:
                hasCompleted = true
                if let remote = connection.currentPath?.remoteEndpoint,
                   case .hostPort(let host, _) = remote {
                    var ipAddress: String? = nil
                    switch host {
                    case .ipv4(let ipv4):
                        // Convert IPv4Address to String
                        ipAddress = "\(ipv4)".components(separatedBy: "%").first
                    case .ipv6(let ipv6):
                        // Convert IPv6Address to String
                        ipAddress = "\(ipv6)".components(separatedBy: "%").first
                    default: break
                    }
                    // Fallback to name-based resolution if native mapping doesn't unwrap purely
                    let finalIP = ipAddress ?? "\(host)".components(separatedBy: "%").first
                    completion(finalIP)
                } else {
                    completion(nil)
                }
                connection.cancel()
            case .failed, .cancelled:
                if !hasCompleted {
                    hasCompleted = true
                    completion(nil)
                }
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
    }
    
    // MARK: - Device Reachability (Deep Module UX)
    func isReachable(deviceName: String) -> Bool {
        availablePeers.contains {
            $0.name.localizedCaseInsensitiveContains(deviceName)
        }
    }
}
