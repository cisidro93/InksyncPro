$path = "c:\Users\chris\.gemini\antigravity\scratch\InksyncPro\ComicToPDF\ComicToPDF\Views\Reader\EBookReaderView.swift"
$content = Get-Content -Raw -Encoding UTF8 $path

$content = [regex]::Replace($content, '(?m)^\s*@State private var showSettings = false\r?\n', '')
$content = [regex]::Replace($content, '(?m)^\s*if showSettings\s*\{ settingsHUD \}\r?\n', '')

$targetBtn = '(?s)Button \{\s*withAnimation\(\.spring\(\)\)\s*\{\s*showSettings\.toggle\(\);\s*if showSettings\s*\{\s*showChapterList = false\s*\}\s*\}\s*\} label: \{\s*(.*?)\.background\(showSettings \? prefs\.activeTheme\.foreground\(colorScheme: colorScheme\)\.opacity\(0\.15\) : prefs\.activeTheme\.foreground\(colorScheme: colorScheme\)\.opacity\(0\.08\)\)(.*?)\}'
$replacementBtn = @"
            Button { showingSettingsPanel.toggle(); showChapterList = false } label: {
                `$1.background(prefs.activeTheme.foreground(colorScheme: colorScheme).opacity(0.08))`$2}
"@
$content = [regex]::Replace($content, $targetBtn, $replacementBtn)

$targetBtn2 = '(?s)Button \{\s*withAnimation\(\.spring\(\)\)\s*\{\s*showChapterList\.toggle\(\);\s*if showChapterList\s*\{\s*showSettings = false\s*\}\s*\}\s*\} label: \{'
$replacementBtn2 = 'Button { withAnimation(.spring()) { showChapterList.toggle() } } label: {'
$content = [regex]::Replace($content, $targetBtn2, $replacementBtn2)

$targetSheet = '(?s)\.task \{ await loadBook\(\) \}'
$replacementSheet = @"
        .sheet(isPresented: `$showingSettingsPanel) {
            EBookSettingsPanel()
                .presentationDetents([.medium, .large])
        }
        .task { await loadBook() }
"@
$content = [regex]::Replace($content, $targetSheet, $replacementSheet)

Set-Content -Path $path -Value $content -Encoding UTF8
