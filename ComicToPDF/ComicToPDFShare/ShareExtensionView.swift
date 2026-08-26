import SwiftUI
import UniformTypeIdentifiers

struct ShareExtensionView: View {
    let extensionContext: NSExtensionContext?
    var onCancel: () -> Void = {}
    var onOpenApp: () -> Void = {}
    
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
        NavigationStack {
            ZStack {
                // Rich Obsidian Background with ambient gradient glow
                Color(red: 0.05, green: 0.05, blue: 0.07)
                    .ignoresSafeArea()

                RadialGradient(
                    colors: [Color(red: 0.15, green: 0.78, blue: 0.45).opacity(0.12), Color.clear],
                    center: .topTrailing,
                    startRadius: 40,
                    endRadius: 360
                )
                .ignoresSafeArea()

                RadialGradient(
                    colors: [Color(red: 0.38, green: 0.30, blue: 0.95).opacity(0.10), Color.clear],
                    center: .bottomLeading,
                    startRadius: 60,
                    endRadius: 400
                )
                .ignoresSafeArea()

                VStack(spacing: 0) {
                    if isLoading {
                        Spacer()
                        VStack(spacing: 18) {
                            ProgressView()
                                .scaleEffect(1.4)
                                .tint(Color(red: 0.15, green: 0.78, blue: 0.45))
                            Text("Loading shared files...")
                                .font(.system(size: 15, weight: .medium, design: .rounded))
                                .foregroundColor(.white.opacity(0.7))
                        }
                        Spacer()
                    } else if selectedFiles.isEmpty {
                        Spacer()
                        VStack(spacing: 18) {
                            Image(systemName: "doc.questionmark.fill")
                                .font(.system(size: 56))
                                .foregroundStyle(
                                    LinearGradient(
                                        colors: [.orange, .pink],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .shadow(color: .orange.opacity(0.3), radius: 12)

                            Text("No Compatible Files Found")
                                .font(.system(size: 18, weight: .bold, design: .rounded))
                                .foregroundColor(.white)

                            Text("Share PDF, EPUB, CBZ, CBR, CB7, or ZIP files to import directly into your InkSync Pro Library.")
                                .font(.system(size: 13, weight: .regular, design: .rounded))
                                .foregroundColor(.white.opacity(0.6))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 36)
                        }
                        Spacer()
                    } else {
                        // File list
                        ScrollView {
                            VStack(spacing: 12) {
                                // Header Pill
                                HStack {
                                    Text("\(selectedFiles.count) FILE\(selectedFiles.count > 1 ? "S" : "") READY TO IMPORT")
                                        .font(.system(size: 11, weight: .bold, design: .rounded))
                                        .foregroundColor(Color(red: 0.15, green: 0.78, blue: 0.45))
                                    Spacer()
                                }
                                .padding(.horizontal, 20)
                                .padding(.top, 16)

                                ForEach(selectedFiles) { file in
                                    HStack(spacing: 14) {
                                        ZStack {
                                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                .fill(iconBackgroundColor(for: file.fileExtension).opacity(0.18))
                                                .frame(width: 44, height: 44)
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                        .stroke(iconBackgroundColor(for: file.fileExtension).opacity(0.35), lineWidth: 1)
                                                )

                                            Image(systemName: iconForExtension(file.fileExtension))
                                                .font(.system(size: 20, weight: .semibold))
                                                .foregroundColor(iconBackgroundColor(for: file.fileExtension))
                                        }

                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(file.name)
                                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                                                .foregroundColor(.white)
                                                .lineLimit(2)

                                            Text(file.fileExtension.uppercased())
                                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                                .foregroundColor(iconBackgroundColor(for: file.fileExtension))
                                                .padding(.horizontal, 7)
                                                .padding(.vertical, 2)
                                                .background(iconBackgroundColor(for: file.fileExtension).opacity(0.15), in: Capsule())
                                        }

                                        Spacer()

                                        if file.isProcessed {
                                            Image(systemName: "checkmark.circle.fill")
                                                .font(.system(size: 22))
                                                .foregroundColor(Color(red: 0.15, green: 0.78, blue: 0.45))
                                        }
                                    }
                                    .padding(14)
                                    .background(.ultraThinMaterial)
                                    .background(Color.white.opacity(0.04))
                                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                                    )
                                    .padding(.horizontal, 16)
                                }
                            }
                            .padding(.bottom, 100)
                        }

                        // Bottom Action Dock
                        VStack(spacing: 10) {
                            if let error = errorMessage {
                                HStack(spacing: 6) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundColor(.red)
                                    Text(error)
                                        .font(.system(size: 12, weight: .medium, design: .rounded))
                                        .foregroundColor(.red)
                                }
                                .padding(.horizontal, 16)
                            }

                            Button(action: processFiles) {
                                HStack(spacing: 8) {
                                    Image(systemName: "arrow.down.doc.fill")
                                        .font(.system(size: 15, weight: .bold))
                                    Text("Import to InkSync Pro Library")
                                        .font(.system(size: 15, weight: .bold, design: .rounded))
                                }
                                .foregroundColor(.black)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 15)
                                .background(
                                    LinearGradient(
                                        colors: [Color(red: 0.20, green: 0.88, blue: 0.52), Color(red: 0.10, green: 0.70, blue: 0.38)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                                )
                                .shadow(color: Color(red: 0.15, green: 0.78, blue: 0.45).opacity(0.4), radius: 10, y: 4)
                            }
                            .padding(.horizontal, 16)
                            .padding(.bottom, 12)
                        }
                        .background(.ultraThinMaterial)
                        .background(Color.black.opacity(0.6))
                    }
                }

