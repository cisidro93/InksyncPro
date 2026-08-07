//
//  EPUBJSBridge.swift
//  InksyncPro
//
//  EPUB Canonical Fragment Identifier (CFI) Generator & JS Bridge.
//  Enables precise, resolution-independent reading location tracking across device screen sizes.
//

import Foundation
import WebKit

@MainActor
final class EPUBJSBridge {
    static let shared = EPUBJSBridge()
    
    private init() {}
    
    /// JavaScript runtime injected into WKWebView to evaluate dynamic CFI position
    let cfiScriptSource: String = """
    (function() {
        if (window.__inksync_cfi_bridge) return;
        window.__inksync_cfi_bridge = {
            getCurrentCFI: function() {
                var visibleNode = document.elementFromPoint(window.innerWidth / 2, 100) || document.body;
                var path = [];
                var node = visibleNode;
                while (node && node.nodeType === Node.ELEMENT_NODE && node !== document.documentElement) {
                    var parent = node.parentNode;
                    if (!parent) break;
                    var index = Array.prototype.indexOf.call(parent.children, node) + 1;
                    var idStr = node.id ? '[' + node.id + ']' : '';
                    path.unshift('/' + (index * 2) + idStr);
                    node = parent;
                }
                return 'epubcfi(/6/2!' + path.join('') + ')';
            },
            scrollToCFI: function(cfiString) {
                if (!cfiString) return;
                var idMatch = cfiString.match(/\\[([^\\]]+)\\]/);
                if (idMatch && idMatch[1]) {
                    var el = document.getElementById(idMatch[1]);
                    if (el) {
                        el.scrollIntoView({ behavior: 'smooth', block: 'start' });
                    }
                }
            }
        };
    })();
    """
    
    /// Inject script into WKUserContentController
    func setupCFIBridge(in userContentController: WKUserContentController) {
        let userScript = WKUserScript(
            source: cfiScriptSource,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        userContentController.addUserScript(userScript)
    }
    
    /// Query current CFI from WKWebView
    func fetchCurrentCFI(from webView: WKWebView, completion: @escaping (String?) -> Void) {
        webView.evaluateJavaScript("window.__inksync_cfi_bridge ? window.__inksync_cfi_bridge.getCurrentCFI() : null") { result, _ in
            completion(result as? String)
        }
    }
}
