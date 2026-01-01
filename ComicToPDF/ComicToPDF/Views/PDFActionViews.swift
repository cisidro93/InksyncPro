import SwiftUI
import PDFKit
import ZIPFoundation

// MARK: - Split PDF View

struct SplitPDFView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @Environment(\.dismiss) private var dismiss
    let pdf: ConvertedPDF
    
    @State private var maxSizeMB: Double = 25
    @State private var isSplitting = false
    @State private var progress: Double = 0
    @State private var showingAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @State private var resultParts: [URL] = []
    
    private var estimatedParts: Int {
        let fileSizeMB = Double(pdf.fileSize) / (1024 * 1024)
        return max(1, Int(ceil(fileSizeMB / maxSizeMB)))
    }
    
    private var fileSizeMB: Double {
        Double(pdf.fileSize) / (1024 * 1024)
    }

    private var isEPUB: Bool {
        pdf.url.pathExtension.lowercased() == "epub"
    }
    
    var body: some View {
        NavigationView {
            ZStack {
                Form {
                    Section {
                        HStack { Text("File Size"); Spacer(); Text(String(format: "%.1f MB", fileSizeMB)).foregroundColor(.secondary) }
                        HStack { Text("Pages/Images"); Spacer(); Text("\(pdf.pageCount)").foregroundColor(.secondary) }
                    } header: { Text(isEPUB ? "Current EPUB" : "Current PDF") }
                    
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack { Text("Max Size per Part"); Spacer(); Text("\(Int(maxSizeMB)) MB").fontWeight(.semibold).foregroundColor(.orange) }
                            Slider(value: $maxSizeMB, in: 5...200, step: 5).tint(.orange)
                            HStack { Text("5 MB").font(.caption).foregroundColor(.secondary); Spacer(); Text("200 MB").font(.caption).foregroundColor(.secondary) }
                        }
                        HStack { Image(systemName: "doc.on.doc.fill").foregroundColor(.blue); Text("Estimated Parts"); Spacer(); Text("~\(estimatedParts) file\(estimatedParts > 1 ? "s" : "")").fontWeight(.medium).foregroundColor(.blue) }
                    } header: { Text("Split Settings") } footer: { Text("Send-to-Kindle (Web) supports up to 200MB. Email is limited to ~50MB.") }
                    
                    Section { HStack { Image(systemName: "info.circle.fill").foregroundColor(.orange); Text("Parts will be named: \(pdf.name)_part1, _part2, etc.").font(.caption).foregroundColor(.secondary) } }
                    
                    if !resultParts.isEmpty {
                        Section {
                            ForEach(resultParts, id: \.absoluteString) { url in
                                HStack { Image(systemName: "doc.fill").foregroundColor(.green); Text(url.lastPathComponent).font(.subheadline); Spacer(); Image(systemName: "checkmark.circle.fill").foregroundColor(.green) }
                            }
                        } header: { Text("Created Parts") }
                    }
                }
                
                if isSplitting {
                    Color.black.opacity(0.5).ignoresSafeArea()
                    VStack(spacing: 20) {
                        ProgressView(value: progress).progressViewStyle(CircularProgressViewStyle(tint: .white)).scaleEffect(1.5)
                        Text("Splitting \(isEPUB ? "EPUB" : "PDF")...").foregroundColor(.white).fontWeight(.medium)
                        Text("\(Int(progress * 100))%").foregroundColor(.white.opacity(0.8))
                    }.padding(40).background(Color.black.opacity(0.7).cornerRadius(20))
                }
            }
            .navigationTitle(isEPUB ? "Split EPUB" : "Split PDF").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) { Button("Split") { splitPDF() }.fontWeight(.semibold).disabled(isSplitting || estimatedParts <= 1) }
            }
            .alert(alertTitle, isPresented: $showingAlert) { Button("OK") { if alertTitle == "Success" { dismiss() } } } message: { Text(alertMessage) }
        }
    }
    
    private func splitPDF() {
        isSplitting = true
        progress = 0
        
        Task {
            do {
                let parts: [URL]
                if pdf.url.pathExtension.lowercased() == "epub" {
                     parts = try await performEPUBSplit()
                } else {
                     parts = try await performSplit()
                }
                
                await MainActor.run {
                    for partURL in parts { conversionManager.addToLibrary(partURL) }
                    isSplitting = false
                    resultParts = parts
                    alertTitle = "Success"
                    alertMessage = "File split into \(parts.count) parts. They have been added to your library."
                    showingAlert = true
                }
            } catch {
                await MainActor.run {
                    isSplitting = false
                    alertTitle = "Error"
                    alertMessage = "Failed to split file: \(error.localizedDescription)"
                    showingAlert = true
                }
            }
        }
    }
    
    private func performSplit() async throws -> [URL] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let document = PDFDocument(url: pdf.url) else {
                    continuation.resume(throwing: NSError(domain: "SplitPDF", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not open PDF"]))
                    return
                }
                
                let pageCount = document.pageCount
                let maxBytes = Int(maxSizeMB) * 1024 * 1024
                let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let outputDir = documentsPath.appendingPathComponent("ConvertedPDFs", isDirectory: true)
                try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
                
                var parts: [URL] = []
                var currentPart = PDFDocument()
                var currentPartIndex = 1
                var pagesInCurrentPart = 0
                let baseName = pdf.name
                
                let avgPageSize = pdf.fileSize / Int64(max(pageCount, 1))
                let pagesPerPart = max(1, Int(Int64(maxBytes) / max(avgPageSize, 1)))
                
                for i in 0..<pageCount {
                    autoreleasepool {
                        if let page = document.page(at: i) {
                            currentPart.insert(page, at: pagesInCurrentPart)
                            pagesInCurrentPart += 1
                        }
                    }
                    
                    if pagesInCurrentPart >= pagesPerPart || i == pageCount - 1 {
                        let partURL = outputDir.appendingPathComponent("\(baseName)_part\(currentPartIndex).pdf")
                        if FileManager.default.fileExists(atPath: partURL.path) { try? FileManager.default.removeItem(at: partURL) }
                        if currentPart.write(to: partURL) { parts.append(partURL) }
                        currentPart = PDFDocument()
                        pagesInCurrentPart = 0
                        currentPartIndex += 1
                    }
                    
                    DispatchQueue.main.async { self.progress = Double(i + 1) / Double(pageCount) }
                }
                
                continuation.resume(returning: parts)
            }
        }
    }

    private func performEPUBSplit() async throws -> [URL] {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        try FileManager.default.unzipItem(at: pdf.url, to: tempDir)
        
        // Find images
        let deepEnumerator = FileManager.default.enumerator(at: tempDir, includingPropertiesForKeys: [.fileSizeKey])
        var imageURLs: [URL] = []
        
        while let url = deepEnumerator?.nextObject() as? URL {
            let ext = url.pathExtension.lowercased()
            if ["jpg", "jpeg", "png", "gif", "webp"].contains(ext) {
                // Ignore thumbnails or cover if they are not part of the main pages (heuristic based on size or path could be better, but simple is okay for now)
                // Actually, finding all images in OEBPS/images is safer for standard EPUBs, but general unzip is safer for varying structures.
                // Let's rely on standard image extensions.
                imageURLs.append(url)
            }
        }
        
        imageURLs.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        
        let maxBytes = Int(maxSizeMB) * 1024 * 1024
        var parts: [URL] = []
        
        // Stream processing state
        var currentBatch: [UIImage] = []
        var currentBatchSize: Int64 = 0
        var partIndex = 1
        var processedItems = 0
        
        // Lower compression for Split to avoid size bloat (users often split large files)
        let generator = EPUBGenerator(settings: EPUBSettings(), metadata: pdf.metadata, compressionQuality: 0.7)
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let outputDir = documentsPath.appendingPathComponent("ConvertedPDFs", isDirectory: true)
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        
        // Detect strips logic (Two-Pass approach like ComicEPUBProcessor)
        var isStrips = false
        var stripsPerPage = 1
        
        if !imageURLs.isEmpty {
            // Check a spread of images to avoid being fooled by covers
            // Sample: Start, 25%, 50%, 75%, End
            let count = imageURLs.count
            let indicesToCheck = Set([
                0,
                count / 4,
                count / 2,
                (count * 3) / 4,
                count - 1
            ]).sorted().filter { $0 >= 0 && $0 < count }
            
            var stripVotes = 0
            var validSamples = 0
            
            for i in indicesToCheck {
                 if let img = UIImage(contentsOfFile: imageURLs[i].path) {
                     validSamples += 1
                     // Aspect ratio check: width > 2 * height -> Strip
                     if img.size.width / img.size.height > 2.0 { stripVotes += 1 }
                 }
            }
            // If more than 30% of samples are strips, treat as strips
            // (Lower threshold because covers/credits might be full pages)
            isStrips = validSamples > 0 && (Double(stripVotes) / Double(validSamples) > 0.3)
        }
        
        if isStrips {
            let total = imageURLs.count
            // Heuristic divisors: Prefer 10, 8, 6, 5, 4
            stripsPerPage = 6 // Default
            for n in [10, 8, 6, 5, 4] {
                if total % n == 0 {
                    stripsPerPage = n
                    break
                }
            }
        }
        
        let totalSteps = isStrips ? (imageURLs.count / stripsPerPage) : imageURLs.count
        
        // Helper to process a ready image
        func processReadyImage(_ image: UIImage) async throws {
            let estimatedSize = Int64(image.size.width * image.size.height * 0.5)
            
            if currentBatchSize + estimatedSize > Int64(maxBytes) && !currentBatch.isEmpty {
                // Generate part
                let partName = "\(pdf.name)_part\(partIndex)"
                let (epubURL, _) = try await generator.generateEPUB(from: currentBatch, outputName: partName)
                
                let finalURL = outputDir.appendingPathComponent("\(partName).epub")
                if FileManager.default.fileExists(atPath: finalURL.path) { try FileManager.default.removeItem(at: finalURL) }
                try FileManager.default.moveItem(at: epubURL, to: finalURL)
                parts.append(finalURL)
                
                currentBatch = []
                currentBatchSize = 0
                partIndex += 1
            }
            
            currentBatch.append(image)
            currentBatchSize += estimatedSize
        }
        
        // Process Loop
        if isStrips {
            // Processing strips in chunks
            for i in stride(from: 0, to: imageURLs.count, by: stripsPerPage) {
                let endIndex = min(i + stripsPerPage, imageURLs.count)
                let chunkURLs = imageURLs[i..<endIndex]
                
                var chunkImages: [UIImage] = []
                for url in chunkURLs {
                    if let img = UIImage(contentsOfFile: url.path) {
                        chunkImages.append(img)
                    }
                }
                
                if let stitched = EPUBStripFixer.combineStripsVertically(chunkImages) {
                    try await processReadyImage(stitched)
                }
                
                processedItems += 1
                await MainActor.run {
                    self.progress = min(Double(processedItems) / Double(totalSteps), 0.99)
                }
            }
        } else {
            // Normal processing
            for url in imageURLs {
                if let img = UIImage(contentsOfFile: url.path) {
                    try await processReadyImage(img)
                }
                
                processedItems += 1
                await MainActor.run {
                    self.progress = min(Double(processedItems) / Double(totalSteps), 0.99)
                }
            }
        }
        
        // Final part
        if !currentBatch.isEmpty {
             let partName = "\(pdf.name)_part\(partIndex)"
             let (epubURL, _) = try await generator.generateEPUB(from: currentBatch, outputName: partName)
             
             let finalURL = outputDir.appendingPathComponent("\(partName).epub")
             if FileManager.default.fileExists(atPath: finalURL.path) { try FileManager.default.removeItem(at: finalURL) }
             try FileManager.default.moveItem(at: epubURL, to: finalURL)
             parts.append(finalURL)
        }
        
        try? FileManager.default.removeItem(at: tempDir)
        return parts
    }
}

