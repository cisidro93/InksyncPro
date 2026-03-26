$path = "c:\Users\chris\.gemini\antigravity\scratch\InksyncPro\ComicToPDF\ComicToPDF\Views\Reader\EBookReaderView.swift"

$content = Get-Content -Raw -Encoding UTF8 $path

$target = '(?s)// MARK: - Top Bar\r?\n\s+@ViewBuilder private var topBar: some View \{.*?\r?\n\s+\}\r?\n\s+// MARK: - Bottom Bar'
$replacement = @"
    // MARK: - Top Bar
    @ViewBuilder private var topBar: some View {
        HStack(spacing: 16) {
            Button { if let onExit = onExit { onExit() } else { dismiss() } } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(prefs.activeTheme.foreground(colorScheme: colorScheme))
                    .padding(10)
                    .background(prefs.activeTheme.foreground(colorScheme: colorScheme).opacity(0.08))
                    .clipShape(Circle())
            }
            
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline).lineLimit(1).foregroundStyle(prefs.activeTheme.foreground(colorScheme: colorScheme))
                if let chapter = metadata?.spineItems[safe: currentIndex] {
                    Text(chapter.label).font(.caption).foregroundStyle(prefs.activeTheme.foreground(colorScheme: colorScheme).opacity(0.55)).lineLimit(1)
                }
            }
            
            Spacer()
            
            Button { showingSettingsPanel.toggle(); showChapterList = false } label: {
                Image(systemName: "textformat.size")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(prefs.activeTheme.foreground(colorScheme: colorScheme))
                    .padding(10)
                    .background(prefs.activeTheme.foreground(colorScheme: colorScheme).opacity(0.08))
                    .clipShape(Circle())
            }
            
            Button { withAnimation(.spring()) { showChapterList.toggle() } } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(prefs.activeTheme.foreground(colorScheme: colorScheme))
                    .padding(10)
                    .background(showChapterList ? prefs.activeTheme.foreground(colorScheme: colorScheme).opacity(0.15) : prefs.activeTheme.foreground(colorScheme: colorScheme).opacity(0.08))
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, (UIApplication.shared.connectedScenes.compactMap { `$0 as? UIWindowScene }.first?.windows.first?.safeAreaInsets.top ?? 47) + 8)
        .padding(.bottom, 12)
        .background(
            prefs.activeTheme.background(colorScheme: colorScheme).opacity(0.92)
                .background(.ultraThinMaterial.opacity(0.3))
                .ignoresSafeArea(edges: .top)
        )
    }
    
    // MARK: - Bottom Bar
"@

$newContent = [regex]::Replace($content, $target, $replacement)
Set-Content -Path $path -Value $newContent -Encoding UTF8
