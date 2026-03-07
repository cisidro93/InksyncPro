import SwiftUI
import ZIPFoundation

@MainActor
class EPUBContentEditorViewModel: ObservableObject {
    @Published var spineItems: [EBookMetadata.SpineItem] = []
    @Published var deletedIds: Set<String> = []
    
    @Published var isLoading = true
    @Published var isSaving = false
    @Published var errorMessage: String?
    
    let pdf: ConvertedPDF
    let conversionManager: ConversionManager
    private var opfPath: String = ""
    private var opfData: Data = Data()
    
    init(pdf: ConvertedPDF, manager: ConversionManager) {
        self.pdf = pdf
        self.conversionManager = manager
    }
    
    func load() async {
        isLoading = true
        errorMessage = nil
        
        // 1. Parse via EBookParser (just to get spine and container)
        if let metadata = await EBookParser.shared.parse(epub: pdf.url) {
            self.spineItems = metadata.spineItems
            
            // 2. We also need to extract the raw OPF to easily modify it on save
            do {
                guard let archive = try? Archive(url: pdf.url, accessMode: .read, pathEncoding: .utf8) else {
                    throw NSError(domain: "EPUBEditor", code: 1, userInfo: [NSLocalizedDescriptionKey: "Archive corrupted"])
                }
                if let containerEntry = archive["META-INF/container.xml"] {
                    var containerData = Data()
                    _ = try archive.extract(containerEntry) { data in containerData.append(data) }
                    
                    if let containerStr = String(data: containerData, encoding: .utf8),
                       let opfPathRaw = containerStr.components(separatedBy: "full-path=\"").last?.components(separatedBy: "\"").first,
                       let opfEntry = archive[opfPathRaw] {
                        
                        self.opfPath = opfPathRaw
                        var rawOPF = Data()
                        _ = try archive.extract(opfEntry) { data in rawOPF.append(data) }
                        self.opfData = rawOPF
                    }
                }
                
                self.isLoading = false
            } catch {
                self.errorMessage = "Failed to load EPUB architecture: \(error.localizedDescription)"
                self.isLoading = false
            }
        } else {
            self.errorMessage = "Failed to parse EPUB metadata."
            self.isLoading = false
        }
    }
    
    func toggleItem(id: String) {
        if deletedIds.contains(id) {
            deletedIds.remove(id)
        } else {
            deletedIds.insert(id)
        }
    }
    
