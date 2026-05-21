import SwiftUI
import SwiftData

// MARK: - OPDS Servers List View

struct OPDSServersView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SDOPDSServer.createdAt) private var servers: [SDOPDSServer]

    @State private var showAddSheet = false
    @State private var onlineStatus: [UUID: Bool] = [:]
    @State private var selectedServer: SDOPDSServer?

    var body: some View {
        ZStack {
            Color.clear.ignoresSafeArea()

            if servers.isEmpty {
                emptyState
            } else {
                serverList
            }
        }
        .navigationTitle("Media Servers")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showAddSheet = true
                } label: {
                    Image(systemName: "plus")
                        .foregroundColor(Color.inkBlue)
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddOPDSServerSheet()
        }
        .task { await pingAllServers() }
    }

    // MARK: - Server List

    private var serverList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("MY SERVERS")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.inkTextSecondary)
                    .tracking(1.2)
                    .padding(.leading, 24)
                    .padding(.top, 16)
                    .padding(.bottom, 8)

                VStack(spacing: 10) {
                    ForEach(servers) { server in
                        NavigationLink(destination: OPDSBrowserView(server: server)) {
                            OPDSServerRow(
                                server: server,
                                isOnline: onlineStatus[server.id]
                            )
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                deleteServer(server)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 120)
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(Color.inkBlue.opacity(0.08))
                    .frame(width: 100, height: 100)

                Image(systemName: "server.rack")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.inkBlue, Color.inkViolet],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
            }

            VStack(spacing: 8) {
                Text("No Media Servers")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Color.inkTextPrimary)
                Text("Connect to Kavita, Komga, or Calibre to browse and stream your collection.")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.inkTextSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .padding(.horizontal, 40)
            }

            Button {
                showAddSheet = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Add Server")
                        .font(.system(size: 16, weight: .semibold))
                }
                .foregroundColor(.white)
                .frame(maxWidth: 220)
                .padding(.vertical, 14)
                .background(
                    LinearGradient(
                        colors: [Color.inkBlue, Color.inkViolet.opacity(0.85)],
                        startPoint: .leading, endPoint: .trailing
                    ),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
                .shadow(color: Color.inkBlue.opacity(0.4), radius: 12, y: 6)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Helpers

    private func deleteServer(_ server: SDOPDSServer) {
        OPDSKeychainStore.delete(for: server.id)
        modelContext.delete(server)
        try? modelContext.save()
        Logger.shared.log("OPDSServersView: deleted server '\(server.name)'", category: "OPDS")
    }

    private func pingAllServers() async {
        await withTaskGroup(of: (UUID, Bool).self) { group in
            for server in servers {
                group.addTask {
                    let alive = await pingServer(server)
                    return (server.id, alive)
                }
            }
            for await (id, alive) in group {
                onlineStatus[id] = alive
            }
        }
    }

    private func pingServer(_ server: SDOPDSServer) async -> Bool {
        guard let url = server.baseURL else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        req.timeoutInterval = 5
        return (try? await URLSession.shared.data(for: req)) != nil
    }
}

// MARK: - Server Row

struct OPDSServerRow: View {
    let server: SDOPDSServer
    let isOnline: Bool?

    var body: some View {
        HStack(spacing: 14) {
            // Type icon badge
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(server.serverType.tint.opacity(0.15))
                    .frame(width: 48, height: 48)
                Image(systemName: server.serverType.sfSymbol)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(server.serverType.tint)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(server.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.inkTextPrimary)

                Text(server.baseURLString)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.inkTextSecondary)
                    .lineLimit(1)

                HStack(spacing: 5) {
                    // Online indicator
                    Group {
                        if let online = isOnline {
                            Circle()
                                .fill(online ? Color.inkGreen : Color.inkTextSecondary)
                                .frame(width: 6, height: 6)
                                .shadow(color: online ? Color.inkGreen.opacity(0.6) : .clear, radius: 4)
                            Text(online ? "Online" : "Offline")
                                .font(.system(size: 11))
                                .foregroundStyle(online ? Color.inkGreen : Color.inkTextSecondary)
                        } else {
                            ProgressView()
                                .scaleEffect(0.6)
                            Text("Checking…")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.inkTextSecondary)
                        }
                    }

                    Text("·")
                        .foregroundStyle(Color.inkTextSecondary)

                    Text(server.serverType.rawValue)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(server.serverType.tint)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.inkTextSecondary.opacity(0.5))
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(Color.inkSurface.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.inkTextPrimary.opacity(0.07), lineWidth: 1)
        )
    }
}
