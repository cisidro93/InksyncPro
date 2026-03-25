$path = "C:\Users\chris\.gemini\antigravity\scratch\InksyncPro\ComicToPDF\ComicToPDF\Views\Reader\BookReaderEngine.swift"
$content = Get-Content -Raw -Encoding UTF8 $path

$target1 = "if let html = try\? String\(contentsOf: url, encoding: \.utf8\) \{\s+self\.currentChapterHTML = html\s+self\.isLoading = false\s+\}"
$replacement1 = @"
        var rawHTML: String?
        var usedEncoding: String.Encoding = .utf8
        if let html = try? String(contentsOf: url, usedEncoding: &usedEncoding) {
            rawHTML = html
        } else if let data = try? Data(contentsOf: url) {
            rawHTML = String(data: data, encoding: .isoLatin1) ?? String(data: data, encoding: .ascii)
        }
        
        if var html = rawHTML {
            let pattern = "<meta[^>]*charset[^>]*>"
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                html = regex.stringByReplacingMatches(in: html, range: NSRange(html.startIndex..., in: html), withTemplate: "<meta charset=`"utf-8`">")
            }
            self.currentChapterHTML = html
            self.isLoading = false
        }
"@

$content = [regex]::Replace($content, $target1, $replacement1)

$target2 = "column-count: 1 !important;\s+\}\s+img \{ max-width: 100% !important; height: auto !important; \}\s+\.inksync-highlight \{ background-color: #ffd700; color: #000; border-radius: 3px; \}"
$replacement2 = @"
                    column-count: 1 !important;
                    /* Premium enhancements */
                    text-align: justify !important;
                    -webkit-hyphens: auto !important;
                    hyphens: auto !important;
                }
                img { max-width: 100% !important; height: auto !important; border-radius: 4px; object-fit: contain; }
                .inksync-highlight { background-color: #ffd700; color: #000; border-radius: 3px; }
"@

$content = [regex]::Replace($content, $target2, $replacement2)

Set-Content -Path $path -Value $content -Encoding UTF8
