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
    
    // Supported extensions across all formats
    nonisolated static let supportedExtensions: Set<String> = [
        "pdf", "epub", "cbz", "cbr", "cb7", "cbt", "zip", "rar", "7z", "tar"
    ]
    
    var body: some View {
        NavigationView {
            ZStack {
                Color(.systemGroupedBackground)
                    .ignoresSafeArea()
                
                VStack(spacing: 0) {
                    if isLoading {
                        Spacer()
                        VStack(spacing: 16) {
                            ProgressView()
                                .scaleEffect(1.3)
                            Text("Loading shared files...")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    } else if selectedFiles.isEmpty {
                        Spacer()
                        VStack(spacing: 16) {
                            Image(systemName: "doc.questionmark")
                                .font(.system(size: 60))
                                .foregroundColor(.secondary)
                            Text("No Compatible Files Found")
                                .font(.headline)
                            Text("Share PDF, EPUB, CBZ, CBR, CB7, or ZIP files to import directly into Inksync Pro.")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 32)
                        }
                        Spacer()
                    } else {
                        // File list
                        List {
                            Section {
                                ForEach(selectedFiles) { file in
                                    HStack(spacing: 12) {
                                        Image(systemName: iconForExtension(file.fileExtension))
                                            .font(.title2)
                                            .foregroundColor(.orange)
                                            .frame(width: 32)
                                        
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(file.name)
                                                .font(.subheadline)
                                                .fontWeight(.medium)
                                                .lineLimit(2)
                                            
                                            Text(file.fileExtension.uppercased())
                                                .font(.caption2)
                                                .fontWeight(.semibold)
                                                .foregroundColor(.orange)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Color.orange.opacity(0.15))
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
                                Text("\(selectedFiles.count) file\(selectedFiles.count > 1 ? "s" : "") ready to import")
                            }
                        }
                        .listStyle(.insetGrouped)
                        
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
                                HStack(spacing: 8) {
                                    Image(systemName: "arrow.down.doc.fill")
                                    Text("Import to Inksync Pro Library")
                                        .fontWeight(.semibold)
                                }
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Color.orange)
                                .cornerRadius(12)
                                .shadow(color: Color.orange.opacity(0.3), radius: 6, y: 3)
                            }
                        }
                        .padding()
                        .background(Color(.secondarySystemGroupedBackground))
                    }
                }
                
                // Processing overlay
                if isProcessing {
                    Color.black.opacity(0.5)
                        .ignoresSafeArea()
                    
                    VStack(spacing: 20) {
                        ProgressView(value: processingProgress)
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(1.5)
                        
                        Text("Importing to Library...")
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
                    .padding(32)
                    .background(RoundedRectangle(cornerRadius: 20).fill(Color.black.opacity(0.85)))
                }
                
                // Success overlay
                if showingSuccess {
                    Color.black.opacity(0.5)
                        .ignoresSafeArea()
                    
                    VStack(spacing: 20) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 56))
                            .foregroundColor(.green)
                        
                        Text("Import Complete!")
                            .font(.headline)
                            .foregroundColor(.white)
                        
                        Text("\(processedCount) item\(processedCount > 1 ? "s" : "") added to your Library")
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.8))
                        
                        Button("Open Inksync Pro") {
                            onDismiss()
                        }
                        .foregroundColor(.white)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 12)
                        .background(Color.green)
                        .cornerRadius(10)
                    }
                    .padding(32)
                    .background(RoundedRectangle(cornerRadius: 20).fill(Color.black.opacity(0.85)))
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
    
    private func iconForExtension(_ ext: String) -> String {
        switch ext.lowercased() {
        case "pdf": return "doc.richtext.fill"
        case "epub": return "book.fill"
        case "cbz", "cbr", "cb7", "cbt": return "doc.zipper.fill"
        default: return "doc.fill"
        }
    }
    
    // MARK: - Format & Extension Detection

    /// Maps a known UTType to the canonical file extension.
    nonisolated static func targetExtension(for type: UTType) -> String? {
        if type.conforms(to: .pdf) { return "pdf" }
        if type.conforms(to: .epub) { return "epub" }
        if type.conforms(to: .zip) { return "cbz" }
        if type.conforms(to: .archive) { return "cbz" }
        
        let ext = type.preferredFilenameExtension?.lowercased() ?? ""
        if supportedExtensions.contains(ext) {
            return ext == "zip" ? "cbz" : (ext == "rar" ? "cbr" : ext)
        }
        
        let id = type.identifier.lowercased()
        if id.contains("pdf") { return "pdf" }
        if id.contains("epub") { return "epub" }
        if id.contains("cbz") || id.contains("comic") { return "cbz" }
        if id.contains("cbr") { return "cbr" }
        if id.contains("cb7") || id.contains("7z") { return "cb7" }
        if id.contains("cbt") || id.contains("tar") { return "cbt" }
        if id.contains("zip") { return "cbz" }
        if id.contains("rar") { return "cbr" }
        
        return nil
    }

    /// Derives a file extension from a filename or suggested name.
    nonisolated static func extensionFromSuggestedName(_ name: String?) -> String? {
        guard let name = name else { return nil }
        let raw = (name as NSString).pathExtension.lowercased()
        switch raw {
        case "pdf": return "pdf"
        case "epub": return "epub"
        case "cbz": return "cbz"
        case "cbr": return "cbr"
        case "cb7", "7z": return "cb7"
        case "cbt", "tar": return "cbt"
        case "zip": return "cbz"
        case "rar": return "cbr"
        default: return nil
        }
    }
    
    /// Inspects the magic bytes of a file to reliably identify its true format.
    nonisolated static func detectFileExtension(from url: URL) -> String? {
        let existingExt = url.pathExtension.lowercased()
        
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        
        guard let fileHandle = try? FileHandle(forReadingFrom: url),
              let data = try? fileHandle.read(upToCount: 4096) else {
            return supportedExtensions.contains(existingExt) ? existingExt : nil
        }
        defer { try? fileHandle.close() }
        
        guard data.count >= 4 else {
            return supportedExtensions.contains(existingExt) ? existingExt : nil
        }

        // PDF (%PDF -> 0x25 0x50 0x44 0x46)
        if data[0] == 0x25 && data[1] == 0x50 && data[2] == 0x44 && data[3] == 0x46 {
            return "pdf"
        }
        // RAR / CBR (Rar! -> 0x52 0x61 0x72 0x21 or 0x52 0x61 0x72 0x20)
        if data[0] == 0x52 && data[1] == 0x61 && data[2] == 0x72 && (data[3] == 0x21 || data[3] == 0x20) {
            return "cbr"
        }
        // 7-Zip / CB7 (7z -> 0x37 0x7A 0xBC 0xAF 0x27 0x1C)
        if data.count >= 6 && data[0] == 0x37 && data[1] == 0x7A && data[2] == 0xBC && data[3] == 0xAF && data[4] == 0x27 && data[5] == 0x1C {
            return "cb7"
        }

        // ZIP / CBZ / EPUB (PK\x03\x04 or PK\x05\x06 or PK\x07\x08)
        if (data[0] == 0x50 && data[1] == 0x4B && data[2] == 0x03 && data[3] == 0x04) ||
           (data[0] == 0x50 && data[1] == 0x4B && data[2] == 0x05 && data[3] == 0x06) {
            if existingExt == "epub" { return "epub" }
            if existingExt == "cbz"  { return "cbz" }
            
            // Check if archive contains EPUB mimetype
            let header = String(decoding: data.prefix(1000), as: UTF8.self)
            if header.contains("mimetype") && (header.contains("epub+zip") || header.contains("epub")) {
                return "epub"
            }
            return "cbz"
        }

        // TAR / CBT (ustar)
        if data.count >= 265 {
            let ustarRange = data[257..<262]
            if let ustarStr = String(data: ustarRange, encoding: .ascii), ustarStr == "ustar" {
                return "cbt"
            }
        }

        if supportedExtensions.contains(existingExt) {
            return existingExt == "zip" ? "cbz" : (existingExt == "rar" ? "cbr" : existingExt)
        }

        return nil
    }

    // MARK: - Load Shared Files

    @State private var sessionStagingID: String = UUID().uuidString

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
                    let baseName = provider.suggestedName ?? "SharedDocument_\(UUID().uuidString.prefix(6))"

                    // Build priority list of UTIs: registered first, then fallbacks
                    var candidateTypes: [String] = []
                    for typeId in registered {
                        if !candidateTypes.contains(typeId) {
                            candidateTypes.append(typeId)
                        }
                    }

                    let fallbackTypes = [
                        UTType.fileURL.identifier,
                        "public.file-url",
                        "com.adobe.pdf",
                        UTType.pdf.identifier,
                        "org.idpf.epub-container",
                        UTType.epub.identifier,
                        "com.macrabbit.comicbookzip",
                        "com.antigravity.cbz",
                        UTType.zip.identifier,
                        "com.macrabbit.comicbookrar",
                        "com.antigravity.cbr",
                        "org.7-zip.7-zip-archive",
                        "public.archive",
                        "public.zip-archive",
                        "public.data",
                        "public.content",
                        "public.item",
                        UTType.url.identifier,
                        "public.url"
                    ]
                    for typeId in fallbackTypes {
                        if !candidateTypes.contains(typeId) {
                            candidateTypes.append(typeId)
                        }
                    }

                    var loadedURL: URL? = nil
                    var detectedExt: String? = nil

                    for typeId in candidateTypes {
                        guard provider.hasItemConformingToTypeIdentifier(typeId) else { continue }

                        let hintExt = Self.extensionFromSuggestedName(baseName)
                            ?? UTType(typeId).flatMap { Self.targetExtension(for: $0) }
                        let tempName: String
                        if let h = hintExt {
                            let clean = (baseName as NSString).deletingPathExtension
                            tempName = "\(clean).\(h)"
                        } else {
                            tempName = baseName
                        }

                        if let url = await Self.tryLoadItem(provider: provider, typeId: typeId, filename: tempName) {
                            loadedURL = url
                            detectedExt = Self.detectFileExtension(from: url) ?? hintExt ?? url.pathExtension.lowercased()
                            break
                        }
                        if let url = await Self.tryLoadFileRepresentation(provider: provider, typeId: typeId, filename: tempName) {
                            loadedURL = url
                            detectedExt = Self.detectFileExtension(from: url) ?? hintExt ?? url.pathExtension.lowercased()
                            break
                        }
                        if let url = await Self.tryLoadInPlaceFileRepresentation(provider: provider, typeId: typeId, filename: tempName) {
                            loadedURL = url
                            detectedExt = Self.detectFileExtension(from: url) ?? hintExt ?? url.pathExtension.lowercased()
                            break
                        }
                        if let url = await Self.tryLoadDataRepresentation(provider: provider, typeId: typeId, filename: tempName) {
                            loadedURL = url
                            detectedExt = Self.detectFileExtension(from: url) ?? hintExt ?? url.pathExtension.lowercased()
                            break
                        }
                    }

                    guard var finalURL = loadedURL else {
                        print("[ShareExt] All loader methods failed for item with types: \(registered)")
                        continue
                    }

                    let ext = (detectedExt ?? Self.detectFileExtension(from: finalURL) ?? finalURL.pathExtension.lowercased()).lowercased()
                    let targetExt: String
                    if ext == "zip" {
                        targetExt = "cbz"
                    } else if ext == "rar" {
                        targetExt = "cbr"
                    } else if Self.supportedExtensions.contains(ext) {
                        targetExt = ext
                    } else {
                        targetExt = Self.detectFileExtension(from: finalURL) ?? (Self.supportedExtensions.contains(ext) ? ext : "pdf")
                    }

                    let cleanBase = (baseName as NSString).deletingPathExtension
                    let properFilename = "\(cleanBase).\(targetExt)"
                    let targetURL = finalURL.deletingLastPathComponent().appendingPathComponent(properFilename)
                    if targetURL.path != finalURL.path {
                        try? FileManager.default.removeItem(at: targetURL)
                        try? FileManager.default.moveItem(at: finalURL, to: targetURL)
                        finalURL = targetURL
                    }

                    filesToProcess.append(SharedFile(
                        name: finalURL.lastPathComponent,
                        url: finalURL,
                        fileExtension: targetExt
                    ))
                }
            }

            self.selectedFiles = filesToProcess
            self.isLoading = false
        }
    }

    // MARK: - Async Item Loaders

    nonisolated static func tryLoadItem(provider: NSItemProvider, typeId: String, filename: String) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: typeId, options: nil) { item, error in
                guard error == nil, let item = item else {
                    continuation.resume(returning: nil)
                    return
                }

                if let url = item as? URL {
                    if url.isFileURL {
                        let res = copyToSharedContainer(url, destFilename: filename)
                        continuation.resume(returning: res)
                    } else if url.scheme == "http" || url.scheme == "https" {
                        // Remote download
                        Task.detached(priority: .userInitiated) {
                            if let (data, _) = try? await URLSession.shared.data(from: url) {
                                let res = writeRawDataToSharedContainer(data, destFilename: filename)
                                continuation.resume(returning: res)
                            } else {
                                continuation.resume(returning: nil)
                            }
                        }
                    } else {
                        continuation.resume(returning: nil)
                    }
                } else if let nsURL = item as? NSURL {
                    let u = nsURL as URL
                    if u.isFileURL {
                        let res = copyToSharedContainer(u, destFilename: filename)
                        continuation.resume(returning: res)
                    } else {
                        continuation.resume(returning: nil)
                    }
                } else if let data = item as? Data {
                    let res = writeRawDataToSharedContainer(data, destFilename: filename)
                    continuation.resume(returning: res)
                } else if let nsData = item as? NSData {
                    let res = writeRawDataToSharedContainer(nsData as Data, destFilename: filename)
                    continuation.resume(returning: res)
                } else if let str = item as? String, let parsedURL = URL(string: str), parsedURL.isFileURL {
                    let res = copyToSharedContainer(parsedURL, destFilename: filename)
                    continuation.resume(returning: res)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    nonisolated static func tryLoadFileRepresentation(provider: NSItemProvider, typeId: String, filename: String) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: typeId) { tempURL, error in
                guard error == nil, let tempURL = tempURL else {
                    continuation.resume(returning: nil)
                    return
                }
                let result = copyToSharedContainer(tempURL, destFilename: filename)
                continuation.resume(returning: result)
            }
        }
    }

    nonisolated static func tryLoadInPlaceFileRepresentation(provider: NSItemProvider, typeId: String, filename: String) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadInPlaceFileRepresentation(forTypeIdentifier: typeId) { fileURL, _, error in
                guard error == nil, let fileURL = fileURL else {
                    continuation.resume(returning: nil)
                    return
                }
                let result = copyToSharedContainer(fileURL, destFilename: filename)
                continuation.resume(returning: result)
            }
        }
    }

    nonisolated static func tryLoadDataRepresentation(provider: NSItemProvider, typeId: String, filename: String) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: typeId) { data, error in
                guard error == nil, let data = data, !data.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }
                let result = writeRawDataToSharedContainer(data, destFilename: filename)
                continuation.resume(returning: result)
            }
        }
    }

    // MARK: - App Group File Operations

    nonisolated static func getAppGroupContainers() -> [URL] {
        var containers: [URL] = []
        let groupIDs = [
            "group.com.antigravity.ComicToPDF",
            "group.com.antigravity.inksync",
            "group.com.antigravity.InksyncPro"
        ]
        for id in groupIDs {
            if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) {
                if !containers.contains(container) {
                    containers.append(container)
                }
            }
        }
        return containers
    }

    nonisolated static func copyToSharedContainer(_ sourceURL: URL, destFilename: String) -> URL? {
        let containers = getAppGroupContainers()
        guard !containers.isEmpty else {
            print("[ShareExt] Error: No shared App Group container accessible.")
            return nil
        }
        
        let cleanDest = destFilename.replacingOccurrences(of: ".tmp", with: "")
        let accessing = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessing { sourceURL.stopAccessingSecurityScopedResource() } }
        
        var primaryResultURL: URL? = nil
        
        for container in containers {
            // Stage into isolated session directory so it is never deleted by markForConversion
            let stagingURL = container.appendingPathComponent("ShareStaging", isDirectory: true)
            try? FileManager.default.createDirectory(at: stagingURL, withIntermediateDirectories: true)
            let destURL = stagingURL.appendingPathComponent(cleanDest)
            try? FileManager.default.removeItem(at: destURL)
            
            do {
                try FileManager.default.copyItem(at: sourceURL, to: destURL)
                if primaryResultURL == nil { primaryResultURL = destURL }
            } catch {
                if let data = try? Data(contentsOf: sourceURL) {
                    try? data.write(to: destURL, options: .atomic)
                    if primaryResultURL == nil { primaryResultURL = destURL }
                }
            }
        }
        
        return primaryResultURL
    }

    nonisolated static func writeRawDataToSharedContainer(_ data: Data, destFilename: String) -> URL? {
        let containers = getAppGroupContainers()
        guard !containers.isEmpty else {
            print("[ShareExt] Error: No shared App Group container accessible.")
            return nil
        }
        
        var primaryResultURL: URL? = nil
        for container in containers {
            let stagingURL = container.appendingPathComponent("ShareStaging", isDirectory: true)
            try? FileManager.default.createDirectory(at: stagingURL, withIntermediateDirectories: true)
            let destURL = stagingURL.appendingPathComponent(destFilename)
            try? FileManager.default.removeItem(at: destURL)
            
            if (try? data.write(to: destURL, options: .atomic)) != nil {
                if primaryResultURL == nil { primaryResultURL = destURL }
            }
        }
        return primaryResultURL
    }

    // MARK: - Process and Mark for Library

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
                    try markForConversion(file)
                    
                    await MainActor.run {
                        if let idx = selectedFiles.firstIndex(where: { $0.id == file.id }) {
                            selectedFiles[idx].isProcessed = true
                        }
                        processedCount += 1
                    }
                } catch {
                    await MainActor.run {
                        errorMessage = "Failed to stage \(file.name)"
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
    
    private func markForConversion(_ file: SharedFile) throws {
        let containers = Self.getAppGroupContainers()
        guard !containers.isEmpty else { throw ShareError.noContainer }

        // Bug 3 fix: Validate source file ONCE before the container loop.
        // Previously the guard was INSIDE the loop with `continue`, which skips
        // to the next container rather than throwing. Since file.url points into
        // the first container's ShareStaging/, the fileExists check always fails
        // for subsequent containers — silently writing nothing to PendingConversions.
        guard FileManager.default.fileExists(atPath: file.url.path) else {
            print("[ShareExt] Error: Source file does not exist at \(file.url.path)")
            throw ShareError.copyFailed
        }

        for container in containers {
            let pendingURL = container.appendingPathComponent("PendingConversions", isDirectory: true)
            let inboxURL = container.appendingPathComponent("Inbox", isDirectory: true)
            try? FileManager.default.createDirectory(at: pendingURL, withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(at: inboxURL, withIntermediateDirectories: true)

            let manifest = ConversionManifest(
                sourceFile: file.name,
                dateAdded: Date(),
                status: .pending
            )
            let manifestURL = pendingURL.appendingPathComponent("\(file.name).manifest.json")
            if let data = try? JSONEncoder().encode(manifest) {
                try? data.write(to: manifestURL)
            }

            let destPending = pendingURL.appendingPathComponent(file.name)
            let destInbox = inboxURL.appendingPathComponent(file.name)

            if file.url.path != destPending.path {
                try? FileManager.default.removeItem(at: destPending)
                try FileManager.default.copyItem(at: file.url, to: destPending)
            }
            if file.url.path != destInbox.path {
                try? FileManager.default.removeItem(at: destInbox)
                try FileManager.default.copyItem(at: file.url, to: destInbox)
            }
        }
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

