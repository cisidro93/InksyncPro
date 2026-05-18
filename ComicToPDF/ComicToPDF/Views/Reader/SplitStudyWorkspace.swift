import SwiftUI

enum DockPosition: String, CaseIterable, Codable {
    case left, right, top, bottom
}

/// Which content is shown in the split notebook panel.
enum NotebookPanelMode: String, CaseIterable {
    case notebook = "Notes"       // Classic per-book study notes (StudyNotebookView)
    case studio   = "Studio"      // Full Research + Writing Studio (InkStudioView)

    var icon: String {
        switch self {
        case .notebook: return "note.text"
        case .studio:   return "pencil.and.list.clipboard"
        }
    }
}

struct SplitStudyWorkspace: View {
    let fileURL: URL
    let contentType: ContentType
    let pdf: ConvertedPDF?
    
    @AppStorage("study_split_fraction")   private var splitFraction: Double = 0.65
    @AppStorage("study_dock_position")    private var dockPosition: DockPosition = .right
    @AppStorage("study_panel_mode")       private var panelMode: NotebookPanelMode = .notebook

    @Environment(\.horizontalSizeClass) var hSizeClass
    @Environment(\.dismiss) var dismiss
    @State private var showNotebook = false
    @State private var showCheatSheet = false
    
    var body: some View {
        GeometryReader { geo in
            let isCompact = hSizeClass == .compact || geo.size.width < 700
            
            if isCompact {
                // Compact device fallback — panel always shown as a sheet
                ZStack {
                    ReaderView(fileURL: fileURL, contentType: contentType, pdf: pdf, onExit: { dismiss() })
                        .sheet(isPresented: $showNotebook) {
                            sheetPanelContent
                        }
                    
                    compactNotebookToggle
                }
            } else {
                // Pro iPad / Mac Workspace — inline split panel
                ZStack {
                    if dockPosition == .right {
                        HStack(spacing: 0) {
                            readerPane(geo: geo, fraction: splitFraction, axis: .horizontal, primary: true)
                            if showNotebook {
                                divider(geo: geo, axis: .horizontal)
                                notebookPane(geo: geo, fraction: 1.0 - splitFraction, axis: .horizontal)
                            }
                        }
                    } else if dockPosition == .left {
                        HStack(spacing: 0) {
                            if showNotebook {
                                notebookPane(geo: geo, fraction: 1.0 - splitFraction, axis: .horizontal)
                                divider(geo: geo, axis: .horizontal)
                            }
                            readerPane(geo: geo, fraction: splitFraction, axis: .horizontal, primary: false)
                        }
                    } else if dockPosition == .bottom {
                        VStack(spacing: 0) {
                            readerPane(geo: geo, fraction: splitFraction, axis: .vertical, primary: true)
                            if showNotebook {
                                divider(geo: geo, axis: .vertical)
                                notebookPane(geo: geo, fraction: 1.0 - splitFraction, axis: .vertical)
                            }
                        }
                    } else if dockPosition == .top {
                        VStack(spacing: 0) {
                            if showNotebook {
                                notebookPane(geo: geo, fraction: 1.0 - splitFraction, axis: .vertical)
                                divider(geo: geo, axis: .vertical)
                            }
                            readerPane(geo: geo, fraction: splitFraction, axis: .vertical, primary: false)
                        }
                    }
                    
                    floatingProToolbar
                }
                .sheet(isPresented: $showCheatSheet) {
                    ProFeatureCheatSheet()
                }
            }
        }
        .edgesIgnoringSafeArea(.all)
        // Hidden Keyboard Navigation Triggers
        .background(
            Group {
                Button("") { dockPosition = .left }.keyboardShortcut("1", modifiers: [.command])
                Button("") { dockPosition = .bottom }.keyboardShortcut("2", modifiers: [.command])
                Button("") { dockPosition = .right }.keyboardShortcut("3", modifiers: [.command])
                Button("") { dockPosition = .top }.keyboardShortcut("4", modifiers: [.command])
                Button("") { showCheatSheet.toggle() }.keyboardShortcut("/", modifiers: [.command])
                Button("") { showNotebook.toggle() }.keyboardShortcut("b", modifiers: [.command])
                Button("") { panelMode = .notebook }.keyboardShortcut("n", modifiers: [.command, .shift])
                Button("") { panelMode = .studio }.keyboardShortcut("s", modifiers: [.command, .shift])
            }.opacity(0)
        )
    }
    
