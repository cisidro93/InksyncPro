$paths = @(
    "c:\Users\chris\.gemini\antigravity\scratch\InksyncPro\ComicToPDF\ComicToPDF\Views\Reader\ReaderView.swift",
    "c:\Users\chris\.gemini\antigravity\scratch\InksyncPro\ComicToPDF\ComicToPDF\Views\Reader\EBookReaderView.swift",
    "c:\Users\chris\.gemini\antigravity\scratch\InksyncPro\ComicToPDF\ComicToPDF\Views\Import\SmartImportSheet.swift"
)

# 1. Update ReaderView.swift (Add onExit)
$path = $paths[0]
$content = Get-Content -Raw -Encoding UTF8 $path
$targetPdf = '(?s)let contentType: ContentType\r?\n\s+@State var pdf: ConvertedPDF\? // Added to support Bookmarking'
$replacementPdf = @"
    let contentType: ContentType
    @State var pdf: ConvertedPDF? // Added to support Bookmarking
    var onExit: (() -> Void)? = nil
"@
$content = [regex]::Replace($content, $targetPdf, $replacementPdf)
Set-Content -Path $path -Value $content -Encoding UTF8

# 2. Update EBookReaderView.swift (Fix $0 literal bug)
$path = $paths[1]
$content = Get-Content -Raw -Encoding UTF8 $path
$targetEBookTopBar = '(?s)\.padding\(\.top, \(UIApplication\.shared\.connectedScenes\.compactMap \{ \.padding\(\.horizontal, 16\)'
$replacementEBookTopBar = @"
        .padding(.top, (UIApplication.shared.connectedScenes.compactMap { `$0 as? UIWindowScene }.first?.windows.first?.safeAreaInsets.top ?? 47) + 8)
"@
$content = [regex]::Replace($content, $targetEBookTopBar, $replacementEBookTopBar)
Set-Content -Path $path -Value $content -Encoding UTF8

# 3. Update SmartImportSheet.swift (Fix onChange deprecation)
$path = $paths[2]
$content = Get-Content -Raw -Encoding UTF8 $path
$targetOnChange = '(?s)\.onChange\(of: vm\.isManga\) \{ _ in'
$replacementOnChange = @"
                .onChange(of: vm.isManga) {
"@
$content = [regex]::Replace($content, $targetOnChange, $replacementOnChange)
Set-Content -Path $path -Value $content -Encoding UTF8
