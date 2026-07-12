import Foundation
import Combine
import PDFKit
import SwiftData

/// Progressive Reporting Events
enum ConversionProgressEvent {
    case started(file: URL)
    case progress(file: URL, current: Int, total: Int, message: String)
    case completed(file: URL, result: URL)
    case failed(file: URL, error: Error)
}

/// Thread-safe wrapper for PassthroughSubject to allow Sendable conformance across actor boundaries
final class SendableSubject<Output>: @unchecked Sendable {
    let subject = PassthroughSubject<Output, Never>()
    func send(_ value: Output) {
        subject.send(value)
    }
}

/// Secure Processing Core: High-performance file conversion engine
/// Uses Swift Concurrency (Actors) for thread safety and performance
actor ConversionEngine {
    static let shared = ConversionEngine()
    
    // Broadcast progress to listeners (likely the ViewModel/Manager)
    // Using PassthroughSubject so we can easily pump events to the UI
    nonisolated let progressSubject = SendableSubject<ConversionProgressEvent>()
    
    private init() {}
    
    /// Main Entry Point: Convert a file securely
    /// - Parameters:
    ///   - url: Source file URL
    ///   - settings: Conversion settings snapshot (Value Type for thread safety)
    func process(url: URL, settings: ConversionSettings, customOutputName: String? = nil) async throws -> URL {
        // ✅ PHASE 9: Unrestricted Execution
        let backgroundTaskToken = await MainActor.run {
            let box = BackgroundTaskBox()
            let token = UIApplication.shared.beginBackgroundTask(withName: "EngineProcess_\(url.lastPathComponent)") {
                UIApplication.shared.endBackgroundTask(box.token)
            }
            box.token = token
            return token
        }
        
        defer {
            Task { @MainActor in
                UIApplication.shared.endBackgroundTask(backgroundTaskToken)
            }
        }
        
        progressSubject.send(.started(file: url))
        
        // Resolve security-scoped URL for linked drive files if applicable
        let sourceMode = await MainActor.run { () -> SourceMode in
            let context = InksyncProApp.sharedModelContainer.mainContext
            let descriptor = FetchDescriptor<SDConvertedPDF>()
            if let pdfs = try? context.fetch(descriptor) {
                let standardizedPath = url.standardizedFileURL.path
                if let matched = pdfs.first(where: { $0.url.standardizedFileURL.path == standardizedPath }) {
                    return matched.sourceMode
                }
            }
            return .local
        }

        var resolvedURL = url
        var needsStopAccess = false
        if case .linked(let bm) = sourceMode, let resolved = try? BookmarkResolver.shared.resolve(bm) {
            needsStopAccess = resolved.startAccessingSecurityScopedResource()
            resolvedURL = resolved
        } else {
            needsStopAccess = url.startAccessingSecurityScopedResource()
            resolvedURL = url
        }
        
        defer {
            if needsStopAccess {
                resolvedURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let resultURL: URL
            
            if resolvedURL.pathExtension.lowercased() == "pdf" {
                resultURL = try await convertPDF(url: resolvedURL, settings: settings)
                
            } else if resolvedURL.pathExtension.lowercased() == "epub" {
                progressSubject.send(.progress(file: url, current: 50, total: 100, message: "Validating EPUB..."))
                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "_" + resolvedURL.lastPathComponent)
                try FileManager.default.copyItem(at: resolvedURL, to: tempURL)
                progressSubject.send(.progress(file: url, current: 100, total: 100, message: "Done"))
                resultURL = tempURL
                
            } else {
                resultURL = try await convertArchive(url: resolvedURL, settings: settings, customOutputName: customOutputName)
            }
            
            progressSubject.send(.completed(file: url, result: resultURL))
            return resultURL
            
        } catch let bookmarkErr as BookmarkError {
            let wrappedError = NSError(
                domain: "ConversionEngine.DriveError",
                code: 901,
                userInfo: [NSLocalizedDescriptionKey: bookmarkErr.localizedDescription]
            )
            progressSubject.send(.failed(file: url, error: wrappedError))
            throw wrappedError
        } catch {
            progressSubject.send(.failed(file: url, error: error))
            throw error
        }
    }
    
    // Internal Worker: PDF
    private func convertPDF(url: URL, settings: ConversionSettings) async throws -> URL {
        // report granular progress mock
        progressSubject.send(.progress(file: url, current: 0, total: 100, message: "Analyzing PDF..."))
        
        let options = PDFToEPUBConverter.ConversionOptions(
            title: url.deletingPathExtension().lastPathComponent,
            settings: settings,
            mangaMode: settings.mangaMode
        )
        let (epubURL, _) = try await PDFToEPUBConverter.convert(
            pdf: url,
            to: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".epub"),
            options: options
        )
        
        progressSubject.send(.progress(file: url, current: 100, total: 100, message: "Finalizing..."))
        return epubURL
    }
    
    // Internal Worker: Archive
    private func convertArchive(url: URL, settings: ConversionSettings, customOutputName: String? = nil) async throws -> URL {
        progressSubject.send(.progress(file: url, current: 0, total: 100, message: "Extracting Archive..."))
        
        // Simulate work or call CBZToEPUBConverter
        // This is where we'd ideally break down the chunks
        
        // Shim for existing converter
        let converter = CBZToEPUBConverter()
        // We'd need to modify CBZToEPUBConverter to accept a progress callback if we want real granular updates here.
        // For the "Architectural" prompt, I will demonstrate the pattern.
        

        let outputURLs = try await converter.convert(
            sourceURL: url,
            settings: settings,
            manualManifest: nil, // We could pass overrides here if we had them in settings
            customOutputName: customOutputName,
            progress: { @Sendable progress in
                // Adapt closure to async stream/subject if needed, but for now just fire and forget or ignore
                // Since this is inside an actor, we need to be careful.
                // The convert method expects a closure (User provided: @escaping (Double) -> Void)
                Task { [weak self] in
                    await self?.reportProgress(url: url, progress: progress)
                }
            }
        )
        
        guard let firstURL = outputURLs.first else {
             throw NSError(domain: "ConversionEngine", code: 2, userInfo: [NSLocalizedDescriptionKey: "No output file produced"])
        }
        
        return firstURL
    }

    // MARK: - PDF Import Logic
    func performPDFImport(url: URL, destFolder: URL) async throws -> URL {
        // ✅ PHASE 9: Unrestricted Execution
        let backgroundTaskToken = await MainActor.run {
            let box = BackgroundTaskBox()
            let token = UIApplication.shared.beginBackgroundTask(withName: "EngineImport_\(url.lastPathComponent)") {
                UIApplication.shared.endBackgroundTask(box.token)
            }
            box.token = token
            return token
        }
        
        defer {
            Task { @MainActor in
                UIApplication.shared.endBackgroundTask(backgroundTaskToken)
            }
        }
        
        progressSubject.send(.started(file: url))
        
        let importer = PDFImporter()
        let pageCount = importer.getPageCount(url: url)
        
        guard pageCount > 0 else {
            let error = NSError(domain: "ConversionEngine", code: 1, userInfo: [NSLocalizedDescriptionKey: "PDF is empty"])
            progressSubject.send(.failed(file: url, error: error))
            throw error
        }
        
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        // Use a defer block to guarantee we ALWAYS clean out the massive JPEG extraction cache
        // even if the loop throws an error on page 499 or the user cancels the import.
        defer { 
            try? fileManager.removeItem(at: tempDir) 
        }
        
        // Extract Pages
        for i in 0..<pageCount {
            if Task.isCancelled { throw CancellationError() }
            
            // Report Progress
            _ = Int((Double(i) / Double(pageCount)) * 100)
            progressSubject.send(.progress(file: url, current: i, total: pageCount, message: "Extracting Page \(i+1)/\(pageCount)"))
            
            // Extract
            // We use a lower DPI for import to keep it fast/light for the editor, 
            // or high if we want quality. Let's use 150-200 for now or stick to default.
            // Using 300 might be slow on main thread, but here we are in a detached actor task.
            // Using autoreleasepool to manage memory
            // UIImage.jpegData() is not thread-safe when the UIImage was rendered
            // via PDFKit on a background thread. Hop to MainActor for the encode only,
            // then write the raw Data bytes back on the background thread.
            let pageURL = tempDir.appendingPathComponent(String(format: "%03d.jpg", i))
            let image = try autoreleasepool { try importer.extractPage(url: url, pageIndex: i, dpi: 200) }
            let jpegData: Data? = await MainActor.run {
                autoreleasepool { image.jpegData(compressionQuality: 0.75) }
            }
            if let data = jpegData {
                try data.write(to: pageURL)
            }
        }
        
        // Zip it up
        progressSubject.send(.progress(file: url, current: 100, total: 100, message: "Finalizing Import..."))
        let cbzURL = destFolder.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".cbz")
        
        // Use existing ZipUtilities helper
        try await ZipUtilities.zipDirectory(tempDir, to: cbzURL)
        
        progressSubject.send(.completed(file: url, result: cbzURL))
        return cbzURL
    }

    // MARK: - Private Helpers
    private func reportProgress(url: URL, progress: Double) {
        progressSubject.send(.progress(file: url, current: Int(progress * 100), total: 100, message: "Converting..."))
    }
}

// MARK: - Thread-safe Background Task Token Container
private final class BackgroundTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _token: UIBackgroundTaskIdentifier = .invalid
    
    var token: UIBackgroundTaskIdentifier {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _token
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _token = newValue
        }
    }
}
