import SwiftUI
import MessageUI
import UIKit
import UniformTypeIdentifiers

struct MailPayload: Identifiable {
    let id = UUID()
    let url: URL
    let data: Data
}

struct LogsView: View {
    @ObservedObject var logger = Logger.shared
    @Environment(\.dismiss) var dismiss
    
    @State private var showingCopiedAlert = false
    @State private var isSharing = false
    @State private var showErrorsOnly = false
    @State private var selectedCategory: String? = nil
    @State private var smartLogURL: URL? = nil
    
    // ✅ NEW: Mail State
    @State private var showingMailErrorAlert = false
    @State private var mailPayload: MailPayload? = nil
    @State private var mailResult: Result<MFMailComposeResult, Error>? = nil
    
    // ✅ NEW: AI State Management
    @State private var showingAIExport = false

    @State private var aiDocumentToExport: AIDocument?
    
    var errorCount: Int {
        logger.parsedLogs.filter { $0.type == .error }.count
    }
    
    var filteredLogs: [LogEntry] {
        var logs = logger.parsedLogs
        if showErrorsOnly {
            logs = logs.filter { $0.type == .error || $0.type == .warning }
        }
        if let cat = selectedCategory {
            logs = logs.filter { $0.category == cat }
        }
        return logs
    }
    
