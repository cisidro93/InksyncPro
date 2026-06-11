import SwiftUI

struct OmniDockView: View {
    @Binding var contentShelf: ContentShelf
    @Binding var filterState: LibraryFilterState
    @Binding var sortOption: ModernLibraryView.SortOption
    @Binding var isBatchMode: Bool
    @Binding var multiSelection: Set<UUID>
    @Binding var batchMergeItems: [ConvertedPDF]
    @Binding var showingBatchMergeReorder: Bool
    @Binding var viewStyle: ModernLibraryView.LibraryViewStyle
    @Binding var currentFolderID: UUID?
    var collections: [PDFCollection]
    
    var onWorkArea: () -> Void
    var onImport: () -> Void
    var onSettings: () -> Void
    var onVaultToggle: () -> Void
    var onSearch: () -> Void
    
    @EnvironmentObject var conversionManager: ConversionManager
    @EnvironmentObject var settingsManager: AppSettingsManager
    @AppStorage("libraryTapAction") private var tapAction: LibraryTapAction = .read
    
    enum DockPosition: String, Codable {
        case bottom = "bottom"
        case top = "top"
        case left = "left"
        case right = "right"
    }

    @AppStorage("omniDockPosition") private var position: DockPosition = .bottom
    @State private var offset: CGSize = .zero
    @Environment(\.colorScheme) var colorScheme

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard !isBatchMode else { return }
                offset = value.translation
            }
            .onEnded { value in
                guard !isBatchMode else { return }
                let screenSize = UIScreen.main.bounds.size
                let finalX = value.predictedEndLocation.x
                let finalY = value.predictedEndLocation.y

                let distLeft = finalX
                let distRight = screenSize.width - finalX
                let distTop = finalY
                let distBottom = screenSize.height - finalY

                let minDist = min(distLeft, distRight, distTop, distBottom)

                withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                    if minDist == distLeft { position = .left }
                    else if minDist == distRight { position = .right }
                    else if minDist == distTop { position = .top }
                    else { position = .bottom }
                    
                    offset = .zero
                }
            }
    }

    var body: some View {
        Group {
            if position == .top || position == .bottom {
                HStack(spacing: 20) {
                    dockItems
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
            } else {
                VStack(spacing: 20) {
                    dockItems
                }
                .padding(.vertical, 24)
                .padding(.horizontal, 14)
            }
        }
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(colorScheme == .dark ? 0.3 : 0.6), Color.white.opacity(0.05)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ), 
                    lineWidth: 1
                )
        )
        .shadow(color: Color.inkBlue.opacity(colorScheme == .dark ? 0.3 : 0.15), radius: 24, x: 0, y: 12)
        .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 5)
        .offset(offset)
        .gesture(dragGesture)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignmentForPosition)
        .padding(safeAreaPaddingForPosition)
        .animation(.spring(response: 0.35, dampingFraction: 0.78), value: isBatchMode)
        .onChange(of: isBatchMode) { _, newValue in
            if newValue {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                    position = .top
                    offset = .zero
                }
            }
        }
    }

    private var alignmentForPosition: Alignment {
        switch position {
        case .top: return .top
        case .bottom: return .bottom
        case .left: return .leading
        case .right: return .trailing
        }
    }

    private var safeAreaPaddingForPosition: EdgeInsets {
        switch position {
        case .top: return EdgeInsets(top: 20, leading: 0, bottom: 0, trailing: 0)
        case .bottom: return EdgeInsets(top: 0, leading: 0, bottom: isBatchMode ? 164 : 96, trailing: 0)
        case .left: return EdgeInsets(top: 0, leading: 20, bottom: isBatchMode ? 80 : 0, trailing: 0)
        case .right: return EdgeInsets(top: 0, leading: 0, bottom: isBatchMode ? 80 : 0, trailing: 20)
        }
    }

    @ViewBuilder
    private var dockItems: some View {
        // 1. Advanced Shelf & Filter Picker
        Menu {
            Section("Browse") {
                Button { filterState = .all; contentShelf = .all; currentFolderID = nil } label: {
                    Label("All", systemImage: "square.grid.2x2.fill")
                }
                Button { filterState = .reading } label: {
                    Label("Reading", systemImage: "book.open.fill")
                }
                Button { sortOption = .dateAdded } label: {
                    Label("Recent", systemImage: "clock.fill")
                }
                Button { sortOption = .favorites } label: {
                    Label("Favorites", systemImage: "heart.fill")
                }
            }
            
            Section("Media Types") {
                ForEach(ContentShelf.allCases.filter { $0 != .all }) { shelf in
                    Button {
                        contentShelf = shelf
                        filterState = .all
                        currentFolderID = nil
                    } label: {
                        Label(shelf.rawValue, systemImage: shelf.icon)
                    }
                }
            }
            
            if !collections.isEmpty {
                Section("Collections") {
                    ForEach(collections) { col in
                        Button {
                            currentFolderID = col.id
                            filterState = .all
                            contentShelf = .all
                        } label: {
                            Label(col.name, systemImage: "folder.fill")
                        }
                    }
                }
            }
        } label: {
            if position == .top || position == .bottom {
                HStack(spacing: 6) {
                    Image(systemName: filterState != .all ? "line.3.horizontal.decrease.circle.fill" : contentShelf.icon)
                    Text(currentFolderID != nil ? "Collection" : (filterState != .all ? filterState.rawValue : contentShelf.rawValue))
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .opacity(0.6)
                }
                .foregroundColor(contentShelf.accentColor)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(contentShelf.accentColor.opacity(0.15), in: Capsule())
            } else {
                VStack(spacing: 4) {
                    Image(systemName: filterState != .all ? "line.3.horizontal.decrease.circle.fill" : contentShelf.icon)
                        .font(.system(size: 18, weight: .semibold))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .opacity(0.6)
                }
                .foregroundColor(contentShelf.accentColor)
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .background(contentShelf.accentColor.opacity(0.15), in: Circle())
            }
        }

        // Search Button
        Button(action: onSearch) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(.gray)
        }

        // Work Area Button (First-Class Icon)
        Button(action: onWorkArea) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(Theme.purple)
        }

        Divider().frame(width: position == .top || position == .bottom ? 1 : 20, height: position == .top || position == .bottom ? 20 : 1)

        // 2. Tools Menu
        Menu {
            Section("Settings") {
                Button(action: { viewStyle = viewStyle == .grid ? .list : .grid }) {
                    Label(viewStyle == .grid ? "Switch to List View" : "Switch to Grid View", systemImage: viewStyle == .grid ? "list.bullet" : "square.grid.2x2")
                }
                Button(action: { withAnimation { isBatchMode.toggle() } }) {
                    Label(isBatchMode ? "Exit Batch Mode" : "Enter Batch Mode", systemImage: "checkmark.circle")
                }
                Button(action: onVaultToggle) {
                    Label(settingsManager.isVaultUnlocked ? "Lock Vault" : "Unlock Vault", systemImage: settingsManager.isVaultUnlocked ? "lock.open.fill" : "lock.fill")
                }
                Button(action: { AppRouter.shared.presentSheet(.stats) }) {
                    Label("Stats", systemImage: "chart.bar.fill")
                }
            }
            
            Section("Connections") {
                Button(action: { AppRouter.shared.presentSheet(.cloudBrowser) }) {
                    let cloudConnected = DropboxProvider.shared.isConnected
                    Label("Cloud Library", systemImage: cloudConnected ? "checkmark.icloud.fill" : "icloud.and.arrow.down")
                }
                Button(action: { AppRouter.shared.presentSheet(.wifi) }) {
                    Label("Wi-Fi Sync", systemImage: "wifi")
                }
                Button(action: { AppRouter.shared.presentSheet(.smartListImporter) }) {
                    Label("Smart List Import", systemImage: "list.star")
                }
            }
            
            Section("Reader Settings") {
                Menu("Target Format: \(settingsManager.conversionSettings.outputFormat.rawValue)", systemImage: "arrow.triangle.2.circlepath") {
                    Picker("Target Format", selection: $settingsManager.conversionSettings.outputFormat) {
                        ForEach(OutputFormat.allCases) { format in
                            Label(format.rawValue, systemImage: format.icon).tag(format)
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
                }
                
                Menu("Tap Action: \(tapAction.rawValue)", systemImage: "hand.tap.fill") {
                    Picker("Tap Action", selection: $tapAction) {
                        ForEach(LibraryTapAction.allCases, id: \.self) { action in
                            Text(action.rawValue).tag(action)
                        }
                    }
                }
            }
            
            Section("Metadata & AI") {
                Button(action: {
                    Task { await BackgroundMetadataEngine.shared.startEngine(manager: conversionManager) }
                }) {
                    Label("Auto-Match Metadata", systemImage: "wand.and.stars.inverse")
                }
                
                if !conversionManager.failedMetadataPDFs.isEmpty {
                    Button(action: {
                        AppRouter.shared.presentSheet(.reviewMetadata)
                    }) {
                        Label("Review Missing", systemImage: "exclamationmark.triangle.fill")
                    }
                }
                
                Button(action: {
                    if multiSelection.count >= 1 {
                        let items = conversionManager.convertedPDFs.filter { multiSelection.contains($0.id) }
                        AppRouter.shared.presentSheet(.cognitiveBatchRenamer(items))
                    } else {
                        withAnimation { isBatchMode = true }
                        conversionManager.appAlert = AppAlert(title: "Select Issues", message: "Select 1 or more scrambled issues from your library to automatically rename using AI Vision.")
                    }
                }) {
                    Label("AI Rename", systemImage: "sparkles.tv")
                }
                
                Button(action: {
                    if multiSelection.count >= 1 {
                        let items = conversionManager.convertedPDFs.filter { multiSelection.contains($0.id) }
                        AppRouter.shared.presentSheet(.metadataSpreadsheet(items))
                        withAnimation { isBatchMode = false }
                    } else {
                        withAnimation { isBatchMode = true }
                        conversionManager.appAlert = AppAlert(title: "Select Issues", message: "Select issues to edit in the Grid Editor.")
                    }
                }) {
                    Label("Grid Editor", systemImage: "tablecells")
                }
            }
            
            Section("File Operations") {
                Button(action: {
                    AppRouter.shared.presentSheet(.merge)
                }) {
                    Label("PDF Merge Tool", systemImage: "arrow.triangle.merge")
                }
                
                Button(action: {
                    if multiSelection.count >= 2 {
                        batchMergeItems = conversionManager.convertedPDFs.filter { multiSelection.contains($0.id) }
                        showingBatchMergeReorder = true
                    } else {
                        withAnimation { isBatchMode = true }
                        conversionManager.appAlert = AppAlert(title: "Select Issues", message: "Select 2 or more issues from your library, then tap Convert & Merge again.")
                    }
                }) {
                    Label("Convert & Merge", systemImage: "doc.on.doc.fill")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle.fill")
                .font(.system(size: 24, weight: .medium))
                .foregroundColor(.white)
        }

        // 3. Import
        Button(action: onImport) {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 28, weight: .semibold))
                .foregroundColor(Color(red: 0.25, green: 0.55, blue: 1.0))
        }

        // 4. Settings
        Button(action: onSettings) {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(.gray)
        }
    }
}