    // MARK: - Panel Content Router

    /// Content shown in the split panel — either the classic Study Notebook or the full Ink Studio.
    @ViewBuilder
    private var panelContent: some View {
        switch panelMode {
        case .notebook:
            StudyNotebookView(
                bookID: pdf?.id.uuidString ?? fileURL.lastPathComponent,
                bookTitle: pdf?.name ?? fileURL.deletingPathExtension().lastPathComponent
            )
        case .studio:
            InkStudioView()
        }
    }

    /// Sheet variant for compact (iPhone) devices.
    @ViewBuilder
    private var sheetPanelContent: some View {
        NavigationStack { panelContent }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
    }
    
    // MARK: - Builders
    
    @ViewBuilder
    private func readerPane(geo: GeometryProxy, fraction: Double, axis: Axis, primary: Bool) -> some View {
        ReaderView(fileURL: fileURL, contentType: contentType, pdf: pdf, onExit: { dismiss() })
            .frame(
                width: showNotebook ? (axis == .horizontal ? geo.size.width * fraction : geo.size.width) : geo.size.width,
                height: showNotebook ? (axis == .vertical ? geo.size.height * fraction : geo.size.height) : geo.size.height
            )
    }
    
    @ViewBuilder
    private func notebookPane(geo: GeometryProxy, fraction: Double, axis: Axis) -> some View {
        panelContent
            .frame(
                width: axis == .horizontal ? geo.size.width * fraction - 8 : geo.size.width,
                height: axis == .vertical ? geo.size.height * fraction - 8 : geo.size.height
            )
            .transition(.opacity)
    }
    
    @ViewBuilder
    private func divider(geo: GeometryProxy, axis: Axis) -> some View {
        ZStack {
            // Invisible larger hit area for easier grabbing
            Rectangle()
                .fill(Color.clear)
                .frame(width: axis == .horizontal ? 24 : nil, height: axis == .vertical ? 24 : nil)
            
            // Visible glass pill
            Capsule()
                .fill(.ultraThinMaterial)
                .frame(width: axis == .horizontal ? 6 : 40, height: axis == .vertical ? 6 : 40)
                .shadow(color: Color.black.opacity(0.15), radius: 2, x: 0, y: 1)
                .overlay(
                    Capsule()
                        .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
                )
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(coordinateSpace: .global)
                .onChanged { val in
                    if axis == .horizontal {
                        let newFraction = val.location.x / geo.size.width
                        splitFraction = min(max(newFraction, 0.2), 0.8)
                    } else {
                        let newFraction = val.location.y / geo.size.height
                        splitFraction = min(max(newFraction, 0.2), 0.8)
                    }
                }
        )
    }
    
