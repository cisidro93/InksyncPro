import SwiftUI

struct CloudConnectionSettingsView: View {
    @StateObject private var dropbox = DropboxProvider.shared
    @StateObject private var gdrive = GoogleDriveProvider.shared
    
    var body: some View {
        Form {
            Section(header: Text("Cloud Storage Providers"), footer: Text("Connect your accounts to stream comics directly without downloading them to your device.")) {
                
                // Dropbox
                HStack {
                    Image(systemName: "shippingbox.fill")
                        .foregroundColor(.blue)
                        .frame(width: 30)
                    VStack(alignment: .leading) {
                        Text("Dropbox")
                            .font(.headline)
                        if dropbox.isConnected {
                            Text("Connected")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        } else {
                            Text("Not Connected")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                    
                    if dropbox.isConnected {
                        Button("Disconnect") {
                            dropbox.signOut()
                        }
                        .foregroundColor(.red)
                    } else {
                        Button("Connect") {
                            Task {
                                do {
                                    try await dropbox.authenticate()
                                } catch {
                                    print("Auth error: \(error)")
                                }
                            }
                        }
                        .buttonStyle(BorderedButtonStyle())
                    }
                }
                
                // Google Drive
                HStack {
                    Image(systemName: "externaldrive.fill.badge.icloud")
                        .foregroundColor(.green)
                        .frame(width: 30)
                    VStack(alignment: .leading) {
                        Text("Google Drive")
                            .font(.headline)
                        if gdrive.isConnected {
                            Text("Connected")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        } else {
                            Text("Not Connected")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                    
                    if gdrive.isConnected {
                        Button("Disconnect") {
                            gdrive.signOut()
                        }
                        .foregroundColor(.red)
                    } else {
                        Button("Connect") {
                            Task {
                                do {
                                    try await gdrive.authenticate()
                                } catch {
                                    print("Auth error: \(error)")
                                }
                            }
                        }
                        .buttonStyle(BorderedButtonStyle())
                    }
                }
            }
        }
        .navigationTitle("Cloud Connections")
    }
}
