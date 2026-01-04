
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
        
        // INJECT JAVASCRIPT READER LOGIC
        let jsParams = """
        var panelIndex = -1;
        var panels = [];
        
        function initPanels() {
            // Find the page container and get data-panels
            var page = document.querySelector('.page');
            if (page && page.dataset.panels) {
                panels = JSON.parse(page.dataset.panels);
            }
        }
        
        function nextPanel() {
            if (panels.length === 0) return;
            panelIndex++;
            if (panelIndex >= panels.length) { panelIndex = -1; resetZoom(); return; }
            
            var p = panels[panelIndex];
            // Zoom to specific panel coordinates (p.x, p.y, p.width, p.height)
            // Implementation of CSS transform/zoom goes here
            document.body.style.transform = `scale(${1/p.width}) translate(${-p.x * 100}%, ${-p.y * 100}%)`;
        }
        """
        
        let script = WKUserScript(source: jsParams, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        config.userContentController.addUserScript(script)
        
        return WKWebView(frame: .zero, configuration: config)
    }
    
    func updateUIView(_ webView: WKWebView, context: Context) {
        // Load file if needed
        if webView.url == nil {
            // Logic to unzip/load local EPUB HTML goes here
            // For now, load raw file URL
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
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
