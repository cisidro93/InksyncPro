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

    @Environment(\.horizontalSizeClass) private var hSizeClass
    @State private var showImportQueue = false

    var body: some View {
        VStack(spacing: 0) {

            if hSizeClass == .compact {
                // ✔️ iPhone layout: title row + full-width search row
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

            } else {
                // ✔️ iPad layout: original single-row design
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                             Image(systemName: "books.vertical.fill")
                                 .font(.system(size: 24, weight: .bold))
                                 .foregroundStyle(Theme.orange.gradient)
                             Text("Library")
                                 .font(.system(size: 28, weight: .bold))
                                 .foregroundColor(Theme.text)
                                 .fixedSize(horizontal: true, vertical: false)
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
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(Theme.textSecondary)
                        TextField("Search Collection...", text: $searchText)
                            .font(.system(size: 17))
                            .foregroundColor(Theme.text)
                            .tint(Theme.orange)
                        if !searchText.isEmpty {
                            Button(action: { searchText = "" }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(Theme.textSecondary)
                            }
                        }
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 16)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Theme.text.opacity(0.1), lineWidth: 1)
                    )
                    .frame(maxWidth: 400)
                    Menu {
                        Picker("Sort By", selection: $sortOption) {
                            ForEach(ModernLibraryView.SortOption.allCases) { option in Text(option.rawValue).tag(option) }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(Theme.text)
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                            .overlay(Circle().stroke(Theme.text.opacity(0.1), lineWidth: 1))
                    }
                    Menu {
                        Picker("Filter By", selection: $filterState) {
                            ForEach(LibraryFilterState.allCases) { state in Text(state.rawValue).tag(state) }
                        }
                    } label: {
                        Image(systemName: filterState == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(filterState == .all ? Theme.text : Theme.orange)
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                            .overlay(Circle().stroke(Theme.text.opacity(0.1), lineWidth: 1))
                    }
                    Button {
                        withAnimation {
                            viewStyle = viewStyle == .grid ? .list : .grid
                        }
                    } label: {
                        Image(systemName: viewStyle == .grid ? "list.bullet" : "square.grid.2x2")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(Theme.text)
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                            .overlay(Circle().stroke(Theme.text.opacity(0.1), lineWidth: 1))
                    }
                    ActivityTrackerButton()
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
            } // end hSizeClass branches
            
            // ── Smart Collections Strip ─────────
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

            // ── Content Shelf Selector ─────────────────────────────────────────
            ContentShelfSelector(
                selected: $contentShelf,
                counts: [
                    .all:    conversionManager.convertedPDFs.count,
                    .comics: conversionManager.convertedPDFs.filter { ($0.contentType == .comic) && !($0.metadata.isManga ?? false) }.count,
                    .manga:  conversionManager.convertedPDFs.filter { $0.metadata.isManga ?? false }.count,
                    .books:  conversionManager.convertedPDFs.filter { $0.contentType == .book }.count
                ]
            )
            .padding(.top, 6)
            .padding(.bottom, 2)

            // ── Row A: Fixed Primary Actions ──────────────────────────────────
            // Always visible — the 3 actions 95% of users actually need.
            HStack(spacing: 10) {
                // Import — gradient fill matching empty-state CTA
                Button(action: { showImportQueue = true }) {
                    HStack(spacing: 7) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 14, weight: .bold))
                        Text("Import")
                            .font(.system(size: 14, weight: .bold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(
                        LinearGradient(
                            colors: [Theme.orange, Color(red: 0.9, green: 0.45, blue: 0.1)],
                            startPoint: .leading, endPoint: .trailing
                        ),
                        in: Capsule()
                    )
                    .shadow(color: Theme.orange.opacity(0.3), radius: 6, y: 3)
                }
                .sheet(isPresented: $showImportQueue) {
                    ImportQueueView().environmentObject(conversionManager)
                }

                // Cloud — live status tint (Infuse/Plex pattern)
                let cloudConnected = DropboxProvider.shared.isConnected || GoogleDriveProvider.shared.isConnected
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

            // ── Row B: Power-User Overflow Tools (slim scrollable strip) ──────
            // Format picker, tap action, Wi-Fi, tools, metadata engine, vault.
            // Inspired by Reeder's compact toolbar — power tools tucked away but reachable.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    // Target format
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

                    // Tap action
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

                    // Wi-Fi
                    ActionPill(title: "Wi-Fi", icon: "wifi", color: Theme.blue) { onSheetTrigger(.wifi) }

                    // Smart List
                    ActionPill(title: "Smart List", icon: "list.star", color: Theme.green) { onSheetTrigger(.smartListImporter) }

                    // Batch tools
                    ActionPill(title: "AI Rename", icon: "sparkles.tv", color: Theme.purple, action: {
                        if multiSelection.count >= 1 {
                            let items = conversionManager.convertedPDFs.filter { multiSelection.contains($0.id) }
                            onSheetTrigger(.cognitiveBatchRenamer(items))
                        }
                        else { withAnimation { isBatchMode = true }; conversionManager.appAlert = AppAlert(title: "Select Issues", message: "Select 1 or more scrambled issues from your library to automatically rename using AI Vision.") }
                    })
                    ActionPill(title: "Merge", icon: "arrow.triangle.merge", color: Theme.purple) { onSheetTrigger(.merge) }
                    ActionPill(title: "Convert & Merge", icon: "doc.on.doc.fill", color: Theme.purple, action: {
                        if multiSelection.count >= 2 { batchMergeItems = conversionManager.convertedPDFs.filter { multiSelection.contains($0.id) }; showingBatchMergeReorder = true }
                        else { withAnimation { isBatchMode = true }; conversionManager.appAlert = AppAlert(title: "Select Issues", message: "Select 2 or more issues from your library, then tap Convert & Merge again.") }
                    })

                    // Metadata + stats
                    ActionPill(title: "Auto-Match", icon: "wand.and.stars.inverse", color: Theme.orange) {
                        Task { await BackgroundMetadataEngine.shared.startEngine(manager: conversionManager) }
                    }
                    if !conversionManager.failedMetadataPDFs.isEmpty {
                        ActionPill(title: "Review Missing", icon: "exclamationmark.triangle.fill", color: Theme.red) {
                            onSheetTrigger(.reviewMetadata)
                        }
                    }
                    ActionPill(title: "Stats", icon: "flame.fill", color: Theme.orange) { onSheetTrigger(.stats) }

                    // Vault
                    ActionPill(
                        title: settingsManager.isVaultUnlocked ? "Vault Open" : "Vault",
                        icon: settingsManager.isVaultUnlocked ? "lock.open.fill" : "lock.fill",
                        color: settingsManager.isVaultUnlocked ? Theme.red : Theme.textSecondary
                    ) { onVaultToggle() }
                }
                .padding(.horizontal, 16)
            }
            .padding(.top, 6)
            .padding(.bottom, 14)
        }
        .background(.ultraThinMaterial)
        .overlay(
            Rectangle().frame(height: 1).foregroundColor(Theme.text.opacity(0.05)),
            alignment: .bottom
        )
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ShowImportQueue"))) { _ in
            showImportQueue = true
        }
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
        case .manga:
            return pdfs.filter {
                ($0.metadata.isManga ?? false) ||
                ReaderProgressTracker.shared.progress(for: $0.id)?.prefersMangaMode == true
            }.count
        case .onDrive:
            return pdfs.filter { if case .linked = $0.sourceMode { return true }; return false }.count
        case .cloudLibrary:
            return pdfs.filter { if case .cloud = $0.sourceMode { return true }; return false }.count
        }
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
