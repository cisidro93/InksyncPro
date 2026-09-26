import SwiftUI

// MARK: - UIGuideContext
/// Contextual domains for visual feature guides across InksyncPro.
public enum UIGuideContext: String, CaseIterable, Identifiable, Sendable {
    case studyNotebook = "Study Notebook"
    case studySuiteHub = "Study Suite"
    case readerControls = "Reader HUD"
    case neoFlowStudio = "NeoFlow Studio"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .studyNotebook: return "Study Notebook & Cornell"
        case .studySuiteHub: return "Study Suite & Active Learning"
        case .readerControls: return "Reader Controls & HUD"
        case .neoFlowStudio: return "NeoFlow Studio & Smart Tiers"
        }
    }

    public var subtitle: String {
        switch self {
        case .studyNotebook:
            return "Cornell 3-zone notes, handwriting canvas, speech dictation, Mortimer Adler reading markers, and export."
        case .studySuiteHub:
            return "Centralized active learning hub, Leitner flashcard SRS decks, concept graph, and audio transcripts."
        case .readerControls:
            return "Reader navigation HUD, color filter presets, margin cropping, smart tiers, dual-page spreads, and inking."
        case .neoFlowStudio:
            return "M×N matrix grids, traversal sequence vectors, magnetic gutter snapping, and tap-to-preview reader simulator."
        }
    }

    public var iconName: String {
        switch self {
        case .studyNotebook: return "notebook.toptab.fill"
        case .studySuiteHub: return "graduationcap.fill"
        case .readerControls: return "textformat.size"
        case .neoFlowStudio: return "rectangle.split.3x3"
        }
    }

    public var themeColor: Color {
        switch self {
        case .studyNotebook: return .purple
        case .studySuiteHub: return .inkViolet
        case .readerControls: return .orange
        case .neoFlowStudio: return .inkGreen
        }
    }
}

// MARK: - UIIconExplanation Model
/// A single documented tool or icon explanation for the contextual guide.
public struct UIIconExplanation: Identifiable, Sendable {
    public let id = UUID()
    public let iconName: String
    public let iconColor: Color
    public let title: String
    public let category: String
    public let explanation: String
    public let proTip: String?

    public init(
        iconName: String,
        iconColor: Color = .primary,
        title: String,
        category: String,
        explanation: String,
        proTip: String? = nil
    ) {
        self.iconName = iconName
        self.iconColor = iconColor
        self.title = title
        self.category = category
        self.explanation = explanation
        self.proTip = proTip
    }
}

// MARK: - UIExplanationRegistry
/// Canonical registry of icon and feature explanations for all InksyncPro surfaces.
public struct UIExplanationRegistry {

    public static func items(for context: UIGuideContext) -> [UIIconExplanation] {
        switch context {
        case .studyNotebook:
            return studyNotebookItems
        case .studySuiteHub:
            return studySuiteHubItems
        case .readerControls:
            return readerControlsItems
        case .neoFlowStudio:
            return neoFlowStudioItems
        }
    }

    public static func categories(for context: UIGuideContext) -> [String] {
        let allItems = items(for: context)
        var seen = Set<String>()
        var result: [String] = ["All"]
        for item in allItems {
            if !seen.contains(item.category) {
                seen.insert(item.category)
                result.append(item.category)
            }
        }
        return result
    }

