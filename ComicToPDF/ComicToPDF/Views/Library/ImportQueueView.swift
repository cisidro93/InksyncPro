import SwiftUI
import UniformTypeIdentifiers

struct StagedImportItem: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    var metadata: PDFMetadata
    var localCover: UIImage? = nil
    
    static func == (lhs: StagedImportItem, rhs: StagedImportItem) -> Bool {
        return lhs.url == rhs.url
    }
}

struct ImportQueueView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var conversionManager: ConversionManager
    
    @State private var stagedItems: [StagedImportItem] = []
    @State private var showingPicker = false
    @State private var isImporting = false
    @State private var isLeaving = false
    
    var body: some View {
        NavigationView {
            ZStack {
                Theme.bg.ignoresSafeArea()
                
                if stagedItems.isEmpty {
                    VStack(alignment: .center, spacing: 16) {
                        Image(systemName: "checklist.checked")
                            .font(.system(size: 80))
                            .foregroundColor(Theme.blue)
                            
                        Text("Pre-Flight Inspector")
                            .font(.title2).bold()
                            .foregroundColor(Theme.text)
                            
                        Text("Add files to staging. You can review and manually fix any bad metadata tags or missing titles right here before permanently importing them into your library.")
                            .multilineTextAlignment(.center)
                            .font(.subheadline)
                            .foregroundColor(Theme.textSecondary)
                            .padding(.horizontal, 32)
                            
                        Button {
                            showingPicker = true
                        } label: {
                            Label("Add Files to Staging", systemImage: "plus")
                                .font(.headline)
                                .foregroundColor(.white)
                                .padding()
                                .frame(maxWidth: 250)
                                .background(Theme.blue)
                                .cornerRadius(12)
                        }
                        .padding(.top, 20)
                    }
                    .padding()
                } else {
                    List {
                        Section(header: Text("Staged Files ready for Review").foregroundColor(Theme.textSecondary)) {
                            ForEach($stagedItems) { $item in
                                StagedItemRow(item: $item)
                            }
                            .onDelete(perform: deleteFiles)
                        }
                    }
                    .listStyle(InsetGroupedListStyle())
                    .scrollContentBackground(.hidden)
                }
                
                // Processing Overlay
                if isImporting {
                    Color.black.opacity(0.8).ignoresSafeArea()
                    VStack(spacing: 16) {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: Theme.orange))
                            .scaleEffect(1.5)
                        Text("Importing \(stagedItems.count) files...")
                            .foregroundColor(.white)
                            .font(.headline)
                    }
                    .padding(32)
                    .background(Theme.surfaceElevated)
                    .cornerRadius(16)
                    .shadow(radius: 20)
                }
            }
            .navigationTitle("Import Inspector")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { 
                        isLeaving = true
                        dismiss() 
                    }
                        .disabled(isImporting)
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Confirm & Import All") {
                        startImport()
                    }
                    .font(.headline)
                    .foregroundColor(Theme.orange)
                    .disabled(stagedItems.isEmpty || isImporting)
                }
                
                ToolbarItem(placement: .bottomBar) {
                    if !stagedItems.isEmpty {
                        Button {
                            showingPicker = true
                        } label: {
                            HStack {
                                Image(systemName: "plus.circle.fill")
                                Text("Add More Files")
                            }
                            .font(.headline)
                        }
                        .disabled(isImporting)
                    }
                }
            }
            // 🚀 ISOLATED PRESENTATION: Forces UIDocumentPicker onto an isolated UIWindow layer to prevent 
            // the notorious iOS 15+ nested `.sheet` auto-dismiss teardown bug!
            .fullScreenCover(isPresented: $showingPicker) {
                DocumentPicker(onDocumentsPicked: { newURLs in
                    processSelectedFiles(newURLs: newURLs)
                })
                .ignoresSafeArea()
            }
        }
        .interactiveDismissDisabled(!stagedItems.isEmpty)
        .onDisappear {
            // 🚀 PROTECTED GC: Only wipe Staging Dirs if the user explicitly commanded an exit!
            // If the view merely disappeared to overlay a DocumentPicker, we MUST NOT destroy the user's queued staging volumes!
            if isLeaving {
                DispatchQueue.global(qos: .background).async {
                    let fm = FileManager.default
                    if let contents = try? fm.contentsOfDirectory(at: fm.temporaryDirectory, includingPropertiesForKeys: nil) {
                        contents.filter { $0.lastPathComponent.hasPrefix("InksyncStaging_") }.forEach {
                            try? fm.removeItem(at: $0)
                        }
                    }
                }
            }
        }
    }
    
    private func processSelectedFiles(newURLs: [URL]) {
        let fileManager = FileManager.default
        let allowedExtensions: Set<String> = ["pdf", "cbz", "cbr", "cb7", "zip", "epub"]
        var fastExtractedItems: [(url: URL, originalParent: String)] = []
        
        let stagingDir = fileManager.temporaryDirectory.appendingPathComponent("InksyncStaging_\(UUID().uuidString)")
        try? fileManager.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        
        var externalURLs: [(url: URL, secured: Bool)] = []
        
        // 🚀 HYBRID I/O ROUTING
        // 1. If the URL is inside Apple's ephemeral 'tmp' cache (e.g. from `asCopy: true`), we MUST physically O(1) move it 
        // instantly on the Caller Thread. Otherwise iOS violently deletes it the moment this delegate returns.
        // 2. If the URL is external (Real iCloud Folder / USB) from `asCopy: false`, moving it deletes the user's root data and causes cross-volume Watchdog crashes! We keep the lease ACTIVE and pass it safely to the background.
        // 3. We use UUID subdirectories to prevent fatal file name collisions across bulk folders!
        for url in newURLs {
            let secured = url.startAccessingSecurityScopedResource()
            
            if url.path.contains("tmp/") || url.path.contains("tmp/DocumentPicker") {
                defer { if secured { url.stopAccessingSecurityScopedResource() } }
                
                let uniqueFolder = stagingDir.appendingPathComponent(UUID().uuidString)
                try? fileManager.createDirectory(at: uniqueFolder, withIntermediateDirectories: true)
                Logger.shared.log("Initiating Volatile Sandbox Enumeration for \(url.lastPathComponent)", category: "Preflight", type: .info)
                
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    if let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey]) {
                        for case let fileURL as URL in enumerator {
                            if allowedExtensions.contains(fileURL.pathExtension.lowercased()) {
                                do {
                                    let safeFolder = uniqueFolder.appendingPathComponent(UUID().uuidString)
                                    try fileManager.createDirectory(at: safeFolder, withIntermediateDirectories: true)
                                    let targetURL = safeFolder.appendingPathComponent(fileURL.lastPathComponent)
                                    try fileManager.moveItem(at: fileURL, to: targetURL)
                                    fastExtractedItems.append((targetURL, url.lastPathComponent))
                                    Logger.shared.log("Preflight APFS Move Success: \(fileURL.lastPathComponent)", category: "Preflight", type: .info)
                                } catch {
                                    Logger.shared.log("Preflight MoveItem Exception on Volatile Staging: \(error.localizedDescription) - File: \(fileURL.lastPathComponent)", category: "Preflight", type: .error)
                                }
                            }
                        }
                    }
                } else {
                    if allowedExtensions.contains(url.pathExtension.lowercased()) {
                        do {
                            let safeFolder = uniqueFolder.appendingPathComponent(UUID().uuidString)
                            try fileManager.createDirectory(at: safeFolder, withIntermediateDirectories: true)
                            let targetURL = safeFolder.appendingPathComponent(url.lastPathComponent)
                            try fileManager.moveItem(at: url, to: targetURL)
                            fastExtractedItems.append((targetURL, url.deletingLastPathComponent().lastPathComponent))
                            Logger.shared.log("Preflight APFS Move Success: \(url.lastPathComponent)", category: "Preflight", type: .info)
                        } catch {
                            Logger.shared.log("Preflight MoveItem Exception on Volatile Staging: \(error.localizedDescription) - File: \(url.lastPathComponent)", category: "Preflight", type: .error)
                        }
                    }
                }
            } else {
                Logger.shared.log("Queueing External Volume Directory for Background Transfer: \(url.lastPathComponent)", category: "Preflight", type: .info)
                externalURLs.append((url, secured))
            }
        }
        
        Task {
            // 🚀 BACKGROUND METADATA EXTRACT
            Logger.shared.log("Dispatching Background Metadata Extraction and External Volume Traversals", category: "Preflight", type: .info)
            let newItems = await Task.detached(priority: .userInitiated) { () -> [StagedImportItem] in
                var backgroundItems: [(url: URL, originalParent: String)] = []
                
                // Background Cross-Volume Copy for external items
                for (url, secured) in externalURLs {
                    defer { if secured { url.stopAccessingSecurityScopedResource() } }
                    
                    let uniqueFolder = stagingDir.appendingPathComponent(UUID().uuidString)
                    try? fileManager.createDirectory(at: uniqueFolder, withIntermediateDirectories: true)
                    
                    var isDirectory: ObjCBool = false
                    if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                        if let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey]) {
                            for case let fileURL as URL in enumerator {
                                if allowedExtensions.contains(fileURL.pathExtension.lowercased()) {
                                    do {
                                        let safeFolder = uniqueFolder.appendingPathComponent(UUID().uuidString)
                                        try fileManager.createDirectory(at: safeFolder, withIntermediateDirectories: true)
                                        let targetURL = safeFolder.appendingPathComponent(fileURL.lastPathComponent)
                                        try fileManager.copyItem(at: fileURL, to: targetURL)
                                        backgroundItems.append((targetURL, url.lastPathComponent))
                                        Logger.shared.log("Preflight Cross-Volume Copy Success: \(fileURL.lastPathComponent)", category: "Preflight", type: .info)
                                    } catch {
                                        Logger.shared.log("Preflight CopyItem Exception on Dataless URL: \(error.localizedDescription) - File: \(fileURL.lastPathComponent)", category: "Preflight", type: .error)
                                    }
                                }
                            }
                        }
                    } else {
                        if allowedExtensions.contains(url.pathExtension.lowercased()) {
                            do {
                                let safeFolder = uniqueFolder.appendingPathComponent(UUID().uuidString)
                                try fileManager.createDirectory(at: safeFolder, withIntermediateDirectories: true)
                                let targetURL = safeFolder.appendingPathComponent(url.lastPathComponent)
                                try fileManager.copyItem(at: url, to: targetURL)
                                backgroundItems.append((targetURL, url.deletingLastPathComponent().lastPathComponent))
                                Logger.shared.log("Preflight Cross-Volume Copy Success: \(url.lastPathComponent)", category: "Preflight", type: .info)
                            } catch {
                                Logger.shared.log("Preflight CopyItem Exception on Dataless URL: \(error.localizedDescription) - File: \(url.lastPathComponent)", category: "Preflight", type: .error)
                            }
                        }
                    }
                }
                
                let allItems = fastExtractedItems + backgroundItems
                Logger.shared.log("Preflight IO Assembly Complete. Launching Metadata Parsing Matrix for \(allItems.count) files...", category: "Preflight", type: .info)
                var pendingStagedItems: [StagedImportItem] = []
                
                // Generate Metadata objects asynchronously with Native ARC Boundary
                for item in allItems {
                    autoreleasepool {
                        let fileURL = item.url
                        var title = fileURL.lastPathComponent
                        var series = item.originalParent
                        var isManga = false
                        
                        if let xmlData = try? LocalComicInfoService.shared.fetchNonDestructiveMetadata(from: fileURL) {
                            title = xmlData.parsedTitle ?? title
                            series = xmlData.parsedSeries ?? series
                            
                            // Only run the deep XML structural parser if we mathematically verified ComicInfo exists
                            if let parsedInfo = ComicInfoParser.parse(from: fileURL) {
                                isManga = parsedInfo.manga
                            }
                        }
                        
                        let metadata = PDFMetadata(title: title, series: series, isManga: isManga)
                        let stagedItem = StagedImportItem(url: fileURL, metadata: metadata)
                        pendingStagedItems.append(stagedItem)
                    }
                }
                
                Logger.shared.log("Metadata Parsing Matrix completed for \(pendingStagedItems.count) files.", category: "Preflight", type: .info)
                return pendingStagedItems
            }.value
            
            // ✅ Safely mutate @State on the explicit @MainActor context using structural bypass
            await MainActor.run {
                var currentUIState = self.stagedItems
                for item in newItems {
                    if !currentUIState.contains(where: { $0.url == item.url }) {
                        currentUIState.append(item)
                    }
                }
                
                // Forcing an absolute reference swap triggers aggressive SwiftUI view invalidation!
                self.stagedItems = currentUIState
                Logger.shared.log("Staged items UI array count is now \(self.stagedItems.count)", category: "Preflight", type: .info)
            }
        }
    }
    
    private func deleteFiles(at offsets: IndexSet) {
        stagedItems.remove(atOffsets: offsets)
    }
    
    private func startImport() {
        guard !stagedItems.isEmpty else { return }
        isImporting = true
        
        var overrides: [URL: PDFMetadata] = [:]
        var urlsToProcess: [URL] = []
        for item in stagedItems {
            overrides[item.url] = item.metadata
            urlsToProcess.append(item.url)
        }
        
        Task {
            await conversionManager.importFilesAsSeries(urls: urlsToProcess, overrides: overrides)
            await MainActor.run {
                isImporting = false
                dismiss()
            }
        }
    }
}

