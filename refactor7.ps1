$f = "c:\Users\chris\.gemini\antigravity\scratch\InksyncPro\ComicToPDF\ComicToPDF\Services\Conversion\ConversionManager.swift"
$c = Get-Content $f -Raw
$c = $c.TrimEnd().TrimEnd("}") + @"

    // MARK: - Orchestrator Restored Callbacks
    func finalizeSeriesImport(pdfs: [ConvertedPDF], seriesName: String) async {
        await ImportOrchestrator.shared.finalizeSeriesImport(pdfs: pdfs, seriesName: seriesName, manager: self)
    }
}
"@
$c | Set-Content $f -Encoding UTF8