    // MARK: - 1. Study Notebook Items
    private static let studyNotebookItems: [UIIconExplanation] = [
        // Mode & Input
        UIIconExplanation(
            iconName: "square.and.pencil",
            iconColor: .blue,
            title: "Text Mode (Markdown)",
            category: "Input & Mode",
            explanation: "Switch to keyboard-friendly Markdown text editing. Supports headings, bold, italic, bullet lists, checkable tasks, and Wiki-style links.",
            proTip: "Type '[[Concept]]' anywhere to create an instant bidirectional link to other notes."
        ),
        UIIconExplanation(
            iconName: "applepencil",
            iconColor: .orange,
            title: "Pencil Mode (Handwriting)",
            category: "Input & Mode",
            explanation: "Activates the Apple Pencil canvas with pressure sensitivity, tilt shading, and palm rejection for natural handwriting.",
            proTip: "Double-tap Apple Pencil 2/Pro to switch between your active pen and eraser."
        ),
        UIIconExplanation(
            iconName: "mic.fill",
            iconColor: .red,
            title: "Speech-to-Text Dictation",
            category: "Audio & Speech",
            explanation: "Real-time speech recognition transcribes your spoken voice directly into the note editor with live visual waveform feedback.",
            proTip: "Press ⌘D on a connected hardware keyboard to instantly start or pause dictation."
        ),
        UIIconExplanation(
            iconName: "speaker.wave.2.fill",
            iconColor: .purple,
            title: "Read Aloud (Narration)",
            category: "Audio & Speech",
            explanation: "AVFoundation text-to-speech engine reads your notes aloud with synthesized voice for auditory proofreading and active study.",
            proTip: "Tap again anytime to stop speech narration."
        ),
        UIIconExplanation(
            iconName: "doc.plaintext",
            iconColor: .primary,
            title: "Paper Styles & Spacing",
            category: "Canvas & Paper",
            explanation: "Customizes the notebook background with Plain, Ruled lined, Square grid, or Dot-grid patterns.",
            proTip: "Change line spacing between Narrow (18pt), Normal (24pt), and Wide (32pt) to match your handwriting style."
        ),
        UIIconExplanation(
            iconName: "sparkles",
            iconColor: .purple,
            title: "AI Smart Summary",
            category: "AI & Learning",
            explanation: "Analyzes your current notes and generates concise executive summaries, key concept bullets, and study questions.",
            proTip: "Requires text in your notes or transcribed handwriting before generating."
        ),
        UIIconExplanation(
            iconName: "checkmark.bubble.fill",
            iconColor: .blue,
            title: "Writing Assistant",
            category: "AI & Learning",
            explanation: "Proofreads grammar, improves clarity, and expands rough lecture outlines into complete study paragraphs.",
            proTip: "Tap suggestions to apply one-click revisions directly to your notes."
        ),
        UIIconExplanation(
            iconName: "play.rectangle.on.rectangle.fill",
            iconColor: .indigo,
            title: "Flashcard Study Deck",
            category: "AI & Learning",
            explanation: "Launches an interactive Spaced Repetition (SRS) flashcard study session derived from highlights and notebook key points.",
            proTip: "Rate your recall difficulty to optimize Leitner algorithm review intervals."
        ),
        UIIconExplanation(
            iconName: "doc.on.clipboard",
            iconColor: .orange,
            title: "Paste from Clipboard",
            category: "Tools & Import",
            explanation: "Instantly pastes copied research text, web articles, or book quotes directly into the notebook.",
            proTip: "Useful when collecting excerpts from web browsers or external reading apps."
        ),
        UIIconExplanation(
            iconName: "square.and.arrow.up",
            iconColor: .primary,
            title: "Export Hub",
            category: "Tools & Import",
            explanation: "Export your notes to PDF, EPUB, Markdown, Plain Text, or an Obsidian-compatible Zettelkasten ZIP archive.",
            proTip: "You can also send notes directly to your Kindle or save as a native book in your library."
        ),
        UIIconExplanation(
            iconName: "highlighter",
            iconColor: .blue,
            title: "Highlights Drawer",
            category: "Highlights & References",
            explanation: "Slides out a searchable drawer of all highlights, color-coded quotes, and bookmarks from the open book.",
            proTip: "Tap any highlight quote in the drawer to jump the active reader directly to that page."
        ),
        UIIconExplanation(
            iconName: "book.badge.plus",
            iconColor: .primary,
            title: "Link Backing Book",
            category: "Highlights & References",
            explanation: "Pairs this notebook directly with an e-book in your library so highlights and page bookmarks sync automatically.",
            proTip: "Once linked, a book icon appears in the toolbar for quick one-tap jumping to the text."
        ),
        UIIconExplanation(
            iconName: "sidebar.left",
            iconColor: .primary,
            title: "Flip Notebook Side",
            category: "Layout & Navigation",
            explanation: "Switches the notebook panel between the right-hand edge and left-hand edge of your screen.",
            proTip: "Left-handed Apple Pencil users can place the notebook on the left to avoid palm-over-book friction."
        ),
        UIIconExplanation(
            iconName: "plus.circle.fill",
            iconColor: .orange,
            title: "Add Notebook Page",
            category: "Layout & Navigation",
            explanation: "Creates a new blank page in the notebook. Use the page picker pill to flip between numbered sheets.",
            proTip: "Multi-page notebooks allow you to organize notes by chapter or lecture topic."
        ),
        UIIconExplanation(
            iconName: "rectangle.split.2x1.fill",
            iconColor: .teal,
            title: "Cornell Notes System",
            category: "Study Systems",
            explanation: "Classical 3-zone note layout: Cues/Keywords on the left (25%), Main Notes on the right (75%), and Summary at the bottom.",
            proTip: "Use 'Cover for Recitation' to hide notes and test your recall against cue questions!"
        ),
        UIIconExplanation(
            iconName: "point.3.connected.trianglepath.dotted",
            iconColor: .purple,
            title: "Zettelkasten System",
            category: "Study Systems",
            explanation: "Atomic note system connecting ideas via bidirectional [[links]], auto-tagging, and visual concept graphs.",
            proTip: "Use the Auto-Linker button to automatically scan your library for recurring themes."
        ),
        UIIconExplanation(
            iconName: "folder.fill.badge.gearshape",
            iconColor: .blue,
            title: "P.A.R.A. System",
            category: "Study Systems",
            explanation: "Productivity framework categorizing notes into Projects (active goals), Areas (responsibilities), Resources (references), and Archives.",
            proTip: "Archive completed study notes to keep active projects focused."
        ),
        UIIconExplanation(
            iconName: "pencil.and.scribble",
            iconColor: .orange,
            title: "Marginalia (Mortimer Adler)",
            category: "Study Systems",
            explanation: "Deep analytical reading markers: ⭐ Essential, ? Question, ! Insight, ⚖️ Critique, ⚡ Conflict, ∞ Epiphany, 🔗 Cross-Ref.",
            proTip: "Tap any Adler marker pill to stamp it into your notes with one touch."
        ),
        UIIconExplanation(
            iconName: "pencil.tip",
            iconColor: .primary,
            title: "Inking Pen",
            category: "Pencil Drawing",
            explanation: "High-precision vector pen with zero latency, smooth Bézier strokes, and customizable ink color and thickness.",
            proTip: "Works on both iPad with Apple Pencil and iPhone with finger touch."
        ),
        UIIconExplanation(
            iconName: "highlighter",
            iconColor: .yellow,
            title: "Canvas Highlighter",
            category: "Pencil Drawing",
            explanation: "Translucent chisel-tip highlighter that layers behind black text without obscuring ink or book typography.",
            proTip: "Use for freeform visual emphasis across both text and handwritten diagrams."
        ),
        UIIconExplanation(
            iconName: "eraser.line.dashed",
            iconColor: .primary,
            title: "Canvas Eraser",
            category: "Pencil Drawing",
            explanation: "Precision eraser. Tap to toggle between Vector Stroke Eraser (erases whole stroke) and Object Eraser.",
            proTip: "Draw with confidence: stroke eraser allows clean, instant cleanup with one swipe."
        ),
        UIIconExplanation(
            iconName: "lasso",
            iconColor: .primary,
            title: "Lasso Selection Tool",
            category: "Pencil Drawing",
            explanation: "Circle any group of handwritten strokes or drawings to move, resize, duplicate, or copy them across the canvas.",
            proTip: "Drag selected elements freely to reorganize your notes."
        ),
        UIIconExplanation(
            iconName: "ruler",
            iconColor: .primary,
            title: "Precision Ruler",
            category: "Pencil Drawing",
            explanation: "On-screen interactive metric ruler for drawing straight lines and measuring margins.",
            proTip: "Use two fingers to rotate the ruler to any angle."
        )
    ]

