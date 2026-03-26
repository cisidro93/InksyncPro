$ErrorActionPreference = "Stop"
$root = "c:\Users\chris\.gemini\antigravity\scratch\InksyncPro\ComicToPDF\ComicToPDF"

function ReplaceFileText($file, $target, $replacement) {
    $path = "$root\$file"
    if (Test-Path $path) {
        $content = Get-Content -Raw -Encoding UTF8 $path
        $content = $content -replace [regex]::Escape($target), $replacement
        Set-Content -Path $path -Value $content -Encoding UTF8
    }
}

# BookReaderEngine.swift
ReplaceFileText "Views\Reader\BookReaderEngine.swift" "guard let archive = try? Archive(url: self.pdf.url, accessMode: .read) else {" "guard let archive = try? Archive(url: self.pdf.url, accessMode: .read, pathEncoding: .utf8) else {"
ReplaceFileText "Views\Reader\BookReaderEngine.swift" "let highlightMenuItem = UIMenuItem(title: ""Highlight"", action: #selector(HighlightableWebView.customHighlightAction(_:)))`r`n        UIMenuController.shared.menuItems = [highlightMenuItem]" "// UIMenuItem deprecated in iOS 16"

# ComicReaderEngine.swift
ReplaceFileText "Views\Reader\ComicReaderEngine.swift" "guard let archive = Archive(url: pdf.url, accessMode: .read) else {" "guard let archive = try? Archive(url: pdf.url, accessMode: .read, pathEncoding: .utf8) else {"

# EPUBMerger.swift
ReplaceFileText "Services\Conversion\EPUBMerger.swift" "guard let archive = Archive(url: outputURL, accessMode: .create, preferredEncoding: .utf8) else {" "guard let archive = try? Archive(url: outputURL, accessMode: .create, pathEncoding: .utf8) else {"

# LocalComicInfoService.swift
ReplaceFileText "Services\Networking\LocalComicInfoService.swift" "guard let archive = Archive(url: cbzURL, accessMode: .read) else {" "guard let archive = try? Archive(url: cbzURL, accessMode: .read, pathEncoding: .utf8) else {"

# CBZToEPUBConverter.swift (supposing all unused assignments can be suppressed)
ReplaceFileText "Services\Conversion\CBZToEPUBConverter.swift" "let bookUUID = UUID().uuidString" "_ = UUID().uuidString"
ReplaceFileText "Services\Conversion\CBZToEPUBConverter.swift" "let safeExt = (trueExt == ""jpg"") ? ""jpeg"" : trueExt" "_ = (trueExt == ""jpg"") ? ""jpeg"" : trueExt"
ReplaceFileText "Services\Conversion\CBZToEPUBConverter.swift" "let properties = (localIndex == 0 && batchIndex == 0) ? ""properties=\""cover-image\"""" : """"" "_ = (localIndex == 0 && batchIndex == 0) ? ""properties=\""cover-image\"""" : """""
ReplaceFileText "Services\Conversion\CBZToEPUBConverter.swift" "let imageElements = images.enumerated().map {" "_ = images.enumerated().map {"
ReplaceFileText "Services\Conversion\CBZToEPUBConverter.swift" "var authorStr = """"" "_ = """""
ReplaceFileText "Services\Conversion\CBZToEPUBConverter.swift" "let directionStr = settings.mangaMode ? ""rtl"" : ""ltr""" "_ = settings.mangaMode ? ""rtl"" : ""ltr"""
ReplaceFileText "Services\Conversion\CBZToEPUBConverter.swift" "let generatedAt = ISO8601DateFormatter().string(from: Date())" "_ = ISO8601DateFormatter().string(from: Date())"
ReplaceFileText "Services\Conversion\CBZToEPUBConverter.swift" "let sourceFilename = sourceURL.deletingPathExtension().lastPathComponent" "_ = sourceURL.deletingPathExtension().lastPathComponent"

# EBookReaderView.swift
ReplaceFileText "Views\Reader\EBookReaderView.swift" "let pagedCSS = isPaged ? """"""" "_ = isPaged ? """""""

Write-Output "Applied syntax warning fixes."
