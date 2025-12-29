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
        }
    }
}
