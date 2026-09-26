import SwiftUI
import SwiftData

// MARK: - Study Workspace Mode

public enum StudyWorkspaceMode: String, CaseIterable, Identifiable {
    case cornellNotes = "Cornell Notes"
    case studyCards   = "Flashcards"
    
    public var id: String { rawValue }
    
    public var iconName: String {
        switch self {
        case .cornellNotes: return "doc.text.fill"
        case .studyCards:   return "play.rectangle.on.rectangle.fill"
        }
    }
}

// MARK: - Master Study Notebook & Active Learning Suite Container View

/// Master unified workspace combining Bear's typography and nested tags,
/// Goodnotes' vector paper templates, Mortimer Adler syntopical markers,
/// and SuperMemo-2 / FSRS spaced repetition active recall.
public struct StudyNotebookContainerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var store = StudyNotebookStore.shared
    
    public var showDismissButton: Bool = false
    @Query private var allAnnotations: [SDAnnotation]
    @Query private var allPDFs: [SDConvertedPDF]
    @EnvironmentObject var conversionManager: ConversionManager
    @State private var selectedBookForReader: ConvertedPDF? = nil
    
    // View Mode & Sidebar
    @State private var activeMode: StudyWorkspaceMode = .cornellNotes
    @State private var showSidebar: Bool = (UIDevice.current.userInterfaceIdiom == .pad)
    
    // Sheets & Overlays
    @State private var isReviewingDeck: Bool = false
    @State private var isComposingCard: Bool = false
    @State private var editingCard: StudyCard? = nil
    @State private var shareExportItem: ExportSharePayload? = nil
    
    private let exportEngine = StudyExportEngine.shared
    
    public init(showDismissButton: Bool = false) {
        self.showDismissButton = showDismissButton
    }
    
    public var body: some View {
        GeometryReader { geo in
            let isWideScreen = geo.size.width > 700
            
            ZStack(alignment: .top) {
                // Background Base
                Color.inkBackground
                    .ignoresSafeArea()
                
                VStack(spacing: 0) {
                    // MARK: - Glassmorphic Header Toolbar
                    headerToolbar(isWideScreen: isWideScreen)
                    
                    Divider()
                        .background(Color.primary.opacity(0.08))
                    
                    // MARK: - Split Layout: Sidebar + Canvas
                    if isWideScreen {
                        // iPad: Side-by-side split layout
                        HStack(spacing: 0) {
                            if showSidebar {
                                leftSidebarView
                                    .frame(width: min(300, geo.size.width * 0.32))
                                    .background(Color.inkSurface.opacity(0.95))
                                    .transition(.move(edge: .leading).combined(with: .opacity))
                                
                                Rectangle()
                                    .fill(Color.primary.opacity(0.1))
                                    .frame(width: 1)
                            }
                            
                            mainWorkspaceView
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    } else {
                        // iPhone: Full width canvas with slide-over drawer and backdrop
                        ZStack(alignment: .leading) {
                            mainWorkspaceView
                                .frame(maxWidth: .infinity, maxHeight: .infinity)

                            if showSidebar {
                                Color.black.opacity(0.4)
                                    .ignoresSafeArea()
                                    .onTapGesture {
                                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                            showSidebar = false
                                        }
                                    }
                                    .transition(.opacity)

                                leftSidebarView
                                    .frame(width: min(320, geo.size.width * 0.82))
                                    .background(Color.inkSurface.opacity(0.98).background(.ultraThinMaterial))
                                    .shadow(color: .black.opacity(0.35), radius: 16, x: 5, y: 0)
                                    .transition(.move(edge: .leading).combined(with: .opacity))
                                    .zIndex(10)
                            }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $isReviewingDeck) {
            StudyDeckReviewView(reviewCards: store.dueCards.isEmpty ? store.filteredCards : store.dueCards) { reviewed in
                Logger.shared.log("Study: Finished review session for \(reviewed) cards", category: "Study")
            }
        }
        .sheet(isPresented: $isComposingCard) {
            StudyCardComposerSheet { newCard in
                store.addCard(newCard)
            }
        }
        .sheet(item: $editingCard) { cardToEdit in
            StudyCardComposerSheet(existingCard: cardToEdit) { updated in
                store.updateCard(updated)
            }
        }
        .sheet(item: $shareExportItem) { payload in
            StudyShareSheet(items: [payload.text])
        }
        .fullScreenCover(item: $selectedBookForReader) { pdf in
            UnifiedReaderView(pdf: pdf)
                .environmentObject(conversionManager)
        }
        .onAppear {
            store.syncFromSwiftData(annotations: allAnnotations, pdfs: allPDFs)
        }
        .onChange(of: allAnnotations.count) { _, _ in
            store.syncFromSwiftData(annotations: allAnnotations, pdfs: allPDFs)
        }
    }
    
    // MARK: - Header Toolbar
    
    // MARK: - Header Toolbar
    
    private func headerToolbar(isWideScreen: Bool) -> some View {
        VStack(spacing: isWideScreen ? 0 : 8) {
            // Main Top Row
            HStack(spacing: 10) {
                // Sidebar Toggle
                Button {
                    HapticEngine.light()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        showSidebar.toggle()
                    }
                } label: {
                    Image(systemName: showSidebar ? "sidebar.left" : "sidebar.leading")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.inkTextPrimary)
                        .padding(8)
                        .background(Color.primary.opacity(0.06), in: Circle())
                }
                .buttonStyle(.plain)
                
                // App Title / Branding
                HStack(spacing: 6) {
                    Image(systemName: "graduationcap.fill")
                        .foregroundColor(.inkViolet)
                        .font(.system(size: 16, weight: .bold))
                    
                    Text(isWideScreen ? "Study Notebook & Active Learning" : "Study Suite")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundColor(.inkTextPrimary)
                        .lineLimit(1)
                }
                
                Spacer()
                
                if isWideScreen {
                    modeSwitcher
                    Spacer()
                    studyDeckButton
                }
                
                // Action Menu (+)
                headerActionMenu
                
                // Dismiss Button (if presented modally)
                if showDismissButton {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.inkTextSecondary)
                            .padding(8)
                            .background(Color.primary.opacity(0.06), in: Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
            
            // Sub-row for iPhone / Compact Screens
            if !isWideScreen {
                HStack(spacing: 8) {
                    modeSwitcher
                    Spacer()
                    studyDeckButton
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, isWideScreen ? 10 : 8)
        .background(Color.inkSurface.opacity(0.85).background(.ultraThinMaterial))
    }

    // MARK: - Extracted Header Toolbar Sub-Components

    private var modeSwitcher: some View {
        HStack(spacing: 2) {
            ForEach(StudyWorkspaceMode.allCases) { mode in
                Button {
                    HapticEngine.selection()
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                        activeMode = mode
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: mode.iconName)
                            .font(.system(size: 11, weight: .bold))
                        Text(mode.rawValue)
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                    }
                    .foregroundColor(activeMode == mode ? .white : .inkTextSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        activeMode == mode
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
    }

    private var studyDeckButton: some View {
        Button {
            HapticEngine.light()
            isReviewingDeck = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "play.fill")
                    .font(.system(size: 10, weight: .bold))
                Text("Study Deck")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                
                if !store.dueCards.isEmpty {
                    Text("\(store.dueCards.count)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.inkRed, in: Capsule())
                }
            }
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                LinearGradient(
                    colors: [.inkViolet, .inkBlue],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: Capsule()
            )
            .shadow(color: Color.inkViolet.opacity(0.3), radius: 4, x: 0, y: 2)
        }
        .buttonStyle(.plain)
    }

    private var headerActionMenu: some View {
        Menu {
            Button {
                isComposingCard = true
            } label: {
                Label("New Flashcard (==Cloze==)", systemImage: "plus.rectangle.on.rectangle")
            }
            
            Button {
                let newNote = StudyNote(
                    title: "New Cornell Note",
                    paperTemplate: store.activePaperTemplate
                )
                store.addNote(newNote)
                activeMode = .cornellNotes
            } label: {
                Label("New Cornell Note", systemImage: "doc.badge.plus")
            }
            
            Button {
                createNoteFromClipboard()
            } label: {
                Label("New Note from Clipboard", systemImage: "doc.on.clipboard")
            }
            
            Section("Export Knowledge Base") {
                Button {
                    if let currentNote = store.activeNote {
                        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                           let rootVC = windowScene.windows.first?.rootViewController {
                            let md = (currentNote.cueColumnText.isEmpty ? "" : "### Cues\n" + currentNote.cueColumnText + "\n\n")
                                + currentNote.mainNotesMarkdown
                                + (currentNote.summaryText.isEmpty ? "" : "\n\n### Summary\n" + currentNote.summaryText)
                            NotebookDocumentExporter.shared.presentKindleExport(
                                title: currentNote.title,
                                content: md,
                                from: rootVC
                            )
                        }
                    }
                } label: {
                    Label("Send Note to E-Reader (PDF)", systemImage: "paperplane")
                }

                Button {
                    let md = exportEngine.exportToMarkdown(cards: store.cards, notes: store.notes)
                    shareExportItem = ExportSharePayload(text: md, title: "Markdown Notes")
                } label: {
                    Label("Export Bear / Markdown (.md)", systemImage: "arrow.down.doc")
                }
                
                Button {
                    let tsv = exportEngine.exportToAnkiTSV(cards: store.cards)
                    shareExportItem = ExportSharePayload(text: tsv, title: "Anki TSV Deck")
                } label: {
                    Label("Export Anki Deck (.tsv)", systemImage: "square.and.arrow.up")
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(.inkTextPrimary)
                .padding(8)
                .background(Color.primary.opacity(0.06), in: Circle())
        }
    }
    
    private func createNoteFromClipboard() {
        guard let text = UIPasteboard.general.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            HapticEngine.error()
            return
        }
        HapticEngine.success()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = trimmed.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cleanTitle = firstLine.isEmpty ? "Clipboard Note" : String(firstLine.prefix(40))
        
        var newNote = StudyNote(
            title: cleanTitle,
            paperTemplate: store.activePaperTemplate
        )
        newNote.mainNotesMarkdown = trimmed
        store.addNote(newNote)
        activeMode = .cornellNotes
    }
    
    // MARK: - Left Sidebar View
    
    private var leftSidebarView: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Search Bar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.inkTextTertiary)
                
                TextField("Search or filter tag...", text: $store.searchQuery)
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                
                if !store.searchQuery.isEmpty {
                    Button {
                        store.searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.inkTextTertiary)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.horizontal, 12)
            .padding(.top, 12)
            
            // Mortimer Adler Marker Filter Pill Bar
            VStack(alignment: .leading, spacing: 4) {
                Text("ADLER READING MARKERS")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundColor(.inkTextTertiary)
                    .padding(.horizontal, 14)
                
                AdlerMarkerPillBar(
                    selectedMarker: $store.selectedAdler,
                    markerCounts: store.adlerMarkerCounts
                )
                .padding(.horizontal, 8)
            }
            
            Divider()
                .background(Color.primary.opacity(0.08))
                .padding(.horizontal, 12)
            
            // Bear-Style Nested Tags Tree
            NestedTagSidebarView(
                nodes: store.nestedTagTree,
                selectedTag: $store.selectedTag,
                totalCardsCount: store.cards.count
            )
            .padding(.horizontal, 12)
            
            Spacer()
            
            // Quick Study Stats Widget
            statsWidget
                .padding(12)
        }
    }
    
    // MARK: - Study Stats Widget
    
    private var statsWidget: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("DUE TODAY")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(.inkTextTertiary)
                Text("\(store.dueCards.count)")
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundColor(store.dueCards.isEmpty ? .inkGreen : .inkRed)
            }
            
            Spacer()
            
            VStack(alignment: .trailing, spacing: 2) {
                Text("TOTAL CARDS")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(.inkTextTertiary)
                Text("\(store.cards.count)")
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundColor(.inkTextPrimary)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
    
    // MARK: - Main Content Workspace
    
    @ViewBuilder
    private var mainWorkspaceView: some View {
        switch activeMode {
        case .cornellNotes:
            if let activeNote = store.activeNote {
                CornellNoteEditorView(
                    note: Binding(
                        get: { activeNote },
                        set: { store.updateNote($0) }
                    ),
                    onConvertToFlashcard: { text in
                        let card = store.createCardFromCitation(
                            citation: PassageCitation(
                                documentID: activeNote.documentID ?? UUID(),
                                documentTitle: activeNote.documentTitle,
                                pageNumber: 1,
                                highlightedText: text
                            ),
                            markdownBody: text,
                            adlerTag: activeNote.adlerMarker,
                            tags: activeNote.tags
                        )
                        editingCard = card
                    }
                )
            } else {
                emptyNotesPlaceholder
            }
            
        case .studyCards:
            cardsGridView
        }
    }
    
    // MARK: - Cards Grid View
    
    private var cardsGridView: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 12) {
                // Filter Header Info
                if store.selectedTag != nil || store.selectedAdler != nil || !store.searchQuery.isEmpty {
                    HStack {
                        Text("Showing \(store.filteredCards.count) filtered card\(store.filteredCards.count == 1 ? "" : "s")")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundColor(.inkTextTertiary)
                        
                        Spacer()
                        
                        Button("Clear Filters") {
                            store.selectedTag = nil
                            store.selectedAdler = nil
                            store.searchQuery = ""
                        }
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundColor(.inkViolet)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                }
                
                if store.filteredCards.isEmpty {
                    emptyCardsPlaceholder
                } else {
                    ForEach(store.filteredCards) { card in
                        StudyCardRowView(
                            card: card,
                            onSelect: {
                                isReviewingDeck = true
                            },
                            onEdit: {
                                editingCard = card
                            },
                            onDelete: {
                                store.deleteCard(withID: card.id)
                            }
                        )
                        .padding(.horizontal, 16)
                    }
                }
            }
            .padding(.vertical, 14)
        }
    }
    
    // MARK: - Empty Placeholders
    
    private var emptyNotesPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text.fill")
                .font(.system(size: 44))
                .foregroundColor(.inkViolet.opacity(0.6))
            
            Text("No Study Notes Yet")
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundColor(.inkTextPrimary)
            
            Button {
                let note = StudyNote(
                    title: "First Cornell Note",
                    paperTemplate: .cornellClassic
                )
                store.addNote(note)
            } label: {
                Text("Create Cornell Note")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.inkViolet, in: Capsule())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var emptyCardsPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.on.rectangle.slash")
                .font(.system(size: 40))
                .foregroundColor(.inkTextTertiary)
            
            Text("No Cards Match Active Filters")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundColor(.inkTextSecondary)
        }
        .padding(.top, 60)
    }
}

// MARK: - Export Share Payload Helper

struct ExportSharePayload: Identifiable {
    let id = UUID()
    let text: String
    let title: String
}

struct StudyShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
