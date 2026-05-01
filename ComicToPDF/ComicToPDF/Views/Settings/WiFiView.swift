import SwiftUI
import UIKit // Required for UIColor

import CoreImage.CIFilterBuiltins

struct WiFiView: View {
    @StateObject private var server = WiFiServer()
    @ObservedObject private var peerManager = PeerManager.shared
    @ObservedObject private var queueManager = TransferQueueManager.shared
    @ObservedObject private var localSendClient = LocalSendClient.shared
    @Environment(\.dismiss) var dismiss
    @State private var qrCodeImage: UIImage?
    
    // ✅ NEW: Sync Architecture
    @StateObject private var syncCoordinator = SyncCoordinator.shared
    @State private var showingSyncAlert = false
    @State private var syncPin = ""
    @State private var selectedSyncPeer: PeerNode?
    
    private func settingsIcon(_ systemName: String, color: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(.white)
            .frame(width: 28, height: 28)
            .background(color)
            .cornerRadius(6)
    }

    @ViewBuilder
    private var serverStatusSection: some View {
        Section {
            VStack(spacing: 20) {
                Image(systemName: "wifi.circle.fill")
                    .font(.system(size: 72))
                    .foregroundColor(server.isRunning ? .green : .gray)
                    .symbolEffect(.pulse, isActive: server.isRunning)
                
                Text(server.isRunning ? "Wi-Fi Server Active" : "Server Offline")
                    .font(.title2).bold()
                
                Button(action: {
                    if server.isRunning { server.stop() } else { server.start() }
                }) {
                    Text(server.isRunning ? "Stop Server" : "Start Server")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(server.isRunning ? Color.red : Color.green)
                        .cornerRadius(12)
                }
            }
            .padding(.vertical)
            .frame(maxWidth: .infinity)
        }
    }
    
    @ViewBuilder
    private var stagedFilesList: some View {
        let sizeString = queueManager.formattedTotalSize()
        let headerText = "Staged Files (\(sizeString))"
        Section(header: Text(headerText)) {
            ForEach(queueManager.stagedFiles) { file in
                HStack {
                    Image(systemName: "doc.text")
                        .foregroundColor(.blue)
                    Text(file.name)
                        .font(.subheadline)
                        .lineLimit(1)
                }
            }
        }
    }

    @ViewBuilder
    private var discoveredPeersList: some View {
        if !peerManager.availablePeers.isEmpty {
            Section(header: Text("Direct Send to Device (High Speed)")) {
                ForEach(peerManager.availablePeers) { peer in
                    Button(action: {
                        Task {
                            do {
                                try await localSendClient.transferFiles(queueManager.stagedFiles, to: peer)
                            } catch {
                                Logger.shared.log("Transfer failed: \(error)", category: "Network", type: .error)
                            }
                        }
                    }) {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(peer.name)
                                    .font(.headline)
                                    .foregroundColor(.primary)
                                Text("IP: \(peer.ipAddress)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if localSendClient.isTransferring {
                                ProgressView()
                            } else {
                                Image(systemName: "paperplane.fill")
                                    .foregroundColor(.blue)
                            }
                        }
                    }
                    .disabled(localSendClient.isTransferring || syncCoordinator.isSyncing)
                    
                    // ✅ NEW: P2P Database Sync Button
                    Button(action: {
                        selectedSyncPeer = peer
                        syncPin = ""
                        showingSyncAlert = true
                    }) {
                        HStack {
                            VStack(alignment: .leading) {
                                Text("Sync Database State")
                                    .font(.headline)
                                    .foregroundColor(.primary)
                                Text("Import reading progress from \(peer.name)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .foregroundColor(.orange)
                        }
                    }
                    .disabled(localSendClient.isTransferring || syncCoordinator.isSyncing)
                }
            }
        }
    }

    @ViewBuilder
    private var stagedFilesSection: some View {
        Group {
            if !queueManager.stagedFiles.isEmpty {
                stagedFilesList
                discoveredPeersList
            }
        }
    }
    
    @ViewBuilder
    private var browserFallbackSection: some View {
        Group {
            if server.isRunning {
                Section(header: Text("Browser Fallback Options (Scan or Type)")) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Type this URL into your browser:")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        
                        Text(server.serverURL ?? "http://unknown-ip")
                            .font(.system(.title3, design: .monospaced))
                            .fontWeight(.bold)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(UIColor.tertiarySystemFill))
                            .cornerRadius(8)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 4)
                    
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Security Code (PIN)")
                            .font(.caption)
                            .textCase(.uppercase)
                            .foregroundColor(.secondary)
                        
                        Text(server.securityCode)
                            .font(.system(size: 34, weight: .heavy, design: .monospaced))
                            .foregroundColor(.blue)
                    }
                    .padding(.vertical, 4)
                    
                    HStack {
                        settingsIcon("network", color: server.activeConnections > 0 ? .green : .gray)
                        Text("\(server.activeConnections) Active Connection\(server.activeConnections == 1 ? "" : "s")")
                    }
                }
                
