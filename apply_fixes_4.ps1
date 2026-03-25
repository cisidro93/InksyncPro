$path = "c:\Users\chris\.gemini\antigravity\scratch\InksyncPro\ComicToPDF\ComicToPDF\Views\Reader\EBookReaderView.swift"
$content = Get-Content -Raw -Encoding UTF8 $path

$content = [regex]::Replace($content, '(?m)^\s*@AppStorage\("ebook_fontSize"\).*$', '')
$content = [regex]::Replace($content, '(?m)^\s*@AppStorage\("ebook_fontFamily"\).*$', '')
$content = [regex]::Replace($content, '(?m)^\s*@AppStorage\("ebook_lineHeight"\).*$', '')
$content = [regex]::Replace($content, '(?m)^\s*@AppStorage\("ebook_theme"\).*$', '')
$content = [regex]::Replace($content, '(?m)^\s*@AppStorage\("ebook_progress_placeholder"\).*$', '')

$targetStructProps = '(?s)struct EBookWebReader: UIViewRepresentable \{\s+let spineItem:\s+EBookMetadata\.SpineItem\s+let unzipDir:\s+URL\?\s+let theme:\s+EBookTheme\s+let fontSize:\s+Double\s+let fontFamily:\s+String\s+let lineHeight:\s+Double'

$replacementStructProps = @"
struct EBookWebReader: UIViewRepresentable {
    let spineItem:  EBookMetadata.SpineItem
    let unzipDir:   URL?
    @ObservedObject var prefs: EBookPreferences
    let colorScheme: ColorScheme
"@
$content = [regex]::Replace($content, $targetStructProps, $replacementStructProps)


$targetCaller = '(?s)spineItem:\s+meta\.spineItems\[currentIndex\],\s+unzipDir:\s+unzipDir,\s+theme:\s+theme,\s+fontSize:\s+fontSize,\s+fontFamily:\s+fontFamily,\s+lineHeight:\s+lineHeight'
$replacementCaller = @"
                            spineItem:  meta.spineItems[currentIndex],
                            unzipDir:   unzipDir,
                            prefs:      prefs,
                            colorScheme: colorScheme
"@
$content = [regex]::Replace($content, $targetCaller, $replacementCaller)

Set-Content -Path $path -Value $content -Encoding UTF8
