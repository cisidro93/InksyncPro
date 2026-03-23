$f = "c:\Users\chris\.gemini\antigravity\scratch\InksyncPro\ComicToPDF\ComicToPDF\Services\Conversion\ConversionManager.swift"
$lines = Get-Content $f -Encoding UTF8

# Block 4: 2099-2152 (0-indexed: 2098 to 2151)
$facade4 = @"
    /// Physically renames the underlying .cbz, .epub, or .pdf on the iOS Storage and updates the database pointer.
    func safelyRenamePhysicalFile(pdf: ConvertedPDF, newName: String) throws {
        try PhysicalFileSystemRouter.shared.safelyRenamePhysicalFile(pdf: pdf, newName: newName, manager: self)
    }
"@
$lines = $lines[0..2097] + ($facade4 -split "`r`n") + $lines[2152..($lines.Count-1)]

# Block 3: 1367-1454 (0-indexed: 1366 to 1453)
$facade3 = @"
    func generateCoverThumbnail(for pdf: ConvertedPDF) async {
        await PhysicalFileSystemRouter.shared.generateCoverThumbnail(for: pdf, manager: self)
    }
    
    func backfillMissingThumbnails() {
        PhysicalFileSystemRouter.shared.backfillMissingThumbnails(manager: self)
    }
    
    func loadThumbnailAsync(for pdf: ConvertedPDF) async {
        await PhysicalFileSystemRouter.shared.loadThumbnailAsync(for: pdf, manager: self)
    }
    
    func getThumbnail(for pdf: ConvertedPDF) -> UIImage? {
        PhysicalFileSystemRouter.shared.getThumbnail(for: pdf, manager: self)
    }
"@
$lines = $lines[0..1365] + ($facade3 -split "`r`n") + $lines[1454..($lines.Count-1)]

# Block 2: 510-527 (0-indexed: 509 to 526)
$facade2 = @"
    func deletePDF(_ pdf: ConvertedPDF) {
        PhysicalFileSystemRouter.shared.deletePDF(pdf, manager: self)
    }
    
    func removeFromLibrary(_ pdf: ConvertedPDF) { deletePDF(pdf) }
"@
$lines = $lines[0..508] + ($facade2 -split "`r`n") + $lines[527..($lines.Count-1)]

# Block 1: 272-359 (0-indexed: 271 to 358)
$facade1 = @"
    /// Returns the active cover (either the selected variant, or the original fallback)
    func getCoverURL(for pdf: ConvertedPDF) -> URL? {
        PhysicalFileSystemRouter.shared.getCoverURL(for: pdf)
    }

    /// Returns the absolute path to the original extracted cover image saved in Application Support
    func getOriginalCoverURL(for pdf: ConvertedPDF) -> URL {
        PhysicalFileSystemRouter.shared.getOriginalCoverURL(for: pdf)
    }
    
    /// Migrates legacy Data-based covers to disk-based storage
    func migrateCoversToDisk() {
        PhysicalFileSystemRouter.shared.migrateCoversToDisk(manager: self)
    }
    
    /// Thread-safe, memory-efficient cover loader
    func loadCoverThumbnail(for pdf: ConvertedPDF) async -> UIImage? {
        await PhysicalFileSystemRouter.shared.loadCoverThumbnail(for: pdf, manager: self)
    }
    
    /// Save cover image to disk and update cache
    func saveCoverImage(_ data: Data, for pdf: ConvertedPDF) {
        PhysicalFileSystemRouter.shared.saveCoverImage(data, for: pdf, manager: self)
    }
"@
$lines = $lines[0..270] + ($facade1 -split "`r`n") + $lines[359..($lines.Count-1)]

$lines | Set-Content $f -Encoding UTF8
