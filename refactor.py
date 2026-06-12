import re

with open('ComicToPDF/Views/Library/SeriesDetailView.swift', 'r', encoding='utf-8') as f:
    content = f.read()

prop_insertion = '''    @Environment(\\.horizontalSizeClass) private var hSizeClass
    
    enum LibraryViewStyle: String {
        case list = "List"
        case grid = "Grid"
    }
    
    @AppStorage("libraryViewStyle") private var viewStyle: LibraryViewStyle = .grid'''

content = content.replace('var useNavigationStack: Bool', 'var useNavigationStack: Bool\\n' + prop_insertion)

content = content.replace('private var contentList: some View {', 'private var mainContent: some View {')

list_start_idx = content.find('List {', content.find('private var mainContent: some View {'))

brace_count = 0
in_list = False
list_end_idx = -1
for i in range(list_start_idx, len(content)):
    if content[i] == '{':
        if not in_list:
            in_list = True
        brace_count += 1
    elif content[i] == '}':
        brace_count -= 1
        if brace_count == 0 and in_list:
            list_end_idx = i
            break

list_content = content[list_start_idx:list_end_idx+1]

main_content_replacement = '''Group {
            if viewStyle == .grid {
                gridView(scrollProxy: scrollProxy)
            } else {
                listView(scrollProxy: scrollProxy)
            }
        }'''

content = content[:list_start_idx] + main_content_replacement + content[list_end_idx+1:]

listView_func = '''
    private func listView(scrollProxy: ScrollViewProxy) -> some View {
        ''' + list_content + '''
    }
'''

gridView_func = '''
    private func gridView(scrollProxy: ScrollViewProxy) -> some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                headerView
                    .padding(.horizontal)
                    .padding(.bottom, 16)
                
                if let nextIssue = nextUnreadIssue {
                    Button {
                        pdfToRead = nextIssue
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 28))
                                .foregroundStyle(
                                    LinearGradient(colors: [Theme.orange, Theme.red],
                                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                                )
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Continue Reading")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(Theme.textSecondary)
                                    .tracking(0.8)
                                
                                Text(nextIssue.name)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(Theme.text)
                                    .lineLimit(1)
                                
                                if let vol = nextIssue.metadata.volume, !vol.isEmpty,
                                   let issue = nextIssue.metadata.issueNumber {
                                    Text("Vol. \\(vol) • Ch. \\(issue) • Page \\((nextIssue.metadata.lastReadPage ?? 0) + 1)")
                                        .font(.system(size: 11, design: .rounded))
                                        .foregroundColor(Theme.orange)
                                } else {
                                    Text("Page \\((nextIssue.metadata.lastReadPage ?? 0) + 1) of \\(nextIssue.pageCount)")
                                        .font(.system(size: 11, design: .rounded))
                                        .foregroundColor(Theme.orange)
                                }
                            }
                            
                            Spacer()
                            
                            Image(systemName: "chevron.right")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(Theme.textSecondary)
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Theme.orange.opacity(0.1))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(Theme.orange.opacity(0.2), lineWidth: 1)
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal)
                    .padding(.bottom, 16)
                }
                
                if !missingIssues.isEmpty {
                    MissingIssueBanner(gaps: missingIssues)
                        .padding(.horizontal)
                        .padding(.bottom, 16)
                }

                let hPad: CGFloat = hSizeClass == .regular ? 24 : 12
                let colSpacing: CGFloat = hSizeClass == .regular ? 20 : 10
                let colCount = hSizeClass == .regular ? 5 : 3
                let columns = Array(repeating: GridItem(.flexible(), spacing: colSpacing), count: colCount)

                if showVolumeGrouping && hasVolumeData {
                    ForEach(volumeGroups, id: \\.key) { group in
                        let isCollapsed = collapsedVolumes.contains(group.key)
                        let progress = readingProgress(for: group.issues)
                        let completed = completedCount(for: group.issues)
                        
                        Section(header: 
                            volumeHeaderView(group: group, isCollapsed: isCollapsed, progress: progress, completed: completed)
                                .background(.ultraThinMaterial)
                                .id("vol_\\(group.key)")
                        ) {
                            if !isCollapsed {
                                LazyVGrid(columns: columns, spacing: hSizeClass == .regular ? 28 : 14) {
                                    ForEach(group.issues) { pdf in
                                        gridIssueCell(pdf)
                                    }
                                }
                                .padding(.horizontal, hPad)
                                .padding(.vertical, 16)
                            }
                        }
                    }
                } else {
                    LazyVGrid(columns: columns, spacing: hSizeClass == .regular ? 28 : 14) {
                        ForEach(localIssues) { pdf in
                            gridIssueCell(pdf)
                        }
                    }
                    .padding(.horizontal, hPad)
                    .padding(.bottom, 120)
                }
            }
        }
    }
'''