// MARK: - Rename File View (Library)

struct RenameFileView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @Environment(\.dismiss) private var dismiss
    let pdf: ConvertedPDF
    
    @State private var newName: String = ""
    @State private var showingAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    
    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("File name", text: $newName)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                } header: { Text("New Name") } footer: { Text("Enter a new name for this PDF file.") }
                
                Section {
                    HStack { Text("Current"); Spacer(); Text(pdf.name).foregroundColor(.secondary).lineLimit(1) }
                    HStack { Text("New"); Spacer(); Text("\(newName).\(pdf.url.pathExtension)").foregroundColor(.orange).lineLimit(1) }
                } header: { Text("Preview") }
                
                Section {
                    HStack { Text("Size"); Spacer(); Text(pdf.formattedSize).foregroundColor(.secondary) }
                    HStack { Text("Pages"); Spacer(); Text("\(pdf.pageCount)").foregroundColor(.secondary) }
                } header: { Text("File Info") }
            }
            .navigationTitle("Rename PDF").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) { Button("Save") { renameFile() }.fontWeight(.semibold).disabled(newName.isEmpty || newName == pdf.name) }
            }
            .onAppear { newName = pdf.name }
            .alert(alertTitle, isPresented: $showingAlert) { Button("OK") { if alertTitle == "Success" { dismiss() } } } message: { Text(alertMessage) }
        }
    }
    
    private func renameFile() {
        let fileManager = FileManager.default
        let directory = pdf.url.deletingLastPathComponent()
        let fileExt = pdf.url.pathExtension
        let newURL = directory.appendingPathComponent("\(newName).\(fileExt)")
        
        if fileManager.fileExists(atPath: newURL.path) && newURL != pdf.url {
            alertTitle = "Error"
            alertMessage = "A file with this name already exists."
            showingAlert = true
            return
        }
        
        do {
            try fileManager.moveItem(at: pdf.url, to: newURL)
            
            if let index = conversionManager.convertedPDFs.firstIndex(where: { $0.id == pdf.id }) {
                let oldMetadata = conversionManager.convertedPDFs[index].metadata
                let oldCollectionId = conversionManager.convertedPDFs[index].collectionId
                
                var newPDF = ConvertedPDF(name: newName, url: newURL, pageCount: pdf.pageCount, fileSize: pdf.fileSize, collectionId: oldCollectionId)
                newPDF.metadata = oldMetadata
                conversionManager.convertedPDFs[index] = newPDF
            }
            
            alertTitle = "Success"
            alertMessage = "File renamed successfully!"
            showingAlert = true
        } catch {
            alertTitle = "Error"
            alertMessage = "Failed to rename: \(error.localizedDescription)"
            showingAlert = true
        }
    }
}
