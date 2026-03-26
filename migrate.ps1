$ErrorActionPreference = "Stop"
$cmFile = "ComicToPDF\ComicToPDF\Services\Conversion\ConversionManager.swift"
$routerFile = "ComicToPDF\ComicToPDF\Services\State\PhysicalFileSystemRouter.swift"

$lines = Get-Content $cmFile -Encoding UTF8
$startIdx = -1
$endIdx = -1

for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match 'nonisolated static func extractCoverImageStatic') {
        $startIdx = $i
        break
    }
}

for ($i = $startIdx; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match 'func extractSmartPanels') {
        $endIdx = $i - 1
        break
    }
}

if ($startIdx -eq -1 -or $endIdx -eq -1) {
    Write-Host "Could not find bounds! $startIdx $endIdx"
    exit 1 
}

$staticFuncs = $lines[$startIdx..$endIdx]

$preCM = $lines[0..($startIdx - 1)]
$postCM = $lines[($endIdx + 1)..($lines.Count - 1)]

$newCM = [System.Collections.Generic.List[string]]::new()
$newCM.AddRange([string[]]$preCM)
$newCM.AddRange([string[]]$postCM)
[System.IO.File]::WriteAllLines((Resolve-Path $cmFile).Path, $newCM, [System.Text.Encoding]::UTF8)

$rLines = Get-Content $routerFile -Encoding UTF8
$insertIdx = $rLines.Count - 1

$newRouter = [System.Collections.Generic.List[string]]::new()
$newRouter.AddRange([string[]]$rLines[0..($insertIdx - 1)])
$newRouter.Add("    // MARK: - Extracted Static Disk Helpers")
$newRouter.AddRange([string[]]$staticFuncs)
$newRouter.Add("}")

[System.IO.File]::WriteAllLines((Resolve-Path $routerFile).Path, $newRouter, [System.Text.Encoding]::UTF8)
Write-Host "Migrated static disk helpers!"
