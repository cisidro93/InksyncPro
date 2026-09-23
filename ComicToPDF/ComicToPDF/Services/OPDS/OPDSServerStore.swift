import Foundation
import Combine
import SwiftUI

// MARK: - OPDS Server Store

/// Manages the user's saved OPDS servers with persistence and presets.
@MainActor
public final class OPDSServerStore: ObservableObject {
    public static let shared = OPDSServerStore()

    @Published public private(set) var servers: [OPDSServer] = []

    private let storageKey = "inksyncpro_opds_servers_v1"

    private init() {
        loadServers()
    }

    public func addServer(_ server: OPDSServer) {
        servers.append(server)
        saveServers()
    }

    public func updateServer(_ server: OPDSServer) {
        if let idx = servers.firstIndex(where: { $0.id == server.id }) {
            servers[idx] = server
            saveServers()
        }
    }

    public func deleteServer(at offsets: IndexSet) {
        servers.remove(atOffsets: offsets)
        saveServers()
    }

    public func deleteServer(id: UUID) {
        servers.removeAll(where: { $0.id == id })
        saveServers()
    }

    private func loadServers() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([OPDSServer].self, from: data),
           !decoded.isEmpty {
            self.servers = decoded
        } else {
            // Seed presets on initial launch
            self.servers = OPDSServer.standardPresets
            saveServers()
        }
    }

    private func saveServers() {
        if let encoded = try? JSONEncoder().encode(servers) {
            UserDefaults.standard.set(encoded, forKey: storageKey)
        }
    }
}