    var body: some View {
        mainContent
            .navigationTitle("Flight Recorder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .overlay(copiedAlertOverlay)
            .sheet(isPresented: $isSharing) {
                if let url = smartLogURL {
                    ShareSheet(activityItems: [url])
                }
            }
            .sheet(item: $mailPayload) { payload in
                MailView(
                    subject: "Inksync Pro Support Request" + (selectedCategory != nil ? " [\(selectedCategory!)]" : ""),
                    recipients: ["support@inksyncpro.app"],
                    messageBody: getDeviceInfo(),
                    isHTML: false,
                    attachments: [(payload.data, "text/plain", payload.url.lastPathComponent)],
                    isShowing: Binding(
                        get: { mailPayload != nil },
                        set: { if !$0 { mailPayload = nil } }
                    ),
                    result: $mailResult
                )
                .ignoresSafeArea()
            }
            .fileExporter(isPresented: $showingAIExport, document: aiDocumentToExport, contentType: .json, defaultFilename: "inksync_ai_settings") { result in
                handleAIExport(result: result)
            }

            .alert("Cannot Send Email", isPresented: $showingMailErrorAlert) {
                 Button("Copy Logs & Open Mail") {
                     copyToClipboard()
                     if let url = URL(string: "mailto:support@inksyncpro.app") {
                         UIApplication.shared.open(url)
                     }
                 }
                 Button("Cancel", role: .cancel) { }
            } message: {
                 Text("Please ensure the Apple Mail app is configured on this device. You can copy the logs and email us directly at support@inksyncpro.app")
            }
    }
    
    // MARK: - View Subcomponents
    
    private var mainContent: some View {
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
                
                Toggle(showErrorsOnly ? "View Full Logs" : "Errors Only", isOn: $showErrorsOnly)
                    .toggleStyle(.button)
                    .font(.caption)
            }
            .padding()
            .background(Color(UIColor.secondarySystemBackground))
            
            Divider()
            
            // ✅ Category Isolation Pills
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button(action: { selectedCategory = nil }) {
                        Text("All")
                            .font(.caption).bold()
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(selectedCategory == nil ? Color.blue : Color.secondary.opacity(0.2))
                            .foregroundColor(selectedCategory == nil ? .white : .primary)
                            .cornerRadius(12)
                    }
                    
                    ForEach(logger.availableCategories, id: \.self) { cat in
                        Button(action: { selectedCategory = cat }) {
                            Text(cat)
                                .font(.caption).bold()
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(selectedCategory == cat ? Color.blue : Color.secondary.opacity(0.2))
                                .foregroundColor(selectedCategory == cat ? .white : .primary)
                                .cornerRadius(12)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            
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
    }
    
    @ViewBuilder
    private var copiedAlertOverlay: some View {
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
    }
    
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button("Done") { dismiss() }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            Menu {
                Button {
                    var filterCategories: [String]? = nil
                    if let cat = selectedCategory { filterCategories = [cat] }
                    var filterTypes: [LogType]? = nil
                    if showErrorsOnly { filterTypes = [.error, .warning] }
                    
                    if let smartURL = logger.generateSmartLog(categories: filterCategories, types: filterTypes),
                       let targetData = try? Data(contentsOf: smartURL) {
                        
                        self.smartLogURL = smartURL
                        if MFMailComposeViewController.canSendMail() {
                            self.mailPayload = MailPayload(url: smartURL, data: targetData)
                        } else {
                            showingMailErrorAlert = true
                        }
                    } else {
                        showingMailErrorAlert = true
                    }
                } label: { Label("Email Support", systemImage: "envelope") }
                
                Button(action: { 
                    var filterCategories: [String]? = nil
                    if let cat = selectedCategory { filterCategories = [cat] }
                    var filterTypes: [LogType]? = nil
                    if showErrorsOnly { filterTypes = [.error, .warning] }
                    
                    if let smartURL = logger.generateSmartLog(categories: filterCategories, types: filterTypes) {
                        self.smartLogURL = smartURL
                        isSharing = true 
                    }
                }) {
                    Label("Share Visible Logs", systemImage: "square.and.arrow.up")
                }
                Button(action: copyToClipboard) {
                    Label("Copy All", systemImage: "doc.on.doc")
                }
                
                Divider()
                
                Button {
                    if let data = AdaptiveLearningManager.shared.exportState() {
                        aiDocumentToExport = AIDocument(data: data)
                        showingAIExport = true
                    }
                } label: { Label("Backup AI Settings", systemImage: "brain.head.profile") }
                
                Button {
                    ImportCoordinator.present(type: .json) { urls in
                        if let first = urls.first {
                            handleAIImport(result: .success(first))
                        }
                    }
                } label: { Label("Restore AI Settings", systemImage: "square.and.arrow.down.on.square") }
                
                Divider()
                
                Button(role: .destructive, action: logger.clearLogs) {
                    Label("Clear Logs", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }
    
    // MARK: - Handlers
    
    private func handleAIExport(result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            logger.log("Successfully Backed Up AI configuration JSON to \(url.lastPathComponent)", category: "System", type: .success)
        case .failure(let error):
            logger.log("Backup Failed: \(error.localizedDescription)", category: "System", type: .error)
        }
    }
    
    private func handleAIImport(result: Result<URL, Error>) {
        switch result {
        case .success(let rawURL):
            let accessing = rawURL.startAccessingSecurityScopedResource()
            
            Task.detached(priority: .userInitiated) {
                defer { if accessing { rawURL.stopAccessingSecurityScopedResource() } }
                
                var parsedData: Data?
                var coordError: NSError?
                NSFileCoordinator().coordinate(readingItemAt: rawURL, options: .withoutChanges, error: &coordError) { safeURL in
                    parsedData = try? Data(contentsOf: safeURL)
                }
                
                // Allow UI to dismiss without dropping frames
                try? await Task.sleep(nanoseconds: 500_000_000)
                
                let finalData = parsedData
                await MainActor.run {
                    if let data = finalData {
                        do {
                            let status = try AdaptiveLearningManager.shared.importState(from: data)
                            switch status {
                            case .success:
                                NotificationCenter.default.post(name: NSNotification.Name("GlobalErrorTriggered"), object: nil, userInfo: ["message": "AI Diagnostics loaded perfectly.", "category": "Success"])
                            case .identical:
                                NotificationCenter.default.post(name: NSNotification.Name("GlobalErrorTriggered"), object: nil, userInfo: ["message": "The system is already running this exact AI Engine version. No changes made.", "category": "System"])
                            }
                        } catch {
                            NotificationCenter.default.post(name: NSNotification.Name("GlobalErrorTriggered"), object: nil, userInfo: ["message": "Invalid or corrupted AI Configuration file.", "category": "System"])
                        }
                    } else {
                        NotificationCenter.default.post(name: NSNotification.Name("GlobalErrorTriggered"), object: nil, userInfo: ["message": "Unable to interact with the selected file access.", "category": "System"])
                    }
                }
            }
        case .failure(let error):
            logger.log("Import Failed: \(error.localizedDescription)", category: "System", type: .error)
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
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 s
            withAnimation { showingCopiedAlert = false }
        }
    }
}

// ✅ NEW: Document wrapper for native Swift File Exporter
struct AIDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        if let data = configuration.file.regularFileContents { self.data = data }
        else { throw CocoaError(.fileReadCorruptFile) }
    }
    
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        return FileWrapper(regularFileWithContents: data)
    }
}
