import SwiftUI

struct OmniDockView: View {
    @Binding var contentShelf: ContentShelf
    @Binding var filterState: LibraryFilterState
    @Binding var sortOption: ModernLibraryView.SortOption
    @Binding var isBatchMode: Bool
    @Binding var viewStyle: ModernLibraryView.LibraryViewStyle
    @Binding var currentFolderID: UUID?
    var collections: [PDFCollection]
    
    var onWorkArea: () -> Void
    var onImport: () -> Void
    var onSettings: () -> Void
    var onVaultToggle: () -> Void
    var onSearch: () -> Void
    
    @State private var offset: CGSize = .zero
    @State private var position: DockPosition = .bottom
    @Environment(\.colorScheme) var colorScheme

    enum DockPosition {
        case bottom, top, left, right
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                offset = value.translation
            }
            .onEnded { value in
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
                .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.15 : 0.4), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.3), radius: 20, x: 0, y: 10)
        .offset(offset)
        .gesture(dragGesture)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignmentForPosition)
        .padding(safeAreaPaddingForPosition)
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
        case .bottom: return EdgeInsets(top: 0, leading: 0, bottom: 30, trailing: 0)
        case .left: return EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 0)
        case .right: return EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 20)
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
        }

        // Search Button
        Button(action: onSearch) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(.gray)
        }

        Divider().frame(width: position == .top || position == .bottom ? 1 : 20, height: position == .top || position == .bottom ? 20 : 1)

        // 2. Tools Menu
        Menu {
            Button(action: onWorkArea) {
                Label("Work Area", systemImage: "wand.and.stars")
            }
            Button(action: { AppRouter.shared.presentSheet(.stats) }) {
                Label("Stats", systemImage: "chart.bar.fill")
            }
            Divider()
            Button(action: { withAnimation { isBatchMode.toggle() } }) {
                Label(isBatchMode ? "Exit Batch Mode" : "Enter Batch Mode", systemImage: "checkmark.circle.badge.questionmark")
            }
            Button(action: { viewStyle = viewStyle == .grid ? .list : .grid }) {
                Label(viewStyle == .grid ? "Switch to List View" : "Switch to Grid View", systemImage: viewStyle == .grid ? "list.bullet" : "square.grid.2x2")
            }
            Divider()
            Button(action: onVaultToggle) {
                Label(AppSettingsManager.shared.isVaultUnlocked ? "Lock Vault" : "Unlock Vault", systemImage: AppSettingsManager.shared.isVaultUnlocked ? "lock.open.fill" : "lock.fill")
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
