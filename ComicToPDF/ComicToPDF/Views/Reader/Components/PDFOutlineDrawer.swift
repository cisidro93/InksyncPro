import SwiftUI
import PDFKit

// MARK: - Lightweight Swift 6 Outline Tree Model

/// Sendable recursive representation of a PDF outline document item.
struct OutlineNode: Identifiable, Sendable, Hashable {
    let id = UUID()
    let title: String
    let destinationPageIndex: Int
    let children: [OutlineNode]
    
    init(title: String, destinationPageIndex: Int, children: [OutlineNode] = []) {
        self.title = title
        self.destinationPageIndex = destinationPageIndex
        self.children = children
    }
}

// MARK: - PDF Outline Drawer

/// Slide-out glassmorphic document navigation drawer supporting hierarchical PDFOutline trees,
/// live keyword filtering, active page tracking, and bookmark management.
struct PDFOutlineDrawer: View {
    let pdf: ConvertedPDF
    let pdfDocument: PDFDocument?
    let currentPageIndex: Int
    var onJumpToPage: (Int) -> Void
    var onDismiss: () -> Void
    
    @State private var selectedTab: DrawerTab = .contents
    @State private var searchQuery: String = ""
    @State private var outlineTree: [OutlineNode] = []
    @State private var bookmarks: [Annotation] = []
    
    @Environment(\.colorScheme) private var colorScheme
    
    enum DrawerTab: String, CaseIterable, Identifiable {
        case contents  = "Contents"
        case bookmarks = "Bookmarks"
        
        var id: String { rawValue }
        var iconName: String {
            switch self {
            case .contents:  return "list.bullet.indent"
            case .bookmarks: return "bookmark.fill"
            }
        }
    }
    
    init(
        pdf: ConvertedPDF,
        pdfDocument: PDFDocument?,
        currentPageIndex: Int,
        onJumpToPage: @escaping (Int) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.pdf = pdf
        self.pdfDocument = pdfDocument
        self.currentPageIndex = currentPageIndex
        self.onJumpToPage = onJumpToPage
        self.onDismiss = onDismiss
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Search & Filter Header
                searchAndSegmentHeader
                
                Divider()
                    .background(Color.primary.opacity(0.08))
                
                // Tab Content
                Group {
                    switch selectedTab {
                    case .contents:
                        outlineContentView
                    case .bookmarks:
                        bookmarksContentView
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color.inkBackground.ignoresSafeArea())
            .navigationTitle("Document Navigator")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        onDismiss()
                    }
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundColor(.inkViolet)
                }
            }
            .onAppear {
                buildOutlineTree()
                refreshBookmarks()
            }
        }
    }
    
    // MARK: - Search & Segment Header
    
    private var searchAndSegmentHeader: some View {
        VStack(spacing: 10) {
            // Search Bar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.inkTextTertiary)
                
                TextField("Search contents or bookmarks...", text: $searchQuery)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                
                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.inkTextTertiary)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.top, 12)
            
            // Segmented Picker
            HStack(spacing: 0) {
                ForEach(DrawerTab.allCases) { tab in
                    Button {
                        HapticEngine.selection()
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                            selectedTab = tab
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: tab.iconName)
                                .font(.system(size: 12, weight: .bold))
                            Text(tab.rawValue)
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                        }
                        .foregroundColor(selectedTab == tab ? .white : .inkTextSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(
                            selectedTab == tab
                                ? AnyShapeStyle(Color.inkViolet)
                                : AnyShapeStyle(Color.clear)
                        )
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(Color.primary.opacity(0.06), in: Capsule())
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .background(Color.inkSurface.opacity(0.85).background(.ultraThinMaterial))
    }
    
    // MARK: - Outline Content View
    
    private var outlineContentView: some View {
        Group {
            let filtered = filterOutlineNodes(nodes: outlineTree, query: searchQuery)
            
            if filtered.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 40))
                        .foregroundColor(.inkTextTertiary)
                    Text(outlineTree.isEmpty ? "No Document Outline Found" : "No Matching Outline Items")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundColor(.inkTextSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(filtered) { node in
                            OutlineNodeRow(
                                node: node,
                                currentPageIndex: currentPageIndex,
                                onJump: { page in
                                    onJumpToPage(page)
                                    onDismiss()
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }
        }
    }
    
    // MARK: - Bookmarks Content View
    
    private var bookmarksContentView: some View {
        Group {
            let filtered = bookmarks.filter {
                searchQuery.isEmpty ||
                ($0.chapterTitle?.localizedCaseInsensitiveContains(searchQuery) ?? false) ||
                "Page \($0.pageIndex + 1)".localizedCaseInsensitiveContains(searchQuery)
            }
            
            VStack(spacing: 0) {
                // Quick Pin Bookmark for Current Page
                HStack {
                    Button {
                        toggleCurrentPageBookmark()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: isCurrentPageBookmarked ? "bookmark.slash.fill" : "bookmark.badge.plus")
                            Text(isCurrentPageBookmarked ? "Remove Page \(currentPageIndex + 1) Bookmark" : "Bookmark Page \(currentPageIndex + 1)")
                        }
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundColor(isCurrentPageBookmarked ? .inkRed : .inkViolet)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            (isCurrentPageBookmarked ? Color.inkRed : Color.inkViolet).opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                
                if filtered.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "bookmark.slash")
                            .font(.system(size: 36))
                            .foregroundColor(.inkTextTertiary)
                        Text("No Bookmarks Saved")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundColor(.inkTextSecondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(filtered) { b in
                            Button {
                                onJumpToPage(b.pageIndex)
                                onDismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "bookmark.fill")
                                        .foregroundColor(.inkViolet)
                                        .font(.system(size: 14))
                                    
                                    VStack(alignment: .leading, spacing: 2) {
                                        let titleString = b.chapterTitle ?? "Page \(b.pageIndex + 1)"
                                        Text(titleString)
                                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                                            .foregroundColor(.inkTextPrimary)
                                        
                                        let pageDesc = "Page \(b.pageIndex + 1)"
                                        Text("\(pageDesc) • \(b.createdAt.formatted(date: .abbreviated, time: .shortened))")
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundColor(.inkTextTertiary)
                                    }
                                    
                                    Spacer()
                                    
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundColor(.inkTextTertiary)
                                 }
                                .padding(.vertical, 4)
                            }
                            .listRowBackground(Color.inkSurface)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    AnnotationStore.shared.delete(id: b.id, pdfID: pdf.id)
                                    refreshBookmarks()
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                }
            }
        }
    }
    
    // MARK: - Helpers & Actions
    
    private var isCurrentPageBookmarked: Bool {
        bookmarks.contains(where: { $0.pageIndex == currentPageIndex })
    }
    
    private func toggleCurrentPageBookmark() {
        if let existing = bookmarks.first(where: { $0.pageIndex == currentPageIndex }) {
            AnnotationStore.shared.delete(id: existing.id, pdfID: pdf.id)
            HapticEngine.light()
        } else {
            let newBookmark = Annotation(
                pdfID: pdf.id,
                pageIndex: currentPageIndex,
                chapterTitle: "Page \(currentPageIndex + 1)",
                kind: .bookmark,
                createdAt: Date(),
                modifiedAt: Date()
            )
            AnnotationStore.shared.add(newBookmark)
            HapticEngine.success()
        }
        refreshBookmarks()
    }
    
    private func refreshBookmarks() {
        self.bookmarks = AnnotationStore.shared.annotations(for: pdf.id).filter { $0.kind == .bookmark }
    }
    
    private func buildOutlineTree() {
        guard let doc = pdfDocument, let root = doc.outlineRoot else {
            self.outlineTree = []
            return
        }
        self.outlineTree = parseOutlineChildren(of: root, in: doc)
    }
    
    private func parseOutlineChildren(of parent: PDFOutline, in document: PDFDocument) -> [OutlineNode] {
        var nodes: [OutlineNode] = []
        let count = parent.numberOfChildren
        
        for i in 0..<count {
            guard let child = parent.child(at: i), let title = child.label else { continue }
            
            var destPage = 0
            if let dest = child.destination, let page = dest.page {
                destPage = document.index(for: page)
            } else if let action = child.action as? PDFActionGoTo, let page = action.destination.page {
                destPage = document.index(for: page)
            }
            
            let subChildren = parseOutlineChildren(of: child, in: document)
            nodes.append(OutlineNode(
                title: title,
                destinationPageIndex: destPage,
                children: subChildren
            ))
        }
        
        return nodes
    }
    
    private func filterOutlineNodes(nodes: [OutlineNode], query: String) -> [OutlineNode] {
        guard !query.isEmpty else { return nodes }
        
        var results: [OutlineNode] = []
        for node in nodes {
            let matchesSelf = node.title.localizedCaseInsensitiveContains(query)
            let matchingChildren = filterOutlineNodes(nodes: node.children, query: query)
            
            if matchesSelf || !matchingChildren.isEmpty {
                results.append(OutlineNode(
                    title: node.title,
                    destinationPageIndex: node.destinationPageIndex,
                    children: matchingChildren
                ))
            }
        }
        return results
    }
}

