import SwiftUI

// MARK: - Calibre Wireless View

/// Main UI for Calibre Wireless Device pairing.
/// Shows auto-discovered Calibre instances, connection state,
/// active session info, and received books log.
struct CalibreWirelessView: View {
    @State private var discovery = CalibreWirelessDiscovery.shared
    @State private var client = CalibreWirelessClient()
    @State private var sessionState: CalibreSessionState = .idle
    @State private var receivedBooks: [ReceivedBook] = []
    @State private var isAutoScanning = true

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject var manager: ConversionManager

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {

                // — Discovery header card ——————————————————————————
                discoveryCard

                // — Active session or prompt ———————————————————————
                sessionCard

                // — Received books log ————————————————————————————
                if !receivedBooks.isEmpty {
                    receivedBooksCard
                }

                // — Instructions ——————————————————————————————————
                instructionsCard
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
        .navigationTitle("Calibre Wireless")
        .navigationBarTitleDisplayMode(.large)
        .background(Color.inkBackground.ignoresSafeArea())
        .onAppear {
            if isAutoScanning { discovery.startScanning() }
        }
        .onDisappear {
            discovery.stopScanning()
        }
    }

    // MARK: - Discovery Card

    private var discoveryCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("LAN Discovery", systemImage: "wifi")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.inkAmber)
                Spacer()
                if discovery.isScanning {
                    HStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.8)
                            .tint(Color.inkAmber)
                        Text("Scanning…")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.inkTextSecondary)
                    }
                } else {
                    Button("Scan") {
                        discovery.startScanning()
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.inkAmber)
                }
            }

            if discovery.discovered.isEmpty {
                Text("No Calibre instances found yet. Make sure Calibre is open with Wireless Device sharing enabled.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.inkTextSecondary)
                    .multilineTextAlignment(.leading)
            } else {
                VStack(spacing: 8) {
                    ForEach(discovery.discovered) { host in
                        calibreHostRow(host)
                    }
                }
            }
        }
        .padding(16)
        .background(Color.inkSurface.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.inkAmber.opacity(0.2), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func calibreHostRow(_ host: CalibreHost) -> some View {
        let isConnected: Bool = {
            if case .connected = sessionState { return true }
            return false
        }()

        HStack(spacing: 12) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 18))
                .foregroundStyle(Color.inkAmber)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(host.hostname)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.inkTextPrimary)
                Text("Port \(host.devicePort) · Content: \(host.contentPort)")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.inkTextSecondary)
            }

            Spacer()

            if isConnected {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.inkGreen)
                        .frame(width: 7, height: 7)
                    Text("Connected")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.inkGreen)
                }
            } else if case .connecting = sessionState {
                ProgressView().scaleEffect(0.8).tint(Color.inkAmber)
            } else {
                Button("Connect") {
                    connectTo(host)
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Color.inkAmber)
                .clipShape(Capsule())
            }
        }
        .padding(12)
        .background(Color.inkSurface.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Session Card

    @ViewBuilder
    private var sessionCard: some View {
        switch sessionState {
        case .idle, .disconnected:
            EmptyView()

        case .connecting:
            sessionStatusBanner(
                icon: "wifi",
                title: "Connecting…",
                subtitle: "Establishing connection to Calibre",
                color: Color.inkAmber,
                showSpinner: true
            )

        case .handshaking:
            sessionStatusBanner(
                icon: "hand.wave.fill",
                title: "Handshaking",
                subtitle: "Exchanging device information with Calibre",
                color: Color.inkAmber,
                showSpinner: true
            )

        case .connected(let libraryName):
            connectedCard(libraryName: libraryName)

        case .receivingBook(let title, let progress):
            receivingBookCard(title: title, progress: progress)

        case .error(let message):
            sessionStatusBanner(
                icon: "exclamationmark.triangle.fill",
                title: "Connection Error",
                subtitle: message,
                color: Color.inkRed,
                showSpinner: false
            )
        }
    }

    private func sessionStatusBanner(icon: String, title: String, subtitle: String, color: Color, showSpinner: Bool) -> some View {
        HStack(spacing: 14) {
            if showSpinner {
                ProgressView().tint(color)
            } else {
                Image(systemName: icon).foregroundStyle(color).font(.system(size: 18))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.inkTextPrimary)
                Text(subtitle).font(.system(size: 12)).foregroundStyle(Color.inkTextSecondary)
            }
            Spacer()
        }
        .padding(14)
        .background(color.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(color.opacity(0.25), lineWidth: 1))
    }

    private func connectedCard(libraryName: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                HStack(spacing: 8) {
                    Circle().fill(Color.inkGreen).frame(width: 8, height: 8)
                    Text("Connected")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.inkGreen)
                }
                Spacer()
                Button("Disconnect") {
                    Task { await client.disconnect() }
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.inkRed)
            }

            Text("Library: \(libraryName)")
                .font(.system(size: 13))
                .foregroundStyle(Color.inkTextSecondary)

            Text("InksyncPro is now visible in Calibre. Select books and use \"Send to device\" to push them here.")
                .font(.system(size: 12))
                .foregroundStyle(Color.inkTextSecondary)
                .multilineTextAlignment(.leading)
        }
        .padding(16)
        .background(Color.inkGreen.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.inkGreen.opacity(0.25), lineWidth: 1))
    }

    private func receivingBookCard(title: String, progress: Double) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(Color.inkAmber)
                    .font(.system(size: 16))
                Text("Receiving Book")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.inkTextPrimary)
            }
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(Color.inkTextSecondary)
                .lineLimit(2)
            ProgressView(value: progress)
                .tint(Color.inkAmber)
            Text("\(Int(progress * 100))%")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.inkTextSecondary)
        }
        .padding(16)
        .background(Color.inkAmber.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.inkAmber.opacity(0.25), lineWidth: 1))
    }

    // MARK: - Received Books Log

    private var receivedBooksCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Received This Session", systemImage: "tray.and.arrow.down.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.inkTextPrimary)

            ForEach(receivedBooks) { book in
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.inkGreen)
                        .font(.system(size: 14))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(book.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.inkTextPrimary)
                            .lineLimit(1)
                        Text(book.ext.uppercased() + " · Added to library")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.inkTextSecondary)
                    }
                    Spacer()
                }
            }
        }
        .padding(16)
        .background(Color.inkSurface.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.inkBorderVisible, lineWidth: 1))
    }

    // MARK: - Instructions Card

    private var instructionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("How to Connect", systemImage: "questionmark.circle")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.inkTextPrimary)

            VStack(alignment: .leading, spacing: 8) {
                instructionStep("1", text: "Open Calibre on your Mac or PC")
                instructionStep("2", text: "Go to Preferences → Sharing → Share books over WiFi")
                instructionStep("3", text: "Enable \"Allow connections from devices on local network\"")
                instructionStep("4", text: "InksyncPro will appear above once discovered")
                instructionStep("5", text: "Tap Connect, then in Calibre select books → Send to device")
            }
        }
        .padding(16)
        .background(Color.inkSurface.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func instructionStep(_ num: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(num)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Color.inkAmber)
                .clipShape(Circle())
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(Color.inkTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Actions

    private func connectTo(_ host: CalibreHost) {
        Task {
            await client.connect(to: host,
                onStateChange: { newState in
                    withAnimation { sessionState = newState }
                },
                onBookReceived: { fileURL in
                    importBook(from: fileURL)
                }
            )
        }
    }

    private func importBook(from url: URL) {
        let title = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension

        // Import into the app's conversion pipeline
        Task {
            await manager.processImportedFiles([url])
        }

        withAnimation {
            receivedBooks.insert(ReceivedBook(title: title, ext: ext), at: 0)
        }

        Logger.shared.log("CalibreWireless: imported '\(title).\(ext)'", category: "Calibre")
    }
}

// MARK: - Supporting Types

private struct ReceivedBook: Identifiable {
    let id = UUID()
    let title: String
    let ext: String
}
