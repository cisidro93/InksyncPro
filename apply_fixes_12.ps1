$path = "c:\Users\chris\.gemini\antigravity\scratch\InksyncPro\ComicToPDF\ComicToPDF\Views\Reader\EBookReaderView.swift"
$content = Get-Content -Raw -Encoding UTF8 $path

$targetBraces = '(?s)        \}\r?\n        \}\r?\n    \}\r?\n\}'
$replacementBraces = @"
        }
    }
}
"@
$content = [regex]::Replace($content, $targetBraces, $replacementBraces)

Set-Content -Path $path -Value $content -Encoding UTF8