volumeHeader_func = '''
    private func volumeHeaderView(group: (key: String, issues: [ConvertedPDF]), isCollapsed: Bool, progress: Double, completed: Int) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.25)) {
                if isCollapsed {
                    collapsedVolumes.remove(group.key)
                } else {
                    collapsedVolumes.insert(group.key)
                }
            }
        } label: {
            VStack(spacing: 6) {
                HStack(spacing: 10) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(Theme.orange)
                        .frame(width: 16)
                    
                    Image(systemName: completed == group.issues.count ? "book.closed.fill" : "book.closed")
                        .font(.system(size: 14))
                        .foregroundColor(completed == group.issues.count ? .green : (group.key == "Ungrouped" ? Theme.textSecondary : Theme.blue))
                    
                    Text(group.key == "Ungrouped" ? "Ungrouped Issues" : "Volume \\(group.key)")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Theme.text)
                    
                    Spacer()
                    
                    Text("\\(completed)/\\(group.issues.count)")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundColor(completed == group.issues.count ? .green : Theme.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Theme.text.opacity(0.08))
                        .clipShape(Capsule())
                }
                
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Theme.text.opacity(0.08))
                            .frame(height: 3)
                        
                        RoundedRectangle(cornerRadius: 2)
                            .fill(
                                progress >= 1.0
                                    ? AnyShapeStyle(Color.green)
                                    : AnyShapeStyle(LinearGradient(colors: [Theme.orange, Theme.red], startPoint: .leading, endPoint: .trailing))
                            )
                            .frame(width: geo.size.width * CGFloat(min(progress, 1.0)), height: 3)
                    }
                }
                .frame(height: 3)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                if fastBundleOmnibus {
                    conversionManager.enqueueOmnibus(
                        name: "\\(series.title) Vol. \\(formattedVolumeKey(group.key))",
                        sourceFiles: group.issues
                    )
                } else {
                    let selectedIDs = Set(group.issues.map { .id })
                    selection = selectedIDs
                    mergeConfigSuggestedName = "\\(series.title) Vol. \\(formattedVolumeKey(group.key))"
                    showingMergeConfig = true
                }
            } label: {
                Label("Build Kindle Omnibus for Vol. \\(formattedVolumeKey(group.key))", systemImage: "books.vertical.fill")
            }
            
            Button {
                withAnimation {
                    if isCollapsed {
                        collapsedVolumes.remove(group.key)
                    } else {
                        collapsedVolumes.insert(group.key)
                    }
                }
            } label: {
                Label(isCollapsed ? "Expand" : "Collapse", systemImage: isCollapsed ? "rectangle.expand.vertical" : "rectangle.compress.vertical")
            }
        }
    }
'''

gridIssueCell_func = '''
    @ViewBuilder
    private func gridIssueCell(_ pdf: ConvertedPDF) -> some View {
        if isSelectionMode {
            Button {
                if selection.contains(pdf.id) {
                    selection.remove(pdf.id)
                } else {
                    selection.insert(pdf.id)
                }
            } label: {
                ModernGridFileCell(pdf: pdf, isSelected: selection.contains(pdf.id), isBatch: true)
            }
            .buttonStyle(PlainButtonStyle())
        } else {
            Button {
                if tapAction == .read {
                    pdfToRead = pdf
                } else {
                    pendingActionPDF = pdf
                    showingActionSheet = true
                }
            } label: {
                ModernGridFileCell(pdf: pdf, isSelected: selectedPDF?.id == pdf.id, isBatch: false)
            }
            .buttonStyle(PlainButtonStyle())
            .contextMenu { contextMenuContent(pdf) }
        }
    }
'''

mainContent_start = content.find('private var mainContent: some View {')
mainContent_end = -1
brace_count = 0
in_func = False
for i in range(mainContent_start, len(content)):
    if content[i] == '{':
        if not in_func:
            in_func = True
        brace_count += 1
    elif content[i] == '}':
        brace_count -= 1
        if brace_count == 0 and in_func:
            mainContent_end = i
            break

