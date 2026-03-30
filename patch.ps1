$path = "C:\Users\chris\.gemini\antigravity\scratch\InksyncPro\ComicToPDF\ComicToPDF\Services\Core\SharedModels.swift"
$content = Get-Content -Raw -Path $path
$pattern = 'var comicVineID:\s*Int\?[\r\n\s]+var seriesID:\s*Int\?'

$replacement = @"
@available(*, deprecated, message="Use universalIssueID")
    var comicVineID: Int?
    @available(*, deprecated, message="Use universalSeriesID")
    var seriesID: Int?
    var externalSeriesID: String?
    var externalIssueID: String?
    
    var universalSeriesID: String? {
        get { externalSeriesID ?? seriesID.map({ `$0.description }) }
        set { externalSeriesID = `$0 }
    }
    
    var universalIssueID: String? {
        get { externalIssueID ?? comicVineID.map({ `$0.description }) }
        set { externalIssueID = `$0 }
    }
"@

$newContent = [regex]::Replace($content, $pattern, $replacement)
Set-Content -Path $path -Value $newContent -Encoding UTF8
Write-Output "Patch successful."
