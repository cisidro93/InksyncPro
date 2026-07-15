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

struct GlobalNotebookView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject var conversionManager: ConversionManager
    @Environment(\.colorScheme) private var colorScheme
    
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
    
    // Redesigned Notebooks Hub State
    enum Tab: String, CaseIterable, Identifiable {
        case notebooks = "Notebooks"
        case highlights = "Highlights"
        
        var id: String { rawValue }
        
        var icon: String {
            switch self {
            case .notebooks: return "note.text"
            case .highlights: return "highlighter"
            }
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
    
    private let coverGradients: [LinearGradient] = [
        LinearGradient(colors: [Color(hex: "#1a2a6c"), Color(hex: "#b21f1f")], startPoint: .topLeading, endPoint: .bottomTrailing),
        LinearGradient(colors: [Color(hex: "#0f2027"), Color(hex: "#203a43")], startPoint: .topLeading, endPoint: .bottomTrailing),
        LinearGradient(colors: [Color(hex: "#11998e"), Color(hex: "#38ef7d")], startPoint: .topLeading, endPoint: .bottomTrailing),
        LinearGradient(colors: [Color(hex: "#c0392b"), Color(hex: "#8e44ad")], startPoint: .topLeading, endPoint: .bottomTrailing),
        LinearGradient(colors: [Color(hex: "#2c3e50"), Color(hex: "#3498db")], startPoint: .topLeading, endPoint: .bottomTrailing),
        LinearGradient(colors: [Color(hex: "#f12711"), Color(hex: "#f5af19")], startPoint: .topLeading, endPoint: .bottomTrailing),
        LinearGradient(colors: [Color(hex: "#833ab4"), Color(hex: "#fd1d1d")], startPoint: .topLeading, endPoint: .bottomTrailing),
        LinearGradient(colors: [Color(hex: "#134e5e"), Color(hex: "#71b280")], startPoint: .topLeading, endPoint: .bottomTrailing)
    ]
    
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
                if !matchesText && !matchesNote && !matchesChapter { return false }
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
                if activeTab == .notebooks {
                    headerView
                }
                
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
                                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 220), spacing: 24)], spacing: 28) {
                                        ForEach(filteredNotebooks) { notebook in
                                            notebookCard(for: notebook)
                                        }
                                    }
                                    .padding(.horizontal, 24)
                                    .padding(.top, 20)
                                    .padding(.bottom, 120) // spacing for tab bar
                                }
                            }
                        }
                    }
                } else {
                    GlobalZettelkastenHubView(activeTab: $activeTab)
                }
            }
        }
        .navigationBarHidden(true)
        .sheet(isPresented: $isShowingShareSheet) {
            ShareSheet(activityItems: [shareText])
        }
        .fullScreenCover(item: $activeNotebookSelection) { selection in
            NavigationStack {
                StudyNotebookView(bookID: selection.id.uuidString, bookTitle: selection.title, fileURL: selection.fileURL)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("Done") {
                                activeNotebookSelection = nil
                            }
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundColor(.orange)
                        }
                    }
            }
        }
        .sheet(isPresented: $isShowingCreateNotebookSheet) {
            CreateNotebookSheet()
                .environmentObject(conversionManager)
        }
        .sheet(item: $editingNotebook) { notebook in
            EditNotebookSheet(notebook: notebook)
                .environmentObject(conversionManager)
        }
    }
    
    // MARK: - Header
    private var headerView: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(activeTab == .notebooks ? "Notebooks Hub" : "Highlights Hub")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.orange, Color.purple],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Text(activeTab == .notebooks ? "Your unified creative sketchbooks & study guides" : "Your consolidated reading highlights & notes")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.inkTextSecondary)
            }
            
            Spacer()
            
            if activeTab == .notebooks {
                Button {
                    HapticEngine.medium()
                    isShowingCreateNotebookSheet = true
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
        let noteAnn = bookAnnotations.first { $0.kindRaw == "note" }
        let hasTextNote = noteAnn != nil && !(noteAnn?.noteText?.isEmpty ?? true)
        let hasDrawing = noteAnn != nil && !(noteAnn?.drawingData?.isEmpty ?? true)
        
        let isSkin = notebook.coverStyle != nil && notebook.coverStyle != "gradient"
        
        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                // Front cover
                Group {
                    if isSkin, let skin = notebook.coverStyle {
                        NotebookCoverSkinView(skinType: skin, title: notebook.title, colorScheme: colorScheme)
                    } else {
                        let gradient = coverGradients[notebook.coverGradientIndex % coverGradients.count]
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(gradient)
                    }
                }
                .frame(height: 240)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.4 : 0.15), radius: 8, x: 0, y: 4)
                .overlay(
                    ZStack(alignment: .leading) {
                        // spine / book binding
                        Rectangle()
                            .fill(Color.black.opacity(0.25))
                            .frame(width: 16)
                        
                        // Cover overlay ribbon for linked books
                        if let lBook = linkedBook, let cData = lBook.coverImageData, let uiImg = UIImage(data: cData) {
                            Image(uiImage: uiImg)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 80, height: 110)
                                .cornerRadius(6)
                                .shadow(radius: 4)
                                .padding(.leading, 32)
                                .padding(.top, 16)
                                .frame(maxHeight: .infinity, alignment: .top)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                )
                
                // Content on cover
                VStack(alignment: .leading, spacing: 10) {
                    Spacer()
                    
                    if notebook.coverStyle != "composition" {
                        // Book Title Label
                        Text(notebook.title)
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    
                    Spacer()
                    
                    // Stats section
                    VStack(alignment: .leading, spacing: 6) {
                        // Linked Badge or Template style
                        HStack(spacing: 4) {
                            Image(systemName: isLinked ? "link.circle.fill" : "doc.text.fill")
                                .font(.system(size: 9, weight: .bold))
                            Text(isLinked ? "Linked Note" : notebook.templateStyle)
                                .font(.system(size: 8, weight: .bold, design: .rounded))
                        }
                        .foregroundColor(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.3), in: Capsule())
                        
                        if highlightsCount > 0 {
                            HStack(spacing: 6) {
                                Image(systemName: "highlighter")
                                    .font(.system(size: 10, weight: .bold))
                                Text("\(highlightsCount) Highlights")
                                    .font(.system(size: 10, weight: .medium, design: .rounded))
                            }
                            .foregroundColor(.white.opacity(0.9))
                        }
                        
                        if hasTextNote {
                            HStack(spacing: 6) {
                                Image(systemName: "text.alignleft")
                                    .font(.system(size: 10, weight: .bold))
                                Text("Text Notes")
                                    .font(.system(size: 10, weight: .medium, design: .rounded))
                            }
                            .foregroundColor(.white.opacity(0.9))
                        }
                        
                        if hasDrawing {
                            HStack(spacing: 6) {
                                Image(systemName: "applepencil")
                                    .font(.system(size: 10, weight: .bold))
                                Text("Sketches")
                                    .font(.system(size: 10, weight: .medium, design: .rounded))
                            }
                            .foregroundColor(.white.opacity(0.9))
                        }
                    }
                    .padding(.leading, 8)
                }
                .padding(.leading, 24) // offset from binding
                .padding(.trailing, 12)
                .padding(.bottom, 16)
                .padding(.top, 16)
                
                // Open Book floating action icon
                if let lBook = linkedBook {
                    Button {
                        openBookInReader(lBook)
                    } label: {
                        Image(systemName: "book.circle.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(.white)
                            .shadow(color: Color.black.opacity(0.3), radius: 4, x: 0, y: 2)
                            .padding(10)
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
                
                Button(role: .destructive) {
                    HapticEngine.warning()
                    modelContext.delete(notebook)
                    try? modelContext.save()
                    Logger.shared.log("Deleted notebook '\(notebook.title)'", category: "Notebook", type: .success)
                } label: {
                    Label("Delete Notebook", systemImage: "trash")
                }
            }
        }
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
    @State private var coverStyle = "gradient" // "gradient" or "skin"
    @State private var selectedGradientIndex = 0
    @State private var selectedSkin = "composition" // "composition", "leather", "kraft", "linen"
    @State private var selectedTemplate: PaperStyle = .plain
    @State private var selectedLinkedBook: ConvertedPDF? = nil
    @State private var searchQuery = ""
    
    private let coverGradients: [LinearGradient] = [
        LinearGradient(colors: [Color(hex: "#1a2a6c"), Color(hex: "#b21f1f")], startPoint: .topLeading, endPoint: .bottomTrailing),
        LinearGradient(colors: [Color(hex: "#0f2027"), Color(hex: "#203a43")], startPoint: .topLeading, endPoint: .bottomTrailing),
        LinearGradient(colors: [Color(hex: "#11998e"), Color(hex: "#38ef7d")], startPoint: .topLeading, endPoint: .bottomTrailing),
        LinearGradient(colors: [Color(hex: "#c0392b"), Color(hex: "#8e44ad")], startPoint: .topLeading, endPoint: .bottomTrailing),
        LinearGradient(colors: [Color(hex: "#2c3e50"), Color(hex: "#3498db")], startPoint: .topLeading, endPoint: .bottomTrailing),
        LinearGradient(colors: [Color(hex: "#f12711"), Color(hex: "#f5af19")], startPoint: .topLeading, endPoint: .bottomTrailing),
        LinearGradient(colors: [Color(hex: "#833ab4"), Color(hex: "#fd1d1d")], startPoint: .topLeading, endPoint: .bottomTrailing),
        LinearGradient(colors: [Color(hex: "#134e5e"), Color(hex: "#71b280")], startPoint: .topLeading, endPoint: .bottomTrailing)
    ]
    
    private let skinNames = [
        ("composition", "Composition"),
        ("leather", "Leather"),
        ("kraft", "Kraft Card"),
        ("linen", "Slate Linen")
    ]
    
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
                        // Live Cover Preview
                        ZStack(alignment: .leading) {
                            if coverStyle == "skin" {
                                NotebookCoverSkinView(skinType: selectedSkin, title: title.isEmpty ? "My Notebook" : title, colorScheme: colorScheme)
                            } else {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(coverGradients[selectedGradientIndex])
                            }
                        }
                        .frame(width: 140, height: 190)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .shadow(radius: 6, y: 3)
                        .overlay(
                            HStack {
                                Rectangle()
                                    .fill(Color.black.opacity(0.2))
                                    .frame(width: 12)
                                Spacer()
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        )
                        .overlay(
                            Group {
                                if coverStyle != "skin" || selectedSkin != "composition" {
                                    VStack(alignment: .leading) {
                                        Spacer()
                                        Text(title.isEmpty ? "My Notebook" : title)
                                            .font(.system(size: 11, weight: .bold, design: .rounded))
                                            .foregroundColor(.white)
                                            .lineLimit(2)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 3)
                                            .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 4))
                                            .padding(.leading, 18)
                                            .padding(.bottom, 12)
                                    }
                                }
                            }
                        )
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 12)
                        
                        // Selector between Gradients and Skins
                        Picker("Style", selection: $coverStyle) {
                            Text("Gradients").tag("gradient")
                            Text("Cover Skins").tag("skin")
                        }
                        .pickerStyle(.segmented)
                        .padding(.bottom, 4)
                        
                        if coverStyle == "gradient" {
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
                        } else {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 12) {
                                    ForEach(skinNames, id: \.0) { skin in
                                        VStack(spacing: 6) {
                                            ZStack {
                                                NotebookCoverSkinView(skinType: skin.0, title: "Preview", colorScheme: colorScheme)
                                                    .frame(width: 48, height: 64)
                                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                                    .shadow(radius: 2)
                                                
                                                if selectedSkin == skin.0 {
                                                    RoundedRectangle(cornerRadius: 6)
                                                        .stroke(Color.orange, lineWidth: 3)
                                                        .frame(width: 48, height: 64)
                                                }
                                            }
                                            
                                            Text(skin.1)
                                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                                .foregroundColor(selectedSkin == skin.0 ? .orange : .inkTextSecondary)
                                        }
                                        .onTapGesture {
                                            HapticEngine.light()
                                            selectedSkin = skin.0
                                        }
                                    }
                                }
                                .padding(.horizontal, 4)
                                .padding(.vertical, 6)
                            }
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
                            
                            NotebookPaperBackground(style: selectedTemplate, colorScheme: colorScheme)
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
                        let newNotebook = SDNotebook(
                            id: UUID(),
                            title: title.isEmpty ? "My Notebook" : title,
                            coverGradientIndex: selectedGradientIndex,
                            coverTitleColorHex: "#FFFFFF",
                            templateStyle: selectedTemplate.rawValue,
                            linkedBookID: selectedLinkedBook?.id,
                            coverStyle: coverStyle == "skin" ? selectedSkin : "gradient"
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

struct NotebookCoverSkinView: View {
    let skinType: String // "composition", "leather", "kraft", "linen"
    let title: String
    let colorScheme: ColorScheme
    
    var body: some View {
        ZStack {
            switch skinType {
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
                }
                
            case "kraft":
                ZStack {
                    Color(hex: "#C69C6D")
                    KraftTexture()
                }
                
            case "linen":
                ZStack {
                    Color(hex: "#2c3e50")
                    LinenTexture()
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
    @State private var coverStyle = "gradient"
    @State private var selectedGradientIndex = 0
    @State private var selectedSkin = "composition"
    @State private var selectedTemplate: PaperStyle = .plain
    @State private var selectedLinkedBook: ConvertedPDF? = nil
    @State private var searchQuery = ""
    
    private let coverGradients: [LinearGradient] = [
        LinearGradient(colors: [Color(hex: "#1a2a6c"), Color(hex: "#b21f1f")], startPoint: .topLeading, endPoint: .bottomTrailing),
        LinearGradient(colors: [Color(hex: "#0f2027"), Color(hex: "#203a43")], startPoint: .topLeading, endPoint: .bottomTrailing),
        LinearGradient(colors: [Color(hex: "#11998e"), Color(hex: "#38ef7d")], startPoint: .topLeading, endPoint: .bottomTrailing),
        LinearGradient(colors: [Color(hex: "#c0392b"), Color(hex: "#8e44ad")], startPoint: .topLeading, endPoint: .bottomTrailing),
        LinearGradient(colors: [Color(hex: "#2c3e50"), Color(hex: "#3498db")], startPoint: .topLeading, endPoint: .bottomTrailing),
        LinearGradient(colors: [Color(hex: "#f12711"), Color(hex: "#f5af19")], startPoint: .topLeading, endPoint: .bottomTrailing),
        LinearGradient(colors: [Color(hex: "#833ab4"), Color(hex: "#fd1d1d")], startPoint: .topLeading, endPoint: .bottomTrailing),
        LinearGradient(colors: [Color(hex: "#134e5e"), Color(hex: "#71b280")], startPoint: .topLeading, endPoint: .bottomTrailing)
    ]
    
    private let skinNames = [
        ("composition", "Composition"),
        ("leather", "Leather"),
        ("kraft", "Kraft Card"),
        ("linen", "Slate Linen")
    ]
    
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
                        ZStack(alignment: .leading) {
                            if coverStyle == "skin" {
                                NotebookCoverSkinView(skinType: selectedSkin, title: title.isEmpty ? "My Notebook" : title, colorScheme: colorScheme)
                            } else {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(coverGradients[selectedGradientIndex])
                            }
                        }
                        .frame(width: 140, height: 190)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .shadow(radius: 6, y: 3)
                        .overlay(
                            HStack {
                                Rectangle()
                                    .fill(Color.black.opacity(0.2))
                                    .frame(width: 12)
                                Spacer()
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        )
                        .overlay(
                            Group {
                                if coverStyle != "skin" || selectedSkin != "composition" {
                                    VStack(alignment: .leading) {
                                        Spacer()
                                        Text(title.isEmpty ? "My Notebook" : title)
                                            .font(.system(size: 11, weight: .bold, design: .rounded))
                                            .foregroundColor(.white)
                                            .lineLimit(2)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 3)
                                            .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 4))
                                            .padding(.leading, 18)
                                            .padding(.bottom, 12)
                                    }
                                }
                            }
                        )
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 12)
                        
                        Picker("Style", selection: $coverStyle) {
                            Text("Gradients").tag("gradient")
                            Text("Cover Skins").tag("skin")
                        }
                        .pickerStyle(.segmented)
                        .padding(.bottom, 4)
                        
                        if coverStyle == "gradient" {
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
                        } else {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 12) {
                                    ForEach(skinNames, id: \.0) { skin in
                                        VStack(spacing: 6) {
                                            ZStack {
                                                NotebookCoverSkinView(skinType: skin.0, title: "Preview", colorScheme: colorScheme)
                                                    .frame(width: 48, height: 64)
                                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                                    .shadow(radius: 2)
                                                
                                                if selectedSkin == skin.0 {
                                                    RoundedRectangle(cornerRadius: 6)
                                                        .stroke(Color.orange, lineWidth: 3)
                                                        .frame(width: 48, height: 64)
                                                }
                                            }
                                            
                                            Text(skin.1)
                                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                                .foregroundColor(selectedSkin == skin.0 ? .orange : .inkTextSecondary)
                                        }
                                        .onTapGesture {
                                            HapticEngine.light()
                                            selectedSkin = skin.0
                                        }
                                    }
                                }
                                .padding(.horizontal, 4)
                                .padding(.vertical, 6)
                            }
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
                            
                            NotebookPaperBackground(style: selectedTemplate, colorScheme: colorScheme)
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
                        notebook.coverStyle = coverStyle == "skin" ? selectedSkin : "gradient"
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
                    coverStyle = "skin"
                    selectedSkin = skin
                } else {
                    coverStyle = "gradient"
                }
                if let linkedID = notebook.linkedBookID {
                    selectedLinkedBook = conversionManager.convertedPDFs.first(where: { $0.id == linkedID })
                }
            }
        }
    }
}
