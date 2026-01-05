
import SwiftUI
import WebKit
import PDFKit

struct ReaderView: View {
    let fileURL: URL
    @State private var isPanelViewEnabled = true
    @State private var currentPage = 1
    
    var body: some View {
        VStack {
            if fileURL.pathExtension.lowercased() == "epub" {
                // Smart EPUB Reader
                EPUBSmartReader(url: fileURL, panelMode: $isPanelViewEnabled)
            } else {
                // Standard PDF Reader
                PDFKitView(url: fileURL)
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Toggle("Panel View", isOn: $isPanelViewEnabled)
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
        
        // OPTIMIZATION: Hardware accelerated CSS transitions
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
        return webView
    }
    
    func updateUIView(_ webView: WKWebView, context: Context) {
        if webView.url == nil {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        // Note: Real implementation would bind a tap gesture here to call 'nextPanel()'
    }
}

// MARK: - Standard PDF Component
struct PDFKitView: UIViewRepresentable {
    let url: URL
    
    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        return pdfView
    }
    
    func updateUIView(_ pdfView: PDFView, context: Context) {
        if pdfView.document == nil {
            pdfView.document = PDFDocument(url: url)
        }
    }
}
