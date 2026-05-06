import SwiftUI

struct CloudConnectionSettingsView: View {
    @ObservedObject private var dropbox = DropboxProvider.shared
    @ObservedObject private var gdrive  = GoogleDriveProvider.shared
    @ObservedObject private var downloads = CloudDownloadManager.shared

    @State private var isConnectingDropbox = false
    @State private var isConnectingGoogle  = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            // MARK: - Banner
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label(
                        "Connect your cloud accounts to stream comics directly from Dropbox or Google Drive — no download required.",
                        systemImage: "cloud.fill"
                    )
                    .font(.footnote)
                    .foregroundColor(.secondary)

                    Label(
                        "Files are read on-demand using byte-range streaming. Your tokens are stored securely in the iOS Keychain and never shared.",
                        systemImage: "lock.shield.fill"
                    )
                    .font(.footnote)
                    .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }

            // MARK: - Providers
            Section(header: Text("Connected Accounts")) {
                // Dropbox Row
                providerRow(
                    name: "Dropbox",
                    icon: "shippingbox.fill",
                    iconColor: .blue,
                    isConnected: dropbox.isConnected,
                    isConnecting: isConnectingDropbox,
                    onConnect: connectDropbox,
                    onDisconnect: { dropbox.signOut() }
                )

                // Google Drive Row
                providerRow(
                    name: "Google Drive",
                    icon: "externaldrive.fill.badge.icloud",
                    iconColor: .green,
                    isConnected: gdrive.isConnected,
                    isConnecting: isConnectingGoogle,
                    onConnect: connectGoogle,
                    onDisconnect: { gdrive.signOut() }
                )
            }

            // MARK: - Active Downloads
            if !downloads.activeDownloads.isEmpty {
                Section(header: Text("Downloading to Device")) {
                    ForEach(Array(downloads.activeDownloads.keys), id: \.self) { fileID in
                        if let progress = downloads.activeDownloads[fileID] {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(fileID)
                                    .font(.caption)
                                    .lineLimit(1)
                                ProgressView(value: progress)
                                    .tint(.blue)
                                Text("\(Int(progress * 100))%")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }

            // MARK: - Error Banner
            if let error = errorMessage {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red)
                        Text(error).font(.callout).foregroundColor(.red)
                        Spacer()
                        Button("Dismiss") { errorMessage = nil }.font(.caption)
                    }
                }
            }

            // MARK: - How It Works
            Section(header: Text("How It Works")) {
                howItWorksRow(icon: "1.circle", text: "Tap Connect to sign in to your cloud account via the secure OAuth flow in Safari.")
                howItWorksRow(icon: "2.circle", text: "InksyncPro indexes your files without downloading them. Comics are streamed page-by-page on demand.")
                howItWorksRow(icon: "3.circle", text: "Tap \"Download to Device\" on any cloud comic in the Library to save it for offline reading.")
                howItWorksRow(icon: "4.circle", text: "Your login tokens are stored in the iOS Keychain — they never leave your device and cannot be accessed by other apps.")
            }
        }
        .navigationTitle("Cloud Storage")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Provider Row

    @ViewBuilder
    private func providerRow(
        name: String,
        icon: String,
        iconColor: Color,
        isConnected: Bool,
        isConnecting: Bool,
        onConnect: @escaping () -> Void,
        onDisconnect: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 14) {
            // Icon
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(iconColor.opacity(0.12))
                    .frame(width: 36, height: 36)
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(iconColor)
            }

            // Label
            VStack(alignment: .leading, spacing: 2) {
                Text(name).fontWeight(.semibold)
                Text(isConnected ? "Connected" : "Not Connected")
                    .font(.caption)
                    .foregroundColor(isConnected ? .green : .secondary)
            }

            Spacer()

            // Action
            if isConnecting {
                ProgressView().controlSize(.small)
            } else if isConnected {
                Button("Disconnect") { onDisconnect() }
                    .font(.caption)
                    .foregroundColor(.red)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else {
                Button("Connect") { onConnect() }
                    .font(.caption)
                    .foregroundColor(.white)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(iconColor)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - How It Works Row

    @ViewBuilder
    private func howItWorksRow(icon: String, text: String) -> some View {
        Label {
            Text(text).font(.caption).foregroundColor(.secondary)
        } icon: {
            Image(systemName: icon).foregroundColor(.accentColor).font(.caption)
        }
    }

    // MARK: - Actions

    private func connectDropbox() {
        isConnectingDropbox = true
        errorMessage = nil
        Task {
            do {
                try await dropbox.authenticate()
            } catch {
                await MainActor.run {
                    errorMessage = "Dropbox: \(error.localizedDescription)"
                }
            }
            await MainActor.run { isConnectingDropbox = false }
        }
    }

    private func connectGoogle() {
        isConnectingGoogle = true
        errorMessage = nil
        Task {
            do {
                try await gdrive.authenticate()
            } catch {
                await MainActor.run {
                    errorMessage = "Google Drive: \(error.localizedDescription)"
                }
            }
            await MainActor.run { isConnectingGoogle = false }
        }
    }
}
