$content = Get-Content -Raw -Path "ComicToPDF/ComicToPDF/Services/Network/WiFiServer.swift"
# Match all returns
$matches = [regex]::Matches($content, '(?s)return """(.*?)"""')
if ($matches.Count -ge 2) {
    # Extract the second template (the main dashboard)
    $html = $matches[1].Groups[1].Value
    $html = $html -replace '\\\(filesJSONString\)', '[]'
    $html = $html -replace '\\\(queueButtonHTML\)', ''
    $html | Out-File -Encoding utf8 "scratch/test_server.html"
    Write-Host "Main dashboard HTML generated successfully at scratch/test_server.html"
} else {
    Write-Host "Could not locate the second generateHTML return block"
}
