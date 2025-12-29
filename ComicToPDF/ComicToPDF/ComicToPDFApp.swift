import SwiftUI
import PDFKit
import UniformTypeIdentifiers
import MessageUI
import Compression

// MARK: - App Entry Point

@main
struct ComicToPDFApp: App {
    @StateObject private var conversionManager = ConversionManager()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(conversionManager)
                .onOpenURL { url in
                    // Handle file opened from Files app or AirDrop
                    let accessing = url.startAccessingSecurityScopedResource()
                    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                    
                    do {
                        // Copy to temp to persist access
                        let tempDir = FileManager.default.temporaryDirectory
                        let destinationURL = tempDir.appendingPathComponent(url.lastPathComponent)
                        try? FileManager.default.removeItem(at: destinationURL)
                        try FileManager.default.copyItem(at: url, to: destinationURL)
                        
                        DispatchQueue.main.async {
                            conversionManager.externalImportURLs.append(destinationURL)
                        }
                    } catch {
                        print("Error opening file: \(error.localizedDescription)")
                    }
                }
        }
    }
}
