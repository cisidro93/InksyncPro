import SwiftUI

struct CloudConnectionSettingsView: View {
    @ObservedObject private var dropbox = DropboxProvider.shared
    @ObservedObject private var gdrive  = GoogleDriveProvider.shared
    @ObservedObject private var downloads = CloudDownloadManager.shared

    @State private var isConnectingDropbox = false
    @State private var isConnectingGoogle  = false
    @State private var errorMessage: String?
    @State private var showDropboxBrowser  = false
    @State private var showGDriveBrowser   = false

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

                // Browse Dropbox (shown only when connected)
                if dropbox.isConnected {
                    Button {
                        showDropboxBrowser = true
                    } label: {
                        HStack(spacing: 14) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.blue.opacity(0.12))
                                    .frame(width: 36, height: 36)
                                Image(systemName: "folder.fill")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundColor(.blue)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Browse Dropbox")
                                    .fontWeight(.semibold)
                                Text("Stream comics directly to your Library")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                        .padding(.vertical, 4)
                    }
                    .foregroundColor(.primary)
                }

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

                // Browse Google Drive (shown only when connected)
                if gdrive.isConnected {
                    Button {
                        showGDriveBrowser = true
                    } label: {
                        HStack(spacing: 14) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.green.opacity(0.12))
                                    .frame(width: 36, height: 36)
                                Image(systemName: "folder.fill")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundColor(.green)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Browse Google Drive")
                                    .fontWeight(.semibold)
                                Text("Stream comics directly to your Library")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                        .padding(.vertical, 4)
                    }
                    .foregroundColor(.primary)
                }
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
                howItWorksRow(icon: "1.circle", text: "Tap Connect — a secure OAuth sign-in sheet appears without ever leaving the app. InksyncPro never sees your password.")
                howItWorksRow(icon: "2.circle", text: "Your token is saved in the iOS Keychain. It never leaves your device and cannot be accessed by other apps.")
                howItWorksRow(icon: "3.circle", text: "Tap 'Browse' to navigate your cloud folders and add comics to your Library. Files are registered instantly — nothing downloads yet.")
                howItWorksRow(icon: "4.circle", text: "Open a cloud comic to stream it page-by-page, or tap 'Download to Device' to save it for offline use.")
            }
        }
        .navigationTitle("Cloud Storage")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showDropboxBrowser) {
            CloudFileBrowserView(provider: .dropbox)
                .environmentObject(LinkedLibraryScanner.shared.conversionManager ?? ConversionManager())
        }
        .sheet(isPresented: $showGDriveBrowser) {
            CloudFileBrowserView(provider: .googleDrive)
                .environmentObject(LinkedLibraryScanner.shared.conversionManager ?? ConversionManager())
        }
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
                Logger.shared.log("Dropbox: OAuth authentication successful", category: "Cloud", type: .success)
            } catch {
                await MainActor.run {
                    errorMessage = "Dropbox: \(error.localizedDescription)"
                }
                Logger.shared.log("Dropbox: OAuth failed — \(error.localizedDescription)", category: "Cloud", type: .error)
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
                Logger.shared.log("Google Drive: OAuth authentication successful", category: "Cloud", type: .success)
            } catch {
                await MainActor.run {
                    errorMessage = "Google Drive: \(error.localizedDescription)"
                }
                Logger.shared.log("Google Drive: OAuth failed — \(error.localizedDescription)", category: "Cloud", type: .error)
            }
            await MainActor.run { isConnectingGoogle = false }
        }
    }
}

