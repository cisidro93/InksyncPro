import SwiftUI

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
                    VStack(spacing: 15) {
                        Text("Type this URL into your computer's browser:")
                            .foregroundColor(.secondary)
                        
                        Text(server.serverURL)
                            .font(.system(.title, design: .monospaced))
                            .fontWeight(.bold)
                            .padding()
                            .background(Color.gray.opacity(0.1))
                            .cornerRadius(10)
                            .textSelection(.enabled)
                    }
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
                    Text("3. Drag files from the 'ComicToPDF' folder.")
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
        }
    }
}
