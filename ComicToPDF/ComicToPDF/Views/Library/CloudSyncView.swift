import SwiftUI

struct CloudSyncView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject private var cloudManager = WebDAVSyncManager.shared
    
    let targetPDF: ConvertedPDF
    
    @AppStorage("cloudSync_serverURL") private var serverURL: String = ""
    @AppStorage("cloudSync_username") private var username: String = ""
    @AppStorage("cloudSync_password") private var password: String = ""
    
    @State private var showingError = false
    @State private var errorMessage = ""
    @State private var showingSuccess = false
    
    private var isPad: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                InkSheetDragPill()
                    .padding(.top, 8)
                    .padding(.bottom, 4)

                Form {
                    Section(header: Text("iCloud Drive Document Mirroring").foregroundColor(Color.inkSecondary)) {
                        Toggle(isOn: Binding(
                            get: { iCloudFileSyncManager.shared.isSyncEnabled },
                            set: { iCloudFileSyncManager.shared.isSyncEnabled = $0 }
                        )) {
                            HStack(spacing: 12) {
                                Image(systemName: "icloud.fill")
                                    .font(.system(size: isPad ? 22 : 18))
                                    .foregroundStyle(Color.inkBlue)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("iCloud Drive Mirroring")
                                        .font(.system(size: isPad ? 16 : 15, weight: .medium))
                                        .foregroundColor(Color.inkText)
                                    Text("Mirror `.cbz`, `.epub`, and `.pdf` files across all your Apple ID devices automatically.")
                                        .font(.system(size: isPad ? 13 : 11.5))
                                        .foregroundStyle(Color.inkSecondary)
                                }
                            }
                        }
                        if iCloudFileSyncManager.shared.isSyncEnabled {
                            HStack {
                                Text("Status:")
                                    .font(.system(size: isPad ? 14 : 12))
                                    .foregroundStyle(Color.inkSecondary)
                                Spacer()
                                Text(iCloudFileSyncManager.shared.syncStatusText)
                                    .font(.system(size: isPad ? 14 : 12, weight: .semibold))
                                    .foregroundStyle(Color.inkBlue)
                            }
                        }
                    }

                    Section(header: Text("WebDAV / Cloud Target").foregroundColor(Color.inkSecondary)) {
                        TextField("Server URL (e.g. https://boox.local:8080)", text: $serverURL)
                            .keyboardType(.URL)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .font(.system(size: isPad ? 16 : 14))
                        
                        TextField("Username (Optional)", text: $username)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .font(.system(size: isPad ? 16 : 14))
                        
                        SecureField("Password (Optional)", text: $password)
                            .font(.system(size: isPad ? 16 : 14))
                    }
                    
                    Section(header: Text("Target File").foregroundColor(Color.inkSecondary)) {
                        Text(targetPDF.name)
                            .font(.system(size: isPad ? 17 : 15, weight: .semibold))
                            .foregroundColor(Color.inkText)
                        Text(ByteCountFormatter.string(fromByteCount: targetPDF.fileSize, countStyle: .file))
                            .font(.system(size: isPad ? 14 : 13))
                            .foregroundColor(Color.inkSecondary)
                    }
                    
                    if cloudManager.isSyncing {
                        Section {
                            VStack(alignment: .center, spacing: 12) {
                                ProgressView()
                                    .tint(Color.inkBlue)
                                Text(cloudManager.lastSyncStatus)
                                    .font(.system(size: isPad ? 14 : 12))
                                    .foregroundColor(Color.inkSecondary)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                        }
                    } else {
                        Section {
                            Button(action: startUpload) {
                                HStack(spacing: 8) {
                                    Spacer()
                                    Image(systemName: "icloud.and.arrow.up.fill")
                                        .font(.system(size: isPad ? 18 : 16))
                                    Text("Upload to Cloud")
                                        .font(.system(size: isPad ? 16 : 15, weight: .semibold))
                                    Spacer()
                                }
                                .foregroundColor(serverURL.isEmpty ? Color.inkSecondary.opacity(0.5) : Color.inkBlue)
                            }
                            .disabled(serverURL.isEmpty)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .frame(maxWidth: isPad ? 640 : .infinity)
            .background(Color.inkBackground.ignoresSafeArea())
            .navigationTitle("Direct Cloud Sync")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .font(.system(size: isPad ? 16 : 15))
                    .foregroundColor(Color.inkSecondary)
                    .disabled(cloudManager.isSyncing)
                }
            }
            .alert(isPresented: $showingError) {
                Alert(title: Text("Sync Failed"), message: Text(errorMessage), dismissButton: .default(Text("OK")))
            }
            .alert(isPresented: $showingSuccess) {
                Alert(title: Text("Upload Complete"), message: Text("The file was successfully synced over WebDAV."), dismissButton: .default(Text("Done")) {
                    dismiss()
                })
            }
        }
    }
    
    private func startUpload() {
        guard let url = URL(string: serverURL) else {
            errorMessage = "Invalid Server URL."
            showingError = true
            return
        }
        
        Task {
            do {
                try await cloudManager.uploadToWebDAV(
                    fileURL: targetPDF.url,
                    serverURL: url,
                    username: username,
                    password: password
                )
                showingSuccess = true
            } catch {
                errorMessage = error.localizedDescription
                showingError = true
            }
        }
    }
}
