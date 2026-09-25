import SwiftUI
import SwiftData
import UniformTypeIdentifiers

enum AnnotationTypeFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case highlights = "Highlights"
    case notes = "Notes"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .highlights: return "highlighter"
        case .notes: return "text.alignleft"
        }
    }
}

// MARK: - Silk Ribbon Bookmark Component (Direction B Signature)
struct RibbonBookmarkShape: Shape {
    var notchDepth: CGFloat = 5

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - notchDepth))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

struct SilkRibbonBookmarkView: View {
    let color: Color
    var width: CGFloat = 13
    var height: CGFloat = 30

    var body: some View {
        ZStack {
            // Ribbon satin weave gradient fill
            RibbonBookmarkShape(notchDepth: 5)
                .fill(
                    LinearGradient(
                        colors: [
                            color.opacity(0.85),
                            color,
                            color.opacity(0.92)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )

            // Satin woven sheen stroke
            RibbonBookmarkShape(notchDepth: 5)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.4),
                            Color.clear,
                            Color.black.opacity(0.25)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    lineWidth: 0.8
                )
        }
        .frame(width: width, height: height)
        .shadow(color: Color.black.opacity(0.35), radius: 2.5, x: 0.5, y: 2)
    }
}

enum CoverStyleCategory: String, CaseIterable, Identifiable {
    case classic = "Classic"
    case creative = "Creative"
    case gradient = "Gradients"

    var id: String { rawValue }
}

struct NotebookSkinDefinition: Identifiable, Hashable {
    let id: String
    let name: String
    let category: Category
    let ribbonColor: Color
    let isSerif: Bool

    enum Category: String, CaseIterable, Identifiable {
        case classic = "Classic Journals"
        case creative = "Creative & Stylish"

        var id: String { rawValue }
    }

    static let allSkins: [NotebookSkinDefinition] = [
        // Classic Archival Journals
        NotebookSkinDefinition(
            id: "moleskine",
            name: "Moleskine",
            category: .classic,
            ribbonColor: Color(hex: "#C0392B"),
            isSerif: true
        ),
        NotebookSkinDefinition(
            id: "leather",
            name: "Saddle Leather",
            category: .classic,
            ribbonColor: Color(hex: "#D4AF37"),
            isSerif: true
        ),
        NotebookSkinDefinition(
            id: "midori",
            name: "Midori Olive",
            category: .classic,
            ribbonColor: Color(hex: "#B87333"),
            isSerif: true
        ),
        NotebookSkinDefinition(
            id: "linen",
            name: "Slate Linen",
            category: .classic,
            ribbonColor: Color(hex: "#F39C12"),
            isSerif: false
        ),
        NotebookSkinDefinition(
            id: "kraft",
            name: "Archival Kraft",
            category: .classic,
            ribbonColor: Color(hex: "#7B241C"),
            isSerif: false
        ),
        NotebookSkinDefinition(
            id: "composition",
            name: "Composition",
            category: .classic,
            ribbonColor: Color(hex: "#27AE60"),
            isSerif: false
        ),

        // Creative & Stylish (Option A style)
        NotebookSkinDefinition(
            id: "aura",
            name: "Aura Sunset",
            category: .creative,
            ribbonColor: Color(hex: "#FF6B6B"),
            isSerif: false
        ),
        NotebookSkinDefinition(
            id: "neon",
            name: "Cyber Neon",
            category: .creative,
            ribbonColor: Color(hex: "#00F2FE"),
            isSerif: false
        ),
        NotebookSkinDefinition(
            id: "cosmic",
            name: "Cosmic Nebula",
            category: .creative,
            ribbonColor: Color(hex: "#A18CD1"),
            isSerif: false
        ),
        NotebookSkinDefinition(
            id: "sage",
            name: "Pastel Sage",
            category: .creative,
            ribbonColor: Color(hex: "#E8D8C8"),
            isSerif: false
        ),
        NotebookSkinDefinition(
            id: "abstract",
            name: "Creative Spark",
            category: .creative,
            ribbonColor: Color(hex: "#FF851B"),
            isSerif: false
        )
    ]

    static func skin(for id: String?) -> NotebookSkinDefinition? {
        guard let id = id else { return nil }
        return allSkins.first(where: { $0.id == id })
    }

    static let coverGradients: [LinearGradient] = [
        LinearGradient(colors: [Color(hex: "#1a2a6c"), Color(hex: "#b21f1f")], startPoint: .topLeading, endPoint: .bottomTrailing),
        LinearGradient(colors: [Color(hex: "#0f2027"), Color(hex: "#203a43")], startPoint: .topLeading, endPoint: .bottomTrailing),
        LinearGradient(colors: [Color(hex: "#11998e"), Color(hex: "#38ef7d")], startPoint: .topLeading, endPoint: .bottomTrailing),
        LinearGradient(colors: [Color(hex: "#c0392b"), Color(hex: "#8e44ad")], startPoint: .topLeading, endPoint: .bottomTrailing),
        LinearGradient(colors: [Color(hex: "#2c3e50"), Color(hex: "#3498db")], startPoint: .topLeading, endPoint: .bottomTrailing),
        LinearGradient(colors: [Color(hex: "#f12711"), Color(hex: "#f5af19")], startPoint: .topLeading, endPoint: .bottomTrailing),
        LinearGradient(colors: [Color(hex: "#833ab4"), Color(hex: "#fd1d1d")], startPoint: .topLeading, endPoint: .bottomTrailing),
        LinearGradient(colors: [Color(hex: "#134e5e"), Color(hex: "#71b280")], startPoint: .topLeading, endPoint: .bottomTrailing)
    ]

    static let coverRibbonColors: [Color] = [
        Color(hex: "#b21f1f"),
        Color(hex: "#203a43"),
        Color(hex: "#38ef7d"),
        Color(hex: "#8e44ad"),
        Color(hex: "#3498db"),
        Color(hex: "#f5af19"),
        Color(hex: "#fd1d1d"),
        Color(hex: "#71b280")
    ]
}