    // MARK: - 2. Study Suite Hub Items
    private static let studySuiteHubItems: [UIIconExplanation] = [
        UIIconExplanation(
            iconName: "sidebar.left",
            iconColor: .primary,
            title: "Sidebar Navigation Drawer",
            category: "Navigation",
            explanation: "Toggles the slide-over sidebar listing all study notebooks, books, subjects, and recent notes.",
            proTip: "Hide the sidebar on smaller screens to maximize canvas study space."
        ),
        UIIconExplanation(
            iconName: "book.pages",
            iconColor: .purple,
            title: "All Notebooks & Cornell Sheets",
            category: "Workspace Modes",
            explanation: "Browse, search, and manage all your book-linked study notebooks and standalone Cornell sheets in one place.",
            proTip: "Swipe any notebook card to rename, export, or delete."
        ),
        UIIconExplanation(
            iconName: "rectangle.stack.fill",
            iconColor: .blue,
            title: "Flashcard Decks (SRS)",
            category: "Workspace Modes",
            explanation: "Review flashcards generated from your book highlights and notes using the Leitner Spaced Repetition System.",
            proTip: "Cards due today are automatically prioritized for your daily study streak."
        ),
        UIIconExplanation(
            iconName: "pencil.and.scribble",
            iconColor: .orange,
            title: "Adler Reading Markers Index",
            category: "Workspace Modes",
            explanation: "Searchable catalog of all Mortimer Adler reading annotations (Essential, Question, Critique, Insight) across your library.",
            proTip: "Filter by marker type to find all questions you wanted to research further."
        ),
        UIIconExplanation(
            iconName: "point.3.connected.trianglepath.dotted",
            iconColor: .purple,
            title: "Zettelkasten Knowledge Graph",
            category: "Workspace Modes",
            explanation: "Interactive 2D graph visualizing connections, author clusters, and shared concepts between your notes.",
            proTip: "Tap any node in the graph to preview its connected atomic notes."
        ),
        UIIconExplanation(
            iconName: "waveform",
            iconColor: .teal,
            title: "Audio Transcripts & Voice Notes",
            category: "Workspace Modes",
            explanation: "Access recorded lectures, dictation transcripts, and voice memos paired with page stamps.",
            proTip: "Tap any transcript timestamp to jump to that moment in the audio recording."
        ),
        UIIconExplanation(
            iconName: "tag.fill",
            iconColor: .pink,
            title: "Tags & Concept Taxonomy",
            category: "Workspace Modes",
            explanation: "Explore notes organized by hashtag taxonomy and book genres.",
            proTip: "Tagging notes with '#exam' or '#thesis' makes assembling final papers seamless."
        ),
        UIIconExplanation(
            iconName: "play.rectangle.on.rectangle.fill",
            iconColor: .indigo,
            title: "Start Active Study Session",
            category: "Actions",
            explanation: "Launches a timed study sprint combining flashcard active recall with Cornell note recitation.",
            proTip: "Review sessions are recorded in your reader progress tracker."
        ),
        UIIconExplanation(
            iconName: "plus.circle.fill",
            iconColor: .orange,
            title: "Quick Create Item",
            category: "Actions",
            explanation: "Opens a creation menu to draft a new Cornell note, flashcard, or standalone study sheet.",
            proTip: "You can create notes independent of books for lecture or meeting notes."
        )
    ]

