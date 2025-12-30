import SwiftUI
import PDFKit

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
    
    var body: some View {
        NavigationView {
            ZStack {
                Form {
                    Section {
                        HStack { Text("File Size"); Spacer(); Text(String(format: "%.1f MB", fileSizeMB)).foregroundColor(.secondary) }
                        HStack { Text("Pages"); Spacer(); Text("\(pdf.pageCount)").foregroundColor(.secondary) }
                    } header: { Text("Current PDF") }
                    
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack { Text("Max Size per Part"); Spacer(); Text("\(Int(maxSizeMB)) MB").fontWeight(.semibold).foregroundColor(.orange) }
                            Slider(value: $maxSizeMB, in: 5...50, step: 5).tint(.orange)
                            HStack { Text("5 MB").font(.caption).foregroundColor(.secondary); Spacer(); Text("50 MB").font(.caption).foregroundColor(.secondary) }
                        }
                        HStack { Image(systemName: "doc.on.doc.fill").foregroundColor(.blue); Text("Estimated Parts"); Spacer(); Text("~\(estimatedParts) file\(estimatedParts > 1 ? "s" : "")").fontWeight(.medium).foregroundColor(.blue) }
                    } header: { Text("Split Settings") } footer: { Text("Kindle has a 50MB limit for emailed documents. Splitting creates separate PDFs.") }
                    
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
                        Text("Splitting PDF...").foregroundColor(.white).fontWeight(.medium)
                        Text("\(Int(progress * 100))%").foregroundColor(.white.opacity(0.8))
                    }.padding(40).background(Color.black.opacity(0.7).cornerRadius(20))
                }
            }
            .navigationTitle("Split PDF").navigationBarTitleDisplayMode(.inline)
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
                let parts = try await performSplit()
                await MainActor.run {
                    for partURL in parts { conversionManager.addToLibrary(partURL) }
                    isSplitting = false
                    resultParts = parts
                    alertTitle = "Success"
                    alertMessage = "PDF split into \(parts.count) parts. They have been added to your library."
                    showingAlert = true
                }
            } catch {
                await MainActor.run {
                    isSplitting = false
                    alertTitle = "Error"
                    alertMessage = "Failed to split PDF: \(error.localizedDescription)"
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
                    HStack { Text("New"); Spacer(); Text("\(newName).pdf").foregroundColor(.orange).lineLimit(1) }
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
        let newURL = directory.appendingPathComponent("\(newName).pdf")
        
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