struct GlobalNotebookView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject var conversionManager: ConversionManager
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var sizeClass

    // Query all annotations
    @Query private var allAnnotations: [SDAnnotation]

    // Query all custom notebooks
    @Query(sort: \SDNotebook.createdAt, order: .reverse) private var notebooks: [SDNotebook]

    @Binding var selectedPDF: ConvertedPDF?

    // Filter State
    @State private var searchQuery = ""
    @State private var selectedColorHex: String? = nil
    @State private var selectedBookID: UUID? = nil
    @State private var typeFilter: AnnotationTypeFilter = .all
    @State private var isShowingShareSheet = false
    @State private var shareText = ""
    @State private var toastMessage: String? = nil

    // Redesigned Notebooks Hub State
    enum Tab: String, CaseIterable, Identifiable {
        case notebooks  = "Notebooks"
        case highlights = "Highlights"
        case studyDeck  = "Active Study"
        case vocabulary = "Vocabulary"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .notebooks:  return "note.text"
            case .highlights: return "highlighter"
            case .studyDeck:  return "play.rectangle.on.rectangle.fill"
            case .vocabulary: return "character.book.closed"
            }
        }
    }

    private var tabTitle: String {
        switch activeTab {
        case .notebooks:  return "Notebooks Hub"
        case .highlights: return "Highlights & Knowledge"
        case .studyDeck:  return "Active Study Suite"
        case .vocabulary: return "Vocabulary Hub"
        }
    }

    private var tabSubtitle: String {
        switch activeTab {
        case .notebooks:  return "Your unified creative sketchbooks & study guides"
        case .highlights: return "Your consolidated reading highlights & Zettelkasten"
        case .studyDeck:  return "Cornell notes, Mortimer Adler markers & spaced repetition"
        case .vocabulary: return "Word bank and vocabulary learned from reading"
        }
    }

    struct ActiveNotebookSelection: Identifiable {
        let id: UUID
        let title: String
        let fileURL: URL?
    }

    enum NotebookSortOrder {
        case modified
        case title
        case created
    }

    @State private var activeTab: Tab = .notebooks
    @State private var activeNotebookSelection: ActiveNotebookSelection? = nil
    @State private var isShowingCreateNotebookSheet = false
    @State private var notebookSearchQuery = ""
    @State private var sortOrder: NotebookSortOrder = .modified
    @State private var editingNotebook: SDNotebook? = nil
    @State private var notebookToDelete: SDNotebook? = nil

    private var coverGradients: [LinearGradient] { NotebookSkinDefinition.coverGradients }
    private var coverRibbonColors: [Color] { NotebookSkinDefinition.coverRibbonColors }

    // Color Palette matching the highlight quick colors
    private let highlightColors = [
        ("#ffd700", "Yellow"),
        ("#30d158", "Green"),
        ("#ff375f", "Pink"),
        ("#0a84ff", "Blue"),
        ("#bf5af2", "Purple"),
        ("#ff9f0a", "Orange")
    ]

    // Filtered annotations sorted by creation date (newest first)
    private var filteredAnnotations: [SDAnnotation] {
        let sorted = allAnnotations.sorted { $0.createdAt > $1.createdAt }
        return sorted.filter { ann in
            // Filter by type
            if typeFilter == .highlights && ann.kindRaw != "highlight" { return false }
            if typeFilter == .notes && ann.kindRaw != "note" { return false }
            if ann.kindRaw != "highlight" && ann.kindRaw != "note" { return false } // only highlights & notes

            // Filter by color
            if let colorHex = selectedColorHex {
                if ann.colorHex?.lowercased() != colorHex.lowercased() { return false }
            }

            // Filter by book
            if let bookID = selectedBookID {
                if ann.pdfID != bookID { return false }
            }

            // Filter by search query
            if !searchQuery.isEmpty {
                let matchesText = ann.selectedText?.localizedCaseInsensitiveContains(searchQuery) ?? false
                let matchesNote = ann.noteText?.localizedCaseInsensitiveContains(searchQuery) ?? false
                let matchesChapter = ann.chapterTitle?.localizedCaseInsensitiveContains(searchQuery) ?? false
                let allTags = (ann.tags ?? []) + (ann.readwiseTags ?? []) + (ann.readwiseDocumentTags ?? [])
                let matchesTag = allTags.contains { $0.localizedCaseInsensitiveContains(searchQuery) || $0.localizedCaseInsensitiveContains(searchQuery.replacingOccurrences(of: "#", with: "")) }
                if !matchesText && !matchesNote && !matchesChapter && !matchesTag { return false }
            }

            return true
        }
    }

    // Grouped annotations by Book ID
    private var groupedAnnotations: [UUID: [SDAnnotation]] {
        Dictionary(grouping: filteredAnnotations, by: { $0.pdfID })
    }

    // Group keys sorted alphabetically by Book name
    private var sortedGroupedKeys: [UUID] {
        groupedAnnotations.keys.sorted { key1, key2 in
            let b1 = conversionManager.convertedPDFs.first(where: { $0.id == key1 })?.name
                ?? groupedAnnotations[key1]?.first?.readwiseBookTitle
                ?? ""
            let b2 = conversionManager.convertedPDFs.first(where: { $0.id == key2 })?.name
                ?? groupedAnnotations[key2]?.first?.readwiseBookTitle
                ?? ""
            return b1.localizedCompare(b2) == .orderedAscending
        }
    }

    // Books that have annotations
    private var booksWithAnnotations: [ConvertedPDF] {
        let annotatedBookIDs = Set(allAnnotations.filter { $0.kindRaw == "highlight" || $0.kindRaw == "note" }.map { $0.pdfID })
        return conversionManager.convertedPDFs.filter { annotatedBookIDs.contains($0.id) }
    }

    var filteredNotebooks: [SDNotebook] {
        let filtered = notebooks.filter { notebook in
            if notebookSearchQuery.isEmpty {
                return true
            }

            // 1. Title match
            if notebook.title.localizedCaseInsensitiveContains(notebookSearchQuery) {
                return true
            }

            // 2. Note text & Handwriting OCR match
            let notebookAnnotations = allAnnotations.filter { $0.pdfID == notebook.id }
            for ann in notebookAnnotations {
                if let note = ann.noteText, note.localizedCaseInsensitiveContains(notebookSearchQuery) {
                    return true
                }
                if let ocr = ann.drawingOCRText, ocr.localizedCaseInsensitiveContains(notebookSearchQuery) {
                    return true
                }
            }

            return false
        }

        return filtered.sorted { a, b in
            switch sortOrder {
            case .modified:
                return a.modifiedAt > b.modifiedAt
            case .title:
                return a.title.localizedStandardCompare(b.title) == .orderedAscending
            case .created:
                return a.createdAt > b.createdAt
            }
        }
    }

    var body: some View {
        ZStack {
            // Premium background
            Color.inkBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // Glassmorphic Header
                headerView

                // Content Switcher
                if activeTab == .notebooks {
                    if notebooks.isEmpty {
                        emptyNotebooksState
                    } else {
                        VStack(spacing: 0) {
                            notebookFilterPanel

                            if filteredNotebooks.isEmpty {
                                emptySearchNotebooksState
                            } else {
                                // Notebooks grid view
                                ScrollView {
                                    LazyVGrid(
                                        columns: sizeClass == .regular
                                            ? [GridItem(.adaptive(minimum: 170, maximum: 220), spacing: 24)]
                                            : [GridItem(.adaptive(minimum: 140, maximum: 180), spacing: 14)],
                                        spacing: sizeClass == .regular ? 28 : 18
                                    ) {
                                        ForEach(filteredNotebooks) { notebook in
                                            notebookCard(for: notebook)
                                        }
                                    }
                                    .padding(.horizontal, sizeClass == .regular ? 24 : 14)
                                    .padding(.top, 20)
                                    .padding(.bottom, 120) // spacing for tab bar
                                }
                            }
                        }
                    }
                } else if activeTab == .highlights {
                    GlobalZettelkastenHubView(activeTab: $activeTab)
                } else if activeTab == .studyDeck {
                    StudyNotebookContainerView(showDismissButton: false)
                } else {
                    VocabularyNotebookHubView()
                }
            }
        }
        .navigationBarHidden(true)
        .sheet(isPresented: $isShowingShareSheet) {
            ShareSheet(activityItems: [shareText])
        }
        .fullScreenCover(item: $activeNotebookSelection) { selection in
            StudyNotebookView(bookID: selection.id.uuidString, bookTitle: selection.title, fileURL: selection.fileURL, showBackButton: true)
        }
        .sheet(isPresented: $isShowingCreateNotebookSheet) {
            CreateNotebookSheet()
                .environmentObject(conversionManager)
        }
        .sheet(item: $editingNotebook) { notebook in
            EditNotebookSheet(notebook: notebook)
                .environmentObject(conversionManager)
        }
        .alert("Delete Notebook", isPresented: Binding(
            get: { notebookToDelete != nil },
            set: { if !$0 { notebookToDelete = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let notebook = notebookToDelete {
                    HapticEngine.warning()
                    modelContext.delete(notebook)
                    try? modelContext.save()
                    Logger.shared.log("Deleted notebook '\(notebook.title)'", category: "Notebook", type: .success)
                }
                notebookToDelete = nil
            }
            Button("Cancel", role: .cancel) {
                notebookToDelete = nil
            }
        } message: {
            if let notebook = notebookToDelete {
                Text("Are you sure you want to permanently delete '\(notebook.title)'? This will lose all typed notes and pencil sketches in this notebook.")
            }
        }
        .overlay(alignment: .bottom) {
            if let msg = toastMessage {
                Text(msg)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .background(Color.black.opacity(0.72), in: Capsule())
                    .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
                    .padding(.bottom, 60)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: toastMessage)
            }
        }
    }

    // MARK: - Header
    private var headerView: some View {
        VStack(spacing: 12) {
            if sizeClass == .compact {
                // Compact iPhone Portrait Layout: 2 rows
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tabTitle)
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [Color.orange, Color.purple],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                        Text(tabSubtitle)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.inkTextSecondary)
                    }

                    Spacer()

                    HStack(spacing: 12) {
                        if activeTab == .notebooks {
                            Menu {
                                Button {
                                    HapticEngine.medium()
                                    isShowingCreateNotebookSheet = true
                                } label: {
                                    Label("New Notebook", systemImage: "plus.circle")
                                }

                                Button {
                                    createNotebookFromClipboard()
                                } label: {
                                    Label("New from Clipboard", systemImage: "doc.on.clipboard")
                                }
                            } label: {
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 24))
                                    .foregroundStyle(
                                        LinearGradient(
                                            colors: [Color.orange, Color.purple],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                            }
                            .buttonStyle(.plain)
                        }

                        Button {
                            exportZettelkasten()
                        } label: {
                            Image(systemName: "square.and.arrow.up.on.square")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundColor(Color.orange)
                                .padding(10)
                                .background(Color.orange.opacity(0.12), in: Circle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(Tab.allCases) { tab in
                            Button {
                                HapticEngine.light()
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.76)) {
                                    activeTab = tab
                                }
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: tab.icon)
                                        .font(.system(size: 11, weight: .bold))
                                    Text(tab.rawValue)
                                        .font(.system(size: 11, weight: .bold, design: .rounded))
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(
                                    activeTab == tab
                                        ? AnyShapeStyle(Color.orange.opacity(0.18))
                                        : AnyShapeStyle(Color.clear)
                                )
                                .foregroundColor(activeTab == tab ? Color.orange : .inkTextSecondary)
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(3)
                    .background(Color.inkSurfaceRaised.opacity(0.5), in: Capsule())
                }
            } else {
                // Regular iPad / Landscape Layout: 1 row
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tabTitle)
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [Color.orange, Color.purple],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                        Text(tabSubtitle)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.inkTextSecondary)
                    }

                    Spacer()

                    if activeTab == .notebooks {
                        Menu {
                            Button {
                                HapticEngine.medium()
                                isShowingCreateNotebookSheet = true
                            } label: {
                                Label("New Notebook", systemImage: "plus.circle")
                            }

                            Button {
                                createNotebookFromClipboard()
                            } label: {
                                Label("New from Clipboard", systemImage: "doc.on.clipboard")
                            }
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 24))
                                .foregroundStyle(
                                    LinearGradient(
                                        colors: [Color.orange, Color.purple],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 8)
                    }

                    // Custom premium segmented tab switcher
                    HStack(spacing: 4) {
                        ForEach(Tab.allCases) { tab in
                            Button {
                                HapticEngine.light()
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.76)) {
                                    activeTab = tab
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: tab.icon)
                                        .font(.system(size: 12, weight: .bold))
                                    Text(tab.rawValue)
                                        .font(.system(size: 12, weight: .bold, design: .rounded))
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    activeTab == tab
                                        ? AnyShapeStyle(Color.orange.opacity(0.18))
                                        : AnyShapeStyle(Color.clear)
                                )
                                .foregroundColor(activeTab == tab ? Color.orange : .inkTextSecondary)
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(4)
                    .background(Color.inkSurfaceRaised.opacity(0.5), in: Capsule())
                    .padding(.trailing, 10)

                    // Export Zettelkasten Zip
                    Button {
                        exportZettelkasten()
                    } label: {
                        Image(systemName: "square.and.arrow.up.on.square")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(Color.orange)
                            .padding(10)
                            .background(Color.orange.opacity(0.12), in: Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(
            Color.inkSurface.opacity(0.4)
                .background(.ultraThinMaterial)
                .ignoresSafeArea()
        )
        .overlay(
            VStack {
                Spacer()
                Divider().background(Color.inkBorderSubtle)
            }
        )
    }

    // MARK: - Filter Panel
    private var filterPanel: some View {
        VStack(spacing: 12) {
            // Search Bar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.inkTextTertiary)
                    .font(.system(size: 15))

                TextField("Search across all highlights & notes...", text: $searchQuery)
                    .font(.system(size: 14))
                    .foregroundColor(.inkTextPrimary)
                    .submitLabel(.search)

                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.inkTextTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color.inkSurfaceRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 16)

            // Filter Chips
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    // Type Filter Picker
                    ForEach(AnnotationTypeFilter.allCases) { filter in
                        Button {
                            HapticEngine.light()
                            typeFilter = filter
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: filter.icon)
                                    .font(.system(size: 12))
                                Text(filter.rawValue)
                                    .font(.system(size: 13, weight: .bold, design: .rounded))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                typeFilter == filter
                                    ? AnyShapeStyle(Color.orange.opacity(0.18))
                                    : AnyShapeStyle(Color.inkSurfaceRaised)
                            )
                            .foregroundColor(typeFilter == filter ? Color.orange : .inkTextSecondary)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(typeFilter == filter ? Color.orange.opacity(0.3) : Color.clear, lineWidth: 1)
                            )
                            .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                    }

                    Divider()
                        .frame(height: 16)
                        .background(Color.inkBorderVisible)

                    // Colors
                    Button {
                        HapticEngine.light()
                        selectedColorHex = nil
                    } label: {
                        Text("All Colors")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(selectedColorHex == nil ? Color.primary.opacity(0.1) : Color.clear)
                            .foregroundColor(selectedColorHex == nil ? .inkTextPrimary : .inkTextSecondary)
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)

                    ForEach(highlightColors, id: \.0) { hex, name in
                        Button {
                            HapticEngine.light()
                            if selectedColorHex == hex {
                                selectedColorHex = nil
                            } else {
                                selectedColorHex = hex
                            }
                        } label: {
                            Circle()
                                .fill(Color(hex: hex))
                                .frame(width: 18, height: 18)
                                .overlay(
                                    Circle()
                                        .stroke(Color.primary.opacity(selectedColorHex == hex ? 0.8 : 0.15), lineWidth: selectedColorHex == hex ? 2 : 1)
                                )
                                .padding(4)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }

            // Books Horizontal shelf
            if booksWithAnnotations.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Button {
                            HapticEngine.light()
                            selectedBookID = nil
                        } label: {
                            Text("All Books")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(selectedBookID == nil ? Color.orange : Color.inkSurfaceRaised)
                                .foregroundColor(selectedBookID == nil ? .white : .inkTextSecondary)
                                .cornerRadius(12)
                        }
                        .buttonStyle(.plain)

                        ForEach(booksWithAnnotations) { book in
                            Button {
                                HapticEngine.light()
                                selectedBookID = book.id
                            } label: {
                                Text(book.name)
                                    .font(.system(size: 12, weight: .bold, design: .rounded))
                                    .lineLimit(1)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(selectedBookID == book.id ? Color.orange : Color.inkSurfaceRaised)
                                    .foregroundColor(selectedBookID == book.id ? .white : .inkTextSecondary)
                                    .cornerRadius(12)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.vertical, 12)
        .background(Color.inkSurface.opacity(0.15))
        .overlay(
            VStack {
                Spacer()
                Divider().background(Color.inkBorderSubtle)
            }
        )
    }

    // MARK: - Section Header for Book
    private func sectionHeader(title: String, author: String?, coverData: Data?, count: Int) -> some View {
        HStack(spacing: 12) {
            // Mini Cover Thumbnail
            if let coverData = coverData, let uiImage = UIImage(data: coverData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 24, height: 34)
                    .cornerRadius(4)
                    .shadow(radius: 2)
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(LinearGradient(colors: [Color.orange.opacity(0.5), Color.purple.opacity(0.5)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 24, height: 34)
                    .overlay(
                        Image(systemName: "book.closed")
                            .font(.system(size: 12))
                            .foregroundColor(.white)
                    )
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundColor(.inkTextPrimary)
                    .lineLimit(1)

                if let author = author, !author.isEmpty {
                    Text(author)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(.inkTextSecondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Text("\(count) items")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(.inkTextSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.inkSurfaceRaised, in: Capsule())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            Color.inkBackground
                .background(.regularMaterial)
        )
    }

    // MARK: - Highlight Card
    @ViewBuilder
    private func highlightCard(for annotation: SDAnnotation, book: ConvertedPDF?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Highlight text snippet
            if let selectedText = annotation.selectedText, !selectedText.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "quote.opening")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(Color(hex: annotation.colorHex ?? "#ffd700").opacity(0.8))

                    Text(selectedText)
                        .font(.system(size: 13, weight: .medium, design: .serif))
                        .foregroundColor(.inkTextPrimary)
                        .lineSpacing(4)
                        .multilineTextAlignment(.leading)
                }
            }

            // Custom notes text if exists
            if let noteText = annotation.noteText, !noteText.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "note.text")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(Color.purple)
                        Text("My Note")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundColor(.inkTextSecondary)
                    }
                    Text(noteText)
                        .font(.system(size: 13))
                        .foregroundColor(.inkTextSecondary)
                        .padding(.all, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.purple.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }

            // Footer (Metadata, page, actions)
            HStack {
                // Location / Page / Chapter Info
                HStack(spacing: 4) {
                    Image(systemName: "book.pages")
                        .font(.system(size: 10))
                    Text(annotation.chapterTitle ?? (annotation.isReadwiseImport ? "Location \(annotation.readwiseLocation ?? 0)" : "Page \(annotation.pageIndex + 1)"))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                }
                .foregroundColor(.inkTextSecondary)

                Spacer()

                // Action Buttons
                HStack(spacing: 12) {
                    // Copy
                    Button {
                        UIPasteboard.general.string = annotation.selectedText
                        HapticEngine.success()
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.inkTextSecondary)
                    }
                    .buttonStyle(.plain)

                    // Share
                    Button {
                        var share = ""
                        if let t = annotation.selectedText { share += "\"\(t)\"\n" }
                        if let n = annotation.noteText { share += "Note: \(n)\n" }
                        share += "— From \(book?.name ?? annotation.readwiseBookTitle ?? "Readwise Import")"
                        shareText = share
                        isShowingShareSheet = true
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.inkTextSecondary)
                    }
                    .buttonStyle(.plain)

                    // Delete
                    Button {
                        HapticEngine.warning()
                        withAnimation {
                            // Delete from AnnotationStore and SwiftData context
                            AnnotationStore.shared.delete(id: annotation.id, pdfID: annotation.pdfID)
                            modelContext.delete(annotation)
                            try? modelContext.save()
                        }
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.red.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.all, 14)
        .background(Color.inkSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.inkBorderSubtle, lineWidth: 0.8)
        )
        // Dynamic sidebar highlighting color
        .overlay(
            HStack {
                Rectangle()
                    .fill(Color(hex: annotation.colorHex ?? "#ffd700"))
                    .frame(width: 4)
                    .cornerRadius(2)
                Spacer()
            }
        )
        // Tap to read & navigate directly to that page
        .onTapGesture {
            if let book = book {
                openAnnotationInReader(annotation, book: book)
            }
        }
    }

    // MARK: - Navigation Logic
    private func openAnnotationInReader(_ annotation: SDAnnotation, book: ConvertedPDF) {
        HapticEngine.medium()

        // 1. Update progress tracker so the reader loads precisely on this page
        let currentProgress = ReaderProgressTracker.shared.progress(for: book.id)
        ReaderProgressTracker.shared.update(ReadingProgress(
            pdfID: book.id,
            lastOpenedAt: Date(),
            currentPageIndex: annotation.pageIndex,
            currentChapterIndex: annotation.pageIndex, // mapping for epub chapters
            currentChapterOffset: 0.0,
            totalPagesRead: currentProgress?.totalPagesRead ?? 1,
            completionFraction: currentProgress?.completionFraction ?? 0.0,
            readingSessionDates: currentProgress?.readingSessionDates ?? [Date()],
            estimatedMinutesRemaining: nil
        ))

        // Write scroll fraction to zero to force page alignment
        UserDefaults.standard.set(0.0, forKey: "epub_fraction_\(book.id.uuidString)")

        // 2. Instruct AppRouter to present the book reader
        selectedPDF = book
        AppRouter.shared.presentFullScreen(.read(book))
    }

    // MARK: - Empty State (Overall Library)
    private var emptyLibraryState: some View {
        VStack(spacing: 18) {
            Spacer()

            Image(systemName: "highlighter")
                .font(.system(size: 64))
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color.orange, Color.purple],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .padding(24)
                .background(Color.orange.opacity(0.1), in: Circle())

            Text("Your Highlights Hub is Empty")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundColor(.inkTextPrimary)

            Text("Highlight passages, select colors, and add notes while reading your books. They will automatically sync and organize inside this Zettelkasten center.")
                .font(.system(size: 13))
                .foregroundColor(.inkTextSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .padding(.horizontal, 36)

            Spacer()
        }
    }

    // MARK: - Empty State (Filters / Search)
    private var emptySearchResultState: some View {
        VStack(spacing: 14) {
            Spacer()

            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 40))
                .foregroundColor(.inkTextSecondary)

            Text("No Matching Highlights")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundColor(.inkTextPrimary)

            Text("Try refining your search text, type filters, or color selections.")
                .font(.system(size: 12))
                .foregroundColor(.inkTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 48)

            Button {
                withAnimation {
                    searchQuery = ""
                    selectedColorHex = nil
                    selectedBookID = nil
                    typeFilter = .all
                }
            } label: {
                Text("Clear All Filters")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundColor(Color.orange)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.orange.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)

            Spacer()
        }
    }

    // MARK: - Export Zettelkasten Action
    private func exportZettelkasten() {
        HapticEngine.medium()

        let fetchDescriptor = FetchDescriptor<SDAnnotation>()
        guard let allAnns = try? modelContext.fetch(fetchDescriptor) else { return }

        let allPDFs = conversionManager.convertedPDFs

        // Map SDAnnotations to Annotation DTOs
        let annDTOs = allAnns.map { $0.toDTO() }
        let pdfDTOs = allPDFs

        Task {
            do {
                let zipURL = try await ZettelkastenExporter.shared.exportToMarkdownZip(annotations: annDTOs, pdfs: pdfDTOs)

                await MainActor.run {
                    shareText = zipURL.path
                    isShowingShareSheet = true
                }
            } catch {
                Logger.shared.log("Highlights Hub: Zettelkasten zip export FAILED: \(error.localizedDescription)", category: "Notebook", type: .error)
            }
        }
    }

    // MARK: - Notebooks Views
    @ViewBuilder
    private func notebookCard(for notebook: SDNotebook) -> some View {
        let isLinked = notebook.linkedBookID != nil
        let linkedBook = isLinked ? conversionManager.convertedPDFs.first(where: { $0.id == notebook.linkedBookID }) : nil

        let bookIDForAnnotations = linkedBook?.id ?? notebook.id
        let bookAnnotations = allAnnotations.filter { $0.pdfID == bookIDForAnnotations }
        let highlightsCount = bookAnnotations.filter { $0.kindRaw == "highlight" }.count
        let noteAnns = bookAnnotations.filter { $0.kindRaw == "note" }
        let wordsCount = noteAnns.compactMap { $0.noteText }.joined(separator: " ").split(whereSeparator: \.isWhitespace).count
        let readMinutes = max(1, Int(ceil(Double(wordsCount) / 180.0)))

        let skinDef = NotebookSkinDefinition.skin(for: notebook.coverStyle)
        let ribbonColor: Color = {
            if let skin = skinDef { return skin.ribbonColor }
            if let _ = linkedBook { return Color.orange }
            return coverRibbonColors[notebook.coverGradientIndex % coverRibbonColors.count]
        }()
        let cardHeight: CGFloat = sizeClass == .regular ? 245 : 205

        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                // Book Main Card
                ZStack(alignment: .bottom) {
                    // Full-bleed Cover Area (Artwork, Skin, or Gradient)
                    Group {
                        if let lBook = linkedBook, let cData = lBook.coverImageData, let uiImg = UIImage(data: cData) {
                            ZStack {
                                Image(uiImage: uiImg)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(height: cardHeight)
                                    .clipped()

                                LinearGradient(
                                    colors: [
                                        Color.black.opacity(0.12),
                                        Color.clear,
                                        Color.black.opacity(0.68)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            }
                        } else if let skin = notebook.coverStyle, skin != "gradient" {
                            NotebookCoverSkinView(skinType: skin, title: notebook.title, colorScheme: colorScheme)
                        } else {
                            let gradient = coverGradients[notebook.coverGradientIndex % coverGradients.count]
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(gradient)
                        }
                    }
                    .frame(height: cardHeight)

                    // Direction B: Structured Frosted-Glass Bottom Metadata Card
                    bottomMetadataCard(
                        notebook: notebook,
                        isLinked: isLinked,
                        highlightsCount: highlightsCount,
                        wordsCount: wordsCount,
                        readMinutes: readMinutes,
                        skinDef: skinDef
                    )
                }
                .frame(height: cardHeight)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(colorScheme == .dark ? 0.15 : 0.28), lineWidth: 1)
                )
                .overlay(
                    // Left edge binding crease highlight (subtle satin edge, not a dark bar)
                    HStack {
                        LinearGradient(
                            colors: [Color.white.opacity(0.20), Color.white.opacity(0.04), Color.clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: 4)
                        Spacer()
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                )
                .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.45 : 0.18), radius: 8, x: 0, y: 5)

                // Direction B Signature: Silk Ribbon Bookmark Tab (Peeking from top edge)
                SilkRibbonBookmarkView(color: ribbonColor)
                    .padding(.trailing, 22)
                    .offset(y: -4)

                // Floating Linked Book Action
                if let lBook = linkedBook {
                    Button {
                        openBookInReader(lBook)
                    } label: {
                        Image(systemName: "book.circle.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(.white)
                            .shadow(color: Color.black.opacity(0.4), radius: 4, x: 0, y: 2)
                            .padding(8)
                    }
                    .buttonStyle(.plain)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                HapticEngine.light()
                self.activeNotebookSelection = ActiveNotebookSelection(
                    id: notebook.id,
                    title: notebook.title,
                    fileURL: linkedBook?.url
                )
            }
            .contextMenu {
                Button {
                    HapticEngine.light()
                    editingNotebook = notebook
                } label: {
                    Label("Edit Details", systemImage: "pencil")
                }

                Section("Export & Kindle") {
                    Button {
                        exportNotebook(notebook, format: .pdf)
                    } label: {
                        Label("Export as PDF (.pdf)", systemImage: "doc.richtext")
                    }

                    Button {
                        exportNotebook(notebook, format: .epub)
                    } label: {
                        Label("Export as EPUB (.epub)", systemImage: "book.pages")
                    }

                    Button {
                        sendNotebookToKindle(notebook, format: .pdf)
                    } label: {
                        Label("Send to Kindle (PDF)", systemImage: "paperplane")
                    }

                    Button {
                        sendNotebookToKindle(notebook, format: .epub)
                    } label: {
                        Label("Send to Kindle (EPUB)", systemImage: "paperplane.fill")
                    }

                    Button {
                        saveNotebookToLibraryAsBook(notebook, format: .pdf)
                    } label: {
                        Label("Save as PDF Book in Library", systemImage: "book.badge.plus")
                    }

                    Button {
                        saveNotebookToLibraryAsBook(notebook, format: .epub)
                    } label: {
                        Label("Save as EPUB Book in Library", systemImage: "books.vertical")
                    }
                }

                Divider()

                Button(role: .destructive) {
                    HapticEngine.warning()
                    notebookToDelete = notebook
                } label: {
                    Label("Delete Notebook", systemImage: "trash")
                }
            }
        }
    }

    private func bottomMetadataCard(
        notebook: SDNotebook,
        isLinked: Bool,
        highlightsCount: Int,
        wordsCount: Int,
        readMinutes: Int,
        skinDef: NotebookSkinDefinition?
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // Title
            Text(notebook.title)
                .font(.system(size: 13, weight: .bold, design: skinDef?.isSerif == true ? .serif : .rounded))
                .foregroundColor(.white)
                .lineLimit(1)

            // Metadata Line
            HStack(spacing: 5) {
                if highlightsCount > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "highlighter")
                            .font(.system(size: 8, weight: .bold))
                        Text("\(highlightsCount) hl")
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                    }
                    .foregroundColor(.white.opacity(0.85))

                    Text("•")
                        .font(.system(size: 8))
                        .foregroundColor(.white.opacity(0.4))
                } else if wordsCount > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 8, weight: .bold))
                        Text("\(wordsCount)w")
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                    }
                    .foregroundColor(.white.opacity(0.85))

                    Text("•")
                        .font(.system(size: 8))
                        .foregroundColor(.white.opacity(0.4))
                }

                HStack(spacing: 2) {
                    Image(systemName: "clock")
                        .font(.system(size: 8))
                    Text("~\(readMinutes)m")
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                }
                .foregroundColor(.white.opacity(0.85))

                Spacer(minLength: 0)

                // Badge (Linked or Template)
                HStack(spacing: 3) {
                    if isLinked {
                        Image(systemName: "link")
                            .font(.system(size: 7, weight: .bold))
                        Text("Linked")
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                    } else {
                        Text(notebook.templateStyle.capitalized)
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.white.opacity(0.18), in: Capsule())
                .foregroundColor(.white)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                Rectangle()
                    .fill(.ultraThinMaterial)
                Color.black.opacity(0.52)
            }
        )
        .overlay(
            Rectangle()
                .frame(height: 0.5)
                .foregroundColor(Color.white.opacity(0.2)),
            alignment: .top
        )
    }

    private func openBookInReader(_ book: ConvertedPDF) {
        HapticEngine.medium()

        // 1. Update progress tracker so the reader loads precisely on its saved page
        let currentProgress = ReaderProgressTracker.shared.progress(for: book.id)
        ReaderProgressTracker.shared.update(ReadingProgress(
            pdfID: book.id,
            lastOpenedAt: Date(),
            currentPageIndex: currentProgress?.currentPageIndex ?? 0,
            currentChapterIndex: currentProgress?.currentChapterIndex ?? 0,
            currentChapterOffset: 0.0,
            totalPagesRead: currentProgress?.totalPagesRead ?? 1,
            completionFraction: currentProgress?.completionFraction ?? 0.0,
            readingSessionDates: currentProgress?.readingSessionDates ?? [Date()],
            estimatedMinutesRemaining: nil
        ))

        // 2. Instruct AppRouter to present the book reader
        selectedPDF = book
        AppRouter.shared.presentFullScreen(.read(book))
    }

    private func fetchNotebookContent(for notebook: SDNotebook) -> String {
        var targetIDs: Set<UUID> = [notebook.id]
        if let linked = notebook.linkedBookID {
            targetIDs.insert(linked)
        }

        let matchingNotes = allAnnotations
            .filter { $0.kindRaw == "note" && targetIDs.contains($0.pdfID) }
            .sorted { $0.pageIndex < $1.pageIndex }

        if matchingNotes.isEmpty {
            return "# \(notebook.title)\n\n*(No written notes in this notebook yet)*"
        }

        if matchingNotes.count == 1 {
            let note = matchingNotes[0]
            var content = "# \(notebook.title)\n\n"
            content += note.noteText ?? ""
            if let cues = note.cornellCueText, !cues.isEmpty {
                content += "\n\n### Cornell Cues\n" + cues
            }
            if let summary = note.cornellSummaryText, !summary.isEmpty {
                content += "\n\n### Summary\n" + summary
            }
            return content
        }

        var pageBlocks: [String] = ["# \(notebook.title)\n"]
        for (idx, page) in matchingNotes.enumerated() {
            var block = "## Page \(idx + 1)\n\n"
            let noteContent = page.noteText ?? ""
            if !noteContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                block += noteContent
            } else {
                block += "*(Blank page)*"
            }
            if let cues = page.cornellCueText, !cues.isEmpty {
                block += "\n\n### Cornell Cues\n" + cues
            }
            if let summary = page.cornellSummaryText, !summary.isEmpty {
                block += "\n\n### Summary\n" + summary
            }
            pageBlocks.append(block)
        }
        return pageBlocks.joined(separator: "\n\n---\n\n")
    }

    private func exportNotebook(_ notebook: SDNotebook, format: NotebookExportFormat) {
        let content = fetchNotebookContent(for: notebook)
        do {
            let fileURL: URL
            switch format {
            case .pdf:
                fileURL = try NotebookDocumentExporter.shared.exportPDF(title: notebook.title, content: content)
            case .epub:
                fileURL = try NotebookDocumentExporter.shared.exportEPUB(title: notebook.title, content: content)
            }
            NotebookDocumentExporter.shared.presentShareSheet(for: fileURL)
            showToast("Exported \(notebook.title) as \(format.displayName)")
        } catch {
            Logger.shared.log("exportNotebook failed for '\(notebook.title)': \(error.localizedDescription)", category: "Notebook", type: .error)
            showToast("Export failed: \(error.localizedDescription)")
        }
    }

    private func sendNotebookToKindle(_ notebook: SDNotebook, format: NotebookExportFormat) {
        let content = fetchNotebookContent(for: notebook)
        NotebookDocumentExporter.shared.presentKindleExport(
            title: notebook.title,
            content: content,
            format: format
        )
    }

    private func saveNotebookToLibraryAsBook(_ notebook: SDNotebook, format: NotebookExportFormat) {
        let content = fetchNotebookContent(for: notebook)
        Task { @MainActor in
            do {
                let savedURL = try await NotebookDocumentExporter.shared.saveToLibraryAsBook(
                    title: notebook.title,
                    content: content,
                    format: format,
                    conversionManager: conversionManager
                )
                Logger.shared.log("Saved notebook '\(notebook.title)' to library at \(savedURL.path)", category: "Notebook", type: .success)
                HapticEngine.success()
                showToast("Saved '\(notebook.title)' to Library as \(format.displayName)!")
            } catch {
                Logger.shared.log("Failed to save notebook as library book: \(error.localizedDescription)", category: "Notebook", type: .error)
                HapticEngine.error()
                showToast("Save to library failed: \(error.localizedDescription)")
            }
        }
    }

    private func showToast(_ msg: String) {
        withAnimation { toastMessage = msg }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            withAnimation {
                if toastMessage == msg {
                    toastMessage = nil
                }
            }
        }
    }

    private func createNotebookFromClipboard() {
        guard let text = UIPasteboard.general.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            HapticEngine.error()
            return
        }
        HapticEngine.success()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = trimmed.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cleanTitle = firstLine.isEmpty ? "Clipboard Note" : String(firstLine.prefix(40))

        let newNotebook = SDNotebook(
            id: UUID(),
            title: cleanTitle,
            coverGradientIndex: Int.random(in: 0..<coverGradients.count),
            coverTitleColorHex: "#FFFFFF",
            templateStyle: "plain",
            linkedBookID: nil,
            coverStyle: "gradient"
        )
        modelContext.insert(newNotebook)

        let newNote = SDAnnotation(
            id: UUID(),
            pdfID: newNotebook.id.uuidString,
            pageIndex: 0,
            text: nil,
            note: trimmed,
            isReadwiseImport: false,
            readwiseBookTitle: cleanTitle,
            readwiseAuthor: nil,
            createdAt: Date()
        )
        newNote.kindRaw = "note"
        modelContext.insert(newNote)
        try? modelContext.save()

        self.activeNotebookSelection = ActiveNotebookSelection(
            id: newNotebook.id,
            title: newNotebook.title,
            fileURL: nil
        )
    }

    // MARK: - Empty State (Overall Notebooks)
    private var emptyNotebooksState: some View {
        VStack(spacing: 18) {
            Spacer()

            Image(systemName: "note.text")
                .font(.system(size: 64))
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color.orange, Color.purple],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .padding(24)
                .background(Color.orange.opacity(0.1), in: Circle())

            Text("No Notebooks Yet")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundColor(.inkTextPrimary)

            Text("Tap the '+' button in the top right to create your first customizable notebook. You can link notebooks directly to files in your library or keep them independent.")
                .font(.system(size: 13))
                .foregroundColor(.inkTextSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .padding(.horizontal, 36)

            Button {
                HapticEngine.medium()
                isShowingCreateNotebookSheet = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                    Text("Create Notebook")
                }
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Color.orange, in: Capsule())
            }
            .buttonStyle(.plain)

            Spacer()
        }
    }
}

