import SwiftUI

struct LibraryHeaderView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @EnvironmentObject var settingsManager: AppSettingsManager
    
    // Bindings to parent view
    @Binding var searchText: String
    @Binding var sortOption: ModernLibraryView.SortOption
    @Binding var filterState: LibraryFilterState
    @Binding var contentShelf: ContentShelf
    @Binding var viewStyle: ModernLibraryView.LibraryViewStyle
    @Binding var tapAction: LibraryTapAction
    var onSheetTrigger: (LibrarySheetDestination) -> Void
    @Binding var isBatchMode: Bool
    @Binding var multiSelection: Set<UUID>
    @Binding var batchMergeItems: [ConvertedPDF]
    @Binding var showingBatchMergeReorder: Bool
    
    // Vault unlock callback
    var onVaultToggle: () -> Void
    var onSelectAll: (() -> Void)? = nil

    // Collapse + Pin state (driven by ModernLibraryView)
    var isCollapsed: Bool = false
    var pinMode: HeaderPinMode = .auto
    var onPinToggle: (() -> Void)? = nil
    var onCollapseToggle: (() -> Void)? = nil   // Phase 4: drag-to-collapse

    @Environment(\.horizontalSizeClass) private var hSizeClass
    @Environment(\.verticalSizeClass) private var vSizeClass
    @State private var dragAccumulated: CGFloat = 0
    @State private var showPillCustomize = false
    @State private var importPulse: Bool = false
    @ObservedObject private var pillConfig = LibraryPillConfig.shared

    var body: some View {
        VStack(spacing: 0) {

            if hSizeClass == .compact {
                // ── Layout branch: portrait vs landscape iPhone ──
                if vSizeClass == .compact {
                    // ✔️ iPhone LANDSCAPE: ultra-compact single-row
                    HStack(spacing: 10) {
                        Image(systemName: "books.vertical.fill")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(Theme.orange.gradient)
                        // Full-width search fills remaining space
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(Theme.textSecondary)
                            TextField("Search…", text: $searchText)
                                .font(.system(size: 14))
                                .foregroundColor(Theme.text)
                                .tint(Theme.orange)
                            if !searchText.isEmpty {
                                Button(action: { searchText = "" }) {
                                    Image(systemName: "xmark.circle.fill").foregroundColor(Theme.textSecondary)
                                }
                            }
                        }
                        .padding(.vertical, 7)
                        .padding(.horizontal, 12)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        // Compact icon row
                        Menu {
                            Picker("Sort By", selection: $sortOption) {
                                ForEach(ModernLibraryView.SortOption.allCases) { o in Text(o.rawValue).tag(o) }
                            }
                        } label: {
                            Image(systemName: "arrow.up.arrow.down")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(Theme.text)
                                .frame(width: 32, height: 32)
                                .background(.ultraThinMaterial)
                                .clipShape(Circle())
                        }
                        Button {
                            withAnimation { viewStyle = viewStyle == .grid ? .list : .grid }
                        } label: {
                            Image(systemName: viewStyle == .grid ? "list.bullet" : "square.grid.2x2")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(Theme.text)
                                .frame(width: 32, height: 32)
                                .background(.ultraThinMaterial)
                                .clipShape(Circle())
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)

                } else {
                    // ✔️ iPhone PORTRAIT: title row + full-width search row
                    VStack(spacing: 8) {
                    // Row 1a: Title + icon buttons
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Image(systemName: "books.vertical.fill")
                                    .font(.system(size: 22, weight: .bold))
                                    .foregroundStyle(Theme.orange.gradient)
                                Text("Library")
                                    .font(.system(size: 24, weight: .bold))
                                    .foregroundColor(Theme.text)
                            }
                            HStack(spacing: 6) {
                                let fileCount = conversionManager.convertedPDFs.count
                                let seriesCount = conversionManager.collections.count
                                Text("\(fileCount) FILES • \(seriesCount) SERIES")
                                    .font(.system(size: 10, weight: .bold, design: .rounded))
                                    .foregroundColor(Theme.textSecondary)
                                    .tracking(1.2)
                                    .opacity(0.8)

                                let streak = ReaderProgressTracker.shared.readingStreak()
                                if streak >= 2 {
                                    HStack(spacing: 3) {
                                        Image(systemName: "flame.fill")
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundStyle(Theme.orange)
                                        Text("\(streak)d")
                                            .font(.system(size: 9, weight: .bold, design: .rounded))
                                            .foregroundStyle(Theme.orange)
                                    }
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(Theme.orange.opacity(0.15), in: Capsule())
                                    .overlay(Capsule().stroke(Theme.orange.opacity(0.3), lineWidth: 0.5))
                                }
                            }
                        }
                        Spacer()
                        // Sort
                        Menu {
                            Picker("Sort By", selection: $sortOption) {
                                ForEach(ModernLibraryView.SortOption.allCases) { option in Text(option.rawValue).tag(option) }
                            }
                        } label: {
                            Image(systemName: "arrow.up.arrow.down")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(Theme.text)
                                .frame(width: 38, height: 38)
                                .background(.ultraThinMaterial)
                                .clipShape(Circle())
                        }
                        // Filter
                        Menu {
                            Picker("Filter", selection: $filterState) {
                                ForEach(LibraryFilterState.allCases) { state in Text(state.rawValue).tag(state) }
                            }
                        } label: {
                            Image(systemName: filterState == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(filterState == .all ? Theme.text : Theme.orange)
                                .frame(width: 38, height: 38)
                                .background(.ultraThinMaterial)
                                .clipShape(Circle())
                        }
                        // Grid / list
                        Button {
                            withAnimation { viewStyle = viewStyle == .grid ? .list : .grid }
                        } label: {
                            Image(systemName: viewStyle == .grid ? "list.bullet" : "square.grid.2x2")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(Theme.text)
                                .frame(width: 38, height: 38)
                                .background(.ultraThinMaterial)
                                .clipShape(Circle())
                        }
                        ActivityTrackerButton()
                    }
                    .padding(.horizontal, 16)

                    // Row 1b: Full-width search (no width competition)
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(Theme.textSecondary)
                        TextField("Search collection…", text: $searchText)
                            .font(.system(size: 15))
                            .foregroundColor(Theme.text)
                            .tint(Theme.orange)
                        if !searchText.isEmpty {
                            Button(action: { searchText = "" }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(Theme.textSecondary)
                            }
                        }
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 14)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Theme.text.opacity(0.1), lineWidth: 1)
                    )
                    .padding(.horizontal, 16)
                }
                .padding(.top, 16)
                }
            } else {
                // ✔️ iPad layout: Premium two-row header
                //   Row 1: Title + subtitle (left)  |  sort/filter/layout icons (right)
                //   Row 2: Full-width search bar spanning the entire content column
                VStack(alignment: .leading, spacing: 10) {

                    // ── Row 1 ─────────────────────────────────────────────────
                    HStack(alignment: .center, spacing: 12) {

                        // Title + subtitle stack
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Image(systemName: "books.vertical.fill")
                                    .font(.system(size: 26, weight: .bold))
                                    .foregroundStyle(
                                        LinearGradient(
                                            colors: [Theme.orange, Color(red: 0.85, green: 0.35, blue: 0.0)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                Text("Library")
                                    .font(.system(size: 30, weight: .bold))
                                    .foregroundColor(Theme.text)
                                    .fixedSize(horizontal: true, vertical: false)
                            }

                            // Subtitle: file count + series + streak badge
                            HStack(spacing: 8) {
                                let fileCount = conversionManager.convertedPDFs.count
                                let seriesCount = conversionManager.collections.count
                                Text("\(fileCount) FILES • \(seriesCount) SERIES")
                                    .font(.system(size: 11, weight: .bold, design: .rounded))
                                    .foregroundColor(Theme.textSecondary)
                                    .tracking(1.3)

                                let streak = ReaderProgressTracker.shared.readingStreak()
                                if streak >= 2 {
                                    HStack(spacing: 3) {
                                        Image(systemName: "flame.fill")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(Theme.orange)
                                        Text("\(streak)d streak")
                                            .font(.system(size: 10, weight: .bold, design: .rounded))
                                            .foregroundStyle(Theme.orange)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Theme.orange.opacity(0.12), in: Capsule())
                                    .overlay(Capsule().stroke(Theme.orange.opacity(0.25), lineWidth: 0.5))
                                    .transition(.scale.combined(with: .opacity))
                                }
                            }
                        }

                        Spacer()

                        // Action icon cluster — sort / filter / layout toggle / activity
                        HStack(spacing: 8) {
                            Menu {
                                Picker("Sort By", selection: $sortOption) {
                                    ForEach(ModernLibraryView.SortOption.allCases) { option in
                                        Text(option.rawValue).tag(option)
                                    }
                                }
                            } label: {
                                iPadHeaderIconButton(
                                    icon: "arrow.up.arrow.down",
                                    active: false
                                )
                            }

                            Menu {
                                Picker("Filter By", selection: $filterState) {
                                    ForEach(LibraryFilterState.allCases) { state in
                                        Text(state.rawValue).tag(state)
                                    }
                                }
                            } label: {
                                iPadHeaderIconButton(
                                    icon: filterState == .all
                                        ? "line.3.horizontal.decrease.circle"
                                        : "line.3.horizontal.decrease.circle.fill",
                                    active: filterState != .all,
                                    tint: filterState != .all ? Theme.orange : Theme.text
                                )
                            }

                            Button {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                                    viewStyle = viewStyle == .grid ? .list : .grid
                                }
                            } label: {
                                iPadHeaderIconButton(
                                    icon: viewStyle == .grid ? "list.bullet" : "square.grid.2x2",
                                    active: false
                                )
                            }

                            ActivityTrackerButton()
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 18)

                    // ── Row 2: Full-width search bar ──────────────────────────
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(Theme.textSecondary)

                        TextField("Search collection…", text: $searchText)
                            .font(.system(size: 16))
                            .foregroundColor(Theme.text)
                            .tint(Theme.orange)

                        if !searchText.isEmpty {
                            Button(action: { searchText = "" }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(Theme.textSecondary)
                                    .transition(.opacity.combined(with: .scale))
                            }
                        }
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 16)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Theme.text.opacity(0.08), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.06), radius: 6, y: 3)
                    .padding(.horizontal, 20)
                    .animation(.spring(response: 0.25, dampingFraction: 0.8), value: searchText.isEmpty)
                }
                .padding(.bottom, 6)
            } // end hSizeClass branches
            
            // ── Smart Collections Strip ──────────────────────────────────
            // Hidden when scrolled / pinned collapsed — saves ~44pt
            if !isCollapsed {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(SmartCollectionRule.allCases) { rule in
                            Button(action: {
                                AppRouter.shared.presentFullScreen(.smartCollection(rule))
                            }) {
                                HStack(spacing: 6) {
                                    Image(systemName: rule.iconName)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(rule.tintColor.gradient)
                                    Text(rule.rawValue)
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundColor(Theme.text)
                                    // Live count badge
                                    let count = smartCollectionCount(rule)
                                    if count > 0 {
                                        Text("\(count)")
                                            .font(.system(size: 10, weight: .bold, design: .rounded))
                                            .foregroundColor(rule.tintColor)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(rule.tintColor.opacity(0.15), in: Capsule())
                                    }
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                                .background(.ultraThinMaterial)
                                .clipShape(Capsule())
                                .overlay(Capsule().stroke(rule.tintColor.opacity(0.2), lineWidth: 0.5))
                            }
                        }
                    }
                    .padding(.horizontal, hSizeClass == .compact ? 16 : 20)
                    .padding(.top, 16)
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            // ── Content Shelf Selector ─────────────────────────────────────────
            ContentShelfSelector(
                selected: $contentShelf,
                counts: [
                    .all:    conversionManager.convertedPDFs.count,
                    .comics: conversionManager.convertedPDFs.filter { ($0.contentType == .comic) && !($0.metadata.isManga ?? false) }.count,
                    .manga:  conversionManager.convertedPDFs.filter { $0.contentType == .manga || ($0.metadata.isManga ?? false) }.count,
                    .books:  conversionManager.convertedPDFs.filter { $0.contentType == .book }.count
                ]
            )
            .padding(.top, 6)
            .padding(.bottom, 2)

            // ── Row A: Fixed Primary Actions ──────────────────────────────────
            // Always visible — the 3 actions 95% of users actually need.
            let isLibraryEmpty = conversionManager.convertedPDFs.isEmpty
            HStack(spacing: 10) {
                // Import — gradient fill, subtle pulse when library is empty
                Button(action: { onSheetTrigger(.importQueue) }) {
                    HStack(spacing: 7) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 14, weight: .bold))
                        Text("Import")
                            .font(.system(size: 14, weight: .bold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .frame(height: 40)
                    .background(
                        LinearGradient(
                            colors: [Theme.orange, Color(red: 0.9, green: 0.45, blue: 0.1)],
                            startPoint: .leading, endPoint: .trailing
                        ),
                        in: Capsule()
                    )
                    .shadow(color: Theme.orange.opacity(importPulse ? 0.55 : 0.30), radius: importPulse ? 10 : 6, y: 3)
                    .scaleEffect(importPulse ? 1.03 : 1.0)
                }
                .onAppear {
                    guard isLibraryEmpty else { return }
                    withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                        importPulse = true
                    }
                }
                .onChange(of: conversionManager.convertedPDFs.count) { _, count in
                    if count > 0 && importPulse {
                        withAnimation(.easeOut(duration: 0.3)) { importPulse = false }
                    }
                }

                // Cloud — live status tint (Infuse/Plex pattern)
                let cloudConnected = DropboxProvider.shared.isConnected
                Button(action: { onSheetTrigger(.cloudBrowser) }) {
                    HStack(spacing: 7) {
                        Image(systemName: cloudConnected ? "checkmark.icloud.fill" : "icloud.and.arrow.down")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(cloudConnected ? Theme.green : Theme.blue)
                        Text("Cloud")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(Theme.text)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .frame(height: 40)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(
                        Capsule().stroke(
                            (cloudConnected ? Theme.green : Theme.blue).opacity(0.3),
                            lineWidth: 1
                        )
                    )
                }

                Spacer()

                // Select / Done + All (batch mode)
                if isBatchMode {
                    Button(action: { onSelectAll?() }) {
                        HStack(spacing: 5) {
                            Image(systemName: "checkmark.square.fill")
                            Text("All")
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Theme.text)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Theme.blue, in: Capsule())
                    }
                    .transition(.scale.combined(with: .opacity))
                }

                Button(action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        isBatchMode.toggle()
                        if !isBatchMode { multiSelection.removeAll() }
                    }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: isBatchMode ? "xmark.circle.fill" : "checkmark.circle")
                            .font(.system(size: 14, weight: .semibold))
                        Text(isBatchMode ? "Done" : "Select")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundColor(isBatchMode ? .white : Theme.text)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .frame(height: 40)
                    .background(
                        isBatchMode
                            ? AnyShapeStyle(Theme.orange)
                            : AnyShapeStyle(.regularMaterial),
                        in: Capsule()
                    )
                    .overlay(Capsule().stroke(Theme.text.opacity(isBatchMode ? 0 : 0.1), lineWidth: 1))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isBatchMode)

            // ── Row B: Power-User Overflow Tools ───────────────────────────
            // Hidden when collapsed — saves ~44pt. Format picker, tap action, tools.
            if !isCollapsed {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        // Target format
                        if pillConfig.isEnabled(.targetFormat) {
                        Menu {
                            Section("Standard Formats") {
                                Picker("Target Format", selection: $settingsManager.conversionSettings.outputFormat) {
                                    ForEach(OutputFormat.allCases) { format in
                                        Label(format.rawValue, systemImage: format.icon).tag(format)
                                    }
                                }
                            }
                            if !settingsManager.conversionPresets.isEmpty {
                                Section("Custom Profiles") {
                                    ForEach(settingsManager.conversionPresets) { preset in
                                        Button {
                                            settingsManager.conversionSettings = preset.settings
                                        } label: {
                                            Label(preset.name, systemImage: "list.clipboard.fill")
                                        }
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(Theme.orange)
                                Text(settingsManager.conversionSettings.outputFormat.rawValue)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(Theme.text)
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(Theme.textSecondary)
                            }
                            .overflowPill()
                        }
                        } // targetFormat

                        // Tap action
                        if pillConfig.isEnabled(.tapAction) {
                        Menu {
                            Picker("Tap Action", selection: $tapAction) {
                                ForEach(LibraryTapAction.allCases, id: \.self) { action in
                                    Text(action.rawValue).tag(action)
                                }
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "hand.tap.fill")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(Theme.blue)
                                Text(tapAction.rawValue)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(Theme.text)
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(Theme.textSecondary)
                            }
                            .overflowPill()
                        }
                        } // tapAction

                        // Wi-Fi
                        if pillConfig.isEnabled(.wifi) {
                            ActionPill(title: "Wi-Fi", icon: "wifi", color: Theme.blue) { onSheetTrigger(.wifi) }
                        }

                        // Smart List
                        if pillConfig.isEnabled(.smartList) {
                            ActionPill(title: "Smart List", icon: "list.star", color: Theme.green) { onSheetTrigger(.smartListImporter) }
                        }

                        // Batch tools
                        if pillConfig.isEnabled(.aiRename) {
                            ActionPill(title: "AI Rename", icon: "sparkles.tv", color: Theme.purple, action: {
                                if multiSelection.count >= 1 {
                                    let items = conversionManager.convertedPDFs.filter { multiSelection.contains($0.id) }
                                    onSheetTrigger(.cognitiveBatchRenamer(items))
                                } else { withAnimation { isBatchMode = true }; conversionManager.appAlert = AppAlert(title: "Select Issues", message: "Select 1 or more scrambled issues from your library to automatically rename using AI Vision.") }
                            })
                        }
                        if pillConfig.isEnabled(.merge) {
                            ActionPill(title: "Merge", icon: "arrow.triangle.merge", color: Theme.purple) { onSheetTrigger(.merge) }
                        }
                        if pillConfig.isEnabled(.convertMerge) {
                            ActionPill(title: "Convert & Merge", icon: "doc.on.doc.fill", color: Theme.purple, action: {
                                if multiSelection.count >= 2 { batchMergeItems = conversionManager.convertedPDFs.filter { multiSelection.contains($0.id) }; showingBatchMergeReorder = true }
                                else { withAnimation { isBatchMode = true }; conversionManager.appAlert = AppAlert(title: "Select Issues", message: "Select 2 or more issues from your library, then tap Convert & Merge again.") }
                            })
                        }

                        // Metadata + stats
                        if pillConfig.isEnabled(.autoMatch) {
                            ActionPill(title: "Auto-Match", icon: "wand.and.stars.inverse", color: Theme.orange) {
                                Task { await BackgroundMetadataEngine.shared.startEngine(manager: conversionManager) }
                            }
                        }
                        if pillConfig.isEnabled(.reviewMissing) && !conversionManager.failedMetadataPDFs.isEmpty {
                            ActionPill(title: "Review Missing", icon: "exclamationmark.triangle.fill", color: Theme.red) {
                                onSheetTrigger(.reviewMetadata)
                            }
                        }
                        if pillConfig.isEnabled(.stats) {
                            ActionPill(title: "Stats", icon: "flame.fill", color: Theme.orange) { onSheetTrigger(.stats) }
                        }

                        // Vault
                        if pillConfig.isEnabled(.vault) {
                            ActionPill(
                                title: settingsManager.isVaultUnlocked ? "Vault Open" : "Vault",
                                icon: settingsManager.isVaultUnlocked ? "lock.open.fill" : "lock.fill",
                                color: settingsManager.isVaultUnlocked ? Theme.red : Theme.textSecondary
                            ) { onVaultToggle() }
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.top, 6)
                .padding(.bottom, 10)
                .transition(.move(edge: .top).combined(with: .opacity))
                .onLongPressGesture(minimumDuration: 0.5) {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    showPillCustomize = true
                }
                .sheet(isPresented: $showPillCustomize) {
                    LibraryPillCustomizeSheet()
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                }
            }

            // ── Collapse indicator + Pin toggle ────────────────────────────
            // Tap the chevron area OR drag up/down to collapse/expand the header.
            // Pin button cycles: auto → pinned-expanded → pinned-collapsed.
            HStack(spacing: 0) {
                Spacer()

                Image(systemName: isCollapsed ? "chevron.down" : "chevron.up")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(Theme.textSecondary.opacity(0.5))

                Spacer()

                Button(action: { onPinToggle?() }) {
                    let (icon, color): (String, Color) = {
                        switch pinMode {
                        case .auto:            return ("pin.slash", Theme.textSecondary.opacity(0.4))
                        case .pinnedExpanded:  return ("pin.fill",  Theme.orange)
                        case .pinnedCollapsed: return ("pin",       Theme.blue)
                        }
                    }()
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(color)
                        .padding(6)
                        .background(
                            pinMode != .auto ? AnyShapeStyle(color.opacity(0.12)) : AnyShapeStyle(Color.clear),
                            in: Circle()
                        )
                        .overlay(Circle().stroke(pinMode != .auto ? color.opacity(0.25) : Color.clear, lineWidth: 0.5))
                }
                .padding(.trailing, 12)
                .animation(.spring(response: 0.3, dampingFraction: 0.75), value: pinMode)
            }
            .frame(height: 28)   // slightly taller hit target for drag
            .padding(.bottom, 4)
            .contentShape(Rectangle())   // make entire width tappable
            .onTapGesture { onCollapseToggle?() }
            .gesture(
                DragGesture(minimumDistance: 10)
                    .onChanged { value in
                        dragAccumulated = value.translation.height
                    }
                    .onEnded { value in
                        let threshold: CGFloat = 20
                        if !isCollapsed && value.translation.height < -threshold {
                            // Dragged up — collapse
                            onCollapseToggle?()
                        } else if isCollapsed && value.translation.height > threshold {
                            // Dragged down — expand
                            onCollapseToggle?()
                        }
                        dragAccumulated = 0
                    }
            )
        }
        .background(.ultraThinMaterial)
        .overlay(
            Rectangle().frame(height: 1).foregroundColor(Theme.text.opacity(0.05)),
            alignment: .bottom
        )
        // (Legacy ShowImportQueue observer removed; using AppRouter)
    }
    // MARK: - Smart Collection Count
    /// Fast single-pass count for pill badges — no async, no full filter rebuild.
    private func smartCollectionCount(_ rule: SmartCollectionRule) -> Int {
        let pdfs = conversionManager.convertedPDFs
        switch rule {
        case .recentlyAdded:
            return min(pdfs.count, 50)
        case .readingNow:
            return pdfs.filter {
                let f = ReaderProgressTracker.shared.progress(for: $0.id)?.completionFraction ?? 0
                return f > 0 && f < 1
            }.count
        case .allUnread:
            return pdfs.filter {
                (ReaderProgressTracker.shared.progress(for: $0.id)?.completionFraction ?? 0) == 0
            }.count
        case .completed:
            return pdfs.filter {
                (ReaderProgressTracker.shared.progress(for: $0.id)?.completionFraction ?? 0) >= 1
            }.count
        case .onDrive:
            return pdfs.filter { if case .linked = $0.sourceMode { return true }; return false }.count
        case .cloudLibrary:
            return pdfs.filter { if case .cloud = $0.sourceMode { return true }; return false }.count
        }
    }

    // MARK: - iPad Header Icon Button Helper
    /// Consistent 44pt frosted-glass icon button used in the iPad two-row header.
    /// `active` = true highlights with the `tint` color (used for the filter button when a filter is set).
    @ViewBuilder
    private func iPadHeaderIconButton(icon: String, active: Bool, tint: Color = Theme.text) -> some View {
        Image(systemName: icon)
            .font(.system(size: 18, weight: .semibold))
            .foregroundColor(active ? tint : Theme.text)
            .frame(width: 44, height: 44)
            .background(
                active
                    ? AnyShapeStyle(tint.opacity(0.12))
                    : AnyShapeStyle(Material.ultraThin)
            )
            .clipShape(Circle())
            .overlay(
                Circle().stroke(
                    active ? tint.opacity(0.3) : Theme.text.opacity(0.08),
                    lineWidth: 1
                )
            )
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: active)
    }
}

// MARK: - Overflow pill style helper
private extension View {
    func overflowPill() -> some View {
        self
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
    }
}
