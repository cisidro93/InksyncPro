import SwiftUI
import UIKit
import PDFKit
import ZIPFoundation
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
                            Slider(value: $maxSizeMB, in: 5...190, step: 5).tint(.orange)
                            HStack { Text("5 MB").font(.caption).foregroundColor(.secondary); Spacer(); Text("190 MB").font(.caption).foregroundColor(.secondary) }
                        }
                        HStack { Image(systemName: "doc.on.doc.fill").foregroundColor(.blue); Text("Estimated Parts"); Spacer(); Text("~\(estimatedParts) file\(estimatedParts > 1 ? "s" : "")").fontWeight(.medium).foregroundColor(.blue) }
                    } header: { Text("Split Settings") } footer: { Text("Send-to-Kindle (Web) supports up to 200MB. Limit capped at 190MB for safety.") }
                    
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
                ToolbarItem(placement: .navigationBarTrailing) { Button("Split") { splitPDF() }.fontWeight(.semibold).disabled(estimatedParts <= 1) }
            }
        }
    }
    
    private func splitPDF() {
        conversionManager.splitFileInBackground(pdf: pdf, maxSizeMB: maxSizeMB)
        dismiss()
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

// MARK: - Panel Extraction Host

struct PanelExtractionHost: View {
    let pdf: ConvertedPDF
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var conversionManager: ConversionManager
    @State private var coverImage: UIImage? = nil
    @State private var isLoading = true
    
    var body: some View {
        NavigationView {
            Group {
                if let image = coverImage {
                    PanelExtractionView(sourceImage: image)
                } else if isLoading {
                    VStack(spacing: 16) {
                        ProgressView()
                        Text("Loading...")
                    }
                } else {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 50))
                            .foregroundColor(.orange)
                        Text("Could not load image")
                        Button("Close") { dismiss() }
                    }
                }
            }
            .navigationTitle("Extract Panels")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .onAppear {
            loadImage()
        }
    }
    
    private func loadImage() {
        Task {
            // Force generate thumbnail if missing
            if pdf.coverImageData == nil {
                conversionManager.generateCoverThumbnail(for: pdf)
                // Wait a bit for it to generate
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
            }
            
            // OPTION 1: Try using existing cover image data first (fastest)
            if let imageData = pdf.coverImageData,
               let image = UIImage(data: imageData) {
                await MainActor.run {
                    self.coverImage = image
                    self.isLoading = false
                }
                return
            }
            
            // OPTION 2: Try loading from ConversionManager cache
            if let cachedImage = conversionManager.getThumbnail(for: pdf) {
                await MainActor.run {
                    self.coverImage = cachedImage
                    self.isLoading = false
                }
                return
            }
            
            // OPTION 3: Generate new thumbnail (last resort)
            await generateThumbnail()
        }
    }
    
    private func generateThumbnail() async {
        // This runs on background thread
        let url = pdf.url
        let ext = url.pathExtension.lowercased()
        
        // Start security access
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        
        var resultImage: UIImage? = nil
        
        if ext == "pdf" {
            // PDF extraction
            if let doc = PDFDocument(url: url),
               let page = doc.page(at: 0) {
                let pageRect = page.bounds(for: .mediaBox)
                let targetSize = CGSize(width: 1200, height: 1800) // High res for panel detection
                let scale = min(targetSize.width / pageRect.width, targetSize.height / pageRect.height)
                let scaledSize = CGSize(width: pageRect.width * scale, height: pageRect.height * scale)
                
                let renderer = UIGraphicsImageRenderer(size: scaledSize)
                resultImage = renderer.image { ctx in
                    UIColor.white.set()
                    ctx.fill(CGRect(origin: .zero, size: scaledSize))
                    ctx.cgContext.translateBy(x: 0, y: scaledSize.height)
                    ctx.cgContext.scaleBy(x: 1.0, y: -1.0)
                    ctx.cgContext.scaleBy(x: scale, y: scale)
                    page.draw(with: .mediaBox, to: ctx.cgContext)
                }
            }
        } else if ext == "epub" {
            // EPUB extraction
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            
            do {
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                try FileManager.default.unzipItem(at: url, to: tempDir)
                
                // Find OEBPS/images or any images directory
                let searchPaths = [
                    tempDir.appendingPathComponent("OEBPS/images"),
                    tempDir.appendingPathComponent("OPS/images"),
                    tempDir.appendingPathComponent("images"),
                    tempDir
                ]
                
                let imageExts = ["jpg", "jpeg", "png", "gif", "webp"]
                
                for searchPath in searchPaths {
                    if let files = try? FileManager.default.contentsOfDirectory(at: searchPath, includingPropertiesForKeys: nil) {
                        let imageFiles = files
                            .filter { imageExts.contains($0.pathExtension.lowercased()) }
                            .filter { !$0.lastPathComponent.hasPrefix("._") }
                            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                        
                        if let firstImage = imageFiles.first,
                           let data = try? Data(contentsOf: firstImage),
                           let image = UIImage(data: data) {
                            resultImage = image
                            break
                        }
                    }
                }
                
                try? FileManager.default.removeItem(at: tempDir)
            } catch {
                try? FileManager.default.removeItem(at: tempDir)
            }
        }
        
        await MainActor.run {
            self.coverImage = resultImage
            self.isLoading = false
        }
    }
}