// MARK: - Create Notebook Sheet
struct CreateNotebookSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var conversionManager: ConversionManager
    @Environment(\.colorScheme) private var colorScheme

    @State private var title = ""
    private var notebookTitle: String {
        title.isEmpty ? "My Notebook" : title
    }
    @State private var coverStyleCategory: CoverStyleCategory = .classic
    @State private var selectedGradientIndex = 0
    @State private var selectedSkin = "moleskine"
    @State private var selectedTemplate: PaperStyle = .plain
    @State private var selectedLinkedBook: ConvertedPDF? = nil
    @State private var searchQuery = ""

    private var coverGradients: [LinearGradient] { NotebookSkinDefinition.coverGradients }
    private var coverRibbonColors: [Color] { NotebookSkinDefinition.coverRibbonColors }

    var filteredBooks: [ConvertedPDF] {
        if searchQuery.isEmpty {
            return conversionManager.convertedPDFs
        } else {
            return conversionManager.convertedPDFs.filter { $0.name.localizedCaseInsensitiveContains(searchQuery) }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Notebook Details").font(.system(size: 11, weight: .semibold, design: .rounded))) {
                    TextField("Title", text: $title)
                        .font(.system(size: 15, design: .rounded))
                        .padding(.vertical, 4)
                }

                Section(header: Text("Cover Design").font(.system(size: 11, weight: .semibold, design: .rounded))) {
                    VStack(spacing: 12) {
                        coverPreviewView()

                        // Selector across Classic, Creative, and Gradients
                        Picker("Style", selection: $coverStyleCategory) {
                            ForEach(CoverStyleCategory.allCases) { cat in
                                Text(cat.rawValue).tag(cat)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding(.bottom, 4)

                        switch coverStyleCategory {
                        case .classic:
                            skinSelectorView(for: .classic)
                        case .creative:
                            skinSelectorView(for: .creative)
                        case .gradient:
                            gradientSelectorView()
                        }
                    }
                }

                Section(header: Text("Page Template").font(.system(size: 11, weight: .semibold, design: .rounded))) {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Template", selection: $selectedTemplate) {
                            ForEach(PaperStyle.allCases) { style in
                                Label(style.rawValue, systemImage: style.icon)
                                    .tag(style)
                            }
                        }
                        .pickerStyle(.menu)

                        // Live Paper Visual Preview
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(colorScheme == .dark ? Color(hex: "#1A1A1A") : Color.white)
                                .frame(height: 100)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.black.opacity(0.1), lineWidth: 1)
                                )

                            NotebookPaperBackground(style: selectedTemplate, spacing: 24.0, colorScheme: colorScheme)
                                .padding(8)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4)
                    }
                }

                Section(header: Text("Link to Library File (Optional)").font(.system(size: 11, weight: .semibold, design: .rounded))) {
                    if let selected = selectedLinkedBook {
                        HStack {
                            if let coverData = selected.coverImageData, let uiImg = UIImage(data: coverData) {
                                Image(uiImage: uiImg)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 30, height: 40)
                                    .cornerRadius(4)
                            } else {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.orange.opacity(0.2))
                                    .frame(width: 30, height: 40)
                                    .overlay(Image(systemName: "book").font(.system(size: 10)))
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text(selected.name)
                                    .font(.system(size: 13, weight: .bold, design: .rounded))
                                    .lineLimit(1)
                                Text("Linked Book")
                                    .font(.system(size: 10, design: .rounded))
                                    .foregroundColor(.orange)
                            }

                            Spacer()

                            Button("Unlink") {
                                selectedLinkedBook = nil
                            }
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.red)
                        }
                        .padding(.vertical, 4)
                    } else {
                        VStack(spacing: 8) {
                            HStack {
                                Image(systemName: "magnifyingglass")
                                    .foregroundColor(.secondary)
                                TextField("Search books...", text: $searchQuery)
                            }
                            .padding(6)
                            .background(Color.inkSurfaceRaised.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))

                            if filteredBooks.isEmpty {
                                Text("No matching books found")
                                    .font(.system(size: 11, design: .rounded))
                                    .foregroundColor(.secondary)
                                    .padding(.vertical, 8)
                            } else {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 12) {
                                        ForEach(filteredBooks) { book in
                                            VStack(spacing: 4) {
                                                if let coverData = book.coverImageData, let uiImg = UIImage(data: coverData) {
                                                    Image(uiImage: uiImg)
                                                        .resizable()
                                                        .aspectRatio(contentMode: .fill)
                                                        .frame(width: 45, height: 60)
                                                        .cornerRadius(6)
                                                        .shadow(radius: 1.5)
                                                } else {
                                                    RoundedRectangle(cornerRadius: 6)
                                                        .fill(Color.orange.opacity(0.15))
                                                        .frame(width: 45, height: 60)
                                                        .overlay(Image(systemName: "book").font(.system(size: 14)).foregroundColor(.orange))
                                                        .shadow(radius: 1.5)
                                                }

                                                Text(book.name)
                                                    .font(.system(size: 8, weight: .medium, design: .rounded))
                                                    .foregroundColor(.inkTextPrimary)
                                                    .lineLimit(1)
                                                    .frame(width: 50)
                                            }
                                            .onTapGesture {
                                                HapticEngine.light()
                                                selectedLinkedBook = book
                                                if title.isEmpty {
                                                    title = book.name + " Notebook"
                                                }
                                            }
                                        }
                                    }
                                    .padding(.vertical, 4)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Create Notebook")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .font(.system(size: 15, design: .rounded))
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Create") {
                        HapticEngine.success()
                        let finalCoverStyle = coverStyleCategory == .gradient ? "gradient" : selectedSkin
                        let newNotebook = SDNotebook(
                            id: UUID(),
                            title: title.isEmpty ? "My Notebook" : title,
                            coverGradientIndex: selectedGradientIndex,
                            coverTitleColorHex: "#FFFFFF",
                            templateStyle: selectedTemplate.rawValue,
                            linkedBookID: selectedLinkedBook?.id,
                            coverStyle: finalCoverStyle
                        )
                        modelContext.insert(newNotebook)
                        try? modelContext.save()
                        dismiss()
                    }
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundColor(.orange)
                    .disabled(title.isEmpty && selectedLinkedBook == nil)
                }
            }
        }
    }

    @ViewBuilder
    private func coverPreviewView() -> some View {
        let skinDef = coverStyleCategory != .gradient ? NotebookSkinDefinition.skin(for: selectedSkin) : nil
        let ribbonColor: Color = {
            if let skin = skinDef { return skin.ribbonColor }
            if let _ = selectedLinkedBook { return Color.orange }
            return coverRibbonColors[selectedGradientIndex % coverRibbonColors.count]
        }()

        ZStack(alignment: .topTrailing) {
            ZStack(alignment: .bottom) {
                Group {
                    if let lBook = selectedLinkedBook, let cData = lBook.coverImageData, let uiImg = UIImage(data: cData) {
                        Image(uiImage: uiImg)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(height: 190)
                            .clipped()
                    } else if coverStyleCategory != .gradient {
                        NotebookCoverSkinView(skinType: selectedSkin, title: notebookTitle, colorScheme: colorScheme)
                    } else {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(coverGradients[selectedGradientIndex])
                    }
                }
                .frame(height: 190)

                // Direction B Frosted-Glass Bottom Metadata Card Preview
                VStack(alignment: .leading, spacing: 4) {
                    Text(notebookTitle)
                        .font(.system(size: 12, weight: .bold, design: skinDef?.isSerif == true ? .serif : .rounded))
                        .foregroundColor(.white)
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        HStack(spacing: 2) {
                            Image(systemName: "doc.text")
                                .font(.system(size: 7))
                            Text("New")
                                .font(.system(size: 8, weight: .semibold, design: .rounded))
                        }
                        .foregroundColor(.white.opacity(0.85))

                        Spacer()

                        Text(selectedLinkedBook != nil ? "Linked" : selectedTemplate.rawValue.capitalized)
                            .font(.system(size: 7, weight: .bold, design: .rounded))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.white.opacity(0.18), in: Capsule())
                            .foregroundColor(.white)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    ZStack {
                        Rectangle().fill(.ultraThinMaterial)
                        Color.black.opacity(0.52)
                    }
                )
                .overlay(
                    Rectangle()
                        .frame(height: 0.5)
                        .foregroundColor(Color.white.opacity(0.2)),
                    alignment: .top
                )
            }
            .frame(width: 140, height: 190)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.25), lineWidth: 1)
            )
            .overlay(
                HStack {
                    LinearGradient(
                        colors: [Color.white.opacity(0.2), Color.white.opacity(0.04), Color.clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: 4)
                    Spacer()
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            )
            .shadow(color: Color.black.opacity(0.3), radius: 6, y: 3)

            // Direction B Silk Ribbon Bookmark Tab
            SilkRibbonBookmarkView(color: ribbonColor, width: 12, height: 26)
                .padding(.trailing, 16)
                .offset(y: -4)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func gradientSelectorView() -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(0..<coverGradients.count, id: \.self) { idx in
                    Circle()
                        .fill(coverGradients[idx])
                        .frame(width: 36, height: 36)
                        .overlay(
                            Circle()
                                .stroke(Color.orange, lineWidth: selectedGradientIndex == idx ? 3.0 : 0.0)
                        )
                        .onTapGesture {
                            HapticEngine.light()
                            selectedGradientIndex = idx
                        }
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private func skinSelectorView(for category: NotebookSkinDefinition.Category) -> some View {
        let skins = NotebookSkinDefinition.allSkins.filter { $0.category == category }
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(skins) { skin in
                    VStack(spacing: 6) {
                        ZStack(alignment: .topTrailing) {
                            NotebookCoverSkinView(skinType: skin.id, title: "Preview", colorScheme: colorScheme)
                                .frame(width: 52, height: 70)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(
                                            selectedSkin == skin.id ? Color.orange : Color.white.opacity(0.15),
                                            lineWidth: selectedSkin == skin.id ? 2.5 : 1
                                        )
                                )
                                .shadow(radius: 2)

                            SilkRibbonBookmarkView(color: skin.ribbonColor, width: 7, height: 16)
                                .padding(.trailing, 6)
                                .offset(y: -2)
                        }

                        Text(skin.name)
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundColor(selectedSkin == skin.id ? .orange : .inkTextSecondary)
                            .lineLimit(1)
                    }
                    .onTapGesture {
                        HapticEngine.light()
                        selectedSkin = skin.id
                    }
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
        }
    }
}

// MARK: - Procedural Cover Textures & Skins
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) {
        self.state = seed
    }
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state) / Double(UInt64.max)
    }
}

