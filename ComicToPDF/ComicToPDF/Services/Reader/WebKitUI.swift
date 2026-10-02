import SwiftUI
import WebKit

/// Declarative wrapper for WebKit rendering in SwiftUI
public struct WebView: UIViewRepresentable {
    public let html: String
    public let baseURL: URL?
    @Binding public var isLoading: Bool
    @Binding public var progress: Double
    @Binding public var webViewRef: WKWebView?
    @ObservedObject private var prefs = EBookPreferences.shared
    
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
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.contentInset = .zero
        
        DispatchQueue.main.async {
            self.webViewRef = webView
        }
        
        return webView
    }

    public func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.parent = self
        
        let prefs = EBookPreferences.shared
        if prefs.paginationMode == EBookPaginationMode.paged.rawValue {
            uiView.scrollView.isScrollEnabled = false
            uiView.scrollView.isPagingEnabled = false
            uiView.scrollView.bounces = false
            uiView.scrollView.alwaysBounceVertical = false
            uiView.scrollView.alwaysBounceHorizontal = false
            uiView.scrollView.showsHorizontalScrollIndicator = false
            uiView.scrollView.showsVerticalScrollIndicator = false
        } else {
            uiView.scrollView.isScrollEnabled = true
            uiView.scrollView.isPagingEnabled = false
            uiView.scrollView.bounces = true
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
                    // Clean up previously active temp file before creating the new one
                    if let previousURL = context.coordinator.activeTempFileURL, previousURL != fileURL {
                        try? FileManager.default.removeItem(at: previousURL)
                    }
                    try html.write(to: fileURL, atomically: true, encoding: .utf8)
                    context.coordinator.activeTempFileURL = fileURL
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
        if let tempURL = coordinator.activeTempFileURL {
            try? FileManager.default.removeItem(at: tempURL)
            coordinator.activeTempFileURL = nil
        }
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
        var activeTempFileURL: URL? = nil
        
        init(_ parent: WebView) {
            self.parent = parent
        }

        deinit {
            if let tempURL = activeTempFileURL {
                try? FileManager.default.removeItem(at: tempURL)
            }
        }
        
        public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
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
        
        public func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
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
    
    open override var canBecomeFirstResponder: Bool {
        return true
    }

    open override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        if !isFirstResponder {
            _ = becomeFirstResponder()
        }
    }

    open override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(customHighlightAction(_:)) {
            return true
        }
        // Suppress native iOS popup menus (Look Up, Translate, Share, Define)
        // so Inksync Pro's capsule HUD remains the exclusive interaction surface.
        return false
    }
    
    @objc open func customHighlightAction(_ sender: Any?) {
        onHighlightRequested?()
    }
    
    open override var keyCommands: [UIKeyCommand]? {
        let makeCmd: (String, UIKeyModifierFlags, String) -> UIKeyCommand = { input, flags, title in
            let cmd = UIKeyCommand(input: input, modifierFlags: flags, action: #selector(self.handleForwardedKeyCommand(_:)))
            cmd.discoverabilityTitle = title
            return cmd
        }

        return [
            makeCmd(UIKeyCommand.inputLeftArrow, [], "Previous Page"),
            makeCmd(UIKeyCommand.inputRightArrow, [], "Next Page"),
            makeCmd(UIKeyCommand.inputUpArrow, [], "Scroll Up / Previous"),
            makeCmd(UIKeyCommand.inputDownArrow, [], "Scroll Down / Next"),
            makeCmd(" ", [], "Next Page"),
            makeCmd(" ", .shift, "Previous Page"),
            makeCmd(UIKeyCommand.inputPageUp, [], "Previous Page"),
            makeCmd(UIKeyCommand.inputPageDown, [], "Next Page"),
            makeCmd("j", [], "Next Page (Vim)"),
            makeCmd("k", [], "Previous Page (Vim)"),
            makeCmd("h", [], "Previous Page (Vim) / Highlight"),
            makeCmd("l", [], "Next Page (Vim)"),
            makeCmd("\r", [], "Highlight Selection"),
            makeCmd("]", .command, "Next Page (Split-Notebook Safe)"),
            makeCmd("[", .command, "Previous Page (Split-Notebook Safe)"),
            makeCmd("r", .command, "Toggle Reflow Mode"),
            makeCmd("d", .command, "Toggle Speech / Read Aloud"),
            makeCmd("m", .command, "Toggle Pencil Markup"),
            makeCmd("h", .command, "Highlight Selection / Toggle Highlighter"),
            makeCmd("n", .command, "Toggle Study Notebook"),
            makeCmd("s", .command, "Toggle Table of Contents / Sidebar"),
            makeCmd("/", .command, "Keyboard Shortcuts Cheat Sheet")
        ]
    }

    @objc open func handleForwardedKeyCommand(_ sender: UIKeyCommand) {
        // Highlighting hotkeys: Enter (\r), ⌘H, or 'h' with active selection
        if sender.input == "\r" || sender.input == "h" {
            self.evaluateJavaScript("window.getSelection() ? window.getSelection().toString() : ''") { [weak self] (result, error) in
                guard let self = self else { return }
                if let str = result as? String, !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.onHighlightRequested?()
                } else if sender.modifierFlags.contains(.command) {
                    NotificationCenter.default.post(name: NSNotification.Name("ReaderToggleHighlighterMode"), object: nil)
                } else {
                    // Vim 'h' turns page backward when no text is selected
                    NotificationCenter.default.post(name: NSNotification.Name("ReaderAdvancePageBackward"), object: nil)
                }
            }
            return
        }

        if sender.modifierFlags.contains(.command) {
            switch sender.input {
            case "]":
                NotificationCenter.default.post(name: NSNotification.Name("ReaderAdvancePageForward"), object: nil)
            case "[":
                NotificationCenter.default.post(name: NSNotification.Name("ReaderAdvancePageBackward"), object: nil)
            case "r":
                NotificationCenter.default.post(name: NSNotification.Name("ReaderToggleReflowMode"), object: nil)
            case "d":
                NotificationCenter.default.post(name: NSNotification.Name("ReaderToggleSpeechMode"), object: nil)
            case "m":
                NotificationCenter.default.post(name: NSNotification.Name("ReaderToggleMarkupMode"), object: nil)
            case "n":
                NotificationCenter.default.post(name: .toggleStudyNotebook, object: nil)
            case "s":
                NotificationCenter.default.post(name: NSNotification.Name("ReaderToggleSidebar"), object: nil)
            case "/", "?":
                NotificationCenter.default.post(name: NSNotification.Name("ReaderShowShortcutsHelp"), object: nil)
            default:
                break
            }
            return
        }

        let isForward = sender.input == UIKeyCommand.inputRightArrow
            || sender.input == UIKeyCommand.inputDownArrow
            || (sender.input == " " && !sender.modifierFlags.contains(.shift))
            || sender.input == UIKeyCommand.inputPageDown
            || sender.input == "j"
            || sender.input == "l"
        NotificationCenter.default.post(
            name: NSNotification.Name(isForward ? "ReaderAdvancePageForward" : "ReaderAdvancePageBackward"),
            object: nil
        )
    }

    open override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        // Strip system menus so native popups never compete with Inksync HUD
        builder.remove(menu: .standardEdit)
        builder.remove(menu: .lookup)
        builder.remove(menu: .learn)
        builder.remove(menu: .share)
        builder.remove(menu: .services)
        builder.remove(menu: .format)
        builder.remove(menu: .substitutions)
        
        let highlightCommand = UICommand(title: "Highlight", action: #selector(customHighlightAction(_:)))
        let highlightMenu = UIMenu(title: "Inksync", options: .displayInline, children: [highlightCommand])
        
        builder.insertSibling(highlightMenu, afterMenu: .standardEdit)
    }
}
