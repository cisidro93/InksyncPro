import SwiftUI
import UniformTypeIdentifiers

struct ShareExtensionView: View {
    let extensionContext: NSExtensionContext?
    let onDismiss: () -> Void
    
    @State private var selectedFiles: [SharedFile] = []
    @State private var isLoading = true
    @State private var isProcessing = false
    @State private var processingProgress: Double = 0
    @State private var currentFileName: String = ""
    @State private var showingSuccess = false
    @State private var processedCount = 0
    @State private var errorMessage: String?
    
    var body: some View {
        NavigationView {
            ZStack {
                VStack(spacing: 0) {
                    if isLoading {
                        Spacer()
                        ProgressView("Loading files...")
                        Spacer()
                    } else if selectedFiles.isEmpty {
                        Spacer()
                        VStack(spacing: 16) {
                            Image(systemName: "doc.questionmark")
                                .font(.system(size: 60))
                                .foregroundColor(.secondary)
                            Text("No Compatible Files")
                                .font(.headline)
                            Text("Select CBZ or CBR files to convert")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    } else {
                        // File list
                        List {
                            Section {
                                ForEach(selectedFiles) { file in
                                    HStack(spacing: 12) {
                                        Image(systemName: "doc.zipper.fill")
                                            .font(.title2)
                                            .foregroundColor(.orange)
                                        
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(file.name)
                                                .font(.subheadline)
                                                .fontWeight(.medium)
                                                .lineLimit(2)
                                            
                                            Text(file.fileExtension.uppercased())
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Color.orange.opacity(0.2))
                                                .cornerRadius(4)
                                        }
                                        
                                        Spacer()
                                        
                                        if file.isProcessed {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundColor(.green)
                                        }
                                    }
                                    .padding(.vertical, 4)
                                }
                            } header: {
                                Text("\(selectedFiles.count) file\(selectedFiles.count > 1 ? "s" : "") to convert")
                            }
                        }
                        
                        // Convert button
                        VStack(spacing: 12) {
                            if let error = errorMessage {
                                HStack {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundColor(.red)
                                    Text(error)
                                        .font(.caption)
                                        .foregroundColor(.red)
                                }
                            }
                            
                            Button(action: processFiles) {
                                HStack {
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                    Text("Convert to PDF")
                                        .fontWeight(.semibold)
                                }
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.orange)
                                .cornerRadius(12)
                            }
                        }
                        .padding()
                        .background(Color(.systemBackground))
                    }
                }
                
                // Processing overlay
                if isProcessing {
                    Color.black.opacity(0.6)
                        .ignoresSafeArea()
                    
                    VStack(spacing: 20) {
                        ProgressView(value: processingProgress)
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(1.5)
                        
                        Text("Converting...")
                            .font(.headline)
                            .foregroundColor(.white)
                        
                        Text(currentFileName)
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.8))
                            .lineLimit(1)
                        
                        Text("\(Int(processingProgress * 100))%")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.6))
                    }
                    .padding(40)
                    .background(Color.black.opacity(0.8))
                    .cornerRadius(20)
                }
                
                // Success overlay
                if showingSuccess {
                    Color.black.opacity(0.6)
                        .ignoresSafeArea()
                    
                    VStack(spacing: 20) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 60))
                            .foregroundColor(.green)
                        
                        Text("Conversion Complete!")
                            .font(.headline)
                            .foregroundColor(.white)
                        
                        Text("\(processedCount) PDF\(processedCount > 1 ? "s" : "") added to library")
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.8))
                        
                        Button("Done") {
                            onDismiss()
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 40)
                        .padding(.vertical, 12)
                        .background(Color.green)
                        .cornerRadius(10)
                    }
                    .padding(40)
                    .background(Color.black.opacity(0.8))
                    .cornerRadius(20)
                }
            }
            .navigationTitle("ComicToPDF")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        onDismiss()
                    }
                }
            }
        }
        .onAppear {
            loadSharedFiles()
        }
    }
    
    // MARK: - Load Shared Files
    
    private func loadSharedFiles() {
        guard let extensionContext = extensionContext,
              let inputItems = extensionContext.inputItems as? [NSExtensionItem] else {
            isLoading = false
            return
        }
        
        let supportedTypes: [UTType] = [
            UTType(filenameExtension: "cbz") ?? .archive,
            UTType(filenameExtension: "cbr") ?? .archive,
            .zip,
            .archive
        ]
        
        var filesToProcess: [SharedFile] = []
        let group = DispatchGroup()
        
        for item in inputItems {
            guard let attachments = item.attachments else { continue }
            
            for provider in attachments {
                for type in supportedTypes {
                    if provider.hasItemConformingToTypeIdentifier(type.identifier) {
                        group.enter()
                        
                        provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                            defer { group.leave() }
                            
                            guard let url = url else { return }
                            
                            let filename = url.lastPathComponent
                            let ext = url.pathExtension.lowercased()
                            
                            // Only process CBZ/CBR files
                            guard ext == "cbz" || ext == "cbr" else { return }
                            
                            // Copy to shared container
                            if let sharedURL = self.copyToSharedContainer(url) {
                                DispatchQueue.main.async {
                                    filesToProcess.append(SharedFile(
                                        name: filename,
                                        url: sharedURL,
                                        fileExtension: ext
                                    ))
                                }
                            }
                        }
                        break
                    }
                }
            }
        }
        
        group.notify(queue: .main) {
            self.selectedFiles = filesToProcess
            self.isLoading = false
        }
    }
    
    // MARK: - Copy to Shared Container
    
    private func copyToSharedContainer(_ sourceURL: URL) -> URL? {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.antigravity.ComicToPDF"
        ) else { return nil }
        
        let inboxURL = containerURL.appendingPathComponent("Inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: inboxURL, withIntermediateDirectories: true)
        
        let destURL = inboxURL.appendingPathComponent(sourceURL.lastPathComponent)
        
        // Remove existing file if any
        try? FileManager.default.removeItem(at: destURL)
        
        do {
            try FileManager.default.copyItem(at: sourceURL, to: destURL)
            return destURL
        } catch {
            print("Failed to copy file: \(error)")
            return nil
        }
    }
    
    // MARK: - Process Files
    
    private func processFiles() {
        isProcessing = true
        processingProgress = 0
        processedCount = 0
        errorMessage = nil
        
        Task {
            for (index, file) in selectedFiles.enumerated() {
                await MainActor.run {
                    currentFileName = file.name
                    processingProgress = Double(index) / Double(selectedFiles.count)
                }
                
                do {
                    // Mark file for processing by main app
                    try markForConversion(file)
                    
                    await MainActor.run {
                        if let idx = selectedFiles.firstIndex(where: { $0.id == file.id }) {
                            selectedFiles[idx].isProcessed = true
                        }
                        processedCount += 1
                    }
                } catch {
                    await MainActor.run {
                        errorMessage = "Failed to process \(file.name)"
                    }
                }
            }
            
            await MainActor.run {
                processingProgress = 1.0
                isProcessing = false
                showingSuccess = true
            }
        }
    }
    
    // MARK: - Mark for Conversion
    
    private func markForConversion(_ file: SharedFile) throws {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.antigravity.ComicToPDF"
        ) else { throw ShareError.noContainer }
        
        let pendingURL = containerURL.appendingPathComponent("PendingConversions", isDirectory: true)
        try FileManager.default.createDirectory(at: pendingURL, withIntermediateDirectories: true)
        
        // Create a manifest file for the main app to pick up
        let manifest = ConversionManifest(
            sourceFile: file.url.lastPathComponent,
            dateAdded: Date(),
            status: .pending
        )
        
        let manifestURL = pendingURL.appendingPathComponent("\(file.name).manifest.json")
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: manifestURL)
        
        // Move file to pending folder
        let destURL = pendingURL.appendingPathComponent(file.url.lastPathComponent)
        try? FileManager.default.removeItem(at: destURL)
        try FileManager.default.moveItem(at: file.url, to: destURL)
    }
}

// MARK: - Supporting Types

struct SharedFile: Identifiable {
    let id = UUID()
    let name: String
    let url: URL
    let fileExtension: String
    var isProcessed: Bool = false
}

struct ConversionManifest: Codable {
    let sourceFile: String
    let dateAdded: Date
    var status: ConversionStatus
}

enum ConversionStatus: String, Codable {
    case pending
    case processing
    case completed
    case failed
}

enum ShareError: Error {
    case noContainer
    case copyFailed
    case conversionFailed
}