struct LinenTexture: View {
    var body: some View {
        GeometryReader { geo in
            Path { path in
                var y: CGFloat = 0
                while y < geo.size.height {
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: geo.size.width, y: y))
                    y += 3
                }
                var x: CGFloat = 0
                while x < geo.size.width {
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: geo.size.height))
                    x += 3
                }
            }
            .stroke(Color.white.opacity(0.06), lineWidth: 0.8)
        }
    }
}

struct KraftTexture: View {
    var body: some View {
        GeometryReader { geo in
            Path { path in
                var rng = SeededRandom(seed: 42)
                for _ in 0..<300 {
                    let rx = CGFloat(rng.next()) * geo.size.width
                    let ry = CGFloat(rng.next()) * geo.size.height
                    let len = CGFloat(rng.next()) * 3 + 1
                    let angle = CGFloat(rng.next()) * .pi * 2
                    path.move(to: CGPoint(x: rx, y: ry))
                    path.addLine(to: CGPoint(
                        x: rx + cos(angle) * len,
                        y: ry + sin(angle) * len
                    ))
                }
            }
            .stroke(Color.black.opacity(0.06), lineWidth: 0.8)
        }
    }
}

struct CompositionTexture: View {
    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color(hex: "#161616")

                Path { path in
                    var rng = SeededRandom(seed: 99)
                    for _ in 0..<180 {
                        let rx = CGFloat(rng.next()) * geo.size.width
                        let ry = CGFloat(rng.next()) * geo.size.height
                        let rw = CGFloat(rng.next()) * 14 + 5
                        let rh = CGFloat(rng.next()) * 7 + 2
                        path.addEllipse(in: CGRect(x: rx - rw/2, y: ry - rh/2, width: rw, height: rh))
                    }
                }
                .fill(Color.white.opacity(0.12))
            }
        }
    }
}