    // MARK: - 3. Reader Controls & HUD Items
    private static let readerControlsItems: [UIIconExplanation] = [
        UIIconExplanation(
            iconName: "textformat.size",
            iconColor: .orange,
            title: "Reader Settings (aA)",
            category: "HUD & Display",
            explanation: "Opens typography, reading modes, color filters, margin trimming, and scaling adjustments.",
            proTip: "All reading settings persist automatically per book."
        ),
        UIIconExplanation(
            iconName: "rectangle.portrait.and.arrow.right",
            iconColor: .blue,
            title: "Reading Modes (Paged / Scroll / Panels)",
            category: "HUD & Display",
            explanation: "Toggle between Horizontal Paged (standard book/manga), Continuous Vertical Scroll (webtoons/PDFs), and Smart Tiers Panel Flow.",
            proTip: "In Continuous Scroll, pinch-to-zoom is locked to horizontal width for zero-drift reading."
        ),
        UIIconExplanation(
            iconName: "slider.horizontal.3",
            iconColor: .purple,
            title: "Color Filters & Sepia",
            category: "Visual Filters",
            explanation: "Switch between Original, Inverted (OLED true dark), Paper Sepia, High Contrast Black/White, and Pure Grayscale for e-ink feel.",
            proTip: "Inverted mode saves battery life on OLED iPhones and iPads while reading at night."
        ),
        UIIconExplanation(
            iconName: "arrow.up.left.and.down.right",
            iconColor: .teal,
            title: "Screen Fit Modes",
            category: "Scaling & Cropping",
            explanation: "Fit Width (fills width for easy reading), Fill Screen (full-bleed display), Smart Fit (proportional fit), or Fit Page (entire page visible).",
            proTip: "Use 'Fill Screen' on iPad to display both pages of dual-page spreads cleanly!"
        ),
        UIIconExplanation(
            iconName: "book.closed",
            iconColor: .indigo,
            title: "Two-Up Dual-Page Spread",
            category: "Layout & Spreads",
            explanation: "Presents two pages side-by-side like an open physical book. Automatically pairs even and odd pages.",
            proTip: "Supports Manga Right-to-Left (RTL) reading order for Japanese comics."
        ),
        UIIconExplanation(
            iconName: "sparkles",
            iconColor: .orange,
            title: "Smart Auto-Crop",
            category: "Scaling & Cropping",
            explanation: "Automatically scans scanned comic and PDF pages to detect and crop away wasteful white margins.",
            proTip: "Adjust Auto-Crop sensitivity slider in Reader Settings to fine-tune how aggressively margins are trimmed."
        ),
        UIIconExplanation(
            iconName: "viewfinder",
            iconColor: .orange,
            title: "Visual Crop Editor",
            category: "Scaling & Cropping",
            explanation: "Interactive live trimmer with drag handles to set precision top, bottom, left, and right page borders.",
            proTip: "Crop borders apply across all pages in the book consistently."
        ),
        UIIconExplanation(
            iconName: "rectangle.split.3x1",
            iconColor: .inkGreen,
            title: "Smart Tiers Guided Flow",
            category: "Panel Navigation",
            explanation: "Divides comic pages and multi-column documents into guided panels, auto-zooming and advancing section-by-section on tap.",
            proTip: "Tap 'Adjust Smart Tiers & Flow' to enter NeoFlow Studio for custom matrix grid layouts."
        ),
        UIIconExplanation(
            iconName: "sparkle.magnifyingglass",
            iconColor: .pink,
            title: "AI Dialogue Lens",
            category: "Panel Navigation",
            explanation: "OCR-assisted floating magnifier that detects speech bubbles and comic text, enlarging dialogue for effortless reading.",
            proTip: "Tap any speech bubble on the page to magnify text without zooming the entire screen."
        ),
        UIIconExplanation(
            iconName: "pencil.tip.crop.circle",
            iconColor: .primary,
            title: "Inking & Pencil Markup",
            category: "Annotations",
            explanation: "Write, draw, and annotate directly on PDF and book pages with Apple Pencil or finger touch.",
            proTip: "PDF markup uses native iOS 16+ PDFKit page overlays for zero UI jank."
        ),
        UIIconExplanation(
            iconName: "bookmark",
            iconColor: .orange,
            title: "Page Bookmark",
            category: "Navigation",
            explanation: "Bookmarks the active page. Tapping again removes the bookmark.",
            proTip: "All bookmarked pages are listed in the Table of Contents drawer."
        ),
        UIIconExplanation(
            iconName: "flag.fill",
            iconColor: .red,
            title: "Flow Flags Strip",
            category: "Navigation",
            explanation: "Interactive flag strip displayed above the scrubber showing key marked pages, chapter boundaries, or dual-page spreads.",
            proTip: "Tap any flag marker to jump instantly to that milestone."
        ),
        UIIconExplanation(
            iconName: "list.bullet.rectangle",
            iconColor: .primary,
            title: "Table of Contents & Outlines",
            category: "Navigation",
            explanation: "Browse chapters, sub-headings, and page milestones with one tap.",
            proTip: "Search by keyword within the table of contents to locate specific sections."
        ),
        UIIconExplanation(
            iconName: "speaker.wave.3",
            iconColor: .blue,
            title: "Read Aloud (TTS Speech)",
            category: "Audio & Speech",
            explanation: "Reads book page text aloud via synthesized system speech, highlighting words as they are spoken.",
            proTip: "Controls for playback speed and voice selection are available in speech settings."
        )
    ]