    private var compactNotebookToggle: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button {
                    showNotebook.toggle()
                } label: {
                    Image(systemName: panelMode.icon)
                        .font(.system(size: 20))
                        .foregroundColor(.white)
                        .padding(16)
                        .background(panelMode == .studio ? Color(hex: "#7B5EA7") : Color.blue)
                        .clipShape(Circle())
                        .shadow(radius: 5)
                }
                .padding()
            }
        }
    }
    
    private var floatingProToolbar: some View {
        VStack {
            HStack {
                Spacer()
                
                HStack(spacing: 4) {
                    // Dock Position Cycler
                    Button {
                        cycleDockPosition()
                    } label: {
                        Image(systemName: "uiwindow.split.2x1")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.primary)
                            .padding(12)
                            .contentShape(Rectangle())
                    }
                    
                    Divider().frame(height: 20)

                    // Panel Mode Toggle (Notes ↔ Studio)
                    // Only shown when the panel is open — no point switching mode while hidden
                    if showNotebook {
                        ForEach(NotebookPanelMode.allCases, id: \.self) { mode in
                            Button {
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                                    panelMode = mode
                                }
                            } label: {
                                Image(systemName: mode.icon)
                                    .font(.system(size: 14, weight: panelMode == mode ? .bold : .regular))
                                    .foregroundColor(
                                        panelMode == mode
                                            ? (mode == .studio ? Color(hex: "#7B5EA7") : Theme.blue)
                                            : .primary.opacity(0.5)
                                    )
                                    .padding(12)
                                    .contentShape(Rectangle())
                            }
                        }

                        Divider().frame(height: 20)
                    }

                    // Cheat Sheet Toggle
                    Button {
                        showCheatSheet.toggle()
                    } label: {
                        Image(systemName: "questionmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(Theme.blue)
                            .padding(12)
                            .contentShape(Rectangle())
                    }
                    
                    Divider().frame(height: 20)
                    
                    // Notebook Toggle
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            showNotebook.toggle()
                        }
                    } label: {
                        Image(systemName: "sidebar.right")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(showNotebook ? Theme.blue : .primary)
                            .padding(12)
                            .contentShape(Rectangle())
                    }
                }
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)
                .overlay(
                    Capsule()
                        .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
                )
                .padding(.top, 110)
                .padding(.trailing, 20)
            }
            Spacer()
        }
    }
    
    private func cycleDockPosition() {
        withAnimation(.easeInOut) {
            switch dockPosition {
            case .right: dockPosition = .bottom
            case .bottom: dockPosition = .left
            case .left: dockPosition = .top
            case .top: dockPosition = .right
            }
        }
    }
}


// MARK: - Phase 3: Pro Feature Cheat Sheet
struct ProFeatureCheatSheet: View {
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationStack {
            List {
                Section(header: Text("Magic Keyboard Shortcuts")) {
                    shortcutRow(cmd: "CMD + B",         desc: "Toggle Side Panel")
                    shortcutRow(cmd: "CMD + SHIFT + N", desc: "Switch Panel to Notes")
                    shortcutRow(cmd: "CMD + SHIFT + S", desc: "Switch Panel to Studio")
                    shortcutRow(cmd: "CMD + E",         desc: "Extract Selection to Notebook")
                    shortcutRow(cmd: "CMD + 1",         desc: "Dock Panel Left")
                    shortcutRow(cmd: "CMD + 2",         desc: "Dock Panel Bottom")
                    shortcutRow(cmd: "CMD + 3",         desc: "Dock Panel Right")
                    shortcutRow(cmd: "CMD + 4",         desc: "Dock Panel Top")
                    shortcutRow(cmd: "CMD + /",         desc: "Show this Cheat Sheet")
                }
                
                Section(header: Text("Apple Pencil Gestures")) {
                    HStack(spacing: 16) {
                        Image(systemName: "lasso")
                            .font(.system(size: 24))
                            .foregroundColor(Theme.blue)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Lasso & Extract")
                                .font(.headline)
                            Text("Draw a circle around any image or text block. A floating menu will appear allowing you to crop and send the artifact directly to your Study Notebook.")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
            .navigationTitle("Pro Features")
            .navigationBarItems(trailing: Button("Done") { dismiss() })
        }
        .presentationDetents([.medium, .large])
    }
    
    private func shortcutRow(cmd: String, desc: String) -> some View {
        HStack {
            Text(desc)
                .font(.subheadline)
            Spacer()
            Text(cmd)
                .font(.caption.monospaced())
                .bold()
                .padding(6)
                .background(Color.primary.opacity(0.1))
                .cornerRadius(6)
        }
    }
}