struct AuraMeshTexture: View {
    var body: some View {
        GeometryReader { geo in
            ZStack {
                Circle()
                    .fill(Color(hex: "#FF5E62").opacity(0.45))
                    .frame(width: geo.size.width * 0.9, height: geo.size.width * 0.9)
                    .blur(radius: 20)
                    .offset(x: -geo.size.width * 0.2, y: -geo.size.height * 0.2)

                Circle()
                    .fill(Color(hex: "#8E2DE2").opacity(0.5))
                    .frame(width: geo.size.width * 0.8, height: geo.size.width * 0.8)
                    .blur(radius: 25)
                    .offset(x: geo.size.width * 0.3, y: geo.size.height * 0.25)
            }
        }
    }
}

struct NeonGridTexture: View {
    var body: some View {
        GeometryReader { geo in
            Path { path in
                var x: CGFloat = 0
                while x < geo.size.width {
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: geo.size.height))
                    x += 16
                }
                var y: CGFloat = 0
                while y < geo.size.height {
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: geo.size.width, y: y))
                    y += 16
                }
            }
            .stroke(Color(hex: "#00F2FE").opacity(0.08), lineWidth: 0.6)
        }
    }
}

struct CosmicStarsTexture: View {
    var body: some View {
        GeometryReader { geo in
            Path { path in
                var rng = SeededRandom(seed: 777)
                for _ in 0..<80 {
                    let rx = CGFloat(rng.next()) * geo.size.width
                    let ry = CGFloat(rng.next()) * geo.size.height
                    let size = CGFloat(rng.next()) * 1.8 + 0.6
                    path.addEllipse(in: CGRect(x: rx, y: ry, width: size, height: size))
                }
            }
            .fill(Color.white.opacity(0.4))
        }
    }
}

