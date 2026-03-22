$f = "c:\Users\chris\.gemini\antigravity\scratch\InksyncPro\ComicToPDF\ComicToPDF\Services\Conversion\ConversionManager.swift"
$c = Get-Content $f -Raw

$replacements = @{
    '(?sm)func getCoverURL\(for pdf: ConvertedPDF\) -> URL\? \{.*?^\s*\}' = "func getCoverURL(for pdf: ConvertedPDF) -> URL? { PhysicalFileSystemRouter.shared.getCoverURL(for: pdf) }"
    '(?sm)func getOriginalCoverURL\(for pdf: ConvertedPDF\) -> URL \{.*?^\s*\}' = "func getOriginalCoverURL(for pdf: ConvertedPDF) -> URL { PhysicalFileSystemRouter.shared.getOriginalCoverURL(for: pdf) }"
    '(?sm)func migrateCoversToDisk\(\) \{.*?^\s*\}' = "func migrateCoversToDisk() { PhysicalFileSystemRouter.shared.migrateCoversToDisk(manager: self) }"
    '(?sm)func loadCoverThumbnail\(for pdf: ConvertedPDF\) async -> UIImage\? \{.*?^\s*\}' = "func loadCoverThumbnail(for pdf: ConvertedPDF) async -> UIImage? { await PhysicalFileSystemRouter.shared.loadCoverThumbnail(for: pdf, manager: self) }"
    '(?sm)func saveCoverImage\(_ data: Data, for pdf: ConvertedPDF\) \{.*?^\s*\}' = "func saveCoverImage(_ data: Data, for pdf: ConvertedPDF) { PhysicalFileSystemRouter.shared.saveCoverImage(data, for: pdf, manager: self) }"
    '(?sm)func deletePDF\(_ pdf: ConvertedPDF\) \{.*?^\s*\}' = "func deletePDF(_ pdf: ConvertedPDF) { PhysicalFileSystemRouter.shared.deletePDF(pdf, manager: self) }"
    '(?sm)func generateCoverThumbnail\(for pdf: ConvertedPDF\) async \{.*?^\s*\}' = "func generateCoverThumbnail(for pdf: ConvertedPDF) async { await PhysicalFileSystemRouter.shared.generateCoverThumbnail(for: pdf, manager: self) }"
    '(?sm)func backfillMissingThumbnails\(\) \{.*?^\s*\}' = "func backfillMissingThumbnails() { PhysicalFileSystemRouter.shared.backfillMissingThumbnails(manager: self) }"
    '(?sm)func loadThumbnailAsync\(for pdf: ConvertedPDF\) async \{.*?^\s*\}' = "func loadThumbnailAsync(for pdf: ConvertedPDF) async { await PhysicalFileSystemRouter.shared.loadThumbnailAsync(for: pdf, manager: self) }"
    '(?sm)func getThumbnail\(for pdf: ConvertedPDF\) -> UIImage\? \{.*?^\s*\}' = "func getThumbnail(for pdf: ConvertedPDF) -> UIImage? { PhysicalFileSystemRouter.shared.getThumbnail(for: pdf, manager: self) }"
    '(?sm)func safelyRenamePhysicalFile\(pdf: ConvertedPDF, newName: String\) throws \{.*?^\s*\}' = "func safelyRenamePhysicalFile(pdf: ConvertedPDF, newName: String) throws { try PhysicalFileSystemRouter.shared.safelyRenamePhysicalFile(pdf: pdf, newName: newName, manager: self) }"
}

foreach ($key in $replacements.Keys) {
    if ($c -match $key) {
        $c = [Regex]::Replace($c, $key, $replacements[$key])
    }
}

$c | Set-Content $f -Encoding UTF8
