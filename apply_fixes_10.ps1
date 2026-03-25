$path = "c:\Users\chris\.gemini\antigravity\scratch\InksyncPro\ComicToPDF\ComicToPDF\Views\Reader\EBookReaderView.swift"
$content = Get-Content -Raw -Encoding UTF8 $path

$targetDelegate = '(?s)        // Prevent external navigation — keep reader self-contained\r?\n\s+func webView\(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping \(WKNavigationActionPolicy\) -> Void\) \{\s+if action\.navigationType == \.linkActivated \{\s+decisionHandler\(\.cancel\)\s+\} else \{\s+decisionHandler\(\.allow\)\s+\}\s+\}'
$replacementDelegate = @"
        // Intercept navigation for Footnotes, External links, and Chapters
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated {
                if let url = action.request.url {
                    if url.scheme == "http" || url.scheme == "https" {
                        UIApplication.shared.open(url)
                    } else if let fragment = url.fragment {
                        // Internal anchor (e.g., footnote)
                        let js = `"""
                        var el = document.getElementById('\(fragment)') || document.getElementsByName('\(fragment)')[0];
                        if (el) {
                            var targetPage = Math.floor(el.getBoundingClientRect().left / window.innerWidth) + _currentPage;
                            goToPage(Math.max(0, targetPage));
                        }
                        `"""
                        webView.evaluateJavaScript(js, completionHandler: nil)
                    }
                }
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
"@
$content = [regex]::Replace($content, $targetDelegate, $replacementDelegate)

Set-Content -Path $path -Value $content -Encoding UTF8
