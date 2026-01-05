import SwiftUI
import PDFKit

class ConversionManager: ObservableObject {
    @Published var convertedPDFs: [ConvertedPDF] = []
    
    // Status State
    @Published var isImporting = false
    @Published var statusMessage: String?
    @Published var showError = false

    init() {
        scanLibrary()
    }
    
    // 1. Scan Library
    func scanLibrary() {
        let fileManager = FileManager.default
        let docDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        
        do {
            let fileURLs = try fileManager.contentsOfDirectory(at: docDir, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])
            let allowed = ["cbz", "cbr", "pdf", "epub", "zip"]
            
            let foundFiles = fileURLs.compactMap { url -> ConvertedPDF? in
                if allowed.contains(url.pathExtension.lowercased()) {
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                    return ConvertedPDF(
                        name: url.lastPathComponent,
                        url: url,
                        pageCount: 0,
                        fileSize: Int64(size),
                        metadata: nil,
                        collectionId: nil
                    )
                }
                return nil
            }
            
            DispatchQueue.main.async {
                self.convertedPDFs = foundFiles
            }
        } catch {
            print("Scan Error: \(error)")
        }
    }
    
    // 2. Import Files
    @MainActor
    func processImportedFiles(urls: [URL]) {
        statusMessage = "Importing..."
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            
            do {
                let fileName = url.lastPathComponent
                let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let destURL = docDir.appendingPathComponent(fileName)
                
                if FileManager.default.fileExists(atPath: destURL.path) {
                    try FileManager.default.removeItem(at: destURL)
                }
                try FileManager.default.copyItem(at: url, to: destURL)
                
            } catch {
                print("Import failed: \(error.localizedDescription)")
            }
        }
        scanLibrary()
        statusMessage = nil
    }
    
    // 3. ✅ NEW: Convert Logic
    func convertComic(_ pdf: ConvertedPDF) async {
        await MainActor.run { statusMessage = "Converting \(pdf.name)..." }
        
        let converter = CBZToEPUBConverter()
        let settings = EPUBSettings() // Use default settings for now
        
        do {
            // Run conversion
            let newURL = try await converter.convert(sourceURL: pdf.url, settings: settings) { progress in
                // Optional: You can pipe 'progress' (0.0 to 1.0) to the UI here if needed
                print("Progress: \(progress)")
            }
            
            print("Conversion Complete: \(newURL)")
            
            await MainActor.run {
                statusMessage = "Conversion Complete!"
                scanLibrary() // Refresh list to show new EPUB
                
                // Clear message after 2 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    self.statusMessage = nil
                }
            }
        } catch {
            await MainActor.run {
                statusMessage = "Error: \(error.localizedDescription)"
            }
        }
    }
    
    func deletePDF(_ pdf: ConvertedPDF) {
        try? FileManager.default.removeItem(at: pdf.url)
        scanLibrary()
    }
}
