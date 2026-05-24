import Foundation
import Network

// MARK: - Calibre Host

/// A discovered Calibre desktop instance on the local network.
struct CalibreHost: Identifiable, Hashable, Sendable {
    let id: String           // hostname:devicePort
    let hostname: String
    let devicePort: UInt16   // TCP port for wireless device protocol (default 9090)
    let contentPort: UInt16  // HTTP port for the Calibre content server (default 8080)

    var displayName: String { hostname }

    /// Builds the TCP URL for the device protocol connection
    var deviceURL: NWEndpoint { .hostPort(host: NWEndpoint.Host(hostname), port: NWEndpoint.Port(rawValue: devicePort)!) }
}

// MARK: - Calibre Wireless Discovery

/// Discovers Calibre desktop instances on the LAN via two parallel mechanisms:
///
/// 1. **mDNS / Bonjour** — `NWBrowser` for `_calibrewireless._tcp`
/// 2. **UDP Broadcast** — Calibre responds to any datagram on ports
///    [54982, 48123, 39001, 44044, 59678] with:
///    `"calibre wireless device client (on hostname);contentPort,devicePort"`
///
/// Results are de-duplicated and published as `discovered: [CalibreHost]`.
@Observable
@MainActor
final class CalibreWirelessDiscovery {

    static let shared = CalibreWirelessDiscovery()

    // MARK: - Published State

    var discovered: [CalibreHost] = []
    var isScanning: Bool = false

    // MARK: - Private

    // mDNS
    private var browser: NWBrowser?

    // UDP broadcast
    private let broadcastPorts: [UInt16] = [54982, 48123, 39001, 44044, 59678]
    private var udpListeners: [NWListener] = []
    private var udpConnections: [NWConnection] = []

    nonisolated private let queue = DispatchQueue(label: "com.inksynpro.calibre.discovery", qos: .utility)

    // MARK: - Public API

    func startScanning() {
        guard !isScanning else { return }
        isScanning = true
        discovered = []
        startMDNS()
        startUDPBroadcast()
        Logger.shared.log("CalibreDiscovery: scanning started", category: "Calibre")
    }

    func stopScanning() {
        isScanning = false
        browser?.cancel()
        browser = nil
        udpConnections.forEach { $0.cancel() }
        udpConnections = []
        udpListeners.forEach { $0.cancel() }
        udpListeners = []
        Logger.shared.log("CalibreDiscovery: scanning stopped", category: "Calibre")
    }

    // MARK: - mDNS / Bonjour

