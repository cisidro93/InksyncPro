$path = "c:\Users\chris\.gemini\antigravity\scratch\InksyncPro\ComicToPDF\ComicToPDF\Views\Reader\EBookReaderView.swift"
$content = Get-Content -Raw -Encoding UTF8 $path

$targetCSS = '(?s)html, body \{.*?padding-top: 60px !important;'
$replacementCSS = @"
        html {
            margin: 0 !important;
            padding: 0 !important;
            height: 100vh !important;
            width: 100vw !important;
            \`\(isPaged ? "overflow: hidden !important;" : "overflow-x: hidden !important; overflow-y: auto !important;")
            background-color: \`\(prefs.activeTheme.cssBackground(colorScheme: colorScheme)) !important;
        }
        body {
            color: \`\(prefs.activeTheme.cssText(colorScheme: colorScheme)) !important;
            font-family: \`\(prefs.fontFamily);
            font-size: \`\(Int(prefs.fontSize))px;
            line-height: \`\(String(format: "%.1f", prefs.lineHeight));
            text-align: \`\(prefs.textAlign) !important;
            
            \`\(pagedCSS)
            
            margin: 0 !important;
            height: 100vh !important;
            \`\(isPaged ? "" : "width: 100vw !important; overflow-x: hidden !important;")
            padding-top: 60px !important;
"@
$content = [regex]::Replace($content, $targetCSS, $replacementCSS)

Set-Content -Path $path -Value $content -Encoding UTF8