// MARK: - Editable Queue Row
struct StagedItemRow: View {
    @Binding var item: StagedImportItem
    @State private var showingQuickEdit = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation {
                    showingQuickEdit.toggle()
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "doc.text.fill")
                        .font(.title2)
                        .foregroundColor(Theme.blue)
                        
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.metadata.title)
                            .font(.headline)
                            .foregroundColor(Theme.text)
                            .lineLimit(1)
                        if let s = item.metadata.series, !s.isEmpty {
                            Text("\(s) \(item.metadata.issueNumber.map { "#\($0)" } ?? "")")
                                .font(.caption)
                                .foregroundColor(Theme.textSecondary)
                        } else {
                            Text(item.url.lastPathComponent)
                                .font(.caption)
                                .foregroundColor(Theme.textTertiary)
                                .lineLimit(1)
                        }
                    }
                    
                    Spacer()
                    
                    if item.metadata.isManga ?? false {
                        Text("MANGA")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Theme.green.opacity(0.2))
                            .foregroundColor(Theme.green)
                            .cornerRadius(4)
                    } else {
                        Text("COMIC")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Theme.blue.opacity(0.2))
                            .foregroundColor(Theme.blue)
                            .cornerRadius(4)
                    }
                    
                    Image(systemName: showingQuickEdit ? "chevron.up" : "pencil")
                        .foregroundColor(Theme.orange)
                        .font(.caption)
                }
            }
            .buttonStyle(PlainButtonStyle())
            
            if showingQuickEdit {
                Divider().background(Theme.surfaceElevated)
                VStack(spacing: 12) {
                    HStack {
                        Text("Title").font(.caption).foregroundColor(Theme.textSecondary).frame(width: 50, alignment: .leading)
                        TextField("Document Title", text: $item.metadata.title)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .submitLabel(.done)
                            .onSubmit { }
                    }
                    HStack {
                        Text("Series").font(.caption).foregroundColor(Theme.textSecondary).frame(width: 50, alignment: .leading)
                        TextField("Series Name", text: Binding(
                            get: { item.metadata.series ?? "" },
                            set: { item.metadata.series = $0 }
                        ))
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .submitLabel(.done)
                        .onSubmit { }
                    }
                    
                    HStack {
                        Button {
                            item.metadata.isManga?.toggle()
                            if item.metadata.isManga == nil { item.metadata.isManga = true }
                        } label: {
                            Text(item.metadata.isManga == true ? "Mode: Right-to-Left (Manga)" : "Mode: Left-to-Right (Comic)")
                                .font(.caption).bold()
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(item.metadata.isManga == true ? Theme.green.opacity(0.2) : Theme.blue.opacity(0.2))
                                .foregroundColor(item.metadata.isManga == true ? Theme.green : Theme.blue)
                                .cornerRadius(8)
                        }
                    }
                }
                .padding(.vertical, 8)
                .transition(.opacity)
            }
        }
        .padding(.vertical, 4)
        .listRowBackground(Theme.surface)
    }
}