    func saveChanges(completion: @escaping () -> Void) {
        guard !deletedIds.isEmpty else {
            completion()
            return
        }
        
        isSaving = true
        
        let targetURL = pdf.url
        
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            
            do {
                // To safely update a ZIP, we create a copy and perform updates, OR use .update access mode.
                // ZIPFoundation's .update mode can corrupt complex EPUBs if not careful.
                // Safest approach: Copy to a new temp archive, skipping deleted files.
                
                let sourceArchive = Archive(url: targetURL, accessMode: .read)!
                let tempZipPath = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".epub")
                let destArchive = Archive(url: tempZipPath, accessMode: .create)!
                
                let opfDir = (self.opfPath as NSString).deletingLastPathComponent
                let pathsToDelete = self.spineItems
                    .filter { self.deletedIds.contains($0.id) }
                    .map { item -> String in
                        return opfDir.isEmpty ? item.href : "\(opfDir)/\(item.href)"
                    }
                let exactPathsToDelete = Set(pathsToDelete)
                
                for entry in sourceArchive {
                    // 1. Skip if it's a deleted HTML/XHTML file
                    if exactPathsToDelete.contains(entry.path) {
                        continue
                    }
                    
                    // 2. If it's the OPF file, inject modifications
                    if entry.path == self.opfPath {
                        if let originalOPFString = String(data: self.opfData, encoding: .utf8) {
                            var modifiedOPF = originalOPFString
                            
                            // Simple string replacements to strip out itemrefs and items with exact matches
                            for delId in self.deletedIds {
                                // Strip <itemref idref="X" /> or similar
                                // Using regex to safely capture the entire tag
                                let refPattern = "<itemref[^>]*idref\\s*=\\s*['\"]\(delId)['\"][^>]*\\/?>"
                                if let regexRef = try? NSRegularExpression(pattern: refPattern, options: .caseInsensitive) {
                                    modifiedOPF = regexRef.stringByReplacingMatches(in: modifiedOPF, range: NSRange(modifiedOPF.startIndex..., in: modifiedOPF), withTemplate: "")
                                }
                                
                                let itemPattern = "<item[^>]*id\\s*=\\s*['\"]\(delId)['\"][^>]*\\/?>"
                                if let regexItem = try? NSRegularExpression(pattern: itemPattern, options: .caseInsensitive) {
                                    modifiedOPF = regexItem.stringByReplacingMatches(in: modifiedOPF, range: NSRange(modifiedOPF.startIndex..., in: modifiedOPF), withTemplate: "")
                                }
                            }
                            
                            let newOPFData = modifiedOPF.data(using: .utf8)!
                            
                            try destArchive.addEntry(with: entry.path, type: .file, uncompressedSize: Int64(newOPFData.count), modificationDate: Date(), permissions: entry.fileAttributes[.posixPermissions] as? UInt16 ?? 0o644, compressionMethod: .deflate, bufferSize: 8192, progress: nil) { position, size in
                                let start = Int(position)
                                let end = min(start + size, newOPFData.count)
                                return newOPFData.subdata(in: start..<end)
                            }
                        }
                        continue
                    }
                    
                    // 3. Otherwise, pass-through copy
                    let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    _ = try sourceArchive.extract(entry, to: tempFile)
                    
                    try destArchive.addEntry(with: entry.path, type: .file, uncompressedSize: Int64(entry.uncompressedSize), modificationDate: Date(), permissions: entry.fileAttributes[.posixPermissions] as? UInt16 ?? 0o644, compressionMethod: .deflate, bufferSize: 8192, progress: nil) { position, size in
                        let fileHandle = try? FileHandle(forReadingFrom: tempFile)
                        try? fileHandle?.seek(toOffset: UInt64(position))
                        return fileHandle?.readData(ofLength: size) ?? Data()
                    }
                    try? FileManager.default.removeItem(at: tempFile)
                }
                
                // 4. Overwrite original
                try FileManager.default.removeItem(at: targetURL)
                try FileManager.default.moveItem(at: tempZipPath, to: targetURL)
                
                await MainActor.run {
                    Logger.shared.log("EPUB Editor: Deleted \(self.deletedIds.count) chapters from \(self.pdf.name)", category: "Editor")
                    
                    // Update metadata page count
                    var updatedPDF = self.pdf
                    updatedPDF.pageCount = self.spineItems.count - self.deletedIds.count
                    if let fileAttrs = try? FileManager.default.attributesOfItem(atPath: targetURL.path),
                       let size = fileAttrs[.size] as? Int64 {
                        updatedPDF.fileSize = size
                    }
                    self.conversionManager.updatePDFMetadata(updatedPDF, metadata: updatedPDF.metadata)
                    
                    self.isSaving = false
                    completion()
                }
                
            } catch {
                await MainActor.run {
                    self.errorMessage = "Failed to modify EPUB: \(error.localizedDescription)"
                    self.isSaving = false
                }
            }
        }
    }
}

struct EPUBContentEditorView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var conversionManager: ConversionManager
    let pdf: ConvertedPDF
    
    @StateObject private var viewModel: EPUBContentEditorViewModel
    @State private var showingHeaderCheck = false
    
    init(pdf: ConvertedPDF, manager: ConversionManager) {
        self.pdf = pdf
        _viewModel = StateObject(wrappedValue: EPUBContentEditorViewModel(pdf: pdf, manager: manager))
    }
    
    var body: some View {
        ZStack {
            Color(UIColor.systemGroupedBackground).edgesIgnoringSafeArea(.all)
            
            if viewModel.isLoading {
                ProgressView("Analyzing EPUB spine...")
            } else if let err = viewModel.errorMessage {
                Text(err).foregroundColor(.red)
            } else {
                List {
                    Section(header: Text("Chapters & Content").textCase(.none), footer: Text("Uncheck items to rapidly remove ad inserts, title pages, or credits before sharing to Kindle.")) {
                        ForEach(viewModel.spineItems) { item in
                            let isDeleted = viewModel.deletedIds.contains(item.id)
                            
                            Button(action: {
                                viewModel.toggleItem(id: item.id)
                            }) {
                                HStack {
                                    Image(systemName: isDeleted ? "circle" : "checkmark.circle.fill")
                                        .foregroundColor(isDeleted ? .gray : .blue)
                                        .font(.title2)
                                    
                                    VStack(alignment: .leading) {
                                        Text(item.label)
                                            .foregroundColor(isDeleted ? .gray : .primary)
                                            .strikethrough(isDeleted)
                                        
                                        Text(item.href)
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                    .padding(.leading, 8)
                                    
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            
            if viewModel.isSaving {
                Color.black.opacity(0.4).edgesIgnoringSafeArea(.all)
                ProgressView("Repackaging EPUB...")
                    .padding()
                    .background(Color(.systemBackground))
                    .cornerRadius(12)
                    .shadow(radius: 10)
            }
        }
        .navigationTitle("Delete Chapters")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .disabled(viewModel.isSaving)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Apply") {
                    viewModel.saveChanges { dismiss() }
                }
                .disabled(viewModel.deletedIds.isEmpty || viewModel.isSaving || viewModel.isLoading)
            }
        }
        .onAppear {
            Task { await viewModel.load() }
        }
    }
}
