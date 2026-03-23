$files = @(
    "c:\Users\chris\.gemini\antigravity\scratch\InksyncPro\ComicToPDF\ComicToPDF\Services\State\ImportOrchestrator.swift",
    "c:\Users\chris\.gemini\antigravity\scratch\InksyncPro\ComicToPDF\ComicToPDF\Services\State\PhysicalFileSystemRouter.swift"
)

foreach ($f in $files) {
    $c = Get-Content $f -Raw
    
    # ImportOrchestrator specific fixes
    $c = $c -replace 'await Task\.detached\(priority: \.userInitiated\) \{\s*let fileManager = FileManager\.default', "await Task.detached(priority: .userInitiated) { () -> [ConvertedPDF] in`n            let fileManager = FileManager.default"
    
    $c = $c -replace 'await Task\.detached\(priority: \.userInitiated\) \{\s*let accessing = folderURL\.startAccessing', "await Task.detached(priority: .userInitiated) { () -> [ConvertedPDF] in`n            let accessing = folderURL.startAccessing"
    
    # PhysicalFileSystemRouter specific fixes
    $c = $c -replace 'return await Task\.detached\(priority: \.userInitiated\) \{\s*if let url = self\.getCoverURL', "return await Task.detached(priority: .userInitiated) { () -> UIImage? in`n            if let url = self.getCoverURL"

    $c = $c -replace 'let image = await Task\.detached\(priority: \.background\) \{\s*return ConversionManager\.extractCoverImageStatic', "let image = await Task.detached(priority: .background) { () -> UIImage? in`n            return ConversionManager.extractCoverImageStatic"

    
    $c | Set-Content $f -Encoding UTF8
}
