import SwiftUI
import MessageUI
import UIKit

struct LogsView: View {
    @ObservedObject var logger = Logger.shared
    @Environment(\.dismiss) var dismiss
    
    @State private var showingCopiedAlert = false
    @State private var isSharing = false
    @State private var showErrorsOnly = false
    
    // ✅ NEW: Mail State
    @State private var showingMailErrorAlert = false
    @State private var isShowingMailView = false
    @State private var mailResult: Result<MFMailComposeResult, Error>? = nil
    
    var errorCount: Int {
        logger.parsedLogs.filter { $0.type == .error }.count
    }
    
    var filteredLogs: [LogEntry] {
        if showErrorsOnly {
            return logger.parsedLogs.filter { $0.type == .error || $0.type == .warning }
        }
        return logger.parsedLogs
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // ✅ Status Header
            HStack {
                VStack(alignment: .leading) {
                    Text("System Status")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    if errorCount == 0 {
                        Label("0 Errors Detected", systemImage: "checkmark.shield.fill")
                            .foregroundColor(.green)
                            .font(.headline)
                    } else {
                        Label("\(errorCount) Errors Detected", systemImage: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                            .font(.headline)
                    }
                }
                Spacer()
                
                Toggle("Errors Only", isOn: $showErrorsOnly)
                    .toggleStyle(.button)
                    .font(.caption)
            }
            .padding()
            .background(Color(UIColor.secondarySystemBackground))
            
            Divider()
            
            // ✅ Log List
            List(filteredLogs) { entry in
                HStack(alignment: .top) {
                    Image(systemName: entry.type.icon)
                        .foregroundColor(entry.type.color)
                        .font(.caption)
                        .frame(width: 20)
                        
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.message)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        
                        HStack {
                            Text(entry.category)
                                .font(.caption2)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.1))
                                .cornerRadius(4)
                            
                            Spacer()
                            Text(entry.timestamp, style: .time)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .listRowBackground(entry.type == .error ? Color.red.opacity(0.05) : nil)
            }
            .listStyle(.plain)
        }
        .navigationTitle("Flight Recorder")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("Done") { dismiss() }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        if MFMailComposeViewController.canSendMail() {
                            isShowingMailView = true
                        } else {
                            showingMailErrorAlert = true
                        }
                    } label: { Label("Email Support", systemImage: "envelope") }
                    
                    Button(action: { isSharing = true }) {
                        Label("Share Log File", systemImage: "square.and.arrow.up")
                    }
                    Button(action: copyToClipboard) {
                        Label("Copy All", systemImage: "doc.on.doc")
                    }
                    Button(role: .destructive, action: logger.clearLogs) {
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
        .sheet(isPresented: $isSharing) {
             ShareSheet(activityItems: [logger.logFileURL])
        }
        .sheet(isPresented: $isShowingMailView) {
            if let errorLogURL = logger.generateErrorLogFile(),
               let fullLogData = try? Data(contentsOf: logger.logFileURL),
               let errorLogData = try? Data(contentsOf: errorLogURL) {
                MailView(
                    subject: "Inksync Pro Support Request",
                    recipients: ["support@inksyncpro.app"],
                    messageBody: getDeviceInfo(),
                    isHTML: false,
                    attachments: [
                        (fullLogData, "text/plain", "debug.log"),
                        (errorLogData, "text/plain", "inksync_error_log.txt")
                    ],
                    isShowing: $isShowingMailView,
                    result: $mailResult
                )
                .ignoresSafeArea()
            } else {
                VStack(spacing: 20) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundColor(.red)
                    Text("Error generating logs for email.").font(.headline)
                    Button("Dismiss") { isShowingMailView = false }
                }
            }
        }
        .alert("Cannot Send Email", isPresented: $showingMailErrorAlert) {
             Button("OK", role: .cancel) { }
        } message: {
             Text("Please ensure the Apple Mail app is configured on this device, or email us directly with your logs at support@inksyncpro.app")
        }
    }
    
    private func getDeviceInfo() -> String {
        let systemName = UIDevice.current.systemName
        let version = UIDevice.current.systemVersion
        let model = UIDevice.current.model
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
        
        return "Device: \(model)\nOS: \(systemName) \(version)\nApp Version: \(appVersion)\n\nPlease describe the issue you are experiencing below:\n\n"
    }
    
    private func copyToClipboard() {
        UIPasteboard.general.string = logger.getLogs()
        withAnimation { showingCopiedAlert = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { showingCopiedAlert = false }
        }
    }
}
