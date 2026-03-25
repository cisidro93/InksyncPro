$path = "c:\Users\chris\.gemini\antigravity\scratch\InksyncPro\ComicToPDF\ComicToPDF\Views\Reader\EBookReaderView.swift"
$content = Get-Content -Raw -Encoding UTF8 $path

$targetCSSHtml = '(?s)<meta charset="utf-8">\r?\n\s*<style id="__inksync_reader__">'
$replacementCSSHtml = @"
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no, viewport-fit=cover">
        <style id="__inksync_reader__">
"@
$content = [regex]::Replace($content, $targetCSSHtml, $replacementCSSHtml)

$targetCSSColor = '(?s)p \{ margin-bottom: \\\(prefs\.paragraphSpacing\)em !important; text-indent: \\\(prefs\.paragraphIndent\)em !important; \}\r?\n\s*h1,h2,h3,h4 \{ color: \\\(prefs\.activeTheme\.cssText\(colorScheme: colorScheme\)\) !important; line-height: 1\.3; \}'
$replacementCSSColor = @"
        p { margin-bottom: \`\(prefs.paragraphSpacing)em !important; text-indent: \`\(prefs.paragraphIndent)em !important; }
        p, div, span, li, td, th, h1, h2, h3, h4, h5, h6 { color: \`\(prefs.activeTheme.cssText(colorScheme: colorScheme)) !important; line-height: 1.3; }
"@
$content = [regex]::Replace($content, $targetCSSColor, $replacementCSSColor)

Set-Content -Path $path -Value $content -Encoding UTF8
