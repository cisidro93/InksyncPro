$path = "c:\Users\chris\.gemini\antigravity\scratch\InksyncPro\ComicToPDF\ComicToPDF\Services\Core\SharedModels.swift"
$lines = Get-Content -Path $path
$newlines = @()

for ($i = 0; $i -lt 200; $i++) { $newlines += $lines[$i] }

$insertion = @"
    // ✅ Rich Metadata
    var writer: String?
    var penciller: String?
    
    // ✅ LEGACY PROPERTIES
    @available(*, deprecated, message: `"Use universalIssueID instead`")
    var comicVineID: Int?
    @available(*, deprecated, message: `"Use universalSeriesID instead`")
    var seriesID: Int?
    
    // ✅ Polymorphic String IDs
    var externalSeriesID: String?
    var externalIssueID: String?
    
    var universalSeriesID: String? {
        get { externalSeriesID ?? seriesID.map(String.init) }
        set { externalSeriesID = newValue }
    }
    
    var universalIssueID: String? {
        get { externalIssueID ?? comicVineID.map(String.init) }
        set { externalIssueID = newValue }
    }
    
    var tags: [String] = []
"@
$insertionLines = $insertion.Split("`n").Replace("`r", "")
$newlines += $insertionLines

for ($i = 224; $i -lt $lines.Length; $i++) { $newlines += $lines[$i] }

Set-Content -Path $path -Value ($newlines -join "`r`n") -Encoding UTF8
