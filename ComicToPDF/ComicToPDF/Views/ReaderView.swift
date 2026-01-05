import SwiftUI
import WebKit
import PDFKit
import ZIPFoundation

struct ReaderView: View {
    let fileURL: URL
    @Environment(\.dismiss) var dismiss
    @State private var isPanelViewEnabled = true
    
    // Unzip State
    @State private var unzippedDir: URL?
    @State private var pages: [URL] = []
    @State private var currentPageIndex = 0
    @State private var isLoading = true
    @State private var errorMessage: String?
    
    var body: some View {
        NavigationView {
            ZStack {
                if isLoading {
                    ProgressView("Opening Book...").scaleEffect(1.2)
                } else if let error = errorMessage {
                    VStack {
                        Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundColor(.red)
                        Text("Error: \(error)").padding()
                    }
                } else {
                    // READER CONTENT
                    if fileURL.pathExtension.lowercased() == "epub" {
                        // EPUB: Show current HTML Page
                        if !pages.isEmpty && currentPageIndex < pages.count {
                            EPUBSmartReader(
                                pageURL: pages[currentPageIndex],
                                panelMode: $isPanelViewEnabled,
                                onNextPage: nextPage,
                                onPrevPage: prevPage
                            )
                            .id(pages[currentPageIndex]) // Force refresh when page changes
                        }
                    } else {
                        // PDF: Standard Viewer
                        PDFKitView(url: fileURL)
                    }
                }
                
                // Page Indicator Overlay (EPUB Only)
                if !pages.isEmpty && !isLoading {
                    VStack {
                        Spacer()
                        HStack {
                            Text("Page \(currentPageIndex + 1) / \(pages.count)")
                                .font(.caption)
                                .padding(6)
                                .background(.thinMaterial)
                                .cornerRadius(8)
                        }
                        .padding(.bottom, 20)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }.fontWeight(.bold)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Toggle("Panel View", isOn: $isPanelViewEnabled)
                }
            }
            .task {
                if fileURL.pathExtension.lowercased() == "epub" {
                    await prepareEPUB()
                } else {
                    isLoading = false
                }
            }
            .onDisappear {
                // Cleanup Temp Files
                if let dir = unzippedDir {
                    try? FileManager.default.removeItem(at: dir)
                }
            }
        }
    }
    
    // MARK: - EPUB Preparation
    private func prepareEPUB() async {
        let fileManager = FileManager.default
        let tempID = UUID().uuidString
        let dest = fileManager.temporaryDirectory.appendingPathComponent("Reader_\(tempID)")
        
        do {
            try fileManager.createDirectory(at: dest, withIntermediateDirectories: true)
            try fileManager.unzipItem(at: fileURL, to: dest)
            self.unzippedDir = dest
            
            // Find all XHTML files in OEBPS/text or root
            // We search recursively
            if let enumerator = fileManager.enumerator(at: dest, includingPropertiesForKeys: nil) {
                var foundPages: [URL] = []
                while let file = enumerator.nextObject() as? URL {
                    if file.pathExtension == "xhtml" || file.pathExtension == "html" {
                        foundPages.append(file)
                    }
                }
                // Sort by name (page0001, page0002)
                foundPages.sort { $0.lastPathComponent < $1.lastPathComponent }
                
                await MainActor.run {
                    self.pages = foundPages
                    self.isLoading = false
                    if foundPages.isEmpty { self.errorMessage = "No pages found in EPUB." }
                }
            }
        } catch {
            await MainActor.run {
                self.errorMessage = "Failed to unzip: \(error.localizedDescription)"
                self.isLoading = false
            }
        }
    }
    
    // MARK: - Navigation
    func nextPage() {
        if currentPageIndex < pages.count - 1 { currentPageIndex += 1 }
    }
    
    func prevPage() {
        if currentPageIndex > 0 { currentPageIndex -= 1 }
    }
}

// MARK: - Smart EPUB WebView
struct EPUBSmartReader: UIViewRepresentable {
    let pageURL: URL
    @Binding var panelMode: Bool
    var onNextPage: () -> Void
    var onPrevPage: () -> Void
    
    func makeUIView(context: Context) -> WKWebView {
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences = prefs
        
        // JAVASCRIPT: Handle Panels AND Tap Navigation
        let js = """
        var panelIndex = -1;
        var panels = [];
        
        // CSS for Zoom
        var style = document.createElement('style');
        style.innerHTML = `body { transition: transform 0.4s ease; transform-origin: top left; overflow: hidden; }`;
        document.head.appendChild(style);

        function initPanels() {
            var page = document.querySelector('.page');
            if (page && page.dataset.panels) {
                try { panels = JSON.parse(page.dataset.panels); } catch(e) {}
            }
        }
        
        function tap(x) {
            // Right side (next), Left side (prev)
            if (x > window.innerWidth * 0.5) {
                // Next
                if (panels.length > 0 && panelIndex < panels.length - 1) {
                    panelIndex++;
                    zoomToPanel();
                    return "panel_adv";
                } else {
                    return "next_page";
                }
            } else {
                // Prev
                if (panels.length > 0 && panelIndex > 0) {
                    panelIndex--;
                    zoomToPanel();
                    return "panel_rev";
                } else {
                    return "prev_page";
                }
            }
        }
        
        function zoomToPanel() {
            var p = panels[panelIndex];
            var scale = Math.min(window.innerWidth/p.width, window.innerHeight/p.height) * 0.95;
            // Native scaling logic would go here
            // For simplicity, we stick to transform:
            var tx = -p.x * 100;
            var ty = -p.y * 100;
            document.body.style.transform = `scale(${1/p.width}) translate(${tx}%, ${ty}%)`; 
            // Note: Simplistic zoom. 
        }
        
        window.onload = initPanels;
        """
        
        let script = WKUserScript(source: js, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        config.userContentController.addUserScript(script)
        config.userContentController.add(context.coordinator, name: "navHandler")
        
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        
        // Add Tap Gesture (Native to Swift)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        webView.addGestureRecognizer(tap)
        
        return webView
    }
    
    func updateUIView(_ webView: WKWebView, context: Context) {
        if webView.url != pageURL {
            webView.loadFileURL(pageURL, allowingReadAccessTo: pageURL.deletingLastPathComponent())
        }
    }
    
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    
    class Coordinator: NSObject, WKScriptMessageHandler {
        var parent: EPUBSmartReader
        init(_ parent: EPUBSmartReader) { self.parent = parent }
        
        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            let loc = gesture.location(in: gesture.view)
            let width = gesture.view?.bounds.width ?? 300
            
            // Simple logic: Left 30% = Prev, Right 30% = Next, Center = Toggle Panels?
            // For now: Right half Next, Left half Prev
            if loc.x > width / 2 {
                parent.onNextPage()
            } else {
                parent.onPrevPage()
            }
        }
        
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            // Handle JS events if needed
        }
    }
}

struct PDFKitView: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        return pdfView
    }
    func updateUIView(_ pdfView: PDFView, context: Context) {
        if pdfView.document == nil { pdfView.document = PDFDocument(url: url) }
    }
}
