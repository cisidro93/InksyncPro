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
                            Text("Select CBZ, CBR, PDF, or EPUB files to import")
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
                                Text("\(selectedFiles.count) file\(selectedFiles.count > 1 ? "s" : "") to import")
                            }
                        }
                        
                        // Import button
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
                                    Text("Import to Inksync Pro")
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
                        
                        Text("Importing...")
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
                        
                        Text("Import Complete!")
                            .font(.headline)
                            .foregroundColor(.white)
                        
                        Text("\(processedCount) file\(processedCount > 1 ? "s" : "") added to library")
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
            .navigationTitle("InkSync Pro")
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
    
    private func targetExtension(for type: UTType) -> String? {
        if type.conforms(to: .pdf) { return "pdf" }
        if type.conforms(to: UTType(filenameExtension: "epub") ?? .data) || type.identifier.contains("epub") { return "epub" }
        if type.conforms(to: UTType(filenameExtension: "cbz") ?? .data) || type.identifier.contains("cbz") { return "cbz" }
        if type.conforms(to: UTType(filenameExtension: "cbr") ?? .data) || type.identifier.contains("cbr") { return "cbr" }
        if type.conforms(to: .zip) || type.identifier.contains("zip") { return "cbz" }
        if type.conforms(to: .archive) {
            if type.identifier.contains("rar") || type.identifier.contains("cbr") { return "cbr" }
            return "cbz"
        }
        return nil
    }

    private func loadSharedFiles() {
        guard let extensionContext = extensionContext,
              let inputItems = extensionContext.inputItems as? [NSExtensionItem] else {
            isLoading = false
            return
        }
        
        Task { @MainActor in
            var filesToProcess: [SharedFile] = []
            
            for item in inputItems {
                guard let attachments = item.attachments else { continue }
                
                for provider in attachments {
                    // Find the best type identifier from registered identifiers
                    var bestTypeIdentifier: String? = nil
                    var targetExt: String? = nil
                    
                    // Prioritize specific types
                    for typeId in provider.registeredTypeIdentifiers {
                        guard let utType = UTType(typeId) else { continue }
                        if utType.conforms(to: .pdf) {
                            bestTypeIdentifier = typeId
                            targetExt = "pdf"
                            break
                        } else if typeId.contains("epub") || utType.conforms(to: UTType(filenameExtension: "epub") ?? .data) {
                            bestTypeIdentifier = typeId
                            targetExt = "epub"
                            break
                        } else if typeId.contains("cbz") || utType.conforms(to: UTType(filenameExtension: "cbz") ?? .data) {
                            bestTypeIdentifier = typeId
                            targetExt = "cbz"
                            break
                        } else if typeId.contains("cbr") || utType.conforms(to: UTType(filenameExtension: "cbr") ?? .data) {
                            bestTypeIdentifier = typeId
                            targetExt = "cbr"
                            break
                        }
                    }
                    
                    // Fallback to zip/rar/archive
                    if bestTypeIdentifier == nil {
                        for typeId in provider.registeredTypeIdentifiers {
                            guard let utType = UTType(typeId) else { continue }
                            if let ext = targetExtension(for: utType) {
                                bestTypeIdentifier = typeId
                                targetExt = ext
                                break
                            }
                        }
                    }
                    
                    // General fallback to public.data or public.file-url if we can extract extension from suggestedName
                    if bestTypeIdentifier == nil {
                        for typeId in provider.registeredTypeIdentifiers {
                            if typeId == UTType.fileURL.identifier || typeId == UTType.data.identifier || typeId == UTType.item.identifier {
                                if let suggested = provider.suggestedName {
                                    let ext = (suggested as NSString).pathExtension.lowercased()
                                    if ext == "pdf" || ext == "epub" || ext == "cbz" || ext == "cbr" || ext == "zip" || ext == "rar" {
                                        bestTypeIdentifier = typeId
                                        targetExt = ext == "zip" ? "cbz" : (ext == "rar" ? "cbr" : ext)
                                        break
                                    }
                                }
                            }
                        }
                    }
                    
                    guard let typeId = bestTypeIdentifier, let ext = targetExt else {
                        print("No compatible type found in registered identifiers: \(provider.registeredTypeIdentifiers)")
                        continue
                    }
                    
                    // Determine desired filename
                    var filename = provider.suggestedName ?? "shared_file"
                    let extSuffix = "." + ext
                    if !filename.lowercased().hasSuffix(extSuffix.lowercased()) {
                        let baseName = (filename as NSString).deletingPathExtension
                        filename = baseName + extSuffix
                    }
                    
                    var loadedURL: URL? = nil
                    
                    // Method A: Try loadFileRepresentation (safest and supports iCloud / cloud providers)
                    do {
                        loadedURL = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                            provider.loadFileRepresentation(forTypeIdentifier: typeId) { tempURL, error in
                                if let error = error {
                                    continuation.resume(throwing: error)
                                } else if let tempURL = tempURL {
                                    if let sharedURL = self.copyToSharedContainer(tempURL, destFilename: filename) {
                                        continuation.resume(returning: sharedURL)
                                    } else {
                                        continuation.resume(throwing: NSError(domain: "ShareExtension", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to copy file"]))
                                    }
                                } else {
                                    continuation.resume(throwing: NSError(domain: "ShareExtension", code: -1, userInfo: nil))
                                }
                            }
                        }
                    } catch {
                        print("loadFileRepresentation failed for \(filename): \(error.localizedDescription)")
                        
                        // Method B: Fallback to loadItem if loadFileRepresentation failed
                        do {
                            let itemURL = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                                provider.loadItem(forTypeIdentifier: typeId, options: nil) { item, error in
                                    if let error = error {
                                        continuation.resume(throwing: error)
                                    } else if let nsURL = item as? NSURL {
                                        continuation.resume(returning: nsURL as URL)
                                    } else if let nsData = item as? NSData,
                                              let urlString = String(data: nsData as Data, encoding: .utf8),
                                              let url = URL(string: urlString) {
                                        continuation.resume(returning: url)
                                    } else if let nsString = item as? NSString,
                                              let url = URL(string: nsString as String) {
                                        continuation.resume(returning: url)
                                    } else {
                                        continuation.resume(throwing: NSError(domain: "ShareExtension", code: -3, userInfo: [NSLocalizedDescriptionKey: "Item is not a URL"]))
                                    }
                                }
                            }
                            
                            if let sharedURL = self.copyToSharedContainer(itemURL, destFilename: filename) {
                                loadedURL = sharedURL
                            }
                        } catch {
                            print("loadItem fallback failed for \(filename): \(error.localizedDescription)")
                        }
                    }
                    
                    if let finalURL = loadedURL {
                        filesToProcess.append(SharedFile(
                            name: filename,
                            url: finalURL,
                            fileExtension: ext
                        ))
                    }
                }
            }
            
            self.selectedFiles = filesToProcess
            self.isLoading = false
        }
    }
    
    // MARK: - Copy to Shared Container
    
    private func copyToSharedContainer(_ sourceURL: URL, destFilename: String) -> URL? {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.antigravity.ComicToPDF"
        ) else { return nil }
        
        let inboxURL = containerURL.appendingPathComponent("Inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: inboxURL, withIntermediateDirectories: true)
        
        let destURL = inboxURL.appendingPathComponent(destFilename)
        
        // Remove existing file if any
        try? FileManager.default.removeItem(at: destURL)
        
        let accessing = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessing { sourceURL.stopAccessingSecurityScopedResource() } }
        
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
