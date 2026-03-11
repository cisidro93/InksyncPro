---
description: Pushes changes to the ios-port branch and immediately regenerates the full_source_code.txt artifact.
---

1. Push changes to GitHub
   ```powershell
   git push origin ios-port
   ```

2. Regenerate full_source_code.txt
   ```powershell
   Get-ChildItem -Path "c:\Users\chris\.gemini\antigravity\scratch\cbz_to_pdf\ComicToPDF\ComicToPDF" -Recurse -Filter *.swift | ForEach-Object { 
       "`n// ============================================================================" 
       "// File: " + $_.Name 
       "// Path: " + $_.FullName 
       "// ============================================================================`n" 
       Get-Content $_.FullName -Raw 
   } | Set-Content -Path "c:\Users\chris\.gemini\antigravity\brain\c5d1cb86-d4ce-4c31-a4aa-96502fc6ab69\full_source_code.txt" -Encoding UTF8
   ```

3. Notify user that source code is updated.
