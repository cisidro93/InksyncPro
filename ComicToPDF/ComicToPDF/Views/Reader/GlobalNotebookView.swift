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
    @Query(sort: \SDAnnotation.createdAt, order: .reverse) private var allAnnotations: [SDAnnotation]
    
    @Binding var selectedPDF: ConvertedPDF?
    
    // Filter State
    @State private var searchQuery = ""
    @State private var selectedColorHex: String? = nil
    @State private var selectedBookID: UUID? = nil
    @State private var typeFilter: AnnotationTypeFilter = .all
    @State private var activeShareText: String? = nil
    
    // Color Palette matching the highlight quick colors
    private let highlightColors = [
        ("#ffd700", "Yellow"),
        ("#30d158", "Green"),
        ("#ff375f", "Pink"),
        ("#0a84ff", "Blue"),
        ("#bf5af2", "Purple"),
        ("#ff9f0a", "Orange")
    ]
    
    // Filtered annotations derived property
    private var filteredAnnotations: [SDAnnotation] {
        allAnnotations.filter { ann in
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
    
    // Books that have annotations
    private var booksWithAnnotations: [ConvertedPDF] {
        let annotatedBookIDs = Set(allAnnotations.filter { $0.kindRaw == "highlight" || $0.kindRaw == "note" }.map { $0.pdfID })
        return conversionManager.convertedPDFs.filter { annotatedBookIDs.contains($0.id) }
    }
    
    var body: some View {
        ZStack {
            // Premium background
            Color.inkBackground.ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Glassmorphic Header
                headerView
                
                // Content Switcher
                if allAnnotations.filter({ $0.kindRaw == "highlight" || $0.kindRaw == "note" }).isEmpty {
                    emptyLibraryState
                } else {
                    VStack(spacing: 0) {
                        // Search and Filters Panel
                        filterPanel
                        
                        if filteredAnnotations.isEmpty {
                            emptySearchResultState
                        } else {
                            // Scrollable list of highlights
                            ScrollView {
                                LazyVStack(spacing: 16, pinnedViews: [.sectionHeaders]) {
                                    let grouped = Dictionary(grouping: filteredAnnotations, by: { $0.pdfID })
                                    let sortedKeys = grouped.keys.sorted { key1, key2 in
                                        let b1 = conversionManager.convertedPDFs.first(where: { $0.id == key1 })?.name ?? ""
                                        let b2 = conversionManager.convertedPDFs.first(where: { $0.id == key2 })?.name ?? ""
                                        return b1 < b2
                                    }
                                    
                                    ForEach(sortedKeys, id: \.self) { pdfID in
                                        if let book = conversionManager.convertedPDFs.first(where: { $0.id == pdfID }),
                                           let annotations = grouped[pdfID] {
                                            Section(header: sectionHeader(for: book, count: annotations.count)) {
                                                ForEach(annotations) { annotation in
                                                    highlightCard(for: annotation, book: book)
                                                        .padding(.horizontal, 16)
                                                }
                                            }
                                        }
                                    }
                                }
                                .padding(.top, 12)
                                .padding(.bottom, 120) // spacing for tab bar
                            }
                        }
                    }
                }
            }
        }
        .navigationBarHidden(true)
        .sheet(item: $activeShareText) { text in
            ShareSheet(activityItems: [text])
        }
    }
    
    // MARK: - Header
    private var headerView: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Highlights Hub")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.orange, Color.purple],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Text("Your consolidated reading insights & notes")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.inkTextSecondary)
            }
            
            Spacer()
            
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
    private func sectionHeader(for book: ConvertedPDF, count: Int) -> some View {
        HStack(spacing: 12) {
            // Mini Cover Thumbnail
            if let coverData = book.coverImageData, let uiImage = UIImage(data: coverData) {
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
                Text(book.name)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundColor(.inkTextPrimary)
                    .lineLimit(1)
                
                if let author = book.metadata.writer ?? book.metadata.author, !author.isEmpty {
                    Text(author)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(.inkTextTertiary)
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
    private func highlightCard(for annotation: SDAnnotation, book: ConvertedPDF) -> some View {
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
                            .foregroundColor(.inkTextTertiary)
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
                    Text(annotation.chapterTitle ?? "Page \(annotation.pageIndex + 1)")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                }
                .foregroundColor(.inkTextTertiary)
                
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
                            .foregroundColor(.inkTextTertiary)
                    }
                    .buttonStyle(.plain)
                    
                    // Share
                    Button {
                        var share = ""
                        if let t = annotation.selectedText { share += "\"\(t)\"\n" }
                        if let n = annotation.noteText { share += "Note: \(n)\n" }
                        share += "— From \(book.name)"
                        activeShareText = share
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.inkTextTertiary)
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
            openAnnotationInReader(annotation, book: book)
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
                .foregroundColor(.inkTextTertiary)
            
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
        let annDTOs = allAnns.map { ann -> Annotation in
            let kind = AnnotationKind(rawValue: ann.kindRaw) ?? .highlight
            var bounds: CGRect? = nil
            if let x = ann.boundsX, let y = ann.boundsY, let w = ann.boundsW, let h = ann.boundsH {
                bounds = CGRect(x: x, y: y, width: w, height: h)
            }
            
            var dto = Annotation(
                id: ann.id,
                pdfID: ann.pdfID,
                pageIndex: ann.pageIndex,
                chapterTitle: ann.chapterTitle,
                kind: kind,
                createdAt: ann.createdAt,
                modifiedAt: ann.modifiedAt,
                colorHex: ann.colorHex,
                selectedText: ann.selectedText,
                noteText: ann.noteText,
                tags: ann.tags,
                bounds: bounds
            )
            dto.readwiseBookTitle = ann.readwiseBookTitle
            dto.reviewCount = ann.reviewCount
            dto.easeFactor = ann.easeFactor
            return dto
        }
        
        let pdfDTOs = allPDFs
        
        Task {
            do {
                let zipURL = try await ZettelkastenExporter.shared.exportToMarkdownZip(annotations: annDTOs, pdfs: pdfDTOs)
                
                await MainActor.run {
                    activeShareText = zipURL.path // Share the Zipped Zettelkasten Archive
                }
            } catch {
                Logger.shared.log("Highlights Hub: Zettelkasten zip export FAILED: \(error.localizedDescription)", category: "Notebook", type: .error)
            }
        }
    }
}

// ShareSheet Helper
struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    var applicationActivities: [UIActivity]? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: activityItems, applicationActivities: applicationActivities)
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
