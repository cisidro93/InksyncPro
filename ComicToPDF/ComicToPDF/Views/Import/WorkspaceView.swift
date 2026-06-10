import SwiftUI

enum WorkspaceMode: String, CaseIterable {
    case active = "Active"
    case inbox = "Inbox"
    case convert = "Convert"

    var icon: String {
        switch self {
        case .active: return "pencil.and.outline"
        case .inbox: return "tray"
        case .convert: return "arrow.triangle.2.circlepath"
        }
    }
    var activeIcon: String {
        switch self {
        case .active: return "pencil.and.outline"
        case .inbox: return "tray.fill"
        case .convert: return "arrow.triangle.2.circlepath.circle.fill"
        }
    }
    var tint: Color {
        switch self {
        case .active: return Color.inkViolet
        case .inbox: return Color.inkAmber
        case .convert: return Color.inkBlue
        }
    }
}

struct WorkspaceView: View {
    var isSheet: Bool = false
    @State private var mode: WorkspaceMode = .active
    @EnvironmentObject var conversionManager: ConversionManager
    @Environment(\.dismiss) var dismiss
    @AppStorage("appUIMode") private var appUIMode: AppUIMode = .pro
    
    private var availableModes: [WorkspaceMode] {
        if appUIMode == .pro {
            return [.active, .inbox, .convert]
        } else {
            return [.inbox, .convert]
        }
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // ── Frosted Segmented Picker ──────────────────────────────────
                workspaceSegmentPicker
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 10)

                Divider()
                    .background(Color.inkBorderVisible)

                // ── Content — all views stay alive ────────────────────────────
                ZStack {
                    ActiveWorkspaceListView()
                        .workspaceVisible(mode == .active)

                    InboxReviewView()
                        .workspaceVisible(mode == .inbox)

                    GoConvertView()
                        .workspaceVisible(mode == .convert)
                }
            }
            .background(Color.clear)
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if isSheet {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Done") {
                            dismiss()
                        }
                        .bold()
                    }
                }
            }
            .onAppear {
                adjustModeIfNeeded()
            }
            .onChange(of: appUIMode) { _, newValue in
                adjustModeIfNeeded()
            }
        }
    }

    private var navigationTitle: String {
        switch mode {
        case .active: return "Work Area"
        case .inbox: return "Inbox Review"
        case .convert: return "Go Convert"
        }
    }

    private var workspaceSegmentPicker: some View {
        HStack(spacing: 6) {
            ForEach(availableModes, id: \.self) { segment in
                segmentPill(segment)
            }
        }
    }

    @ViewBuilder
    private func segmentPill(_ segment: WorkspaceMode) -> some View {
        let isActive = mode == segment

        Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                mode = segment
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: isActive ? segment.activeIcon : segment.icon)
                    .font(.system(size: 13, weight: .semibold))
                Text(segment.rawValue)
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(isActive ? .white : Color.inkTextSecondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(
                isActive
                    ? AnyShapeStyle(
                        LinearGradient(
                            colors: [segment.tint, segment.tint.opacity(0.75)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                      )
                    : AnyShapeStyle(.regularMaterial),
                in: Capsule()
            )
            .overlay(
                Capsule().stroke(
                    isActive
                        ? Color.clear
                        : Color.inkBorderVisible.opacity(0.5),
                    lineWidth: 0.75
                )
            )
            .shadow(
                color: isActive ? segment.tint.opacity(0.35) : .clear,
                radius: 8, y: 3
            )
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: mode)
    }
    
    private func adjustModeIfNeeded() {
        if appUIMode == .pro {
            if mode != .active && mode != .inbox && mode != .convert {
                mode = .active
            }
        } else {
            if mode == .active {
                mode = .inbox
            }
        }
    }
}

// MARK: - Active Workspace Section Components

