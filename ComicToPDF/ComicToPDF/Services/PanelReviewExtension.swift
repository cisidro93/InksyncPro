
// MARK: - Panel Editor Extension
extension ConversionManager {
    @MainActor
    func performPanelReview(sourceEPUB: URL, settings: EPUBSettings) async throws {
        self.processingStatus = "Preparing Logic..."
        self.isLoading = true
        
        defer { self.isLoading = false }
        
        // 1. Create a unique temp directory for this session
        let sessionID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("PanelSession_\(sessionID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        // 2. Extract Images (Unzip EPUB)
        self.processingStatus = "Extracting Images..."
        // Use ZIPFoundation to unzip sourceEPUB to tempDir
        try FileManager.default.unzipItem(at: sourceEPUB, to: tempDir)
        
        // 3. Find Images recursively
        let resourceKeys = Set<URLResourceKey>([.nameKey, .isDirectoryKey])
        guard let enumerator = FileManager.default.enumerator(at: tempDir, includingPropertiesForKeys: Array(resourceKeys), options: [.skipsHiddenFiles]) else {
            throw NSError(domain: "PanelReview", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to enumerate temp files"])
        }
        
        var imageURLs: [URL] = []
        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            if ["jpg", "jpeg", "png", "webp"].contains(ext) {
                // Ignore MacOS resource forks
                if !fileURL.path.contains("__MACOSX") {
                    imageURLs.append(fileURL)
                }
            }
        }
        
        // Sort images by filename to ensure correct page order
        imageURLs.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        
        guard !imageURLs.isEmpty else {
            throw NSError(domain: "PanelReview", code: 3, userInfo: [NSLocalizedDescriptionKey: "No images found in file"])
        }
        
        // 4. Create Session Pages
        // We initialize with empty panels. The user can run auto-detect in the editor.
        var pages: [PanelEditSession.PageEditData] = []
        for (index, url) in imageURLs.enumerated() {
             let page = PanelEditSession.PageEditData(
                 pageNumber: index + 1,
                 imageURL: url,
                 panels: [] 
             )
             pages.append(page)
        }
        
        // 5. Launch Session
        let session = PanelEditSession(pages: pages, readingDirection: settings.readingDirection, sessionTempDirectory: tempDir)
        
        self.currentPanelSession = session
        
        // specific completion handler that knows how to save back to EPUB/PDF equivalent
        self.panelEditorCompletion = { [weak self] updatedSession in
            guard let self = self else { return }
            self.showingPanelEditor = false
            self.currentPanelSession = nil
            
            // In a real implementation allowing saving, we would:
            // 1. Generate new EPUB/PDF based on the panels
            // 2. Replace the original file or save as new
            // For now, we perform cleanup.
            
            if let dir = updatedSession?.sessionTempDirectory {
               try? FileManager.default.removeItem(at: dir)
            }
        }
        
        // Trigger UI
        self.showingPanelEditor = true
        self.processingStatus = ""
    }
}
