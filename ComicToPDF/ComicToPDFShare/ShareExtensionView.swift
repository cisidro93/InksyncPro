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
    
    // MARK: - Helpers

    /// Maps a known UTType to the file extension we want to save.
    private func targetExtension(for type: UTType) -> String? {
        if type.conforms(to: .pdf) { return "pdf" }
        let ext = type.preferredFilenameExtension?.lowercased() ?? ""
        switch ext {
        case "pdf":  return "pdf"
        case "epub": return "epub"
        case "cbz":  return "cbz"
        case "cbr":  return "cbr"
        case "zip":  return "cbz"
        case "rar":  return "cbr"
        default: break
        }
        if type.identifier.contains("epub") { return "epub" }
        if type.identifier.contains("cbz")  { return "cbz" }
        if type.identifier.contains("cbr")  { return "cbr" }
        if type.identifier.contains("zip")  { return "cbz" }
        if type.identifier.contains("rar")  { return "cbr" }
        if type != .data && type != .item {
            if let epubUT = UTType("org.idpf.epub-container"), type.conforms(to: epubUT) { return "epub" }
            if type.conforms(to: .zip)     { return "cbz" }
            if type.conforms(to: .archive) { return "cbz" }
        }
        return nil
    }

    /// Derives a file extension from the `suggestedName` of an NSItemProvider.
    private func extensionFromSuggestedName(_ name: String?) -> String? {
        guard let name = name else { return nil }
        let raw = (name as NSString).pathExtension.lowercased()
        switch raw {
        case "pdf":  return "pdf"
        case "epub": return "epub"
        case "cbz":  return "cbz"
        case "cbr":  return "cbr"
        case "zip":  return "cbz"
        case "rar":  return "cbr"
        default:     return nil
        }
    }
    
    /// Inspects the first bytes of a file to identify its format.
    private func detectFileExtension(from url: URL) -> String? {
        guard let fileHandle = try? FileHandle(forReadingFrom: url),
              let data = try? fileHandle.read(upToCount: 200) else { return nil }
        defer { try? fileHandle.close() }
        guard data.count >= 4 else { return nil }

        // ZIP / CBZ / EPUB  (PK\x03\x04)
        if data[0] == 0x50 && data[1] == 0x4B && data[2] == 0x03 && data[3] == 0x04 {
            // Prefer existing extension if it's already correct
            let existing = url.pathExtension.lowercased()
            if existing == "epub" { return "epub" }
            if existing == "cbz"  { return "cbz" }
            // Peek into the archive: EPUB always stores a "mimetype" entry as the first local file
            let header = String(decoding: data.prefix(150), as: UTF8.self)
            if header.contains("mimetype") && (header.contains("epub+zip") || header.contains("epub")) {
                return "epub"
            }
            return "cbz"
        }
        // PDF  (%PDF)
        if data[0] == 0x25 && data[1] == 0x50 && data[2] == 0x44 && data[3] == 0x46 { return "pdf" }
        // RAR / CBR  (Rar!)
        if data[0] == 0x52 && data[1] == 0x61 && data[2] == 0x72 && data[3] == 0x21 { return "cbr" }
        return nil
    }

    // MARK: - Load Shared Files

    private func loadSharedFiles() {
        guard let ctx = extensionContext,
              let inputItems = ctx.inputItems as? [NSExtensionItem] else {
            isLoading = false
            return
        }

        Task { @MainActor in
            var filesToProcess: [SharedFile] = []

            for item in inputItems {
                guard let attachments = item.attachments else { continue }

                for provider in attachments {
                    let registered = provider.registeredTypeIdentifiers
                    let baseName   = provider.suggestedName ?? "shared_file"

                    // ──────────────────────────────────────────────────────────────
                    // STEP 1: Build an ordered list of type identifiers to try.
                    // We attempt every candidate until one successfully provides a file.
                    // Priority: specific format types → file-URL types → data types → anything
                    // ──────────────────────────────────────────────────────────────
                    var candidates: [(typeId: String, hintExt: String?)] = []

                    // 1a. Specific format UTTypes (epub, pdf, cbz, cbr, zip, rar)
                    for typeId in registered {
                        guard let utType = UTType(typeId) else { continue }
                        if let ext = targetExtension(for: utType) {
                            candidates.append((typeId, ext))
                        }
                    }

                    // 1b. If the suggestedName carries a recognisable extension, pair generic
                    //     type IDs with it so we know what extension to use post-load.
                    let nameExt = extensionFromSuggestedName(baseName)
                    let genericFileURLTypes = [UTType.fileURL.identifier, "public.file-url", "com.apple.cocoa.path"]
                    let genericDataTypes    = [UTType.data.identifier, "public.data", UTType.item.identifier, "public.item"]

                    for typeId in registered where genericFileURLTypes.contains(typeId) {
                        candidates.append((typeId, nameExt))   // nameExt may be nil — will rely on magic bytes
                    }
                    for typeId in registered where genericDataTypes.contains(typeId) {
                        candidates.append((typeId, nameExt))
                    }

                    // 1c. Absolute last resort: try anything that's registered
                    for typeId in registered {
                        if !candidates.contains(where: { $0.typeId == typeId }) {
                            candidates.append((typeId, nameExt))
                        }
                    }

                    if candidates.isEmpty {
                        print("[ShareExt] No candidates for provider: \(registered)")
                        continue
                    }

                    // ──────────────────────────────────────────────────────────────
                    // STEP 2: Attempt to load the file using each candidate in order.
                    // ──────────────────────────────────────────────────────────────
                    var loadedURL: URL?   = nil
                    var resolvedExt: String? = nil

                    for candidate in candidates {
                        let typeId  = candidate.typeId
                        let hintExt = candidate.hintExt

                        // Construct a temporary filename. Use the hint if we have one;
                        // otherwise we'll detect the extension from magic bytes after loading.
                        let tempName: String
                        if let h = hintExt {
                            let cleanBase = (baseName as NSString).deletingPathExtension
                            tempName = cleanBase + "." + h
                        } else {
                            tempName = baseName
                        }

                        // --- Method A: loadFileRepresentation ---
                        if let url = await tryLoadFileRepresentation(provider: provider, typeId: typeId, filename: tempName) {
                            loadedURL = url
                            resolvedExt = hintExt ?? detectFileExtension(from: url) ?? url.pathExtension.lowercased().nonEmpty
                            break
                        }

                        // --- Method B: loadItem ---
                        if let url = await tryLoadItem(provider: provider, typeId: typeId, filename: tempName) {
                            loadedURL = url
                            resolvedExt = hintExt ?? detectFileExtension(from: url) ?? url.pathExtension.lowercased().nonEmpty
                            break
                        }
                    }

                    // ──────────────────────────────────────────────────────────────
                    // STEP 3: Validate extension and add to the import list.
                    // ──────────────────────────────────────────────────────────────
                    guard var finalURL = loadedURL else {
                        print("[ShareExt] All candidates failed for \(baseName), registered: \(registered)")
                        continue
                    }

                    // If we still don't know the extension, try magic bytes one more time
                    if resolvedExt == nil || resolvedExt?.isEmpty == true {
                        resolvedExt = detectFileExtension(from: finalURL)
                    }

                    guard let ext = resolvedExt,
                          ["pdf", "epub", "cbz", "cbr"].contains(ext) else {
                        print("[ShareExt] Unrecognised format for \(finalURL.lastPathComponent) – removing.")
                        try? FileManager.default.removeItem(at: finalURL)
                        continue
                    }

                    // Rename to ensure the correct extension is present
                    let cleanBase    = (baseName as NSString).deletingPathExtension
                    let finalName    = cleanBase + "." + ext
                    let renamedURL   = finalURL.deletingLastPathComponent().appendingPathComponent(finalName)

                    // Only move if paths differ (avoids error when they're identical)
                    if renamedURL.path != finalURL.path {
                        try? FileManager.default.removeItem(at: renamedURL)
                        do {
                            try FileManager.default.moveItem(at: finalURL, to: renamedURL)
                            finalURL = renamedURL
                        } catch {
                            print("[ShareExt] Rename failed for \(finalURL.lastPathComponent): \(error)")
                            // Keep the original path — it's still usable
                        }
                    } else {
                        finalURL = renamedURL
                    }

                    filesToProcess.append(SharedFile(
                        name: finalURL.lastPathComponent,
                        url: finalURL,
                        fileExtension: ext
                    ))
                }
            }

            self.selectedFiles = filesToProcess
            self.isLoading = false
        }
    }

    // MARK: - Low-level load helpers

    private func tryLoadFileRepresentation(provider: NSItemProvider, typeId: String, filename: String) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: typeId) { tempURL, error in
                guard error == nil, let tempURL = tempURL else {
                    continuation.resume(returning: nil)
                    return
                }
                let result = self.copyToSharedContainer(tempURL, destFilename: filename)
                continuation.resume(returning: result)
            }
        }
    }

    private func tryLoadItem(provider: NSItemProvider, typeId: String, filename: String) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: typeId, options: nil) { item, error in
                guard error == nil else { continuation.resume(returning: nil); return }
                
                var sourceURL: URL? = nil
                var isRawData = false
                var rawData: Data? = nil
                
                if let nsURL = item as? NSURL {
                    sourceURL = nsURL as URL
                } else if let url = item as? URL {
                    sourceURL = url
                } else if let nsData = item as? NSData {
                    let data = nsData as Data
                    if let str = String(data: data, encoding: .utf8),
                       let url = URL(string: str),
                       url.scheme != nil {
                        sourceURL = url
                    } else {
                        // Raw binary payload
                        isRawData = true
                        rawData = data
                    }
                } else if let nsString = item as? NSString {
                    let str = nsString as String
                    if let url = URL(string: str), url.scheme != nil {
                        sourceURL = url
                    }
                }
                
                if let src = sourceURL {
                    let result = self.copyToSharedContainer(src, destFilename: filename)
                    continuation.resume(returning: result)
                } else if isRawData, let data = rawData {
                    let result = self.writeRawDataToSharedContainer(data, destFilename: filename)
                    continuation.resume(returning: result)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
    
    // MARK: - Copy to Shared Container
    
    nonisolated private func copyToSharedContainer(_ sourceURL: URL, destFilename: String) -> URL? {
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
        
        var copySuccess = false
        let coordinator = NSFileCoordinator()
        var coordinatorError: NSError?
        
        coordinator.coordinate(readingItemAt: sourceURL, options: [], error: &coordinatorError) { coordinatedURL in
            do {
                try FileManager.default.copyItem(at: coordinatedURL, to: destURL)
                copySuccess = true
            } catch {
                print("[ShareExt] Coordinated copy failed: \(error.localizedDescription)")
            }
        }
        
        if copySuccess {
            return destURL
        } else {
            // Fallback to uncoordinated copy
            do {
                try FileManager.default.copyItem(at: sourceURL, to: destURL)
                return destURL
            } catch {
                print("[ShareExt] Fallback copy failed: \(error.localizedDescription)")
                return nil
            }
        }
    }
    
    nonisolated private func writeRawDataToSharedContainer(_ data: Data, destFilename: String) -> URL? {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.antigravity.ComicToPDF"
        ) else { return nil }
        
        let inboxURL = containerURL.appendingPathComponent("Inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: inboxURL, withIntermediateDirectories: true)
        
        let destURL = inboxURL.appendingPathComponent(destFilename)
        try? FileManager.default.removeItem(at: destURL)
        
        do {
            try data.write(to: destURL, options: .atomic)
            return destURL
        } catch {
            print("[ShareExt] Failed to write raw binary data: \(error.localizedDescription)")
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

// MARK: - String helpers
private extension String {
    /// Returns nil if the string is empty, otherwise self. Useful for optional-chaining path extensions.
    var nonEmpty: String? { isEmpty ? nil : self }
}