struct SageBotanicalTexture: View {
    var body: some View {
        GeometryReader { geo in
            Path { path in
                path.move(to: CGPoint(x: geo.size.width * 0.15, y: geo.size.height * 0.85))
                path.addQuadCurve(
                    to: CGPoint(x: geo.size.width * 0.85, y: geo.size.height * 0.2),
                    control: CGPoint(x: geo.size.width * 0.3, y: geo.size.height * 0.3)
                )
            }
            .stroke(Color(hex: "#588157").opacity(0.2), lineWidth: 2)
        }
    }
}

struct AbstractWavesTexture: View {
    var body: some View {
        GeometryReader { geo in
            ZStack {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: geo.size.height * 0.4))
                    path.addCurve(
                        to: CGPoint(x: geo.size.width, y: geo.size.height * 0.25),
                        control1: CGPoint(x: geo.size.width * 0.3, y: geo.size.height * 0.15),
                        control2: CGPoint(x: geo.size.width * 0.7, y: geo.size.height * 0.5)
                    )
                    path.addLine(to: CGPoint(x: geo.size.width, y: 0))
                    path.addLine(to: CGPoint(x: 0, y: 0))
                    path.closeSubpath()
                }
                .fill(Color(hex: "#FF6B4A").opacity(0.8))

                Circle()
                    .fill(Color(hex: "#F4B41A"))
                    .frame(width: geo.size.width * 0.45, height: geo.size.width * 0.45)
                    .offset(x: geo.size.width * 0.25, y: geo.size.height * 0.15)

                Path { path in
                    path.move(to: CGPoint(x: 0, y: geo.size.height * 0.75))
                    path.addCurve(
                        to: CGPoint(x: geo.size.width, y: geo.size.height * 0.9),
                        control1: CGPoint(x: geo.size.width * 0.4, y: geo.size.height * 0.95),
                        control2: CGPoint(x: geo.size.width * 0.7, y: geo.size.height * 0.7)
                    )
                    path.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height))
                    path.addLine(to: CGPoint(x: 0, y: geo.size.height))
                    path.closeSubpath()
                }
                .fill(Color(hex: "#1E2A78").opacity(0.85))
            }
        }
    }
}

struct NotebookCoverSkinView: View {
    let skinType: String
    let title: String
    let colorScheme: ColorScheme

    var body: some View {
        ZStack {
            switch skinType {
            case "moleskine":
                ZStack {
                    RadialGradient(
                        colors: [Color(hex: "#1E2026"), Color(hex: "#101115")],
                        center: .center,
                        startRadius: 10,
                        endRadius: 220
                    )

                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.08), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .padding(6)

                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color(hex: "#D4AF37").opacity(0.6), lineWidth: 1.2)
                        .padding(10)
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color(hex: "#D4AF37").opacity(0.35), lineWidth: 0.6)
                        .padding(13)

                    VStack(spacing: 4) {
                        Text("ARCHIVAL JOURNAL")
                            .font(.system(size: 7, weight: .bold, design: .serif))
                            .tracking(1.5)
                            .foregroundColor(Color(hex: "#D4AF37").opacity(0.85))

                        Text(title)
                            .font(.system(size: 10, weight: .bold, design: .serif))
                            .foregroundColor(Color(hex: "#F5E6CC"))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .padding(.horizontal, 6)

                        Text("✦")
                            .font(.system(size: 7))
                            .foregroundColor(Color(hex: "#D4AF37").opacity(0.7))
                    }
                    .frame(maxWidth: 100)
                    .padding(.vertical, 8)
                    .background(Color(hex: "#0A0B0E").opacity(0.85))
                    .cornerRadius(6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(hex: "#D4AF37").opacity(0.5), lineWidth: 1.0))
                    .shadow(color: .black.opacity(0.5), radius: 3)
                }

            case "leather":
                ZStack {
                    RadialGradient(
                        colors: [Color(hex: "#4E2F1D"), Color(hex: "#26150B")],
                        center: .center,
                        startRadius: 10,
                        endRadius: 200
                    )

                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color(hex: "#CFB53B").opacity(0.55), lineWidth: 1.2)
                        .padding(8)
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color(hex: "#CFB53B").opacity(0.35), lineWidth: 0.6)
                        .padding(11)

                    VStack(spacing: 2) {
                        Text(title.uppercased())
                            .font(.system(size: 8, weight: .bold, design: .serif))
                            .foregroundColor(Color(hex: "#CFB53B"))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                    }
                    .frame(width: 95)
                    .background(Color(hex: "#1A0F07").opacity(0.85))
                    .cornerRadius(4)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(hex: "#CFB53B").opacity(0.6), lineWidth: 1.0))
                    .shadow(radius: 3)
                }

            case "midori":
                ZStack {
                    RadialGradient(
                        colors: [Color(hex: "#2B3C2F"), Color(hex: "#141D17")],
                        center: .center,
                        startRadius: 10,
                        endRadius: 200
                    )

                    Rectangle()
                        .fill(Color(hex: "#0E1410"))
                        .frame(width: 3.5)
                        .shadow(color: Color.black.opacity(0.4), radius: 1, x: 1, y: 0)

                    RoundedRectangle(cornerRadius: 2)
                        .fill(
                            LinearGradient(
                                colors: [Color(hex: "#D4AF37"), Color(hex: "#AA7C11"), Color(hex: "#D4AF37")],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: 6, height: 10)
                        .shadow(color: .black.opacity(0.3), radius: 1)

                    VStack(spacing: 3) {
                        Text("VOYAGE")
                            .font(.system(size: 6.5, weight: .bold, design: .monospaced))
                            .tracking(2.0)
                            .foregroundColor(Color(hex: "#C5A059"))

                        Text(title)
                            .font(.system(size: 9, weight: .semibold, design: .serif))
                            .foregroundColor(Color(hex: "#E8D8B8"))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .padding(.horizontal, 6)
                    }
                    .frame(width: 88)
                    .padding(.vertical, 6)
                    .background(Color(hex: "#101612").opacity(0.9))
                    .cornerRadius(4)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(hex: "#C5A059").opacity(0.6), lineWidth: 1))
                    .shadow(radius: 3)
                }

            case "linen":
                ZStack {
                    Color(hex: "#2c3e50")
                    LinenTexture()

                    VStack(spacing: 2) {
                        Text(title)
                            .font(.system(size: 9, weight: .semibold, design: .default))
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                    }
                    .frame(width: 95)
                    .background(Color(hex: "#34495e").opacity(0.9))
                    .cornerRadius(4)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.25), lineWidth: 1.0))
                    .shadow(radius: 2)
                }

            case "kraft":
                ZStack {
                    Color(hex: "#C69C6D")
                    KraftTexture()

                    VStack(spacing: 2) {
                        Text(title)
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundColor(Color(hex: "#2C1D11"))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                    }
                    .frame(width: 95)
                    .background(Color(hex: "#F9F6F0"))
                    .cornerRadius(4)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(hex: "#C69C6D").opacity(0.8), lineWidth: 1.0))
                    .shadow(radius: 2)
                }

            case "composition":
                ZStack {
                    CompositionTexture()

                    VStack(spacing: 3) {
                        Text("COMPOSITION")
                            .font(.system(size: 8, weight: .black, design: .monospaced))
                            .foregroundColor(.black)
                            .padding(.top, 4)

                        Text(title)
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundColor(.black)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)

                        VStack(spacing: 5) {
                            Divider().background(Color.black.opacity(0.2))
                            Divider().background(Color.black.opacity(0.2))
                        }
                        .padding(.horizontal, 10)
                        .padding(.bottom, 6)
                    }
                    .frame(width: 105)
                    .background(Color.white)
                    .cornerRadius(6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.black, lineWidth: 1.5))
                    .shadow(radius: 2)
                }

            case "aura":
                ZStack {
                    LinearGradient(
                        colors: [
                            Color(hex: "#FF5E62"),
                            Color(hex: "#FF9966"),
                            Color(hex: "#8E2DE2"),
                            Color(hex: "#4A00E0")
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )

                    AuraMeshTexture()

                    VStack(spacing: 3) {
                        Text(title)
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                    }
                    .frame(width: 100)
                    .background(.ultraThinMaterial)
                    .cornerRadius(8)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.35), lineWidth: 1))
                    .shadow(color: Color.black.opacity(0.2), radius: 4)
                }

            case "neon":
                ZStack {
                    Color(hex: "#0A0D18")
                    NeonGridTexture()

                    VStack(spacing: 3) {
                        Text(title.uppercased())
                            .font(.system(size: 9, weight: .black, design: .monospaced))
                            .foregroundColor(Color(hex: "#00F2FE"))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                    }
                    .frame(width: 95)
                    .background(Color(hex: "#101626").opacity(0.9))
                    .cornerRadius(6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(hex: "#00F2FE").opacity(0.7), lineWidth: 1.2))
                    .shadow(color: Color(hex: "#00F2FE").opacity(0.4), radius: 6)
                }

            case "cosmic":
                ZStack {
                    LinearGradient(
                        colors: [Color(hex: "#0F021F"), Color(hex: "#2A0845"), Color(hex: "#120127")],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )

                    CosmicStarsTexture()

                    VStack(spacing: 3) {
                        Text("✦ COSMOS ✦")
                            .font(.system(size: 6.5, weight: .bold, design: .rounded))
                            .foregroundColor(Color(hex: "#C084FC"))

                        Text(title)
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .padding(.horizontal, 8)
                    }
                    .frame(width: 95)
                    .padding(.vertical, 6)
                    .background(Color(hex: "#1A0933").opacity(0.85))
                    .cornerRadius(6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(hex: "#A855F7").opacity(0.5), lineWidth: 1))
                    .shadow(color: Color(hex: "#9333EA").opacity(0.3), radius: 4)
                }

            case "sage":
                ZStack {
                    LinearGradient(
                        colors: [Color(hex: "#CCD5AE"), Color(hex: "#E9EDC9"), Color(hex: "#D4A373").opacity(0.8)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )

                    SageBotanicalTexture()

                    VStack(spacing: 2) {
                        Text(title)
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundColor(Color(hex: "#333D29"))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                    }
                    .frame(width: 95)
                    .background(Color(hex: "#FEFAE0").opacity(0.92))
                    .cornerRadius(6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(hex: "#CCD5AE"), lineWidth: 1))
                    .shadow(color: Color.black.opacity(0.12), radius: 3)
                }

            case "abstract":
                ZStack {
                    Color(hex: "#FFFDF7")
                    AbstractWavesTexture()

                    VStack(spacing: 2) {
                        Text(title)
                            .font(.system(size: 9, weight: .black, design: .rounded))
                            .foregroundColor(Color(hex: "#1F2937"))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                    }
                    .frame(width: 95)
                    .background(Color.white.opacity(0.95))
                    .cornerRadius(6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(hex: "#1F2937").opacity(0.2), lineWidth: 1))
                    .shadow(color: Color.black.opacity(0.1), radius: 3)
                }

            default:
                Color.gray
            }
        }
    }
}

