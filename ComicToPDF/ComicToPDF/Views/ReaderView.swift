import SwiftUI
import WebKit
import PDFKit

struct ReaderView: View {
    let fileURL: URL
    @Environment(\.dismiss) var dismiss // ✅ Added Dismiss Environment
    @State private var isPanelViewEnabled = true
    
    var body: some View {
        NavigationView { // ✅ Wrapped in Navigation View for Toolbar
            VStack {
                if fileURL.pathExtension.lowercased() == "epub" {
                    EPUBSmartReader(url: fileURL, panelMode: $isPanelViewEnabled)
                } else {
                    PDFKitView(url: fileURL)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // ✅ Left Side: Close Button
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") {
                        dismiss()
                    }
                    .fontWeight(.bold)
                }
                
                // Right Side: Panel Toggle
                ToolbarItem(placement: .navigationBarTrailing) {
                    Toggle("Panel View", isOn: $isPanelViewEnabled)
                }
            }
        }
    }
}

// MARK: - Smart EPUB Component
struct EPUBSmartReader: UIViewRepresentable {
    let url: URL
    @Binding var panelMode: Bool
    
    func makeUIView(context: Context) -> WKWebView {
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences = prefs
        
        // CSS for smooth animation
        let jsReaderLogic = """
        var panelIndex = -1;
        var panels = [];
        
        var style = document.createElement('style');
        style.innerHTML = `
            body { 
                transition: transform 0.4s cubic-bezier(0.25, 1, 0.5, 1); 
                transform-origin: top left; 
                will-change: transform;
                overflow: hidden; 
            }
        `;
        document.head.appendChild(style);

        function initPanels() {
            var page = document.querySelector('.page');
            if (page && page.dataset.panels) {
                try { panels = JSON.parse(page.dataset.panels); } 
                catch(e) { console.error("Invalid panel data"); }
            }
        }
        
        function nextPanel() {
            if (panels.length === 0) return;
            panelIndex++;
            if (panelIndex >= panels.length) { 
                panelIndex = -1; 
                document.body.style.transform = "scale(1) translate(0, 0)";
                return; 
            }
            var p = panels[panelIndex];
            var scaleX = window.innerWidth / (p.width * window.innerWidth);
            var scaleY = window.innerHeight / (p.height * window.innerHeight);
            var scale = Math.min(scaleX, scaleY) * 0.95; 
            var tx = -p.x * 100;
            var ty = -p.y * 100;
            document.body.style.transform = `scale(${scale}) translate(${tx}%, ${ty}%)`;
        }
        window.onload = initPanels;
        """
        
        let script = WKUserScript(source: jsReaderLogic, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        config.userContentController.addUserScript(script)
        
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        
        // Add Tap Gesture for Panel Navigation
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap))
        webView.addGestureRecognizer(tap)
        
        return webView
    }
    
    func updateUIView(_ webView: WKWebView, context: Context) {
        if webView.url == nil {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        // Update panel mode state in JS if needed
    }
    
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    
    class Coordinator: NSObject {
        var parent: EPUBSmartReader
        init(_ parent: EPUBSmartReader) { self.parent = parent }
        
        @objc func handleTap() {
            guard parent.panelMode else { return }
            // Trigger JS function
            // Note: In production, use evaluateJavaScript. This is a simplified trigger.
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
