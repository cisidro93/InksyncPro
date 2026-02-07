import SwiftUI

struct LogsView: View {
    @Environment(\.dismiss) var dismiss
    @State private var logs: String = "Loading..."
    @State private var showingCopiedAlert = false
    
    var body: some View {
        ScrollView {
            Text(logs)
                .font(.system(.caption, design: .monospaced))
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Debug Logs (v2)")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { refreshLogs() }
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("Done") { dismiss() }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button(action: refreshLogs) {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    Button(action: copyToClipboard) {
                        Label("Copy All", systemImage: "doc.on.doc")
                    }
                    Button(role: .destructive, action: clearLogs) {
                        Label("Clear Logs", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .overlay(
            Group {
                if showingCopiedAlert {
                    VStack {
                        Text("Copied to Clipboard")
                            .font(.caption)
                            .padding()
                            .background(Color.secondary.opacity(0.8))
                            .foregroundColor(.white)
                            .cornerRadius(8)
                    }
                    .transition(.opacity)
                }
            }
        )
    }
    
    private func refreshLogs() {
        logs = Logger.shared.getLogs()
    }
    
    private func clearLogs() {
        Logger.shared.clearLogs()
        refreshLogs()
    }
    
    private func copyToClipboard() {
        UIPasteboard.general.string = logs
        withAnimation { showingCopiedAlert = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { showingCopiedAlert = false }
        }
    }
}
