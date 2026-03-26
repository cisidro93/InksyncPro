$paths = @(
    "c:\Users\chris\.gemini\antigravity\scratch\InksyncPro\ComicToPDF\ComicToPDF\Views\Reader\ReaderView.swift",
    "c:\Users\chris\.gemini\antigravity\scratch\InksyncPro\ComicToPDF\ComicToPDF\Views\Reader\EBookReaderView.swift"
)

# 1. Update ReaderView.swift Top Bar bounds
$path = $paths[0]
$content = Get-Content -Raw -Encoding UTF8 $path
$targetTopBar = '(?s)\.padding\(\.top, 8\)\r?\n\s+\.padding\(\.bottom, 12\)'
$replacementTopBar = @"
        .padding(.top, (UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.windows.first?.safeAreaInsets.top ?? 47) + 8)
        .padding(.bottom, 12)
"@
$content = [regex]::Replace($content, $targetTopBar, $replacementTopBar)
Set-Content -Path $path -Value $content -Encoding UTF8

# 2. Update EBookReaderView.swift Top Bar bounds & Contrast bug
$path = $paths[1]
$content = Get-Content -Raw -Encoding UTF8 $path

$targetEBookTopBar = '(?s)\.padding\(\.top, 16\)\r?\n\s+\.padding\(\.bottom, 16\)'
$replacementEBookTopBar = @"
        .padding(.top, (UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.windows.first?.safeAreaInsets.top ?? 47) + 8)
        .padding(.bottom, 16)
"@
# If padding varies, try matching broader scope
if ($content -notmatch 'padding\(\.top, 16\)') {
    $targetEBookTopBarFallback = '(?s)\.padding\(\.vertical, 16\)\r?\n\s+\.background\('
    $replacementEBookTopBarFallback = @"
        .padding(.top, (UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.windows.first?.safeAreaInsets.top ?? 47) + 8)
        .padding(.bottom, 16)
        .background(
"@
    $content = [regex]::Replace($content, $targetEBookTopBarFallback, $replacementEBookTopBarFallback)
} else {
    $content = [regex]::Replace($content, $targetEBookTopBar, $replacementEBookTopBar)
}

$targetContrast = '(?s)h1,h2,h3,h4 \{ color: \\\(prefs\.activeTheme\.cssText\(colorScheme: colorScheme\)\) !important; line-height: 1\.3; \}'
$replacementContrast = @"
        p, div, span, li, td, th, h1, h2, h3, h4, h5, h6 { color: \`\(prefs.activeTheme.cssText(colorScheme: colorScheme)) !important; line-height: 1.3; }
"@
$content = [regex]::Replace($content, $targetContrast, $replacementContrast)

Set-Content -Path $path -Value $content -Encoding UTF8
