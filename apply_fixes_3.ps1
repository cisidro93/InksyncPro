$path = "c:\Users\chris\.gemini\antigravity\scratch\InksyncPro\ComicToPDF\ComicToPDF\Views\Reader\EBookReaderView.swift"
$content = Get-Content -Raw -Encoding UTF8 $path

# 1. Strip lines 5 through 61
$content = $content -replace '(?s)// MARK: - Reading Preferences.*?// MARK: - EBookReaderView', '// MARK: - EBookReaderView'

# 2. Replace @AppStorage prefs with StateObject and Environment
$targetAppStorage = '(?s)// Preferences — shared across all books.*?// Per-book progress key'
$replacementAppStorage = @"
    @StateObject private var prefs = EBookPreferences.shared
    @Environment(\.colorScheme) var colorScheme
    @State private var showingSettingsPanel = false
    
    // Per-book progress key
"@
$content = $content -replace $targetAppStorage, $replacementAppStorage

# 3. Strip 'theme' property
$content = $content -replace '    private var theme: EBookTheme \{ EBookTheme\(rawValue: themeRaw\) \?\? \.sepia \}', ''

# 4. Replace `theme.background` to `prefs.activeTheme.background(colorScheme: colorScheme)`
$content = $content -replace 'theme\.background', 'prefs.activeTheme.background(colorScheme: colorScheme)'
$content = $content -replace 'theme\.foreground', 'prefs.activeTheme.foreground(colorScheme: colorScheme)'

# 5. Fix UIUserInterfaceStyle preferredColorScheme
$content = $content -replace '\.preferredColorScheme\(theme\.systemUIStyle == \.dark \? \.dark : \.light\)', ''

# 6. Delete settingsHUD
$content = $content -replace '(?s)// MARK: - Settings HUD.*?\/\/ MARK: - Loading & Error States', '// MARK: - Loading & Error States'

# 7. Update settings toggle button to `.sheet` / `.popover`
$targetSettingsToggle = '(?s)Button \{\s+withAnimation\(\.spring\(\)\) \{\s+showSettings\.toggle\(\)\s+\}\s+\} label: \{'
$replacementSettingsToggle = @"
                        Button {
                            showingSettingsPanel.toggle()
                        } label: {
"@
$content = $content -replace $targetSettingsToggle, $replacementSettingsToggle

# 8. Add `.sheet` presentation securely before `.onAppear`
$content = $content -replace '\.onAppear \{', ".sheet(isPresented: `$showingSettingsPanel) {`n            EBookSettingsPanel().presentationDetents([.medium, .large])`n        }`n        .onAppear {"

# 9. Update EBookWebReader usage
$targetWebReader = '(?s)EBookWebReader\(\s+spineItem:\s+meta\.spineItems\[currentIndex\],\s+unzipDir:\s+unzipDir,\s+theme:\s+theme,\s+fontSize:\s+fontSize,\s+fontFamily:\s+fontFamily,\s+lineHeight:\s+lineHeight,'
$replacementWebReader = @"
                        EBookWebReader(
                            spineItem:  meta.spineItems[currentIndex],
                            unzipDir:   unzipDir,
                            prefs:      prefs,
                            colorScheme: colorScheme,
"@
$content = [regex]::Replace($content, $targetWebReader, $replacementWebReader)

# 10. Update EBookWebReader Struct Properties
$targetStructProps = '(?s)struct EBookWebReader: UIViewRepresentable \{\s+let spineItem: SpineItem\s+let unzipDir: URL\?\s+let theme:      EBookTheme\s+let fontSize:   Double\s+let fontFamily: String\s+let lineHeight: Double'
$replacementStructProps = @"
struct EBookWebReader: UIViewRepresentable {
    let spineItem: SpineItem
    let unzipDir: URL?
    @ObservedObject var prefs: EBookPreferences
    let colorScheme: ColorScheme
"@
$content = [regex]::Replace($content, $targetStructProps, $replacementStructProps)

# 11. Update updateUIView cache checking
$targetCache = '(?s)if context\.coordinator\.lastLoadedHref == spineItem\.href.*?if let html = try\? String'
$replacementCache = @"
        // Re-render trigger on ANY pref change
        let currentStateHash = "\(prefs.themeRaw)_\(prefs.fontSize)_\(prefs.fontFamily)_\(prefs.lineHeight)_\(prefs.textMargin)_\(prefs.paragraphSpacing)_\(prefs.paragraphIndent)_\(prefs.paginationMode)_\(prefs.textAlign)"
        
        if context.coordinator.lastLoadedHref == spineItem.href && context.coordinator.lastTheme == currentStateHash { return }
        context.coordinator.lastLoadedHref = spineItem.href
        context.coordinator.lastTheme = currentStateHash
        
        // Read HTML
        var rawHTML: String?
        var usedEncoding: String.Encoding = .utf8
        if let html = try? String
"@
$content = [regex]::Replace($content, $targetCache, $replacementCache)

# 12. Fix injectReaderCSS arguments
$content = $content -replace 'let styledHTML = injectReaderCSS\(into: html\)', 'let styledHTML = injectReaderCSS(into: html, prefs: prefs, colorScheme: colorScheme)'

# 13. Replace injectReaderCSS implementation
$targetInjectCSS = '(?s)private func injectReaderCSS\(into html: String\) -> String \{.*?return html\.replacingOccurrences\(of: "</head>", with: css \+ "</head>", options: \.caseInsensitive\)\s+\}'
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
        </script>
        `"""
        
        return html.replacingOccurrences(of: "</head>", with: css + "</head>", options: .caseInsensitive)
    }
"@

$content = [regex]::Replace($content, $targetInjectCSS, $replacementInjectCSS)

Set-Content -Path $path -Value $content -Encoding UTF8
