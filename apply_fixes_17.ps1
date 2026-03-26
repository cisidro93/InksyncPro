$path = "c:\Users\chris\.gemini\antigravity\scratch\InksyncPro\ComicToPDF\ComicToPDF\Views\Reader\EBookReaderView.swift"
$content = Get-Content -Raw -Encoding UTF8 $path

$targetEBookTopBar = '(?s)\.padding\(\.top, \(UIApplication.*?\.padding\(\.bottom, 12\)'
$replacementEBookTopBar = @"
        .padding(.top, (UIApplication.shared.connectedScenes.compactMap { `$0 as? UIWindowScene }.first?.windows.first?.safeAreaInsets.top ?? 47) + 8)
        .padding(.bottom, 12)
"@

$content = [regex]::Replace($content, $targetEBookTopBar, $replacementEBookTopBar)
Set-Content -Path $path -Value $content -Encoding UTF8