                if let qr = qrCodeImage {
                    Section(header: Text("Quick Connect")) {
                        VStack(spacing: 12) {
                            Image(uiImage: qr)
                                .resizable()
                                .interpolation(.none)
                                .scaledToFit()
                                .frame(width: 140, height: 140)
                                .cornerRadius(12)
                            
                            Text("Scan with your mobile device")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical)
                    }
                }
            }
        }
    }
    
    @ViewBuilder
    private var progressSection: some View {
        Group {
            if server.isUploading {
                Section(header: Text("In Progress")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Uploading: \(server.currentUploadFilename)")
                            .font(.caption)
                            .lineLimit(1)
                        
                        ProgressView(value: server.uploadProgress)
                            .progressViewStyle(LinearProgressViewStyle(tint: .orange))
                        
                        Text("\(Int(server.uploadProgress * 100))%")
                            .font(.caption.bold())
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .padding(.vertical, 4)
                }
            }
            
            if localSendClient.isTransferring {
                Section(header: Text("Direct Transfer Progress")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Sending: \(localSendClient.currentFileName)")
                            .font(.caption)
                            .lineLimit(1)
                        
                        ProgressView(value: localSendClient.progress)
                            .progressViewStyle(LinearProgressViewStyle(tint: .blue))
                        
                        Text("\(Int(localSendClient.progress * 100))%")
                            .font(.caption.bold())
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
    
    @ViewBuilder
    private var alternativeTransferSection: some View {
        Section(header: Text("Alternative: USB Transfer")) {
            HStack(alignment: .top, spacing: 16) {
                settingsIcon("cable.connector", color: .gray)
                VStack(alignment: .leading, spacing: 6) {
                    Text("1. Connect to Computer via USB")
                    Text("2. Open Finder (Mac) or iTunes (PC)")
                    Text("3. Drag files from the 'Inksync Pro' folder")
                }
                .font(.subheadline)
            }
            .padding(.vertical, 4)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                serverStatusSection
                stagedFilesSection
                browserFallbackSection
                progressSection
                alternativeTransferSection
            }
            .navigationTitle("Transfer Files")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") { 
                        server.stop()
                        dismiss() 
                    }
                }
            }
            .onAppear {
                server.triggerLocalNetworkPrivacyAlert()
                if server.isRunning { generateQRCode() }
            }
            .onChange(of: server.isRunning) { _, isRunning in
                if isRunning { generateQRCode() } else { qrCodeImage = nil }
            }
            .onDisappear { server.stop() }
            // ✅ NEW: Error Alert
            .alert(item: Binding<ErrorWrapper?>(
                get: { server.errorMessage.map { ErrorWrapper(id: UUID(), message: $0) } },
                set: { _ in server.errorMessage = nil }
            )) { wrapper in
                let isPermissionError = wrapper.message.contains("Local Network permission")
                                     || wrapper.message.contains("NoAuth")
                if isPermissionError {
                    return Alert(
                        title: Text("Local Network Permission Required"),
                        message: Text(wrapper.message),
                        primaryButton: .default(Text("Open Settings")) {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        },
                        secondaryButton: .cancel(Text("Dismiss"))
                    )
                } else {
                    return Alert(
                        title: Text("Server Error"),
                        message: Text(wrapper.message),
                        dismissButton: .default(Text("OK"))
                    )
                }
            }
            .alert("Database Sync", isPresented: $showingSyncAlert) {
                TextField("4-Digit PIN", text: $syncPin)
                    .keyboardType(.numberPad)
                Button("Cancel", role: .cancel) {}
                Button("Sync Now") {
                    guard let peer = selectedSyncPeer, syncPin.count == 4 else { return }
                    Task {
                        do {
                            try await syncCoordinator.fetchAndMerge(from: peer.ipAddress, pin: syncPin)
                        } catch {
                            server.errorMessage = "Sync Error: \(error.localizedDescription)"
                        }
                    }
                }
            } message: {
                Text("Enter the 4-Digit Security PIN shown on \(selectedSyncPeer?.name ?? "the other device") to sync reading progress.")
            }
            .overlay {
                if syncCoordinator.isSyncing {
                    ZStack {
                        Color(.systemBackground).opacity(0.85).ignoresSafeArea()
                        VStack(spacing: 20) {
                            ProgressView()
                                .scaleEffect(1.5)
                            Text(syncCoordinator.syncStatus)
                                .font(.headline)
                        }
                        .padding(30)
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(16)
                        .shadow(radius: 10)
                    }
                }
            }
        }
    }
    
    private func generateQRCode() {
        guard let serverURL = server.serverURL else { return }
        // Base URL for general connection
        let targetURL = serverURL
        
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(targetURL.utf8)
        filter.correctionLevel = "M" // Medium error correction
        
        if let outputImage = filter.outputImage {
            let transform = CGAffineTransform(scaleX: 10, y: 10)
            let scaledImage = outputImage.transformed(by: transform)
            
            if let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) {
                self.qrCodeImage = UIImage(cgImage: cgImage)
            }
        }
    }
}

// Helper for Alert Binding
struct ErrorWrapper: Identifiable {
    let id: UUID
    let message: String
}