    private func startMDNS() {
        let params = NWParameters.udp
        params.includePeerToPeer = true

        let browser = NWBrowser(for: .bonjour(type: "_calibrewireless._tcp", domain: "local"), using: params)
        self.browser = browser

        browser.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let error):
                Logger.shared.log("CalibreDiscovery: mDNS error — \(error)", category: "Calibre", type: .warning)
            default: break
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            for result in results {
                if case .service(let name, _, let domain, _) = result.endpoint {
                    Task { @MainActor [weak self] in
                        self?.resolveBonjour(name: name, domain: domain)
                    }
                }
            }
        }

        browser.start(queue: queue)
    }

    private func resolveBonjour(name: String, domain: String) {
        // Resolve service to get host + port using NWBrowser endpoint
        // Calibre's mDNS service name is typically the hostname.
        // We extract port 9090 as the default device port from the TXT record.
        let endpoint = NWEndpoint.service(name: name, type: "_calibrewireless._tcp", domain: domain, interface: nil)
        let connection = NWConnection(to: endpoint, using: .tcp)
        connection.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                if let inner = connection.currentPath?.remoteEndpoint,
                   case .hostPort(let host, let port) = inner {
                    let hostname = "\(host)"
                    let devicePort = port.rawValue
                    Task { @MainActor [weak self] in
                        self?.addHost(CalibreHost(
                            id: "\(hostname):\(devicePort)",
                            hostname: hostname,
                            devicePort: devicePort,
                            contentPort: 8080   // default; will be refined by UDP response
                        ))
                    }
                }
                connection.cancel()
            }
        }
        connection.start(queue: queue)
    }

    // MARK: - UDP Broadcast

    private func startUDPBroadcast() {
        // Send a UDP datagram to each Calibre broadcast port.
        // Calibre responds with its hostname, content-server port, and device port.
        for port in broadcastPorts {
            sendUDPProbe(port: port)
        }

        // Also listen for unsolicited responses on all broadcast ports.
        for port in broadcastPorts {
            listenUDP(on: port)
        }
    }

    private func sendUDPProbe(port: UInt16) {
        // Calibre expects any datagram as a "hi there" probe.
        // We use the broadcast address on the local subnet.
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true

        let conn = NWConnection(
            to: .hostPort(host: "255.255.255.255", port: NWEndpoint.Port(rawValue: port)!),
            using: params
        )
        udpConnections.append(conn)

        conn.stateUpdateHandler = { state in
            if case .ready = state {
                // Send a short probe payload (empty is fine for Calibre)
                let probe = "InksyncPro".data(using: .utf8)!
                conn.send(content: probe, completion: .contentProcessed { _ in })
            }
        }

        conn.receiveMessage { [weak self] data, _, _, _ in
            guard let data, let response = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                self?.parseBroadcastResponse(response)
            }
        }

        conn.start(queue: queue)
    }

    private func listenUDP(on port: UInt16) {
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true

        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        guard let listener = try? NWListener(using: params, on: nwPort) else { return }
        udpListeners.append(listener)

        let q = self.queue
        listener.newConnectionHandler = { [weak self] conn in
            conn.receiveMessage { data, _, _, _ in
                guard let data, let response = String(data: data, encoding: .utf8) else { return }
                Task { @MainActor [weak self] in
                    self?.parseBroadcastResponse(response)
                }
            }
            conn.start(queue: q)
        }

        listener.start(queue: queue)
    }

    // MARK: - Response Parsing

    /// Parses Calibre's UDP broadcast response:
    /// Format: `"calibre wireless device client (on hostname);contentPort,devicePort"`
    private func parseBroadcastResponse(_ response: String) {
        // e.g. "calibre wireless device client (on MyMac);8080,9090"
        Logger.shared.log("CalibreDiscovery: UDP response — \(response)", category: "Calibre")

        // Extract hostname from "(on <hostname>)"
        var hostname = "Calibre"
        if let onRange = response.range(of: #"\(on (.+?)\)"#, options: .regularExpression) {
            let match = String(response[onRange])
            // strip "(on " and ")"
            hostname = match
                .replacingOccurrences(of: "(on ", with: "")
                .replacingOccurrences(of: ")", with: "")
        }

        // Extract port numbers after ";"
        var contentPort: UInt16 = 8080
        var devicePort: UInt16 = 9090
        if let semiRange = response.range(of: ";") {
            let portPart = String(response[semiRange.upperBound...])
            let parts = portPart.components(separatedBy: ",")
            if parts.count >= 2 {
                contentPort = UInt16(parts[0].trimmingCharacters(in: .whitespaces)) ?? 8080
                devicePort  = UInt16(parts[1].trimmingCharacters(in: .whitespaces)) ?? 9090
            } else if parts.count == 1 {
                devicePort = UInt16(parts[0].trimmingCharacters(in: .whitespaces)) ?? 9090
            }
        }

        addHost(CalibreHost(
            id: "\(hostname):\(devicePort)",
            hostname: hostname,
            devicePort: devicePort,
            contentPort: contentPort
        ))
    }

    // MARK: - Helpers

    private func addHost(_ host: CalibreHost) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if !self.discovered.contains(where: { $0.id == host.id }) {
                self.discovered.append(host)
                Logger.shared.log("CalibreDiscovery: found \(host.hostname):\(host.devicePort)", category: "Calibre")
            }
        }
    }
}
