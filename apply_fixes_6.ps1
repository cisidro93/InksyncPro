$path = "c:\Users\chris\.gemini\antigravity\scratch\InksyncPro\ComicToPDF\ComicToPDF\Views\Reader\EBookReaderView.swift"
$content = Get-Content -Raw -Encoding UTF8 $path

$targetInjectCSS = '(?s)\s*private func injectReaderCSS\(into html: String\) -> String \{.*?return css \+ html\s+\}'
$replacementInjectCSS = @"

    private func injectReaderCSS(into html: String, prefs: EBookPreferences, colorScheme: ColorScheme) -> String {
        let isPaged = prefs.paginationMode == EBookPaginationMode.paged.rawValue
        let pagedCSS = isPaged ? `"""
            /* Paged */
            column-width: calc(100vw - \`\(prefs.textMargin * 2)px) !important;
            column-gap: \`\(prefs.textMargin * 2)px !important;
            column-fill: auto !important;
        `""" : ""

        let css = `"""
        <meta charset="utf-8">
        <style id="__inksync_reader__">
        *, *::before, *::after { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
        html, body {
            margin: 0 !important;
            padding: 0 !important;
            height: 100vh !important;
            width: 100vw !important;
            \`\(isPaged ? "overflow-x: hidden !important; overflow-y: hidden !important;" : "overflow-x: hidden !important; overflow-y: auto !important;")
            background-color: \`\(prefs.activeTheme.cssBackground(colorScheme: colorScheme)) !important;
        }
        body {
            color: \`\(prefs.activeTheme.cssText(colorScheme: colorScheme)) !important;
            font-family: \`\(prefs.fontFamily);
            font-size: \`\(Int(prefs.fontSize))px;
            line-height: \`\(String(format: "%.1f", prefs.lineHeight));
            text-align: \`\(prefs.textAlign) !important;
            
            \`\(pagedCSS)
            
            padding-top: 60px !important;
            padding-bottom: 60px !important;
            padding-left: \`\(prefs.textMargin)px !important;
            padding-right: \`\(prefs.textMargin)px !important;
            box-sizing: border-box !important;
            word-wrap: break-word;
            -webkit-text-size-adjust: none;
            
            /* Premium Typography */
            -webkit-hyphens: auto !important;
            hyphens: auto !important;
        }
        p { margin-bottom: \`\(prefs.paragraphSpacing)em !important; text-indent: \`\(prefs.paragraphIndent)em !important; }
        h1,h2,h3,h4 { color: \`\(prefs.activeTheme.cssText(colorScheme: colorScheme)) !important; line-height: 1.3; }
        img { max-width: 100%; height: auto; border-radius: 4px; object-fit: contain; max-height: calc(100vh - 120px); }
        a { color: \`\(prefs.activeTheme.cssLink(colorScheme: colorScheme)) !important; }
        blockquote { border-left: 3px solid \`\(prefs.activeTheme.cssLink(colorScheme: colorScheme)); margin-left: 0; padding-left: 16px; opacity: 0.85; }
        </style>
        <script>
        document.addEventListener('DOMContentLoaded', function() {
            document.querySelectorAll('[style]').forEach(function(el) {
                el.style.removeProperty('background-color');
                el.style.removeProperty('color');
            });
        });
        
        var _currentPage = 0;
        var _totalPages = 1;

        function updateMetrics() {
            // Screen width equals one page scroll
            _totalPages = Math.max(1, Math.ceil(document.body.scrollWidth / window.innerWidth));
            window.webkit.messageHandlers.metrics.postMessage({ current: _currentPage, total: _totalPages });
        }

        function goToPage(page) {
            _currentPage = Math.max(0, Math.min(page, _totalPages - 1));
            window.scrollTo({ left: _currentPage * window.innerWidth, behavior: 'instant' });
            updateMetrics();
        }

        window.onload = function() { setTimeout(updateMetrics, 100); };
        window.addEventListener('resize', function() {
            updateMetrics();
            goToPage(_currentPage);
        });

        // Swipe & Tap engine
        var _sx = 0;
        document.addEventListener('touchstart', function(e) { _sx = e.changedTouches[0].clientX; }, {passive:true});
        document.addEventListener('touchend', function(e) {
            var dx = e.changedTouches[0].clientX - _sx;
            if (dx < -40) { // Swipe Left (Next)
                if (_currentPage < _totalPages - 1) goToPage(_currentPage + 1);
                else window.webkit.messageHandlers.nav.postMessage('next');
            } else if (dx > 40) { // Swipe Right (Prev)
                if (_currentPage > 0) goToPage(_currentPage - 1);
                else window.webkit.messageHandlers.nav.postMessage('prev');
            }
        }, {passive:true});

        document.addEventListener('click', function(e) {
            // Ignore clicks on links
            if (e.target.tagName.toLowerCase() === 'a') return;
            var x = e.clientX;
            var w = window.innerWidth;
            if (x < w * 0.25) { // Left 25%
                if (_currentPage > 0) goToPage(_currentPage - 1);
                else window.webkit.messageHandlers.nav.postMessage('prev');
            } else if (x > w * 0.75) { // Right 25%
                if (_currentPage < _totalPages - 1) goToPage(_currentPage + 1);
                else window.webkit.messageHandlers.nav.postMessage('next');
            } else {
                window.webkit.messageHandlers.nav.postMessage('center');
            }
        });
        </script>
        `"""
        
        if let range = html.range(of: "</head>", options: .caseInsensitive) {
            return html.replacingCharacters(in: range, with: css + "</head>")
        }
        return css + html
    }
"@
$content = [regex]::Replace($content, $targetInjectCSS, $replacementInjectCSS)

# Inject vars
$targetVars = '(?s)let title: String\s+@Environment\(\\.dismiss\) private var dismiss'
$replacementVars = @"
    let title: String
    
    @Environment(\.dismiss) private var dismiss
    @StateObject private var prefs = EBookPreferences.shared
    @Environment(\.colorScheme) var colorScheme
    @State private var showingSettingsPanel = false
"@
$content = [regex]::Replace($content, $targetVars, $replacementVars)

Set-Content -Path $path -Value $content -Encoding UTF8