struct ActiveWorkspaceListView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @ObservedObject private var focusManager = WorkspaceFocusManager.shared
    @State private var searchText = ""
    
    var filteredPDFs: [ConvertedPDF] {
        let pinned = focusManager.pinnedIDs.compactMap { id in
            conversionManager.convertedPDFs.first(where: { $0.id == id })
        }
        if searchText.isEmpty {
            return pinned
        } else {
            return pinned.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }
    }
    
    var body: some View {
        ZStack {
            Color.clear.ignoresSafeArea()
            
            if filteredPDFs.isEmpty && searchText.isEmpty {
                VStack(spacing: 24) {
                    Spacer()
                    
                    ZStack {
                        NeuralExpressiveBackground()
                            .frame(width: 144, height: 144)
                            .clipShape(Circle())

                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .fill(.ultraThinMaterial)
                            .frame(width: 96, height: 96)
                            .overlay(
                                RoundedRectangle(cornerRadius: 28, style: .continuous)
                                    .stroke(
                                        LinearGradient(
                                            colors: [Color.white.opacity(0.35), Color.white.opacity(0.05)],
                                            startPoint: .topLeading, endPoint: .bottomTrailing
                                        ),
                                        lineWidth: 1
                                    )
                            )
                            .shadow(color: Theme.purple.opacity(0.2), radius: 20, y: 8)

                        Image(systemName: "pencil.and.outline")
                            .font(.system(size: 42, weight: .medium))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [Theme.purple, Theme.blue],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    }
                    .padding(.bottom, 16)
                    
                    Text("No Files in Work Area")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(Theme.text)
                        
                    Text("Long-press a file in the Library tab and tap \"Send to Work Area\" to start editing.")
                        .font(.system(size: 15))
                        .foregroundColor(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                        .padding(.horizontal, 40)
                        
                    Button(action: {
                        withAnimation {
                            AppRouter.shared.selectedTab = 0
                        }
                    }) {
                        Text("Go to Library")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                            .background(
                                LinearGradient(
                                    colors: [Theme.purple, Theme.blue],
                                    startPoint: .leading, endPoint: .trailing
                                ),
                                in: Capsule()
                            )
                            .shadow(color: Theme.purple.opacity(0.3), radius: 8, y: 3)
                    }
                    .padding(.top, 10)
                    
                    Spacer()
                }
            } else {
                VStack(spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Active Projects")
                                .font(.system(size: 28, weight: .bold))
                                .foregroundColor(Theme.text)
                            Text("\(filteredPDFs.count) active workspace files.")
                                .font(.system(size: 14))
                                .foregroundColor(Theme.textSecondary)
                        }
                        Spacer()
                        
                        if !filteredPDFs.isEmpty {
                            ActionPill(title: "Clear All", icon: "trash", color: Theme.red) {
                                focusManager.clearAll()
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    
                    WorkspaceSearchBar(text: $searchText, placeholder: "Search work area...")
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                    
                    if filteredPDFs.isEmpty {
                        VStack(spacing: 16) {
                            Spacer()
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 48))
                                .foregroundColor(Theme.textTertiary)
                            Text("No results for \"\(searchText)\"")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundColor(Theme.textSecondary)
                            Text("Check the spelling or try search terms.")
                                .font(.system(size: 14))
                                .foregroundColor(Theme.textTertiary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 40)
                            Spacer()
                        }
                    } else {
                        List {
                            ForEach(filteredPDFs) { pdf in
                                ActiveWorkspaceRowView(pdf: pdf) {
                                    AppRouter.shared.presentFullScreen(.advancedWorkspace(pdf))
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        focusManager.unpin(pdf)
                                    } label: {
                                        Label("Remove", systemImage: "pin.slash")
                                    }
                                    .tint(Theme.red)
                                }
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                    }
                }
            }
        }
    }
}

struct ActiveWorkspaceRowView: View {
    let pdf: ConvertedPDF
    let action: () -> Void
    @EnvironmentObject var conversionManager: ConversionManager
    
    var editedPageCount: Int {
        PageModelStore.shared.getEditedPageCount(for: pdf.id)
    }
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ComicCoverLoader(pdf: pdf)
                    .frame(width: 44, height: 66)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .clipped()
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(pdf.metadata.title.isEmpty ? pdf.name : pdf.metadata.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Theme.text)
                        .lineLimit(1)
                        .multilineTextAlignment(.leading)
                    
                    HStack(spacing: 6) {
                        HStack(spacing: 4) {
                            Image(systemName: pdf.contentType.icon)
                                .font(.system(size: 9, weight: .bold))
                            Text(pdf.contentType.rawValue)
                                .font(.system(size: 9, weight: .bold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(pdf.contentType.badgeColor, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        
                        Text("\(pdf.pageCount) Pages")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textSecondary)
                    }
                    
                    if editedPageCount > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "wand.and.stars")
                                .font(.system(size: 10))
                            Text("\(editedPageCount) pages with Guided View")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .foregroundColor(Theme.purple)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Theme.purple.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    } else {
                        Text("No Guided View data")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textTertiary)
                    }
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(Theme.textTertiary)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.inkBorderSubtle, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                WorkspaceFocusManager.shared.unpin(pdf)
            } label: {
                Label("Remove from Work Area", systemImage: "pin.slash")
            }
        }
    }
}

struct WorkspaceSearchBar: View {
    @Binding var text: String
    var placeholder: String = "Search..."
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Theme.textSecondary)
            
            TextField(placeholder, text: $text)
                .font(.system(size: 14))
                .foregroundColor(Theme.text)
                .tint(Theme.purple)
                .autocorrectionDisabled()
            
            if !text.isEmpty {
                Button(action: { text = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(Theme.textSecondary)
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Theme.text.opacity(0.08), lineWidth: 1)
        )
    }
}

private extension View {
    @ViewBuilder
    func workspaceVisible(_ isVisible: Bool) -> some View {
        self
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(isVisible ? 1 : 0)
            .allowsHitTesting(isVisible)
            .accessibilityHidden(!isVisible)
    }
}
