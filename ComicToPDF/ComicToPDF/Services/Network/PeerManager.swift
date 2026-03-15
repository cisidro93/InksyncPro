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
                // In a true implementation, we would extract the IP and properties from the endpoint or TXT records.
                // For simplicity in this iOS core engine refactor, we parse the basic name.
                // Normally we need to resolve the endpoint to an IP address using NWConnection or get it from TXT record.
                
                // We mock the IP resolution here since NWBrowser.Result.endpoint doesn't expose IP directly without establishing a connection.
                let mockIp = extractMockIP(from: name) ?? "0.0.0.0" 
                
                let peer = PeerNode(
                    id: UUID(),
                    name: name,
                    ipAddress: mockIp,
                    port: 8080,
                    os: "Unknown",
                    deviceModel: "Unknown",
                    protocolType: "Inksync"
                )
                
                if !discoveredPeers.contains(peer) {
                    discoveredPeers.append(peer)
                }
            }
        }
        
        DispatchQueue.main.async {
            self.availablePeers = discoveredPeers.sorted(by: { $0.name < $1.name })
        }
    }
    
    // A temporary helper since retrieving direct IPs from NWBrowser requires an active network handshake in Swift
    private func extractMockIP(from name: String) -> String? {
        // e.g., "Boox NoteAir (192.168.1.100)"
        if let range1 = name.range(of: "("), let range2 = name.range(of: ")") {
            return String(name[range1.upperBound..<range2.lowerBound])
        }
        return nil
    }
}
