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
                    Button("Cancel") { dismiss() }
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
            .sheet(isPresented: $showingPicker) {
                DocumentPicker(onDocumentsPicked: { newURLs in
                    processSelectedFiles(newURLs: newURLs)
                })
            }
        }
        .onDisappear {
            // 🚀 NEW: Sandbox Garbage Collection hooks to purge Staging Dirs if user cancels UI
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
    
    private func processSelectedFiles(newURLs: [URL]) {
        // 🚀 SYNCHRONOUS FILE SECURE VAULT
        // We MUST lock these volatile files into our staging directory before returning from the delegate,
        // otherwise iOS will aggressively garbage collect `tmp/` before the background thread parses the metadata.
        var extractedURLs: [URL] = []
        let fileManager = FileManager.default
        let allowedExtensions: Set<String> = ["pdf", "cbz", "cbr", "cb7", "zip", "epub"]

            
            // ✅ NEW: Secure Staging Vault to prevent UIKit UIDocumentPicker from auto-deleting the files
            let stagingDir = fileManager.temporaryDirectory.appendingPathComponent("InksyncStaging_\(UUID().uuidString)")
            try? fileManager.createDirectory(at: stagingDir, withIntermediateDirectories: true)
            
            for url in newURLs {
                let secured = url.startAccessingSecurityScopedResource()
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    if let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey]) {
                        for case let fileURL as URL in enumerator {
                            if allowedExtensions.contains(fileURL.pathExtension.lowercased()) {
                                let localStagedURL = stagingDir.appendingPathComponent(fileURL.lastPathComponent)
                                try? fileManager.copyItem(at: fileURL, to: localStagedURL)
                                extractedURLs.append(localStagedURL)
                            }
                        }
                    }
                } else {
                    if allowedExtensions.contains(url.pathExtension.lowercased()) {
                        let localStagedURL = stagingDir.appendingPathComponent(url.lastPathComponent)
                        try? fileManager.copyItem(at: url, to: localStagedURL)
                        extractedURLs.append(localStagedURL)
                    }
                }
                if secured { url.stopAccessingSecurityScopedResource() }
            }
            
            // 🚀 ASYNCHRONOUS METADATA PARSING
            // Now that the physical files are safely duplicated into `InksyncStaging_`, we detach
            // the sluggish XML parsing workload to the background queue so the UI doesn't stutter.
            DispatchQueue.global(qos: .userInitiated).async {
                // Generate Metadata objects
                for fileURL in extractedURLs {
                let secured = fileURL.startAccessingSecurityScopedResource()
                
                var title = fileURL.lastPathComponent
                var series = fileURL.deletingLastPathComponent().lastPathComponent
                var isManga = false
                
                if let xmlData = try? LocalComicInfoService.shared.fetchNonDestructiveMetadata(from: fileURL) {
                    title = xmlData.parsedTitle ?? title
                    series = xmlData.parsedSeries ?? series
                }
                if let parsedInfo = ComicInfoParser.parse(from: fileURL) {
                    isManga = parsedInfo.manga
                }
                
                if secured { fileURL.stopAccessingSecurityScopedResource() }
                
                let metadata = PDFMetadata(title: title, series: series, isManga: isManga)
                let item = StagedImportItem(url: fileURL, metadata: metadata)
                
                DispatchQueue.main.async {
                    if !self.stagedItems.contains(where: { $0.url.lastPathComponent == fileURL.lastPathComponent }) {
                        self.stagedItems.append(item)
                    }
                }
            }
        }
    }
    
    private func deleteFiles(at offsets: IndexSet) {
        stagedItems.remove(atOffsets: offsets)
    }
    
    private func startImport() {
        guard !stagedItems.isEmpty else { return }
        isImporting = true
        
        var overrides: [String: PDFMetadata] = [:]
        var urlsToProcess: [URL] = []
        for item in stagedItems {
            overrides[item.url.lastPathComponent] = item.metadata
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