// MARK: - Edit Notebook Sheet & Filter Panels Extension
extension GlobalNotebookView {
    private var notebookFilterPanel: some View {
        HStack(spacing: 12) {
            // Glassmorphic search field
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.inkTextSecondary)

                TextField("Search notebooks...", text: $notebookSearchQuery)
                    .font(.system(size: 13, design: .rounded))
                    .foregroundColor(.inkTextPrimary)

                if !notebookSearchQuery.isEmpty {
                    Button {
                        HapticEngine.light()
                        notebookSearchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.inkTextSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.inkSurfaceRaised.opacity(0.5))
            .cornerRadius(10)

            // Sort Menu Button
            Menu {
                Button {
                    HapticEngine.light()
                    sortOrder = .modified
                } label: {
                    HStack {
                        Text("Last Modified")
                        if sortOrder == .modified { Image(systemName: "checkmark") }
                    }
                }
                Button {
                    HapticEngine.light()
                    sortOrder = .title
                } label: {
                    HStack {
                        Text("Title (A-Z)")
                        if sortOrder == .title { Image(systemName: "checkmark") }
                    }
                }
                Button {
                    HapticEngine.light()
                    sortOrder = .created
                } label: {
                    HStack {
                        Text("Date Created")
                        if sortOrder == .created { Image(systemName: "checkmark") }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.arrow.down.circle")
                        .font(.system(size: 16, weight: .bold))
                    Text(sortOrderLabel)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                }
                .foregroundColor(.orange)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
    }

    private var sortOrderLabel: String {
        switch sortOrder {
        case .modified: return "Modified"
        case .title: return "Title"
        case .created: return "Created"
        }
    }

    private var emptySearchNotebooksState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("No Notebooks Found")
                .font(.system(size: 16, weight: .bold, design: .rounded))
            Text("We couldn't find any notebooks matching '\(notebookSearchQuery)'. Try checking your spelling or search term.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 48)
            Spacer()
        }
    }
}

struct EditNotebookSheet: View {
    @Bindable var notebook: SDNotebook
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var conversionManager: ConversionManager
    @Environment(\.colorScheme) private var colorScheme

    @State private var title = ""
    private var notebookTitle: String {
        title.isEmpty ? "My Notebook" : title
    }
    @State private var coverStyleCategory: CoverStyleCategory = .classic
    @State private var selectedGradientIndex = 0
    @State private var selectedSkin = "moleskine"
    @State private var selectedTemplate: PaperStyle = .plain
    @State private var selectedLinkedBook: ConvertedPDF? = nil
    @State private var searchQuery = ""

    private var coverGradients: [LinearGradient] { NotebookSkinDefinition.coverGradients }
    private var coverRibbonColors: [Color] { NotebookSkinDefinition.coverRibbonColors }

    var filteredBooks: [ConvertedPDF] {
        if searchQuery.isEmpty {
            return conversionManager.convertedPDFs
        } else {
            return conversionManager.convertedPDFs.filter { $0.name.localizedCaseInsensitiveContains(searchQuery) }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Notebook Details").font(.system(size: 11, weight: .semibold, design: .rounded))) {
                    TextField("Title", text: $title)
                        .font(.system(size: 15, design: .rounded))
                        .padding(.vertical, 4)
                }

                Section(header: Text("Cover Design").font(.system(size: 11, weight: .semibold, design: .rounded))) {
                    VStack(spacing: 12) {
                        coverPreviewView()

                        Picker("Style", selection: $coverStyleCategory) {
                            ForEach(CoverStyleCategory.allCases) { cat in
                                Text(cat.rawValue).tag(cat)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding(.bottom, 4)

                        switch coverStyleCategory {
                        case .classic:
                            skinSelectorView(for: .classic)
                        case .creative:
                            skinSelectorView(for: .creative)
                        case .gradient:
                            gradientSelectorView()
                        }
                    }
                }

                Section(header: Text("Page Template").font(.system(size: 11, weight: .semibold, design: .rounded))) {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Template", selection: $selectedTemplate) {
                            ForEach(PaperStyle.allCases) { style in
                                Label(style.rawValue, systemImage: style.icon)
                                    .tag(style)
                            }
                        }
                        .pickerStyle(.menu)

                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(colorScheme == .dark ? Color(hex: "#1A1A1A") : Color.white)
                                .frame(height: 100)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.black.opacity(0.1), lineWidth: 1)
                                    )

                            NotebookPaperBackground(style: selectedTemplate, spacing: 24.0, colorScheme: colorScheme)
                                .padding(8)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4)
                    }
                }

