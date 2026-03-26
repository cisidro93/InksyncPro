$path = "c:\Users\chris\.gemini\antigravity\scratch\InksyncPro\ComicToPDF\ComicToPDF\Views\Reader\EBookReaderView.swift"
$content = Get-Content -Raw -Encoding UTF8 $path

$targetTopBar = '(?s)\.padding\(\.horizontal, 16\)\r?\n\s+\.padding\(\.top, 8\)\r?\n\s+\.padding\(\.bottom, 12\)'
$replacementTopBar = @"
        .padding(.horizontal, 16)
        .padding(.top, (UIApplication.shared.connectedScenes.compactMap { `$0 as? UIWindowScene }.first?.windows.first?.safeAreaInsets.top ?? 47) + 8)
        .padding(.bottom, 12)
"@
$content = [regex]::Replace($content, $targetTopBar, $replacementTopBar)

$targetContrast = '(?s)h1,h2,h3,h4 \{ color: \\\\?\(prefs\.activeTheme\.cssText\(colorScheme: colorScheme\)\) !important; line-height: 1\.3; \}'
$replacementContrast = @"
        p, div, span, li, td, th, h1, h2, h3, h4, h5, h6 { color: \`\(prefs.activeTheme.cssText(colorScheme: colorScheme)) !important; line-height: 1.3; }
"@
$content = [regex]::Replace($content, $targetContrast, $replacementContrast)

Set-Content -Path $path -Value $content -Encoding UTF8
