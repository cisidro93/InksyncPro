$f = "c:\Users\chris\.gemini\antigravity\scratch\InksyncPro\ComicToPDF\ComicToPDF\Services\Conversion\ConversionManager.swift"
$c = Get-Content $f -Raw

$target = '(?sm)    func importFilesAsSeries\(urls: \[URL\]\) async \{.*?^\s*\}'
$replacement = @"
    func importFilesAsSeries(urls: [URL]) async {
        await ImportOrchestrator.shared.importFilesAsSeries(urls: urls, manager: self)
    }

    func finalizeSeriesImport(pdfs: [ConvertedPDF], seriesName: String) async {
        await ImportOrchestrator.shared.finalizeSeriesImport(pdfs: pdfs, seriesName: seriesName, manager: self)
    }
"@

$c = [Regex]::Replace($c, $target, $replacement)
$c | Set-Content $f -Encoding UTF8