    // MARK: - 4. NeoFlow Studio Items
    private static let neoFlowStudioItems: [UIIconExplanation] = [
        UIIconExplanation(
            iconName: "rectangle.split.3x3",
            iconColor: Color(hex: "#00C853") ?? .green,
            title: "M×N Matrix Grid Presets",
            category: "Grid Layout",
            explanation: "Quick presets: 1×1 (Full Page), 2×1 (2 Rows), 1×2 (2 Columns), 2×2 (4 Quadrants), 3×2 (6 Panels), 2×3, and 3×3 (9 Panels).",
            proTip: "Select the grid matching your comic strip or document column structure."
        ),
        UIIconExplanation(
            iconName: "doc.text",
            iconColor: .blue,
            title: "Single Page vs Spread Mode",
            category: "Grid Layout",
            explanation: "Toggle whether panel sections are computed for a single portrait page or split across a two-page wide spread.",
            proTip: "Spread mode allows navigating two-page comic splash spreads seamlessly."
        ),
        UIIconExplanation(
            iconName: "arrow.right.to.line.compact",
            iconColor: .orange,
            title: "Traversal Order & Direction",
            category: "Flow Sequence",
            explanation: "Z-Path (Western left-to-right top-to-bottom), Inverted-N (Japanese Manga right-to-left), Snake Boustrophedon, Column-first, or Row-first.",
            proTip: "Select Inverted-N Manga for authentic Japanese manga reading flow."
        ),
        UIIconExplanation(
            iconName: "line.horizontal.3",
            iconColor: .teal,
            title: "Magnetic Gutter Snapping",
            category: "Interactive Editing",
            explanation: "Drag partition split lines on the canvas. Lines automatically detect and magnetically snap to white gutters between panels.",
            proTip: "Magnetic snapping ensures panel crops never slice through dialogue bubbles."
        ),
        UIIconExplanation(
            iconName: "plus.slash.minus",
            iconColor: .indigo,
            title: "Quadrant Zoom & Padding Overrides",
            category: "Interactive Editing",
            explanation: "Tap any section block in the matrix to set custom zoom levels, crop inset padding, or pan offsets.",
            proTip: "Use custom zoom on small or dialogue-heavy panels to make them crystal clear on mobile."
        ),
        UIIconExplanation(
            iconName: "play.circle.fill",
            iconColor: .inkGreen,
            title: "Tap-to-Preview Simulator",
            category: "Testing & Simulator",
            explanation: "Full-screen interactive reader simulator allowing you to test your traversal sequence with tap gestures before saving.",
            proTip: "Tap right/left edges in the simulator to verify smooth panel progression."
        ),
        UIIconExplanation(
            iconName: "arrow.counterclockwise",
            iconColor: .secondary,
            title: "Reset Grid to Default",
            category: "Actions",
            explanation: "Restores standard 2×2 quadrant layout and clears all custom block overrides.",
            proTip: "Use this if panel boundaries become misaligned after extensive editing."
        )
    ]
}