insertion = listView_func + gridView_func + volumeHeader_func + gridIssueCell_func
content = content[:mainContent_end+1] + "\\n" + insertion + content[mainContent_end+1:]

list_volume_header_pattern = '''Button {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                if isCollapsed {
                                    collapsedVolumes.remove(group.key)
                                } else {
                                    collapsedVolumes.insert(group.key)
                                }
                            }
                        } label: {

                            VStack(spacing: 6) {
                                HStack(spacing: 10) {
                                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundColor(Theme.orange)
                                        .frame(width: 16)
                                    
                                    Image(systemName: completed == group.issues.count ? "book.closed.fill" : "book.closed")
                                        .font(.system(size: 14))
                                        .foregroundColor(completed == group.issues.count ? .green : (group.key == "Ungrouped" ? Theme.textSecondary : Theme.blue))
                                    
                                    Text(group.key == "Ungrouped" ? "Ungrouped Issues" : "Volume \\(group.key)")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundColor(Theme.text)
                                    
                                    Spacer()
                                    
                                    Text("\\(completed)/\\(group.issues.count)")
                                        .font(.system(size: 12, weight: .medium, design: .rounded))
                                        .foregroundColor(completed == group.issues.count ? .green : Theme.textSecondary)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Theme.text.opacity(0.08))
                                        .clipShape(Capsule())
                                }
                                
                                // Reading Progress Bar
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        RoundedRectangle(cornerRadius: 2)
                                            .fill(Theme.text.opacity(0.08))
                                            .frame(height: 3)
                                        
                                        RoundedRectangle(cornerRadius: 2)
                                            .fill(
                                                progress >= 1.0
                                                    ? AnyShapeStyle(Color.green)
                                                    : AnyShapeStyle(LinearGradient(colors: [Theme.orange, Theme.red], startPoint: .leading, endPoint: .trailing))
                                            )
                                            .frame(width: geo.size.width * CGFloat(min(progress, 1.0)), height: 3)
                                    }
                                }
                                .frame(height: 3)
                            }
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Theme.surface.opacity(0.5))
                        .id("vol_\\(group.key)")  // anchor for QuickVolumeJump scroll
                        // Feature 3: Volume Omnibus Quick-Build (long-press)
                        .contextMenu {
                            Button {
                                if fastBundleOmnibus {
                                    // User opted-in to the background autobuilder
                                    conversionManager.enqueueOmnibus(
                                        name: "\\(series.title) Vol. \\(formattedVolumeKey(group.key))",
                                        sourceFiles: group.issues
                                    )
                                } else {
                                    // User prefers the manual control sheet
                                    manualOmnibusBuildsCount += 1
                                    let selectedIDs = Set(group.issues.map { .id })
                                    
                                    // Trigger the prompt instead of instantly showing if they hit the 3-build threshold
                                    if manualOmnibusBuildsCount == 3 {
                                        pendingConfigSelection = selectedIDs
                                        mergeConfigSuggestedName = "\\(series.title) Vol. \\(formattedVolumeKey(group.key))"
                                        showingOmnibusPrompt = true
                                    } else {
                                        selection = selectedIDs
                                        mergeConfigSuggestedName = "\\(series.title) Vol. \\(formattedVolumeKey(group.key))"
                                        showingMergeConfig = true
                                    }
                                }
                            } label: {
                                Label("Build Kindle Omnibus for Vol. \\(formattedVolumeKey(group.key))", systemImage: "books.vertical.fill")
                            }
                            
                            Button {
                                withAnimation {
                                    if isCollapsed {
                                        collapsedVolumes.remove(group.key)
                                    } else {
                                        collapsedVolumes.insert(group.key)
                                    }
                                }
                            } label: {
                                Label(isCollapsed ? "Expand" : "Collapse", systemImage: isCollapsed ? "rectangle.expand.vertical" : "rectangle.compress.vertical")
                            }
                        }'''

replacement = '''volumeHeaderView(group: group, isCollapsed: isCollapsed, progress: progress, completed: completed)
                        .listRowBackground(Theme.surface.opacity(0.5))
                        .id("vol_\\(group.key)")'''

content = content.replace(list_volume_header_pattern, replacement)

content = content.replace('var body: some View {\\n        contentList', 'var body: some View {\\n        mainContent')

with open('ComicToPDF/Views/Library/SeriesDetailView.swift', 'w', encoding='utf-8') as f:
    f.write(content)

print("Refactor complete.")
