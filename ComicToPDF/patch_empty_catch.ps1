$pattern = 'catch\s*\{\s*\}'
$replacement = 'catch { Logger.shared.log("Silenced empty catch: \(error.localizedDescription)", category: "System", level: .error) }'

$files = Get-ChildItem -Path "ComicToPDF\ComicToPDF" -Recurse -Filter "*.swift"
$count = 0

foreach ($file in $files) {
    $content = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8)
    
    if ($content -match $pattern) {
        $newContent = [regex]::Replace($content, $pattern, $replacement)
        [System.IO.File]::WriteAllText($file.FullName, $newContent, [System.Text.Encoding]::UTF8)
        Write-Host "Patched: $($file.Name)"
        $count++
    }
}

Write-Host "Total files patched: $count"
