# scan_crashers.ps1
# Scans all Swift files for if let / guard let blocks containing try? or as? that could trigger type-checker bugs.

$swiftFiles = Get-ChildItem -Path "ComicToPDF/ComicToPDF" -Filter "*.swift" -Recurse

foreach ($file in $swiftFiles) {
    $content = Get-Content -Raw -Path $file.FullName
    
    # We find if/guard let constructs
    # We can match: (if|guard)\s+let\s+.*?\{  or  else\s*\{
    # To keep it simple, we can search for blocks starting with 'if let' or 'guard let' up to the next '{' or 'else'
    
    $matches = [regex]::Matches($content, '(?sm)(if|guard)\s+let\s+([^\{]*?)(?=\{|\belse\b)')
    
    foreach ($m in $matches) {
        $block = $m.Value
        $cond = $m.Groups[2].Value
        
        # Check if condition contains try? or as?
        $hasTry = $cond -match 'try\?'
        $hasAs = $cond -match 'as\?'
        
        if ($hasTry -or $hasAs) {
            # Let's find the line number of this match
            $index = $m.Index
            $lineNum = ($content.Substring(0, $index) -split "`n").Count
            
            Write-Host "File: $($file.FullName) (Line: $lineNum)"
            Write-Host "Type: $($m.Groups[1].Value) let"
            Write-Host "Condition: $cond"
            Write-Host ("-" * 40)
        }
    }
}
