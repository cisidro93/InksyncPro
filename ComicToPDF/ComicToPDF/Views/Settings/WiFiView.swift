import SwiftUI
import UIKit // Required for UIColor

struct WiFiView: View {
    @StateObject private var server = WiFiServer()
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationView {
            VStack(spacing: 30) {
                Image(systemName: "wifi.circle.fill")
                    .font(.system(size: 80))
                    .foregroundColor(server.isRunning ? .green : .gray)
                    .symbolEffect(.pulse, isActive: server.isRunning)
                
                Text(server.isRunning ? "Wi-Fi Server Active" : "Wi-Fi Server Stopped")
                    .font(.title2).bold()
                
                if server.isRunning {
                    VStack(spacing: 20) {
                        VStack(spacing: 5) {
                            Text("Type this URL into your browser:")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            
                            Text(server.serverURL ?? "http://unknown-ip")
                                .font(.system(.title3, design: .monospaced))
                                .fontWeight(.bold)
                                .padding(10)
                                .background(Color.gray.opacity(0.1))
                                .cornerRadius(8)
                                .textSelection(.enabled)
                        }
                        
                        Divider()
                        
                        VStack(spacing: 5) {
                            Text("Security Code (PIN)")
                                .font(.caption)
                                .textCase(.uppercase)
                                .foregroundColor(.secondary)
                            
                            Text(server.securityCode)
                                .font(.system(size: 44, weight: .heavy, design: .monospaced))
                                .foregroundColor(.blue)
                                .padding(.horizontal)
                        }
                        
                        HStack {
                            Image(systemName: "network")
                            Text("\(server.activeConnections) Active Connection\(server.activeConnections == 1 ? "" : "s")")
                        }
                        .font(.footnote)
                        .foregroundColor(server.activeConnections > 0 ? .green : .secondary)
                        .padding(.top, 5)
                    }
                    .padding()
                    .background(Color(UIColor.secondarySystemBackground))
                    .cornerRadius(16)
                }
                
                // ✅ NEW: Progress UI
                if server.isUploading {
                    VStack(spacing: 8) {
                        Text("Uploading: \(server.currentUploadFilename)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        ProgressView(value: server.uploadProgress)
                            .progressViewStyle(LinearProgressViewStyle(tint: .orange))
                            .padding(.horizontal)
                        
                        Text("\(Int(server.uploadProgress * 100))%")
                            .font(.caption.bold())
                    }
                    .padding()
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                
                Button(action: {
                    if server.isRunning { server.stop() } else { server.start() }
                }) {
                    Text(server.isRunning ? "Stop Server" : "Start Server")
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding()
                        .frame(maxWidth: 200)
                        .background(server.isRunning ? Color.red : Color.green)
                        .cornerRadius(12)
                }
                
                Spacer()
                
                VStack(alignment: .leading, spacing: 10) {
                    Divider()
                    Text("💡 USB Transfer").font(.headline)
                    Text("1. Connect to Computer via USB.")
                    Text("2. Open Finder (Mac) or iTunes (PC).")
                    Text("3. Drag files from the 'Inksync Pro' folder.")
                }
                .padding()
                .foregroundColor(.secondary)
            }
            .padding()
            .navigationTitle("Transfer Files")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") { 
                        server.stop()
                        dismiss() 
                    }
                }
            }
            .onDisappear { server.stop() }
            // ✅ NEW: Error Alert
            .alert(item: Binding<ErrorWrapper?>(
                get: { server.errorMessage.map { ErrorWrapper(id: UUID(), message: $0) } },
                set: { _ in server.errorMessage = nil }
            )) { wrapper in
                Alert(title: Text("Server Error"), message: Text(wrapper.message), dismissButton: .default(Text("OK")))
            }
        }
    }
}

// Helper for Alert Binding
struct ErrorWrapper: Identifiable {
    let id: UUID
    let message: String
}
