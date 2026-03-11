import SwiftUI
import UIKit // Required for UIColor

import CoreImage.CIFilterBuiltins

struct WiFiView: View {
    @StateObject private var server = WiFiServer()
    @Environment(\.dismiss) var dismiss
    @State private var qrCodeImage: UIImage?
    
    private func settingsIcon(_ systemName: String, color: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(.white)
            .frame(width: 28, height: 28)
            .background(color)
            .cornerRadius(6)
    }

    var body: some View {
        NavigationView {
            Form {
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
                
                if server.isRunning {
                    Section(header: Text("Connection Details")) {
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
            .onChange(of: server.isRunning) { isRunning in
                if isRunning { generateQRCode() } else { qrCodeImage = nil }
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
