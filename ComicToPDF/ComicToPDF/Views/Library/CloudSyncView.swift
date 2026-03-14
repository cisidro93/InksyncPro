import SwiftUI

struct CloudSyncView: View {
    @Environment(\.dismiss) var dismiss
    @StateObject private var cloudManager = CloudSyncManager.shared
    
    let targetPDF: ConvertedPDF
    
    @AppStorage("cloudSync_serverURL") private var serverURL: String = ""
    @AppStorage("cloudSync_username") private var username: String = ""
    @AppStorage("cloudSync_password") private var password: String = ""
    
    @State private var showingError = false
    @State private var errorMessage = ""
    @State private var showingSuccess = false
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("WebDAV / Cloud Target")) {
                    TextField("Server URL (e.g. https://boox.local:8080)", text: $serverURL)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    
                    TextField("Username (Optional)", text: $username)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    
                    SecureField("Password (Optional)", text: $password)
                }
                
                Section(header: Text("Target File")) {
                    Text(targetPDF.name)
                        .font(.headline)
                    Text(ByteCountFormatter.string(fromByteCount: targetPDF.fileSize, countStyle: .file))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                
                if cloudManager.isSyncing {
                    Section {
                        VStack(alignment: .center, spacing: 12) {
                            ProgressView()
                            Text(cloudManager.lastSyncStatus)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                } else {
                    Section {
                        Button(action: startUpload) {
                            HStack {
                                Spacer()
                                Image(systemName: "icloud.and.arrow.up.fill")
                                Text("Upload to Cloud")
                                Spacer()
                            }
                            .font(.headline)
                            .foregroundColor(serverURL.isEmpty ? .gray : .blue)
                        }
                        .disabled(serverURL.isEmpty)
                    }
                }
            }
            .navigationTitle("Direct Cloud Sync")
            .navigationBarItems(
                leading: Button("Cancel") {
                    dismiss()
                }
                .disabled(cloudManager.isSyncing)
            )
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
