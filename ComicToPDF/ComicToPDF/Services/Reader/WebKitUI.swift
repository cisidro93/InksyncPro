import SwiftUI
import WebKit

/// Declarative wrapper for WebKit rendering in SwiftUI
public struct WebView: UIViewRepresentable {
    public let html: String
    public let baseURL: URL?
    @Binding public var isLoading: Bool
    @Binding public var progress: Double
    @Binding public var webViewRef: WKWebView?
    
    // Callbacks for navigation and messaging
    public let onNavigate: ((URL, WKWebView) -> Bool)?
    public let messageHandler: ((WKScriptMessage) -> Void)?
    public let onHighlight: (() -> Void)?
    
    // Callbacks for ScrollView and Lifecycles
    public let didFinishNavigation: ((WKWebView) -> Void)?
    public let scrollViewDidEndDragging: ((UIScrollView, Bool) -> Void)?
    public let scrollViewDidScroll: ((UIScrollView) -> Void)?
    public let processDidTerminate: ((WKWebView) -> Void)?
    
    public init(
        html: String,
        baseURL: URL? = nil,
        isLoading: Binding<Bool> = .constant(false),
        progress: Binding<Double> = .constant(0.0),
        webViewRef: Binding<WKWebView?> = .constant(nil),
        onNavigate: ((URL, WKWebView) -> Bool)? = nil,
        messageHandler: ((WKScriptMessage) -> Void)? = nil,
        onHighlight: (() -> Void)? = nil,
        didFinishNavigation: ((WKWebView) -> Void)? = nil,
        scrollViewDidEndDragging: ((UIScrollView, Bool) -> Void)? = nil,
        scrollViewDidScroll: ((UIScrollView) -> Void)? = nil,
        processDidTerminate: ((WKWebView) -> Void)? = nil
    ) {
        self.html = html
        self.baseURL = baseURL
        self._isLoading = isLoading
        self._progress = progress
        self._webViewRef = webViewRef
        self.onNavigate = onNavigate
        self.messageHandler = messageHandler
        self.onHighlight = onHighlight
        self.didFinishNavigation = didFinishNavigation
        self.scrollViewDidEndDragging = scrollViewDidEndDragging
        self.scrollViewDidScroll = scrollViewDidScroll
        self.processDidTerminate = processDidTerminate
    }

    public func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let controller = configuration.userContentController
        
        let handler = Coordinator(self)
        // Add script handlers for navigation, metrics, highlighting, and footnotes
        controller.add(handler, name: "nav")
        controller.add(handler, name: "metrics")
        controller.add(handler, name: "highlight")
        controller.add(handler, name: "highlightHandler")
        controller.add(handler, name: "footnote")
        controller.add(handler, name: "scrollFraction")
        
        let webView = HighlightableWebView(frame: .zero, configuration: configuration)
        webView.onHighlightRequested = {
            self.onHighlight?()
        }
        
        webView.navigationDelegate = context.coordinator
        webView.scrollView.delegate = context.coordinator
        
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        
        DispatchQueue.main.async {
            self.webViewRef = webView
        }
        
        return webView
    }

    public func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.parent = self
        
        let prefs = EBookPreferences.shared
        if prefs.paginationMode == EBookPaginationMode.paged.rawValue {
            uiView.scrollView.isScrollEnabled = true
            uiView.scrollView.isPagingEnabled = true
            uiView.scrollView.alwaysBounceVertical = false
            uiView.scrollView.alwaysBounceHorizontal = true
            uiView.scrollView.showsHorizontalScrollIndicator = false
            uiView.scrollView.showsVerticalScrollIndicator = false
        } else {
            uiView.scrollView.isScrollEnabled = true
            uiView.scrollView.isPagingEnabled = false
            uiView.scrollView.alwaysBounceVertical = true
            uiView.scrollView.alwaysBounceHorizontal = false
            uiView.scrollView.showsHorizontalScrollIndicator = false
            uiView.scrollView.showsVerticalScrollIndicator = true
        }
        
        let contentHash = html.hashValue
        if context.coordinator.lastContentHash != contentHash {
            context.coordinator.lastContentHash = contentHash
            
            if let baseURL = baseURL, baseURL.isFileURL {
                let tempName = "__inksync_\(abs(html.hashValue)).injected.html"
                let fileURL = baseURL.appendingPathComponent(tempName)
                do {
                    try html.write(to: fileURL, atomically: true, encoding: .utf8)
                    uiView.loadFileURL(fileURL, allowingReadAccessTo: baseURL.deletingLastPathComponent())
                } catch {
                    uiView.loadHTMLString(html, baseURL: baseURL)
                }
            } else {
                uiView.loadHTMLString(html, baseURL: baseURL)
            }
        }
    }
    
    public static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "nav")
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "metrics")
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "highlight")
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "highlightHandler")
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "footnote")
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "scrollFraction")
        uiView.navigationDelegate = nil
        uiView.scrollView.delegate = nil
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    @MainActor
    public class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler, UIScrollViewDelegate {
        var parent: WebView
        var lastContentHash: Int = 0
        
        init(_ parent: WebView) {
            self.parent = parent
        }
        
        public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url, let onNavigate = parent.onNavigate {
                if !onNavigate(url, webView) {
                    decisionHandler(.cancel)
                    return
                }
            }
            decisionHandler(.allow)
        }
        
        public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.isLoading = true
            parent.progress = 0.1
        }
        
        public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false
            parent.progress = 1.0
            parent.didFinishNavigation?(webView)
        }
        
        public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
            parent.progress = 0.0
        }
        
        public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            parent.messageHandler?(message)
        }
        
        public func scrollViewDidEndDragging(_ scrollView: UIScrollView, decelerate: Bool) {
            parent.scrollViewDidEndDragging?(scrollView, decelerate)
        }
        
        public func scrollViewDidScroll(_ scrollView: UIScrollView) {
            parent.scrollViewDidScroll?(scrollView)
        }
        
        public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            parent.processDidTerminate?(webView)
        }
        
        public func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            return nil
        }
    }
}

/// Custom WebKit WebView subclass to handle native text selections
open class HighlightableWebView: WKWebView {
    public var onHighlightRequested: (() -> Void)?
    
    open override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(customHighlightAction(_:)) {
            return true
        }
        let actionStr = NSStringFromSelector(action)
        let allowedNativeFunctions = ["copy:", "_lookup:", "_translate:", "share:", "_define:", "speak:"]
        
        if allowedNativeFunctions.contains(actionStr) {
            return true
        }
        
        return super.canPerformAction(action, withSender: sender)
    }
    
    @objc open func customHighlightAction(_ sender: Any?) {
        onHighlightRequested?()
    }
    
    open override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        
        let highlightCommand = UICommand(title: "Highlight", action: #selector(customHighlightAction(_:)))
        let highlightMenu = UIMenu(title: "Inksync", options: .displayInline, children: [highlightCommand])
        
        builder.insertSibling(highlightMenu, afterMenu: .standardEdit)
    }
}
