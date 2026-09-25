import SwiftUI

struct LibraryControlCenterView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @EnvironmentObject var settingsManager: AppSettingsManager
    @ObservedObject private var router = AppRouter.shared
    @ObservedObject private var dropbox = DropboxProvider.shared
    @ObservedObject private var bgEngine = BackgroundMetadataEngine.shared
    
    @Binding var sortOption: ModernLibraryView.SortOption
    @Binding var filterState: LibraryFilterState
    @Binding var viewStyle: ModernLibraryView.LibraryViewStyle
    @Binding var isBatchMode: Bool
    @Binding var multiSelection: Set<UUID>
    @Binding var tapAction: LibraryTapAction
    
    @Environment(\.dismiss) private var dismiss
    
    // Grid columns for Quick Actions
    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Quick Stats Banner
                    statsBanner
                        .padding(.horizontal)
                    
                    // Section 1: Quick Actions (Grid of Cards)
                    VStack(alignment: .leading, spacing: 10) {
                        InkSectionHeader("Quick Actions")
                            .padding(.horizontal)
                        
                        LazyVGrid(columns: columns, spacing: 12) {
                            // Wi-Fi Transfer & Sync
                            cardButton(
                                title: "Wi-Fi Sync",
                                subtitle: "Transfer files wirelessly",
                                icon: "wifi",
                                gradient: Gradient(colors: [Color.inkBlue, Color(hex: "#4facfe")]),
                                action: {
                                    transitionToSheet(.wifi)
                                }
                            )
                            
                            // Create Volume
                            cardButton(
                                title: "Create Volume",
                                subtitle: "Virtual or merged archive",
                                icon: "books.vertical.fill",
                                gradient: Gradient(colors: [Color.inkViolet, Color(hex: "#7928ca")]),
                                action: {
                                    let items = conversionManager.convertedPDFs.filter { multiSelection.contains($0.id) }
                                    let sortedItems = items.sorted {
                                        let n1 = Double($0.metadata.issueNumber ?? "")
                                        let n2 = Double($1.metadata.issueNumber ?? "")
                                        if let v1 = n1, let v2 = n2 { return v1 < v2 }
                                        if n1 != nil && n2 == nil { return true }
                                        if n1 == nil && n2 != nil { return false }
                                        return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                                    }
                                    let sortedIDs = sortedItems.map { $0.id }
                                    
                                    let suggestedName: String
                                    if let firstSeries = sortedItems.first(where: { $0.metadata.series?.isEmpty == false })?.metadata.series {
                                        if let sharedVolume = sortedItems.first(where: { $0.metadata.volume?.isEmpty == false })?.metadata.volume {
                                            suggestedName = "\(firstSeries) Vol. \(sharedVolume)"
                                        } else {
                                            suggestedName = "\(firstSeries) Volume 1"
                                        }
                                    } else {
                                        suggestedName = ""
                                    }
                                    
                                    transitionToSheet(.volumeStudio(existingOmnibus: nil, initialFileIDs: sortedIDs, suggestedName: suggestedName, parentSeriesID: nil, initialMode: .virtual))
                                }
                            )
                            
                            // Cloud Library
                            cardButton(
                                title: "Cloud Library",
                                subtitle: dropbox.isConnected ? "Dropbox: Connected" : "Dropbox: Tap to Link",
                                icon: dropbox.isConnected ? "icloud.and.arrow.down.fill" : "icloud.and.arrow.down",
                                gradient: Gradient(colors: [Color.inkGreen, Color(hex: "#059669")]),
                                action: {
                                    transitionToSheet(.cloudBrowser)
                                }
                            )
                            
                            // Smart List Import
                            cardButton(
                                title: "Smart List Import",
                                subtitle: "Import CBL/CSV lists",
                                icon: "list.star",
                                gradient: Gradient(colors: [Color.inkOrange, Color.inkAmber]),
                                action: {
                                    transitionToSheet(.smartListImporter)
                                }
                            )
                            
                            // OPDS Catalogs
                            cardButton(
                                title: "OPDS Catalogs",
                                subtitle: "Calibre, Kavita, Komga",
                                icon: "server.rack",
                                gradient: Gradient(colors: [Color.purple, Color(hex: "#7928ca")]),
                                action: {
                                    transitionToSheet(.opdsBrowser)
                                }
                            )
                        }
                        .padding(.horizontal)
                    }
                    
                    // Section 2: Sorting & Filter Settings
                    VStack(alignment: .leading, spacing: 10) {
                        InkSectionHeader("Library Display & Filters")
                            .padding(.horizontal)
                        
                        VStack(spacing: 16) {
                            // Sort Picker
                            HStack {
                                Label("Sort By", systemImage: "arrow.up.arrow.down")
                                    .font(.subheadline)
                                    .foregroundColor(.primary)
                                Spacer()
                                Picker("Sort By", selection: $sortOption) {
                                    ForEach(ModernLibraryView.SortOption.allCases) { option in
                                        Text(option.rawValue).tag(option)
                                    }
                                }
                                .pickerStyle(.menu)
                                .accentColor(.inkBlue)
                            }
                            .padding(.horizontal)
                            .padding(.top, 4)
                            
                            Divider()
                                .background(Color.inkBorderSubtle)
                                .padding(.horizontal)
                            
                            // On Tap Gesture Picker
                            HStack {
                                Label("On Tap Gesture", systemImage: "hand.tap")
                                    .font(.subheadline)
                                    .foregroundColor(.primary)
                                Spacer()
                                Picker("On Tap Gesture", selection: $tapAction) {
                                    ForEach(LibraryTapAction.allCases, id: \.self) { action in
                                        Text(action.rawValue).tag(action)
                                    }
                                }
                                .pickerStyle(.menu)
                                .accentColor(.inkBlue)
                            }
                            .padding(.horizontal)
                            
                            Divider()
                                .background(Color.inkBorderSubtle)
                                .padding(.horizontal)
                            
                            // Filter Pills Scroll
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Filter Items")
                                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                                    .foregroundColor(Color.inkTextSecondary)
                                    .padding(.horizontal)
                                
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 8) {
                                        ForEach(LibraryFilterState.allCases) { state in
                                            Button(action: {
                                                HapticEngine.selection()
                                                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                                    filterState = state
                                                }
                                            }) {
                                                Text(state.rawValue)
                                                    .font(.subheadline)
                                                    .fontWeight(filterState == state ? .semibold : .regular)
                                                    .padding(.horizontal, 16)
                                                    .padding(.vertical, 8)
                                                    .background(
                                                        Capsule()
                                                            .fill(filterState == state ? Color.inkBlue : Color.inkSurface)
                                                    )
                                                    .overlay(
                                                        Capsule()
                                                            .stroke(filterState == state ? Color.inkBlue : Color.inkBorderSubtle, lineWidth: 0.8)
                                                    )
                                                    .foregroundColor(filterState == state ? .white : .primary)
                                            }
                                        }
                                    }
                                    .padding(.horizontal)
                                }
                            }
                            
                            Divider()
                                .background(Color.inkBorderSubtle)
                                .padding(.horizontal)
                            
                            // Visual Layout & Options Grid
                            HStack(spacing: 12) {
                                // Toggle View Style Button
                                optionToggleButton(
                                    title: viewStyle == .grid ? "List View" : "Grid View",
                                    icon: viewStyle == .grid ? "list.bullet" : "square.grid.2x2",
                                    isActive: false,
                                    action: {
                                        HapticEngine.light()
                                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                            viewStyle = viewStyle == .grid ? .list : .grid
                                        }
                                    }
                                )
                                
                                // Toggle Batch Mode Button
                                optionToggleButton(
                                    title: isBatchMode ? "Exit Batch" : "Batch Mode",
                                    icon: "checkmark.circle",
                                    isActive: isBatchMode,
                                    action: {
                                        HapticEngine.medium()
                                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                            isBatchMode.toggle()
                                        }
                                    }
                                )
                                
                                // Toggle Vault Button
                                optionToggleButton(
                                    title: settingsManager.isVaultUnlocked ? "Lock Vault" : "Unlock Vault",
                                    icon: settingsManager.isVaultUnlocked ? "lock.open.fill" : "lock.fill",
                                    isActive: settingsManager.isVaultUnlocked,
                                    color: settingsManager.isVaultUnlocked ? .inkRed : .inkGreen,
                                    action: {
                                        HapticEngine.selection()
                                        handleVaultToggle()
                                    }
                                )
                            }
                            .padding(.horizontal)
                            .padding(.bottom, 8)
                        }
                        .padding(.vertical, 12)
                        .background(Color.inkSurfaceRaised)
                        .cornerRadius(16)
                        .inkSpecularBorder(cornerRadius: 16)
                        .shadow(color: Color.black.opacity(0.12), radius: 8, x: 0, y: 3)
                        .padding(.horizontal)
                    }
                    
                    // Section 3: AI & Metadata Operations
                    VStack(alignment: .leading, spacing: 10) {
                        InkSectionHeader("AI & Metadata Engine")
                            .padding(.horizontal)
                        
                        VStack(spacing: 12) {
                            // Auto Match Progress Button
                            Button(action: {
                                HapticEngine.medium()
                                if bgEngine.isRunning {
                                    bgEngine.cancel()
                                } else {
                                    Task {
                                        await bgEngine.startEngine(manager: conversionManager)
                                    }
                                }
                            }) {
                                HStack {
                                    Image(systemName: bgEngine.isRunning ? "stop.fill" : "wand.and.stars.inverse")
                                        .font(.title3)
                                        .foregroundColor(bgEngine.isRunning ? .inkRed : .inkViolet)
                                        .frame(width: 32)
                                    
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(bgEngine.isRunning ? "Stop Auto-Match" : "Auto-Match Metadata")
                                            .font(.body)
                                            .fontWeight(.medium)
                                            .foregroundColor(.primary)
                                        
                                        if bgEngine.isRunning {
                                            Text("Matching item \(bgEngine.currentProgress) of \(bgEngine.queueCount)")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        } else {
                                            Text("Scan files and auto-fill metadata using AI")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    
                                    Spacer()
                                    
                                    if bgEngine.isRunning {
                                        ProgressView()
                                            .scaleEffect(0.8)
                                    } else {
                                        Image(systemName: "chevron.right")
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .padding()
                                .background(Color.inkSurfaceRaised)
                                .cornerRadius(12)
                                .inkSpecularBorder(cornerRadius: 12)
                            }
                            
                            // Review Missing Metadata (conditional)
                            if !conversionManager.failedMetadataPDFs.isEmpty {
                                listActionButton(
                                    title: "Review Missing Metadata",
                                    subtitle: "\(conversionManager.failedMetadataPDFs.count) issues need manual matching",
                                    icon: "exclamationmark.triangle.fill",
                                    color: .inkAmber,
                                    action: {
                                        transitionToSheet(.reviewMetadata)
                                    }
                                )
                            }
                            
                            // AI Rename (with validation)
                            listActionButton(
                                title: "AI Vision Rename",
                                subtitle: isBatchMode ? "Rename \(multiSelection.count) selected issues" : "Select issues to automatically rename",
                                icon: "sparkles.tv",
                                color: .inkViolet,
                                disabled: isBatchMode && multiSelection.isEmpty,
                                action: {
                                    if isBatchMode && !multiSelection.isEmpty {
                                        let items = conversionManager.convertedPDFs.filter { multiSelection.contains($0.id) }
                                        transitionToSheet(.cognitiveBatchRenamer(items))
                                    } else {
                                        withAnimation { isBatchMode = true }
                                        dismiss()
                                        conversionManager.appAlert = AppAlert(title: "Select Issues", message: "Select 1 or more scrambled issues from your library, then open Control Center to rename.")
                                    }
                                }
                            )
                            
                            // Grid Editor
                            listActionButton(
                                title: "Grid Metadata Editor",
                                subtitle: isBatchMode ? "Edit metadata spreadsheet for \(multiSelection.count) items" : "Select issues to open in spreadsheet grid",
                                icon: "tablecells",
                                color: .inkBlue,
                                disabled: isBatchMode && multiSelection.isEmpty,
                                action: {
                                    if isBatchMode && !multiSelection.isEmpty {
                                        let items = conversionManager.convertedPDFs.filter { multiSelection.contains($0.id) }
                                        transitionToSheet(.metadataSpreadsheet(items))
                                        withAnimation { isBatchMode = false }
                                    } else {
                                        withAnimation { isBatchMode = true }
                                        dismiss()
                                        conversionManager.appAlert = AppAlert(title: "Select Issues", message: "Select issues first, then open Control Center and tap Grid Editor.")
                                    }
                                }
                            )
                        }
                        .padding(.horizontal)
                    }
                    
                    // Section 4: File Operations & Utilities
                    VStack(alignment: .leading, spacing: 10) {
                        InkSectionHeader("File Operations & Utilities")
                            .padding(.horizontal)
                        
                        VStack(spacing: 12) {
                            listActionButton(
                                title: "PDF Merge Tool",
                                subtitle: "Merge existing PDFs together",
                                icon: "arrow.triangle.merge",
                                color: .inkGreen,
                                action: {
                                    transitionToSheet(.merge)
                                }
                            )
                            
                            listActionButton(
                                title: "Convert & Merge",
                                subtitle: isBatchMode ? "Convert & merge \(multiSelection.count) selected issues" : "Select multiple zip/cbr/cbz to convert & merge",
                                icon: "arrow.triangle.2.circlepath.doc",
                                color: .inkOrange,
                                action: {
                                    if isBatchMode && multiSelection.count >= 2 {
                                        dismiss()
                                        NotificationCenter.default.post(name: NSNotification.Name("TriggerBatchMergeReorder"), object: nil)
                                    } else {
                                        withAnimation { isBatchMode = true }
                                        dismiss()
                                        conversionManager.appAlert = AppAlert(title: "Select Issues", message: "Select 2 or more issues from your library, then tap Convert & Merge again.")
                                    }
                                }
                            )
                            
                            HStack(spacing: 12) {
                                // Stats Card
                                Button(action: {
                                    HapticEngine.selection()
                                    transitionToSheet(.stats)
                                }) {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Image(systemName: "chart.bar.fill")
                                            .font(.title2)
                                            .foregroundColor(.inkBlue)
                                        Text("Library Stats")
                                            .font(.subheadline)
                                            .fontWeight(.semibold)
                                            .foregroundColor(.primary)
                                        Text("Read metrics & usage")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    .padding()
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.inkSurfaceRaised)
                                    .cornerRadius(12)
                                    .inkSpecularBorder(cornerRadius: 12)
                                }
                                
                                // Settings Card
                                Button(action: {
                                    HapticEngine.selection()
                                    dismiss()
                                    NotificationCenter.default.post(name: NSNotification.Name("ShowSettingsInspector"), object: nil)
                                }) {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Image(systemName: "gearshape.fill")
                                            .font(.title2)
                                            .foregroundColor(.inkTextSecondary)
                                        Text("Settings")
                                            .font(.subheadline)
                                            .fontWeight(.semibold)
                                            .foregroundColor(.primary)
                                        Text("Preferences & configurations")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    .padding()
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.inkSurfaceRaised)
                                    .cornerRadius(12)
                                    .inkSpecularBorder(cornerRadius: 12)
                                }
                            }
                        }
                        .padding(.horizontal)
                    }
                }
                .padding(.vertical)
            }
            .background(Color.inkBackground.ignoresSafeArea())
            .navigationTitle("Library Dashboard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        HapticEngine.light()
                        dismiss()
                    }
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.inkBlue)
                }
            }
        }
    }
    
    // MARK: - Subviews & Helpers
    
    @ViewBuilder
    private var statsBanner: some View {
        HStack(spacing: 20) {
            statItem(
                value: "\(conversionManager.convertedPDFs.count)",
                title: "Total Files",
                icon: "doc.text.fill",
                color: .inkBlue
            )
            Divider()
                .background(Color.inkBorderSubtle)
                .frame(height: 40)
            statItem(
                value: "\(conversionManager.collections.count)",
                title: "Collections",
                icon: "folder.fill.badge.plus",
                color: .inkViolet
            )
            Divider()
                .background(Color.inkBorderSubtle)
                .frame(height: 40)
            statItem(
                value: "\(conversionManager.failedMetadataPDFs.count)",
                title: "Unmatched",
                icon: "questionmark.circle.fill",
                color: conversionManager.failedMetadataPDFs.isEmpty ? .secondary : .inkAmber
            )
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color.inkSurfaceRaised)
        .cornerRadius(16)
        .inkSpecularBorder(cornerRadius: 16)
        .shadow(color: Color.black.opacity(0.12), radius: 8, x: 0, y: 3)
    }
    
    @ViewBuilder
    private func statItem(value: String, title: String, icon: String, color: Color) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundColor(color)
                Text(value)
                    .font(.title3)
                    .fontWeight(.bold)
                    .foregroundColor(.inkTextPrimary)
            }
            Text(title)
                .font(.caption2)
                .foregroundColor(.inkTextSecondary)
        }
        .frame(maxWidth: .infinity)
    }
    
    @ViewBuilder
    private func cardButton(title: String, subtitle: String, icon: String, gradient: Gradient, action: @escaping () -> Void) -> some View {
        Button(action: {
            HapticEngine.selection()
            action()
        }) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: icon)
                        .font(.title2)
                        .foregroundColor(.white)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.8))
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundColor(.white)
                        .fontWeight(.semibold)
                    
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.9))
                        .lineLimit(1)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(gradient: gradient, startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            .cornerRadius(16)
            .inkSpecularBorder(cornerRadius: 16)
            .shadow(color: gradient.stops.first?.color.opacity(0.3) ?? Color.black.opacity(0.1), radius: 6, x: 0, y: 3)
        }
    }
    
    @ViewBuilder
    private func optionToggleButton(title: String, icon: String, isActive: Bool, color: Color = .inkBlue, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundColor(isActive ? .white : color)
                Text(title)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(isActive ? .white : .primary)
            }
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isActive ? color : Color.inkSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isActive ? color : Color.inkBorderSubtle, lineWidth: 0.8)
            )
        }
    }
    
    @ViewBuilder
    private func listActionButton(title: String, subtitle: String, icon: String, color: Color, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: {
            HapticEngine.selection()
            action()
        }) {
            HStack {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundColor(disabled ? .secondary : color)
                    .frame(width: 32)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundColor(disabled ? .secondary : .primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .foregroundColor(.secondary)
                    .font(.caption)
            }
            .padding()
            .background(Color.inkSurfaceRaised)
            .cornerRadius(12)
            .inkSpecularBorder(cornerRadius: 12)
        }
        .disabled(disabled)
        .opacity(disabled ? 0.6 : 1.0)
    }
    
    private func transitionToSheet(_ destination: LibrarySheetDestination) {
        AppRouter.shared.pendingSheet = destination
        dismiss()
    }
    
    private func handleVaultToggle() {
        if settingsManager.isVaultUnlocked {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                settingsManager.isVaultUnlocked = false
            }
        } else {
            Task {
                if await SecurityManager.shared.authenticate() {
                    await MainActor.run {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            settingsManager.isVaultUnlocked = true
                        }
                    }
                }
            }
        }
    }
}