// MARK: - HelpPillButton
/// A sleek, frosted-glass '?' pill button that calls up the contextual icon & feature guide.
public struct HelpPillButton: View {
    let context: UIGuideContext
    var isCompact: Bool = true
    var title: String? = nil
    var customTint: Color? = nil

    @State private var showGuideSheet = false

    public init(
        context: UIGuideContext,
        isCompact: Bool = true,
        title: String? = nil,
        customTint: Color? = nil
    ) {
        self.context = context
        self.isCompact = isCompact
        self.title = title
        self.customTint = customTint
    }

    public var body: some View {
        Button {
            HapticEngine.selection()
            showGuideSheet = true
        } label: {
            if isCompact && title == nil {
                // Sleek circular glass '?' pill
                ZStack {
                    Circle()
                        .fill(Color.primary.opacity(0.06))
                        .background(.ultraThinMaterial, in: Circle())
                    
                    Circle()
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.8)

                    Image(systemName: "questionmark")
                        .font(.system(size: 11, weight: .black, design: .rounded))
                        .foregroundColor(customTint ?? Color.primary.opacity(0.85))
                }
                .frame(width: 28, height: 28)
                .contentShape(Circle())
            } else {
                // Wide capsule ' ? Guide ' pill
                HStack(spacing: 4) {
                    Image(systemName: "questionmark.circle.fill")
                        .font(.system(size: 11, weight: .bold))
                    Text(title ?? "Guide")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                }
                .foregroundColor(customTint ?? Color.primary.opacity(0.85))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(Color.primary.opacity(0.06))
                        .background(.ultraThinMaterial, in: Capsule())
                )
                .overlay(
                    Capsule()
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.8)
                )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(context.title) feature guide")
        .accessibilityHint("Opens an interactive visual guide explaining all icons and features in this section")
        .sheet(isPresented: $showGuideSheet) {
            UIFeatureGuideSheet(initialContext: context)
        }
    }
}