                Section(header: Text("Link to Library File (Optional)").font(.system(size: 11, weight: .semibold, design: .rounded))) {
                    if let selected = selectedLinkedBook {
                        HStack {
                            if let coverData = selected.coverImageData, let uiImg = UIImage(data: coverData) {
                                Image(uiImage: uiImg)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 30, height: 40)
                                    .cornerRadius(4)
                            } else {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.orange.opacity(0.2))
                                    .frame(width: 30, height: 40)
                                    .overlay(Image(systemName: "book").font(.system(size: 10)))
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text(selected.name)
                                    .font(.system(size: 13, weight: .bold, design: .rounded))
                                    .lineLimit(1)
                                Text("Linked Book")
                                    .font(.system(size: 10, design: .rounded))
                                    .foregroundColor(.orange)
                            }

                            Spacer()

                            Button("Unlink") {
                                selectedLinkedBook = nil
                            }
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.red)
                        }
                        .padding(.vertical, 4)
                    } else {
                        VStack(spacing: 8) {
                            HStack {
                                Image(systemName: "magnifyingglass")
                                    .foregroundColor(.secondary)
                                TextField("Search books...", text: $searchQuery)
                            }
                            .padding(6)
                            .background(Color.inkSurfaceRaised.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))

                            if filteredBooks.isEmpty {
                                Text("No matching books found")
                                    .font(.system(size: 11, design: .rounded))
                                    .foregroundColor(.secondary)
                                    .padding(.vertical, 8)
                            } else {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 12) {
                                        ForEach(filteredBooks) { book in
                                            VStack(spacing: 4) {
                                                if let coverData = book.coverImageData, let uiImg = UIImage(data: coverData) {
                                                    Image(uiImage: uiImg)
                                                        .resizable()
                                                        .aspectRatio(contentMode: .fill)
                                                        .frame(width: 45, height: 60)
                                                        .cornerRadius(6)
                                                        .shadow(radius: 1.5)
                                                } else {
                                                    RoundedRectangle(cornerRadius: 6)
                                                        .fill(Color.orange.opacity(0.15))
                                                        .frame(width: 45, height: 60)
                                                        .overlay(Image(systemName: "book").font(.system(size: 14)).foregroundColor(.orange))
                                                        .shadow(radius: 1.5)
                                                }

                                                Text(book.name)
                                                    .font(.system(size: 8, weight: .medium, design: .rounded))
                                                    .foregroundColor(.inkTextPrimary)
                                                    .lineLimit(1)
                                                    .frame(width: 50)
                                            }
                                            .onTapGesture {
                                                HapticEngine.light()
                                                selectedLinkedBook = book
                                                if title.isEmpty {
                                                    title = book.name + " Notebook"
                                                }
                                            }
                                        }
                                    }
                                    .padding(.vertical, 4)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Edit Notebook Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .font(.system(size: 15, design: .rounded))
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        HapticEngine.success()
                        notebook.title = title.isEmpty ? "My Notebook" : title
                        notebook.coverGradientIndex = selectedGradientIndex
                        notebook.templateStyle = selectedTemplate.rawValue
                        notebook.linkedBookID = selectedLinkedBook?.id
                        notebook.coverStyle = coverStyleCategory == .gradient ? "gradient" : selectedSkin
                        notebook.modifiedAt = Date()
                        try? modelContext.save()
                        dismiss()
                    }
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundColor(.orange)
                    .disabled(title.isEmpty && selectedLinkedBook == nil)
                }
            }
            .onAppear {
                title = notebook.title
                selectedGradientIndex = notebook.coverGradientIndex
                selectedTemplate = PaperStyle(rawValue: notebook.templateStyle) ?? .plain
                if let skin = notebook.coverStyle, skin != "gradient" {
                    selectedSkin = skin
                    if let skinDef = NotebookSkinDefinition.allSkins.first(where: { $0.id == skin }) {
                        coverStyleCategory = skinDef.category == .classic ? .classic : .creative
                    } else {
                        coverStyleCategory = .classic
                    }
                } else {
                    coverStyleCategory = .gradient
                }
                if let linkedID = notebook.linkedBookID {
                    selectedLinkedBook = conversionManager.convertedPDFs.first(where: { $0.id == linkedID })
                }
            }
        }
    }

    @ViewBuilder
    private func coverPreviewView() -> some View {
        let skinDef = coverStyleCategory != .gradient ? NotebookSkinDefinition.skin(for: selectedSkin) : nil
        let ribbonColor: Color = {
            if let skin = skinDef { return skin.ribbonColor }
            if let _ = selectedLinkedBook { return Color.orange }
            return coverRibbonColors[selectedGradientIndex % coverRibbonColors.count]
        }()

        ZStack(alignment: .topTrailing) {
            ZStack(alignment: .bottom) {
                Group {
                    if let lBook = selectedLinkedBook, let cData = lBook.coverImageData, let uiImg = UIImage(data: cData) {
                        Image(uiImage: uiImg)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(height: 190)
                            .clipped()
                    } else if coverStyleCategory != .gradient {
                        NotebookCoverSkinView(skinType: selectedSkin, title: notebookTitle, colorScheme: colorScheme)
                    } else {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(coverGradients[selectedGradientIndex])
                    }
                }
                .frame(height: 190)

                // Direction B Frosted-Glass Bottom Metadata Card Preview
                VStack(alignment: .leading, spacing: 4) {
                    Text(notebookTitle)
                        .font(.system(size: 12, weight: .bold, design: skinDef?.isSerif == true ? .serif : .rounded))
                        .foregroundColor(.white)
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        HStack(spacing: 2) {
                            Image(systemName: "doc.text")
                                .font(.system(size: 7))
                            Text("Notebook")
                                .font(.system(size: 8, weight: .semibold, design: .rounded))
                        }
                        .foregroundColor(.white.opacity(0.85))

                        Spacer()

                        Text(selectedLinkedBook != nil ? "Linked" : selectedTemplate.rawValue.capitalized)
                            .font(.system(size: 7, weight: .bold, design: .rounded))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.white.opacity(0.18), in: Capsule())
                            .foregroundColor(.white)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    ZStack {
                        Rectangle().fill(.ultraThinMaterial)
                        Color.black.opacity(0.52)
                    }
                )
                .overlay(
                    Rectangle()
                        .frame(height: 0.5)
                        .foregroundColor(Color.white.opacity(0.2)),
                    alignment: .top
                )
            }
            .frame(width: 140, height: 190)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.25), lineWidth: 1)
            )
            .overlay(
                HStack {
                    LinearGradient(
                        colors: [Color.white.opacity(0.2), Color.white.opacity(0.04), Color.clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: 4)
                    Spacer()
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            )
            .shadow(color: Color.black.opacity(0.3), radius: 6, y: 3)

            // Direction B Silk Ribbon Bookmark Tab
            SilkRibbonBookmarkView(color: ribbonColor, width: 12, height: 26)
                .padding(.trailing, 16)
                .offset(y: -4)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func gradientSelectorView() -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(0..<coverGradients.count, id: \.self) { idx in
                    Circle()
                        .fill(coverGradients[idx])
                        .frame(width: 36, height: 36)
                        .overlay(
                            Circle()
                                .stroke(Color.orange, lineWidth: selectedGradientIndex == idx ? 3.0 : 0.0)
                        )
                        .onTapGesture {
                            HapticEngine.light()
                            selectedGradientIndex = idx
                        }
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private func skinSelectorView(for category: NotebookSkinDefinition.Category) -> some View {
        let skins = NotebookSkinDefinition.allSkins.filter { $0.category == category }
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(skins) { skin in
                    VStack(spacing: 6) {
                        ZStack(alignment: .topTrailing) {
                            NotebookCoverSkinView(skinType: skin.id, title: "Preview", colorScheme: colorScheme)
                                .frame(width: 52, height: 70)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(
                                            selectedSkin == skin.id ? Color.orange : Color.white.opacity(0.15),
                                            lineWidth: selectedSkin == skin.id ? 2.5 : 1
                                        )
                                )
                                .shadow(radius: 2)

                            SilkRibbonBookmarkView(color: skin.ribbonColor, width: 7, height: 16)
                                .padding(.trailing, 6)
                                .offset(y: -2)
                        }

                        Text(skin.name)
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundColor(selectedSkin == skin.id ? .orange : .inkTextSecondary)
                            .lineLimit(1)
                    }
                    .onTapGesture {
                        HapticEngine.light()
                        selectedSkin = skin.id
                    }
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
        }
    }
}

// ============================================================
// MARK: - Vocabulary Builder Notebook Hub View
// ============================================================
struct VocabularyNotebookHubView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SDVocabularyWord.dateAdded, order: .reverse) private var vocabularyWords: [SDVocabularyWord]

    @State private var searchQuery = ""
    @State private var selectedFilter: VocabularyFilter = .all

    enum VocabularyFilter: String, CaseIterable, Identifiable {
        case all = "All Words"
        case favorites = "Favorites"
        case learning = "Learning (<5 ★)"
        case mastered = "Mastered (5 ★)"

        var id: String { rawValue }
    }

    private var filteredWords: [SDVocabularyWord] {
        vocabularyWords.filter { item in
            if !searchQuery.isEmpty {
                let matchesWord = item.word.localizedCaseInsensitiveContains(searchQuery)
                let matchesContext = item.contextSentence.localizedCaseInsensitiveContains(searchQuery)
                let matchesBook = item.bookTitle.localizedCaseInsensitiveContains(searchQuery)
                if !matchesWord && !matchesContext && !matchesBook { return false }
            }
            switch selectedFilter {
            case .all:
                return true
            case .favorites:
                return item.isFavorite
            case .learning:
                return item.masteryLevel < 5
            case .mastered:
                return item.masteryLevel >= 5
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Filter Bar
            HStack(spacing: 12) {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Search vocabulary...", text: $searchQuery)
                        .font(.system(size: 14, design: .rounded))
                    if !searchQuery.isEmpty {
                        Button(action: { searchQuery = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.inkSurfaceRaised)
                .clipShape(RoundedRectangle(cornerRadius: 10))

                Picker("Filter", selection: $selectedFilter) {
                    ForEach(VocabularyFilter.allCases) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.menu)
                .tint(.orange)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)

            if filteredWords.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "character.book.closed.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(LinearGradient(colors: [.orange, .yellow], startPoint: .topLeading, endPoint: .bottomTrailing))
                    Text("No Vocabulary Words Found")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundColor(.primary)
                    Text("Look up words while reading EPUBs or PDFs to automatically build your personal vocabulary dictionary!")
                        .font(.system(size: 13, design: .rounded))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.bottom, 100)
            } else {
                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(filteredWords) { word in
                            VocabularyWordCard(word: word)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
                    .padding(.bottom, 120)
                }
            }
        }
    }
}

struct VocabularyWordCard: View {
    @Environment(\.modelContext) private var modelContext
    let word: SDVocabularyWord

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(word.word)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundColor(.primary)

                Spacer()

                Button(action: {
                    HapticEngine.light()
                    word.isFavorite.toggle()
                    try? modelContext.save()
                }) {
                    Image(systemName: word.isFavorite ? "heart.fill" : "heart")
                        .foregroundColor(word.isFavorite ? .pink : .secondary)
                }

                Button(action: {
                    HapticEngine.light()
                    DictionaryLookupService.shared.presentSystemDictionary(for: word.word)
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "book.fill")
                        Text("Define")
                    }
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.orange.opacity(0.15))
                    .foregroundColor(.orange)
                    .clipShape(Capsule())
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "book.closed")
                    .font(.system(size: 11))
                Text(word.bookTitle)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
            }
            .foregroundColor(.secondary)

            if !word.contextSentence.isEmpty {
                Text("\"\(word.contextSentence)\"")
                    .font(.system(size: 13, weight: .regular, design: .serif))
                    .italic()
                    .foregroundColor(.secondary)
                    .padding(.vertical, 2)
            }

            HStack {
                Text("Mastery:")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(.secondary)

                HStack(spacing: 4) {
                    ForEach(1...5, id: \.self) { star in
                        Image(systemName: star <= word.masteryLevel ? "star.fill" : "star")
                            .font(.system(size: 12))
                            .foregroundColor(star <= word.masteryLevel ? .orange : .secondary.opacity(0.4))
                            .onTapGesture {
                                HapticEngine.light()
                                word.masteryLevel = star
                                try? modelContext.save()
                            }
                    }
                }

                Spacer()

                Text(word.dateAdded.formatted(date: .abbreviated, time: .omitted))
                    .font(.system(size: 11, design: .rounded))
                    .foregroundColor(.secondary.opacity(0.7))
            }
        }
        .padding(16)
        .background(Color.inkSurface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.inkBorderSubtle, lineWidth: 0.8)
        )
        .shadow(color: Color.black.opacity(0.04), radius: 6, x: 0, y: 3)
    }
}
