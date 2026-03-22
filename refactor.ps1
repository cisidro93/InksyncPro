$file = "c:\Users\chris\.gemini\antigravity\scratch\InksyncPro\ComicToPDF\ComicToPDF\Services\Conversion\ConversionManager.swift"
$lines = Get-Content $file -Encoding UTF8

$facade = @"
    // MARK: - Orchestrator Façade Connectors
    func importFolderStructure(from folderURL: URL) async {
        await ImportOrchestrator.shared.importFolderStructure(from: folderURL, manager: self)
    }

    func importFilesAsSeries(urls: [URL]) async {
        await ImportOrchestrator.shared.importFilesAsSeries(urls: urls, manager: self)
    }

    func assignToSeries(_ pdf: ConvertedPDF, seriesName: String) {
        ImportOrchestrator.shared.assignToSeries(pdf, seriesName: seriesName, manager: self)
    }

    func syncWatchedFolders() async {
        await ImportOrchestrator.shared.syncWatchedFolders(manager: self)
    }

    func detectContentType(from url: URL) -> ContentType {
        return ImportOrchestrator.shared.detectContentType(from: url, manager: self)
    }

    func importPDF(url: URL) async {
        await ImportOrchestrator.shared.importPDF(url: url, manager: self)
    }
    
"@
$facadeLines = $facade -split "`r`n"
$newLines = @()
$newLines += $lines[0..704]
$newLines += $facadeLines
$newLines += $lines[1344..($lines.Count-1)]

$newLines | Set-Content -Path $file -Encoding UTF8
