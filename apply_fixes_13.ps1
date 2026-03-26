$paths = @(
    "c:\Users\chris\.gemini\antigravity\scratch\InksyncPro\ComicToPDF\ComicToPDF\Views\Library\ModernLibraryView.swift",
    "c:\Users\chris\.gemini\antigravity\scratch\InksyncPro\ComicToPDF\ComicToPDF\Views\Library\ReadNowTabView.swift",
    "c:\Users\chris\.gemini\antigravity\scratch\InksyncPro\ComicToPDF\ComicToPDF\Views\Library\SeriesDetailView.swift",
    "c:\Users\chris\.gemini\antigravity\scratch\InksyncPro\ComicToPDF\ComicToPDF\Views\Reader\SplitStudyWorkspace.swift",
    "c:\Users\chris\.gemini\antigravity\scratch\InksyncPro\ComicToPDF\ComicToPDF\Views\Reader\ReaderView.swift",
    "c:\Users\chris\.gemini\antigravity\scratch\InksyncPro\ComicToPDF\ComicToPDF\Views\Reader\EBookReaderView.swift"
)

# 1. Update ReaderView.swift
$path = $paths[4]
$content = Get-Content -Raw -Encoding UTF8 $path
$content = [regex]::Replace($content, '(?s)let pdf: ConvertedPDF\?', "let pdf: ConvertedPDF?`n    var onExit: (() -> Void)? = nil")
$content = [regex]::Replace($content, '(?s)Button \{ dismiss\(\) \} label: \{', "Button { if let onExit = onExit { onExit() } else { dismiss() } } label: {")
$content = [regex]::Replace($content, '(?s)EBookReaderView\(\s+fileURL: fileURL,\s+title: fileURL\.deletingPathExtension\(\)\.lastPathComponent\s+\)', "EBookReaderView(`n                        fileURL: fileURL,`n                        title: fileURL.deletingPathExtension().lastPathComponent,`n                        onExit: onExit ?? { dismiss() }`n                    )")
Set-Content -Path $path -Value $content -Encoding UTF8

# 2. Update EBookReaderView.swift
$path = $paths[5]
$content = Get-Content -Raw -Encoding UTF8 $path
$content = [regex]::Replace($content, '(?s)let title: String', "let title: String`n    var onExit: (() -> Void)? = nil")
$content = [regex]::Replace($content, '(?s)Button \{ dismiss\(\) \} label: \{', "Button { if let onExit = onExit { onExit() } else { dismiss() } } label: {")
Set-Content -Path $path -Value $content -Encoding UTF8

# 3. Update SplitStudyWorkspace.swift
$path = $paths[3]
$content = Get-Content -Raw -Encoding UTF8 $path
$content = [regex]::Replace($content, '(?s)ReaderView\s*\(\s*fileURL:\s*fileURL,\s*contentType:\s*contentType,\s*pdf:\s*pdf\s*\)', "ReaderView(fileURL: fileURL, contentType: contentType, pdf: pdf, onExit: { dismiss() })")
Set-Content -Path $path -Value $content -Encoding UTF8

# 4. Update ModernLibraryView.swift
$path = $paths[0]
$content = Get-Content -Raw -Encoding UTF8 $path
$content = [regex]::Replace($content, '(?s)SplitStudyWorkspace\s*\(\s*fileURL:\s*pdf\.url,\s*contentType:\s*pdf\.contentType,\s*pdf:\s*pdf\s*\)', "if pdf.contentType == .book { SplitStudyWorkspace(fileURL: pdf.url, contentType: pdf.contentType, pdf: pdf) } else { ReaderView(fileURL: pdf.url, contentType: pdf.contentType, pdf: pdf) }")
Set-Content -Path $path -Value $content -Encoding UTF8

# 5. Update ReadNowTabView.swift
$path = $paths[1]
$content = Get-Content -Raw -Encoding UTF8 $path
$content = [regex]::Replace($content, '(?s)SplitStudyWorkspace\s*\(\s*fileURL:\s*pdf\.url,\s*contentType:\s*pdf\.contentType,\s*pdf:\s*pdf\s*\)', "if pdf.contentType == .book { SplitStudyWorkspace(fileURL: pdf.url, contentType: pdf.contentType, pdf: pdf) } else { ReaderView(fileURL: pdf.url, contentType: pdf.contentType, pdf: pdf) }")
Set-Content -Path $path -Value $content -Encoding UTF8

# 6. Update SeriesDetailView.swift
$path = $paths[2]
$content = Get-Content -Raw -Encoding UTF8 $path
$content = [regex]::Replace($content, '(?s)SplitStudyWorkspace\s*\(\s*fileURL:\s*pdf\.url,\s*contentType:\s*pdf\.contentType,\s*pdf:\s*pdf\s*\)', "if pdf.contentType == .book { SplitStudyWorkspace(fileURL: pdf.url, contentType: pdf.contentType, pdf: pdf) } else { ReaderView(fileURL: pdf.url, contentType: pdf.contentType, pdf: pdf) }")
Set-Content -Path $path -Value $content -Encoding UTF8
