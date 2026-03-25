$path = "c:\Users\chris\.gemini\antigravity\scratch\InksyncPro\ComicToPDF\ComicToPDF\Views\Reader\BookReaderEngine.swift"
$content = Get-Content -Raw -Encoding UTF8 $path

$target1 = "if action == #selector\(copy\(_:\)\) \{\s+return true\s+\}\s+return false // Hide definition, share, etc\. for cleaner UI"
$replacement1 = @"
        let actionStr = NSStringFromSelector(action)
        let allowedNativeFunctions = ["copy:", "_lookup:", "_translate:", "share:", "_define:", "speak:"]
        
        if allowedNativeFunctions.contains(actionStr) {
            return true
        }
        
        return super.canPerformAction(action, withSender: sender)
"@

$content = [regex]::Replace($content, $target1, $replacement1)

$target2 = "AnnotationStore\.shared\.add\(highlight\)"
$replacement2 = "AnnotationStore.shared.add(highlight)`n                        StudyNotesStore.shared.appendHighlight(selectedText, chapter: `"Chapter `\(vm.currentChapterIndex + 1)`")"

$content = [regex]::Replace($content, $target2, $replacement2)

Set-Content -Path $path -Value $content -Encoding UTF8
