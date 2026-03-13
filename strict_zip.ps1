param (
    [string]$SourceFolder = "c:\Users\chris\.gemini\antigravity\scratch\InksyncPro\minimal_epub_test",
    [string]$OutputFile = "c:\Users\chris\.gemini\antigravity\scratch\InksyncPro\minimal_strict.epub"
)

if (-not (Test-Path -Path $SourceFolder)) {
    Write-Host "Folder $SourceFolder does not exist."
    exit 1
}

Add-Type -AssemblyName System.IO.Compression.FileSystem

if (Test-Path $OutputFile) {
    Remove-Item $OutputFile -Force
}

# Create zip file properly
$zipStream = [System.IO.File]::Open($OutputFile, [System.IO.FileMode]::Create)
$zipArchive = New-Object System.IO.Compression.ZipArchive($zipStream, [System.IO.Compression.ZipArchiveMode]::Create)

Write-Host "Adding mimetype (NoCompression)..."
$mimeEntry = $zipArchive.CreateEntry("mimetype", [System.IO.Compression.CompressionLevel]::NoCompression)
$memStream = $mimeEntry.Open()
$mimeBytes = [System.Text.Encoding]::ASCII.GetBytes("application/epub+zip")
$memStream.Write($mimeBytes, 0, $mimeBytes.Length)
$memStream.Close()

$files = Get-ChildItem -Path $SourceFolder -Recurse -File | Where-Object { $_.Name -ne "mimetype" }

foreach ($file in $files) {
    $relPath = $file.FullName.Substring($SourceFolder.Length + 1).Replace('\', '/')
    Write-Host "Adding $relPath ..."
    
    $entry = $zipArchive.CreateEntry($relPath, [System.IO.Compression.CompressionLevel]::Optimal)
    $entryStream = $entry.Open()
    $fileStream = [System.IO.File]::OpenRead($file.FullName)
    $fileStream.CopyTo($entryStream)
    $fileStream.Close()
    $entryStream.Close()
}

$zipArchive.Dispose()
$zipStream.Close()

Write-Host "Successfully generated $OutputFile with STRICT EPUB3 zip packaging."