                // Processing Overlay
                if isProcessing {
                    Color.black.opacity(0.65)
                        .ignoresSafeArea()

                    VStack(spacing: 20) {
                        ProgressView(value: processingProgress)
                            .progressViewStyle(CircularProgressViewStyle(tint: Color(red: 0.15, green: 0.78, blue: 0.45)))
                            .scaleEffect(1.6)

                        Text("Importing to Library...")
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                            .foregroundColor(.white)

                        Text(currentFileName)
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundColor(.white.opacity(0.75))
                            .lineLimit(1)

                        Text("\(Int(processingProgress * 100))%")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundColor(Color(red: 0.15, green: 0.78, blue: 0.45))
                    }
                    .padding(32)
                    .background(.ultraThinMaterial)
                    .background(Color.black.opacity(0.85))
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(Color.white.opacity(0.18), lineWidth: 1)
                    )
                }

                // Success Overlay
                if showingSuccess {
                    Color.black.opacity(0.65)
                        .ignoresSafeArea()

                    VStack(spacing: 18) {
                        ZStack {
                            Circle()
                                .fill(Color(red: 0.15, green: 0.78, blue: 0.45).opacity(0.2))
                                .frame(width: 80, height: 80)
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 54))
                                .foregroundColor(Color(red: 0.15, green: 0.78, blue: 0.45))
                        }

                        Text("Import Complete!")
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundColor(.white)

                        Text("\(processedCount) item\(processedCount > 1 ? "s" : "") added to your Library")
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundColor(.white.opacity(0.8))

                        Button(action: onOpenApp) {
                            HStack(spacing: 6) {
                                Text("Open InkSync Pro")
                                    .font(.system(size: 15, weight: .bold, design: .rounded))
                                Image(systemName: "arrow.right.circle.fill")
                                    .font(.system(size: 16))
                            }
                            .foregroundColor(.black)
                            .padding(.horizontal, 28)
                            .padding(.vertical, 13)
                            .background(
                                LinearGradient(
                                    colors: [Color(red: 0.20, green: 0.88, blue: 0.52), Color(red: 0.10, green: 0.70, blue: 0.38)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                in: Capsule()
                            )
                            .shadow(color: Color(red: 0.15, green: 0.78, blue: 0.45).opacity(0.4), radius: 10, y: 4)
                        }
                    }
                    .padding(32)
                    .background(.ultraThinMaterial)
                    .background(Color.black.opacity(0.85))
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(Color.white.opacity(0.2), lineWidth: 1)
                    )
                }
            }
            .navigationTitle("InkSync Pro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                    }
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.8))
                }
            }
        }
        .onAppear {
            loadSharedFiles()
        }
    }

    private func iconBackgroundColor(for ext: String) -> Color {
        switch ext.lowercased() {
        case "pdf": return Color(red: 1.0, green: 0.35, blue: 0.35)
        case "epub": return Color(red: 0.35, green: 0.65, blue: 1.0)
        case "cbz", "cbr", "cb7", "cbt": return Color(red: 1.0, green: 0.65, blue: 0.2)
        default: return Color(red: 0.15, green: 0.78, blue: 0.45)
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
        Task { @MainActor in
            var foundItems: [NSExtensionItem] = []

            // Retry loop up to 5 times (total ~1 second) if extensionContext.inputItems takes time to populate
            for attempt in 0..<5 {
                if let ctx = extensionContext,
                   let items = ctx.inputItems as? [NSExtensionItem],
                   !items.isEmpty {
                    let hasAttachments = items.contains { ($0.attachments?.count ?? 0) > 0 }
                    if hasAttachments {
                        foundItems = items
                        break
                    }
                }
                if attempt < 4 {
                    try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
                }
            }

            guard !foundItems.isEmpty else {
                isLoading = false
                return
            }

            var filesToProcess: [SharedFile] = []

            for item in foundItems {
                guard let attachments = item.attachments else { continue }

                for provider in attachments {
                    let registered = provider.registeredTypeIdentifiers
                    let baseName = provider.suggestedName ?? "SharedDocument_\(UUID().uuidString.prefix(6))"

                    // Try registered type identifiers first!
                    var candidateTypes: [String] = registered
                    let fallbackTypes = [
                        UTType.data.identifier,
                        UTType.item.identifier,
                        UTType.content.identifier,
                        UTType.pdf.identifier,
                        "com.adobe.pdf",
                        UTType.epub.identifier,
                        "org.idpf.epub-container",
                        UTType.fileURL.identifier,
                        "public.file-url",
                        "com.macrabbit.comicbookzip",
                        "com.antigravity.cbz",
                        UTType.zip.identifier,
                        "com.macrabbit.comicbookrar",
                        "com.antigravity.cbr",
                        "org.7-zip.7-zip-archive",
                        "public.archive",
                        "public.zip-archive",
                        "public.data"
                    ]
                    for fallback in fallbackTypes {
                        if !candidateTypes.contains(fallback) {
                            candidateTypes.append(fallback)
                        }
                    }

                    var loadedURL: URL? = nil
                    var detectedExt: String? = nil

                    for typeId in candidateTypes {
                        guard provider.hasItemConformingToTypeIdentifier(typeId) || registered.contains(typeId) else { continue }

                        let hintExt = Self.extensionFromSuggestedName(baseName)
                            ?? UTType(typeId).flatMap { Self.targetExtension(for: $0) }
                        let tempName: String
                        if let h = hintExt {
                            let clean = (baseName as NSString).deletingPathExtension
                            tempName = "\(clean).\(h)"
                        } else {
                            tempName = baseName
                        }

                        // Method 1: loadFileRepresentation (modern Apple standard for files from Files app, Mail, Safari)
                        if let url = await Self.tryLoadFileRepresentation(provider: provider, typeId: typeId, filename: tempName) {
                            loadedURL = url
                            detectedExt = Self.detectFileExtension(from: url) ?? hintExt ?? url.pathExtension.lowercased()
                            break
                        }

                        // Method 2: loadInPlaceFileRepresentation
                        if let url = await Self.tryLoadInPlaceFileRepresentation(provider: provider, typeId: typeId, filename: tempName) {
                            loadedURL = url
                            detectedExt = Self.detectFileExtension(from: url) ?? hintExt ?? url.pathExtension.lowercased()
                            break
                        }

                        // Method 3: loadItem (handles URLs, NSURLs, file-urls)
                        if let url = await Self.tryLoadItem(provider: provider, typeId: typeId, filename: tempName) {
                            loadedURL = url
                            detectedExt = Self.detectFileExtension(from: url) ?? hintExt ?? url.pathExtension.lowercased()
                            break
                        }

                        // Method 4: loadDataRepresentation (in-memory fallback)
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

                    // Preserve the authentic original filename from finalURL / source item
                    let sourceFilename = finalURL.lastPathComponent
                    let effectiveBase: String
                    if !sourceFilename.isEmpty && !sourceFilename.hasPrefix("SharedDocument_") && !sourceFilename.hasPrefix("temp_") && !sourceFilename.hasPrefix("tmp_") {
                        effectiveBase = (sourceFilename as NSString).deletingPathExtension
                    } else if let suggested = provider.suggestedName, !suggested.isEmpty, !suggested.hasPrefix("SharedDocument_") {
                        effectiveBase = (suggested as NSString).deletingPathExtension
                    } else {
                        effectiveBase = (baseName as NSString).deletingPathExtension
                    }

                    let properFilename = "\(effectiveBase).\(targetExt)"
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

            // Immediately pre-stage all discovered files into App Group Inbox & PendingConversions
            for file in filesToProcess {
                try? self.markForConversion(file)
            }
            
            let appGroupIDs = [
                "group.com.antigravity.InksyncPro",
                "group.com.antigravity.ComicToPDF",
                "group.com.antigravity.inksync"
            ]
            let timestamp = Date().timeIntervalSince1970
            for gid in appGroupIDs {
                if let ud = UserDefaults(suiteName: gid) {
                    ud.set(timestamp, forKey: "pendingShareImportTimestamp")
                    ud.set(true, forKey: "hasPendingShareImport")
                    ud.synchronize()
                }
            }

            self.selectedFiles = filesToProcess
            self.isLoading = false
        }
    }

    // MARK: - Async Item Loaders

    @MainActor
    static func tryLoadItem(provider: NSItemProvider, typeId: String, filename: String) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: typeId, options: nil) { item, error in
                guard error == nil, let item = item else {
                    continuation.resume(returning: nil)
                    return
                }

                if let url = item as? URL {
                    if url.isFileURL {
                        let actualName = url.lastPathComponent
                        let effectiveName = (!actualName.isEmpty && !actualName.hasPrefix("SharedDocument_") && !actualName.hasPrefix("temp_")) ? actualName : filename
                        let res = copyToSharedContainer(url, destFilename: effectiveName)
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
                        let actualName = u.lastPathComponent
                        let effectiveName = (!actualName.isEmpty && !actualName.hasPrefix("SharedDocument_") && !actualName.hasPrefix("temp_")) ? actualName : filename
                        let res = copyToSharedContainer(u, destFilename: effectiveName)
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
                    let actualName = parsedURL.lastPathComponent
                    let effectiveName = (!actualName.isEmpty && !actualName.hasPrefix("SharedDocument_") && !actualName.hasPrefix("temp_")) ? actualName : filename
                    let res = copyToSharedContainer(parsedURL, destFilename: effectiveName)
                    continuation.resume(returning: res)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    @MainActor
    static func tryLoadFileRepresentation(provider: NSItemProvider, typeId: String, filename: String) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: typeId) { tempURL, error in
                guard error == nil, let tempURL = tempURL else {
                    continuation.resume(returning: nil)
                    return
                }
                let actualName = tempURL.lastPathComponent
                let effectiveName = (!actualName.isEmpty && !actualName.hasPrefix("SharedDocument_") && !actualName.hasPrefix("temp_")) ? actualName : filename
                let result = copyToSharedContainer(tempURL, destFilename: effectiveName)
                continuation.resume(returning: result)
            }
        }
    }

    @MainActor
    static func tryLoadInPlaceFileRepresentation(provider: NSItemProvider, typeId: String, filename: String) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadInPlaceFileRepresentation(forTypeIdentifier: typeId) { fileURL, _, error in
                guard error == nil, let fileURL = fileURL else {
                    continuation.resume(returning: nil)
                    return
                }
                let actualName = fileURL.lastPathComponent
                let effectiveName = (!actualName.isEmpty && !actualName.hasPrefix("SharedDocument_") && !actualName.hasPrefix("temp_")) ? actualName : filename
                let result = copyToSharedContainer(fileURL, destFilename: effectiveName)
                continuation.resume(returning: result)
            }
        }
    }

    @MainActor
    static func tryLoadDataRepresentation(provider: NSItemProvider, typeId: String, filename: String) async -> URL? {
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
            "group.com.antigravity.InksyncPro",
            "group.com.antigravity.ComicToPDF",
            "group.com.antigravity.inksync"
        ]
        for id in groupIDs {
            if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) {
                if !containers.contains(container) {
                    containers.append(container)
                }
            }
        }
        if containers.isEmpty {
            if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                containers.append(docs)
            }
            if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
                containers.append(appSupport)
            }
            containers.append(FileManager.default.temporaryDirectory)
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
        
        var sourceData: Data? = nil
        let accessing = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessing { sourceURL.stopAccessingSecurityScopedResource() } }

        // Attempt coordinated read
        let coordinator = NSFileCoordinator()
        var coordError: NSError?
        coordinator.coordinate(readingItemAt: sourceURL, options: .withoutChanges, error: &coordError) { coordinatedURL in
            let innerAccess = coordinatedURL.startAccessingSecurityScopedResource()
            defer { if innerAccess { coordinatedURL.stopAccessingSecurityScopedResource() } }
            sourceData = try? Data(contentsOf: coordinatedURL, options: .alwaysMapped)
        }
        if sourceData == nil {
            sourceData = try? Data(contentsOf: sourceURL, options: .alwaysMapped)
        }
        
        for container in containers {
            let stagingURL = container.appendingPathComponent("ShareStaging", isDirectory: true)
            let inboxURL = container.appendingPathComponent("Inbox", isDirectory: true)
            let pendingURL = container.appendingPathComponent("PendingConversions", isDirectory: true)
            try? FileManager.default.createDirectory(at: stagingURL, withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(at: inboxURL, withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(at: pendingURL, withIntermediateDirectories: true)

            let destURL = stagingURL.appendingPathComponent(cleanDest)
            let inboxDestURL = inboxURL.appendingPathComponent(cleanDest)
            let pendingDestURL = pendingURL.appendingPathComponent(cleanDest)

            try? FileManager.default.removeItem(at: destURL)
            try? FileManager.default.removeItem(at: inboxDestURL)
            try? FileManager.default.removeItem(at: pendingDestURL)
            
            var didCopy = false
            if let data = sourceData {
                if (try? data.write(to: destURL, options: .atomic)) != nil {
                    try? data.write(to: inboxDestURL, options: .atomic)
                    try? data.write(to: pendingDestURL, options: .atomic)
                    didCopy = true
                }
            }
            if !didCopy {
                do {
                    try FileManager.default.copyItem(at: sourceURL, to: destURL)
                    try? FileManager.default.copyItem(at: destURL, to: inboxDestURL)
                    try? FileManager.default.copyItem(at: destURL, to: pendingDestURL)
                    didCopy = true
                } catch {
                    // Fallback handled
                }
            }
            if didCopy && primaryResultURL == nil {
                primaryResultURL = destURL
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
            let inboxURL = container.appendingPathComponent("Inbox", isDirectory: true)
            let pendingURL = container.appendingPathComponent("PendingConversions", isDirectory: true)
            try? FileManager.default.createDirectory(at: stagingURL, withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(at: inboxURL, withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(at: pendingURL, withIntermediateDirectories: true)

            let destURL = stagingURL.appendingPathComponent(destFilename)
            let inboxDest = inboxURL.appendingPathComponent(destFilename)
            let pendingDest = pendingURL.appendingPathComponent(destFilename)
            try? FileManager.default.removeItem(at: destURL)
            try? FileManager.default.removeItem(at: inboxDest)
            try? FileManager.default.removeItem(at: pendingDest)
            
            if (try? data.write(to: destURL, options: .atomic)) != nil {
                try? data.write(to: inboxDest, options: .atomic)
                try? data.write(to: pendingDest, options: .atomic)
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
            var anyErrors = false
            var stagedCount = 0
            
            for (index, file) in selectedFiles.enumerated() {
                await MainActor.run {
                    currentFileName = file.name
                    processingProgress = Double(index) / Double(max(1, selectedFiles.count))
                }
                
                do {
                    try markForConversion(file)
                    
                    await MainActor.run {
                        if let idx = selectedFiles.firstIndex(where: { $0.id == file.id }) {
                            selectedFiles[idx].isProcessed = true
                        }
                        processedCount += 1
                    }
                    stagedCount += 1
                } catch {
                    anyErrors = true
                    print("[ShareExt] Error: Failed to stage \(file.name): \(error)")
                    await MainActor.run {
                        errorMessage = "Failed to stage \(file.name): \(error.localizedDescription)"
                    }
                }
            }
            
            await MainActor.run {
                processingProgress = 1.0
                isProcessing = false
                if stagedCount > 0 {
                    // Set import flags immediately in all App Group UserDefaults suites
                    let appGroupIDs = [
                        "group.com.antigravity.InksyncPro",
                        "group.com.antigravity.ComicToPDF",
                        "group.com.antigravity.inksync"
                    ]
                    let timestamp = Date().timeIntervalSince1970
                    for gid in appGroupIDs {
                        if let ud = UserDefaults(suiteName: gid) {
                            ud.set(timestamp, forKey: "pendingShareImportTimestamp")
                            ud.set(true, forKey: "hasPendingShareImport")
                            ud.synchronize()
                        }
                    }
                    showingSuccess = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        onOpenApp()
                    }
                } else {
                    showingSuccess = false
                    if errorMessage == nil {
                        errorMessage = "Failed to stage shared documents to App Group container"
                    }
                }
            }
        }
    }
    
    private func markForConversion(_ file: SharedFile) throws {
        let containers = Self.getAppGroupContainers()
        guard !containers.isEmpty else { throw ShareError.noContainer }

        let accessing = file.url.startAccessingSecurityScopedResource()
        defer { if accessing { file.url.stopAccessingSecurityScopedResource() } }

        guard FileManager.default.fileExists(atPath: file.url.path) else {
            print("[ShareExt] Error: Source file does not exist at \(file.url.path)")
            throw ShareError.copyFailed
        }

        var successfulStagings = 0

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
                try? data.write(to: manifestURL, options: .atomic)
            }

            let destPending = pendingURL.appendingPathComponent(file.name)
            let destInbox = inboxURL.appendingPathComponent(file.name)

            var didStagePending = false
            var didStageInbox = false

            if file.url.path == destPending.path {
                didStagePending = true
            } else {
                didStagePending = Self.safeCopyOrWrite(from: file.url, to: destPending)
            }

            if file.url.path == destInbox.path {
                didStageInbox = true
            } else {
                didStageInbox = Self.safeCopyOrWrite(from: file.url, to: destInbox)
            }

            if didStagePending || didStageInbox {
                successfulStagings += 1
            }
        }

        if successfulStagings == 0 {
            throw ShareError.copyFailed
        }
    }

    nonisolated static func safeCopyOrWrite(from sourceURL: URL, to destURL: URL) -> Bool {
        let accessing = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessing { sourceURL.stopAccessingSecurityScopedResource() } }

        let parentDir = destURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: destURL)

        do {
            try FileManager.default.copyItem(at: sourceURL, to: destURL)
            return true
        } catch {
            if let data = try? Data(contentsOf: sourceURL, options: .alwaysMapped) {
                if (try? data.write(to: destURL, options: .atomic)) != nil {
                    return true
                }
            }
        }
        return false
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

