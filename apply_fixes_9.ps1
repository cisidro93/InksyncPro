$path = "c:\Users\chris\.gemini\antigravity\scratch\InksyncPro\ComicToPDF\ComicToPDF\Views\Reader\EBookReaderView.swift"
$content = Get-Content -Raw -Encoding UTF8 $path

# 1. Inject page tracking keys
$targetState = '(?s)// Per-book progress key: fingerprinted by filename\s+private var progressKey: String \{ "ebook_progress_\\\(fileURL\.lastPathComponent\.hashValue\)" \}'
$replacementState = @"
    // Per-book progress key: fingerprinted by filename
    private var progressKey: String { "ebook_progress_\(fileURL.lastPathComponent.hashValue)" }
    private var pageKey: String { "ebook_page_\(fileURL.lastPathComponent.hashValue)" }
"@
$content = [regex]::Replace($content, $targetState, $replacementState)


# 2. Inject initialPage into loadBook and EBookWebReader
$targetLoadBook = '(?s)let saved = UserDefaults\.standard\.integer\(forKey: progressKey\)'
$replacementLoadBook = @"
        let saved = UserDefaults.standard.integer(forKey: progressKey)
        let savedPage = UserDefaults.standard.integer(forKey: pageKey)
"@
$content = [regex]::Replace($content, $targetLoadBook, $replacementLoadBook)

$targetSetter = '(?s)self\.currentIndex = min\(saved, max\(0, total - 1\)\)'
$replacementSetter = @"
                self.currentIndex = min(saved, max(0, total - 1))
                if saved == self.currentIndex {
                    self.chapterPage = savedPage
                } else {
                    self.chapterPage = 0
                }
"@
$content = [regex]::Replace($content, $targetSetter, $replacementSetter)

$targetSaveProgress = '(?s)private func saveProgress\(\) \{\s+UserDefaults\.standard\.set\(currentIndex, forKey: progressKey\)\s+\}'
$replacementSaveProgress = @"
    private func saveProgress() {
        UserDefaults.standard.set(currentIndex, forKey: progressKey)
        UserDefaults.standard.set(chapterPage, forKey: pageKey)
    }
"@
$content = [regex]::Replace($content, $targetSaveProgress, $replacementSaveProgress)

# Update Next/Prev logic
$targetNextPrev = '(?s)private func nextChapter\(\) \{\s+guard currentIndex < totalChapters - 1 else \{ return \}\s+withAnimation\(\.easeInOut\(duration: 0\.18\)\) \{ currentIndex \+= 1 \}\s+saveProgress\(\)\s+\}\s+private func prevChapter\(\) \{\s+guard currentIndex > 0 else \{ return \}\s+withAnimation\(\.easeInOut\(duration: 0\.18\)\) \{ currentIndex -= 1 \}\s+saveProgress\(\)\s+\}'
$replacementNextPrev = @"
    private func nextChapter() {
        guard currentIndex < totalChapters - 1 else { return }
        chapterPage = 0 // Start next chapter at page 0
        withAnimation(.easeInOut(duration: 0.18)) { currentIndex += 1 }
        saveProgress()
    }
    
    private func prevChapter() {
        guard currentIndex > 0 else { return }
        chapterPage = 99999 // Send a signal to JS to jump to the END of the previous chapter
        withAnimation(.easeInOut(duration: 0.18)) { currentIndex -= 1 }
        saveProgress()
    }
"@
$content = [regex]::Replace($content, $targetNextPrev, $replacementNextPrev)

# Update the WebReader signature to request initialPage
$targetSignature = '(?s)let colorScheme: ColorScheme\s+@Binding var currentPage: Int'
$replacementSignature = @"
    let colorScheme: ColorScheme
    @Binding var currentPage: Int
    var initialPage: Int
"@
$content = [regex]::Replace($content, $targetSignature, $replacementSignature)

$targetInitialize = '(?s)EBookWebReader\(\s+spineItem:  meta\.spineItems\[currentIndex\],\s+unzipDir:   unzipDir,\s+prefs:      prefs,\s+colorScheme: colorScheme,\s+currentPage: \$chapterPage,'
$replacementInitialize = @"
                        EBookWebReader(
                            spineItem:  meta.spineItems[currentIndex],
                            unzipDir:   unzipDir,
                            prefs:      prefs,
                            colorScheme: colorScheme,
                            currentPage: `$chapterPage,
                            initialPage: chapterPage,
"@
$content = [regex]::Replace($content, $targetInitialize, $replacementInitialize)

$targetInjectCall = '(?s)let styledHTML = injectReaderCSS\(into: html, prefs: prefs, colorScheme: colorScheme\)'
$replacementInjectCall = @"
            let styledHTML = injectReaderCSS(into: html, prefs: prefs, colorScheme: colorScheme, initialPage: initialPage)
"@
$content = [regex]::Replace($content, $targetInjectCall, $replacementInjectCall)

$targetInjectSignature = '(?s)private func injectReaderCSS\(into html: String, prefs: EBookPreferences, colorScheme: ColorScheme\) -> String \{'
$replacementInjectSignature = @"
    private func injectReaderCSS(into html: String, prefs: EBookPreferences, colorScheme: ColorScheme, initialPage: Int) -> String {
"@
$content = [regex]::Replace($content, $targetInjectSignature, $replacementInjectSignature)

$targetJSCurrentPage = '(?s)var _currentPage = 0;'
$replacementJSCurrentPage = @"
        var _currentPage = `\(initialPage);
"@
$content = [regex]::Replace($content, $targetJSCurrentPage, $replacementJSCurrentPage)


# 3. Two column support on larger widths
$targetPagedCSS = '(?s)let isPaged = prefs\.paginationMode == EBookPaginationMode\.paged\.rawValue\s+let pagedCSS = isPaged \? """\s+/\* Paged \*/\s+column-width: calc\(100vw - \\\(prefs\.textMargin \* 2\)px\) !important;\s+column-gap: \\\(prefs\.textMargin \* 2\)px !important;\s+column-fill: auto !important;\s+""" : ""'
$replacementPagedCSS = @"
        let isPaged = prefs.paginationMode == EBookPaginationMode.paged.rawValue
        let pagedCSS = isPaged ? `"""
            /* iPad uses 2 columns if screen is wide enough */
            @media (min-width: 768px) {
                column-count: 2 !important;
                column-width: auto !important;
                column-gap: \`\(prefs.textMargin * 3)px !important;
                column-fill: auto !important;
            }
            @media (max-width: 767px) {
                column-width: calc(100vw - \`\(prefs.textMargin * 2)px) !important;
                column-gap: \`\(prefs.textMargin * 2)px !important;
                column-fill: auto !important;
            }
        `""" : ""
"@
$content = [regex]::Replace($content, $targetPagedCSS, $replacementPagedCSS)


Set-Content -Path $path -Value $content -Encoding UTF8
