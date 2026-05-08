import SwiftUI

// MARK: - Branded Cloud Icon Views

/// Dropbox-branded icon: white open box shape on Dropbox blue (#0061FF)
struct DropboxIcon: View {
    let size: CGFloat
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22)
                .fill(Color(red: 0, green: 0.38, blue: 1.0))
                .frame(width: size, height: size)
            // Dropbox diamond/box simplified mark
            VStack(spacing: size * 0.04) {
                HStack(spacing: size * 0.06) {
                    dropboxDiamond(size: size * 0.3)
                    dropboxDiamond(size: size * 0.3)
                }
                HStack(spacing: size * 0.06) {
                    dropboxDiamond(size: size * 0.3)
                    dropboxDiamond(size: size * 0.3)
                }
            }
        }
    }
    private func dropboxDiamond(size: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(.white)
            .frame(width: size, height: size)
            .rotationEffect(.degrees(45))
    }
}

/// Google Drive–branded icon: colored triangle on white background
struct GoogleDriveIcon: View {
    let size: CGFloat
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22)
                .fill(.white)
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
            // Google Drive triangle mark (three-color)
            Canvas { ctx, sz in
                let cx = sz.width / 2
                let cy = sz.height / 2
                let r  = sz.width * 0.36

                // Bottom-left (green) segment
                var p1 = Path(); p1.move(to: CGPoint(x: cx, y: cy - r))
                p1.addLine(to: CGPoint(x: cx - r * 0.87, y: cy + r * 0.5))
                p1.addLine(to: CGPoint(x: cx - r * 0.1, y: cy + r * 0.5))
                p1.addLine(to: CGPoint(x: cx + r * 0.37, y: cy - r * 0.25))
                p1.closeSubpath()
                ctx.fill(p1, with: .color(Color(red: 0.13, green: 0.65, blue: 0.27)))

                // Bottom-right (yellow) segment
                var p2 = Path(); p2.move(to: CGPoint(x: cx, y: cy - r))
                p2.addLine(to: CGPoint(x: cx + r * 0.87, y: cy + r * 0.5))
                p2.addLine(to: CGPoint(x: cx + r * 0.1, y: cy + r * 0.5))
                p2.addLine(to: CGPoint(x: cx - r * 0.37, y: cy - r * 0.25))
                p2.closeSubpath()
                ctx.fill(p2, with: .color(Color(red: 1.0, green: 0.73, blue: 0.0)))

                // Bottom (blue) segment
                var p3 = Path()
                p3.move(to: CGPoint(x: cx - r * 0.87, y: cy + r * 0.5))
                p3.addLine(to: CGPoint(x: cx + r * 0.87, y: cy + r * 0.5))
                p3.addLine(to: CGPoint(x: cx + r * 0.1, y: cy + r * 0.5))
                p3.addLine(to: CGPoint(x: cx - r * 0.1, y: cy + r * 0.5))
                p3.closeSubpath()
                // Use a thin bar instead for the bottom band
                var bar = Path()
                bar.addRect(CGRect(x: cx - r * 0.87, y: cy + r * 0.38,
                                   width: r * 1.74, height: r * 0.24))
                ctx.fill(bar, with: .color(Color(red: 0.26, green: 0.52, blue: 0.96)))
            }
            .frame(width: size, height: size)
        }
    }
}

// MARK: - CloudConnectionSettingsView

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
                    brandIcon: AnyView(DropboxIcon(size: 36)),
                    accentColor: Color(red: 0, green: 0.38, blue: 1.0),
                    isConnected: dropbox.isConnected,
                    isConnecting: isConnectingDropbox,
                    onConnect: connectDropbox,
                    onDisconnect: { dropbox.signOut() }
                )

                // Browse Dropbox (shown only when connected)
                if dropbox.isConnected {
                    browseRow(
                        title: "Browse Dropbox",
                        subtitle: "Stream comics directly to your Library",
                        color: Color(red: 0, green: 0.38, blue: 1.0)
                    ) { showDropboxBrowser = true }
                }

                // Google Drive Row
                providerRow(
                    name: "Google Drive",
                    brandIcon: AnyView(GoogleDriveIcon(size: 36)),
                    accentColor: Color(red: 0.26, green: 0.52, blue: 0.96),
                    isConnected: gdrive.isConnected,
                    isConnecting: isConnectingGoogle,
                    onConnect: connectGoogle,
                    onDisconnect: { gdrive.signOut() }
                )

                // Browse Google Drive (shown only when connected)
                if gdrive.isConnected {
                    browseRow(
                        title: "Browse Google Drive",
                        subtitle: "Stream comics directly to your Library",
                        color: Color(red: 0.13, green: 0.65, blue: 0.27)
                    ) { showGDriveBrowser = true }
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

    // MARK: - Provider Row (with branded icon)

    @ViewBuilder
    private func providerRow(
        name: String,
        brandIcon: AnyView,
        accentColor: Color,
        isConnected: Bool,
        isConnecting: Bool,
        onConnect: @escaping () -> Void,
        onDisconnect: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 14) {
            brandIcon

            VStack(alignment: .leading, spacing: 2) {
                Text(name).fontWeight(.semibold)
                Text(isConnected ? "Connected" : "Not Connected")
                    .font(.caption)
                    .foregroundColor(isConnected ? .green : .secondary)
            }

            Spacer()

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
                    .tint(accentColor)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Browse Row

    @ViewBuilder
    private func browseRow(
        title: String,
        subtitle: String,
        color: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(color.opacity(0.12))
                        .frame(width: 36, height: 36)
                    Image(systemName: "folder.fill")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(color)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).fontWeight(.semibold)
                    Text(subtitle).font(.caption).foregroundColor(.secondary)
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