// MARK: - UIFeatureGuideSheet
/// Interactive visual guide sheet displaying all icons, tools, gestures, and explanations.
public struct UIFeatureGuideSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var activeContext: UIGuideContext
    @State private var selectedCategory: String = "All"
    @State private var searchQuery: String = ""

    public init(initialContext: UIGuideContext) {
        self._activeContext = State(initialValue: initialContext)
    }

    private var availableCategories: [String] {
        UIExplanationRegistry.categories(for: activeContext)
    }

    private var filteredItems: [UIIconExplanation] {
        let items = UIExplanationRegistry.items(for: activeContext)
        return items.filter { item in
            let matchesCategory = (selectedCategory == "All") || (item.category == selectedCategory)
            if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return matchesCategory
            }
            let q = searchQuery.lowercased()
            let matchesSearch = item.title.lowercased().contains(q) ||
                                item.explanation.lowercased().contains(q) ||
                                (item.proTip?.lowercased().contains(q) ?? false) ||
                                item.category.lowercased().contains(q)
            return matchesCategory && matchesSearch
        }
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                Color.inkBackground.ignoresSafeArea()

                VStack(spacing: 0) {
                    // Context Switcher Strip
                    contextSwitcherStrip

                    // Category Filter Pills
                    categoryFilterStrip

                    // Search Bar
                    searchBarView
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)

                    // Feature / Icon Cards List
                    if filteredItems.isEmpty {
                        emptyStateView
                    } else {
                        ScrollView(.vertical, showsIndicators: true) {
                            LazyVStack(spacing: 12) {
                                ForEach(filteredItems) { item in
                                    FeatureGuideCard(item: item)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                            .padding(.bottom, 24)
                        }
                    }
                }
            }
            .navigationTitle("Visual Feature Guide")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        HapticEngine.light()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Context Switcher Strip
    private var contextSwitcherStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(UIGuideContext.allCases) { ctx in
                    let isSelected = activeContext == ctx
                    Button {
                        HapticEngine.selection()
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                            activeContext = ctx
                            selectedCategory = "All"
                            searchQuery = ""
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: ctx.iconName)
                                .font(.system(size: 11, weight: .bold))
                            Text(ctx.rawValue)
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                        }
                        .foregroundColor(isSelected ? .white : Color.primary.opacity(0.8))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            isSelected
                                ? AnyShapeStyle(ctx.themeColor)
                                : AnyShapeStyle(Color.primary.opacity(0.06))
                        )
                        .clipShape(Capsule())
                        .overlay(
                            Capsule().strokeBorder(
                                isSelected ? Color.white.opacity(0.3) : Color.primary.opacity(0.08),
                                lineWidth: 0.8
                            )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 6)
        }
    }

    // MARK: - Category Filter Strip
    private var categoryFilterStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(availableCategories, id: \.self) { cat in
                    let isSelected = selectedCategory == cat
                    Button {
                        HapticEngine.selection()
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                            selectedCategory = cat
                        }
                    } label: {
                        Text(cat)
                            .font(.system(size: 11, weight: isSelected ? .bold : .medium, design: .rounded))
                            .foregroundColor(isSelected ? .primary : .secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                isSelected
                                    ? Color.primary.opacity(0.12)
                                    : Color.primary.opacity(0.04),
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 4)
        }
    }

    // MARK: - Search Bar View
    private var searchBarView: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
                .font(.system(size: 14))

            TextField("Search icons, tools, or shortcuts...", text: $searchQuery)
                .font(.system(size: 13))
                .textFieldStyle(.plain)

            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.system(size: 14))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.inkSurfaceRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.inkBorderSubtle, lineWidth: 0.8)
        )
    }

    // MARK: - Empty State View
    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "questionmark.bubble")
                .font(.system(size: 40))
                .foregroundColor(.secondary.opacity(0.6))

            Text("No matching tools found")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundColor(Color.inkTextPrimary)

            Text("Try searching with different keywords or switch categories.")
                .font(.system(size: 12))
                .foregroundColor(Color.inkSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button {
                searchQuery = ""
                selectedCategory = "All"
            } label: {
                Text("Reset Filters")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(activeContext.themeColor)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(activeContext.themeColor.opacity(0.12), in: Capsule())
            }
            .padding(.top, 4)

            Spacer()
        }
    }
}

// MARK: - FeatureGuideCard
/// Visual card showing the icon badge, title, category tag, full explanation, and pro-tip.
public struct FeatureGuideCard: View {
    let item: UIIconExplanation

    public var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // Icon Badge
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(item.iconColor.opacity(0.14))
                    .frame(width: 44, height: 44)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(item.iconColor.opacity(0.28), lineWidth: 1)
                    )

                Image(systemName: item.iconName)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(item.iconColor)
            }

            // Text Content
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundColor(Color.inkTextPrimary)

                    Spacer(minLength: 4)

                    Text(item.category.uppercased())
                        .font(.system(size: 9, weight: .heavy, design: .rounded))
                        .foregroundColor(item.iconColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(item.iconColor.opacity(0.10), in: Capsule())
                }

                Text(item.explanation)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(Color.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(2)

                if let proTip = item.proTip {
                    HStack(alignment: .top, spacing: 4) {
                        Text("💡")
                            .font(.system(size: 10))
                        Text(proTip)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundColor(Color.inkTextPrimary.opacity(0.88))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .padding(.top, 2)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.inkSurfaceRaised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.inkBorderSubtle, lineWidth: 0.8)
        )
    }
}