// MARK: - Recursive Outline Node Row

public struct OutlineNodeRow: View {
    let node: OutlineNode
    let currentPageIndex: Int
    var onJump: (Int) -> Void
    var depth: Int = 0
    
    @State private var isExpanded: Bool = true
    
    private var isCurrentPosition: Bool {
        node.destinationPageIndex == currentPageIndex
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                // Indentation Spacer
                if depth > 0 {
                    Spacer()
                        .frame(width: CGFloat(depth * 14))
                }
                
                // Disclosure Chevron (if children exist)
                if !node.children.isEmpty {
                    Button {
                        HapticEngine.light()
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                            isExpanded.toggle()
                        }
                    } label: {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.inkTextTertiary)
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.plain)
                } else {
                    Spacer()
                        .frame(width: 16)
                }
                
                // Chapter Jump Button
                Button {
                    HapticEngine.light()
                    onJump(node.destinationPageIndex)
                } label: {
                    HStack(spacing: 8) {
                        Text(node.title)
                            .font(.system(size: 13, weight: isCurrentPosition ? .bold : .medium, design: .rounded))
                            .foregroundColor(isCurrentPosition ? .inkViolet : .inkTextPrimary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        
                        Spacer()
                        
                        Text("p. \(node.destinationPageIndex + 1)")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(isCurrentPosition ? .inkViolet : .inkTextTertiary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.primary.opacity(isCurrentPosition ? 0.12 : 0.04), in: Capsule())
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                    .background(
                        isCurrentPosition
                            ? AnyShapeStyle(Color.inkViolet.opacity(0.12))
                            : AnyShapeStyle(Color.clear)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            
            // Nested Children
            if isExpanded && !node.children.isEmpty {
                ForEach(node.children) { child in
                    OutlineNodeRow(
                        node: child,
                        currentPageIndex: currentPageIndex,
                        onJump: onJump,
                        depth: depth + 1
                    )
                }
            }
        }
    }
}
