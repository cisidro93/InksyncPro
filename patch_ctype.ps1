$path = "c:\Users\chris\.gemini\antigravity\scratch\InksyncPro\ComicToPDF\ComicToPDF\Services\State\ImportOrchestrator.swift"
$content = Get-Content -Raw -Path $path

$pattern1 = '(?sm)let \w+ = destURL\.pathExtension\.lowercased\(\)[\r\n\s]+var cType: ContentType = \.book[\r\n\s]+if \w+ == "pdf" \|\| \w+ == "epub" \{ cType = \.book \} else \{ cType = \.comic \}'
$replacement = 'let cType = MetadataHeuristics.detectAsymmetricContentType(url: destURL)'
$content = [regex]::Replace($content, $pattern1, $replacement)

$pattern2 = '(?sm)var cType: ContentType = \.book[\r\n\s]+let \w+ = destURL\.pathExtension\.lowercased\(\)[\r\n\s]+if \w+ == "pdf" \|\| \w+ == "epub" \{ cType = \.book \} else \{ cType = \.comic \}'
$content = [regex]::Replace($content, $pattern2, $replacement)

Set-Content -Path $path -Value $content -Encoding UTF8
Write-Output "Patch successful for ImportOrchestrator."
