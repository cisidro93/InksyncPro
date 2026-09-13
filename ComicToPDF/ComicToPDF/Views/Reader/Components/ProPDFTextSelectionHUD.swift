import SwiftUI
import AVFoundation

/// Highlight color palette for Pro PDF Reader
enum PDFHighlightColor: String, CaseIterable, Identifiable {
    case yellow = "#FFD600"
    case orange = "#FF9100"
    case green = "#00E676"
    case blue = "#29B6F6"
    case pink = "#FF4081"
    case purple = "#B388FF"

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .yellow: return Color(red: 1.0, green: 0.84, blue: 0.0)
        case .orange: return Color(red: 1.0, green: 0.57, blue: 0.0)
        case .green:  return Color(red: 0.0, green: 0.90, blue: 0.46)
        case .blue:   return Color(red: 0.16, green: 0.71, blue: 0.96)
        case .pink:   return Color(red: 1.0, green: 0.25, blue: 0.51)
        case .purple: return Color(red: 0.70, green: 0.53, blue: 1.0)
        }
    }

    var uiColor: UIColor {
        switch self {
        case .yellow: return UIColor(red: 1.0, green: 0.84, blue: 0.0, alpha: 1.0)
        case .orange: return UIColor(red: 1.0, green: 0.57, blue: 0.0, alpha: 1.0)
        case .green:  return UIColor(red: 0.0, green: 0.90, blue: 0.46, alpha: 1.0)
        case .blue:   return UIColor(red: 0.16, green: 0.71, blue: 0.96, alpha: 1.0)
        case .pink:   return UIColor(red: 1.0, green: 0.25, blue: 0.51, alpha: 1.0)
        case .purple: return UIColor(red: 0.70, green: 0.53, blue: 1.0, alpha: 1.0)
        }
    }

    /// Pre-multiplied highlight UIColor ready to pass directly to PDFAnnotation.color.
    /// Never use `uiColor.withAlphaComponent(0.45)` — the hex round-trip degrades saturation
    /// for vivid colors like Emerald Green and Electric Blue.
    var directHighlightUIColor: UIColor {
        switch self {
        case .yellow: return UIColor(red: 1.0,  green: 0.84, blue: 0.0,  alpha: 0.55)
        case .orange: return UIColor(red: 1.0,  green: 0.55, blue: 0.05, alpha: 0.65)
        case .green:  return UIColor(red: 0.0,  green: 0.85, blue: 0.40, alpha: 0.65)
        case .blue:   return UIColor(red: 0.15, green: 0.68, blue: 0.95, alpha: 0.65)
        case .pink:   return UIColor(red: 1.0,  green: 0.20, blue: 0.52, alpha: 0.65)
        case .purple: return UIColor(red: 0.68, green: 0.48, blue: 0.96, alpha: 0.65)
        }
    }

    var displayName: String {
        switch self {
        case .yellow: return "Solar Yellow"
        case .orange: return "Sunset Orange"
        case .green: return "Emerald Green"
        case .blue: return "Electric Blue"
        case .pink: return "Neon Pink"
        case .purple: return "Soft Purple"
        }
    }
}

/// Markup style for text annotations (Highlight, Underline, Strikethrough)
enum AnnotationMarkupStyle: String, CaseIterable, Identifiable {
    case highlight = "highlight"
    case underline = "underline"
    case strikeOut = "strikeout"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .highlight: return "Highlight"
        case .underline: return "Underline"
        case .strikeOut: return "Strike"
        }
    }

    var icon: String {
        switch self {
        case .highlight: return "highlighter"
        case .underline: return "underline"
        case .strikeOut: return "strikethrough"
        }
    }
}

/// Floating Contextual Text Markup HUD for Pro PDF Reader
struct ProPDFTextSelectionHUD: View {
    let selectedText: String
    let pageIndex: Int
    var onHighlight: (PDFHighlightColor) -> Void
    var onMarkup: ((PDFHighlightColor, AnnotationMarkupStyle) -> Void)? = nil
    var onUnhighlight: (() -> Void)? = nil
    var onAddNote: (String) -> Void
    var onCopy: () -> Void
    var onSpeak: (String) -> Void
    var onCreateZettelkastenCard: (String) -> Void
    var onAddMarginaliaSymbol: ((String) -> Void)? = nil
    var onAdjustStart: ((Int) -> Void)? = nil
    var onAdjustEnd: ((Int) -> Void)? = nil
    var onDismiss: (() -> Void)? = nil

    init(
        selectedText: String,
        pageIndex: Int,
        onHighlight: @escaping (PDFHighlightColor) -> Void,
        onMarkup: ((PDFHighlightColor, AnnotationMarkupStyle) -> Void)? = nil,
        onUnhighlight: (() -> Void)? = nil,
        onAddNote: @escaping (String) -> Void,
        onCopy: @escaping () -> Void,
        onSpeak: @escaping (String) -> Void,
        onCreateZettelkastenCard: @escaping (String) -> Void,
        onAddMarginaliaSymbol: ((String) -> Void)? = nil,
        onAdjustStart: ((Int) -> Void)? = nil,
        onAdjustEnd: ((Int) -> Void)? = nil,
        onDismiss: (() -> Void)? = nil
    ) {
        self.selectedText = selectedText
        self.pageIndex = pageIndex
        self.onHighlight = onHighlight
        self.onMarkup = onMarkup
        self.onUnhighlight = onUnhighlight
        self.onAddNote = onAddNote
        self.onCopy = onCopy
        self.onSpeak = onSpeak
        self.onCreateZettelkastenCard = onCreateZettelkastenCard
        self.onAddMarginaliaSymbol = onAddMarginaliaSymbol
        self.onAdjustStart = onAdjustStart
        self.onAdjustEnd = onAdjustEnd
        self.onDismiss = onDismiss
    }

    @State private var showingNoteInput = false
    @State private var noteText = ""
    @State private var showingMorePopover = false
    @State private var selectedMarkupStyle: AnnotationMarkupStyle = .highlight
    @State private var activeColor: PDFHighlightColor = EBookPreferences.shared.defaultHighlightColor

    private let marginaliaSymbols = [
        (symbol: "?", label: "Question / Needs Clarification", shortLabel: "Question"),
        (symbol: "!", label: "Important / Key Insight", shortLabel: "Important"),
        (symbol: "★", label: "Core Thesis / Main Argument", shortLabel: "Core Thesis"),
        (symbol: "≠", label: "Counter-Argument / Disagreement", shortLabel: "Counter-Argument"),
        (symbol: "Δ", label: "Shift in Logic / Topic Change", shortLabel: "Logic Shift")
    ]

    var body: some View {
        VStack(spacing: 8) {
            // Main Kindle-inspired Floating Capsule Bar
            HStack(spacing: 8) {
                // Color swatches (Kindle direct color picker)
                HStack(spacing: 5) {
                    ForEach(PDFHighlightColor.allCases) { color in
                        Button {
                            HapticEngine.selection()
                            activeColor = color
                            EBookPreferences.shared.defaultHighlightColor = color
                            if let onMarkup = onMarkup {
                                onMarkup(color, selectedMarkupStyle)
                            } else {
                                onHighlight(color)
                            }
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(color.color)
                                    .frame(width: 20, height: 20)
                                    .shadow(color: color.color.opacity(0.45), radius: 2)

                                if activeColor == color {
                                    Circle()
                                        .stroke(Color.white, lineWidth: 2)
                                        .frame(width: 25, height: 25)
                                }
                            }
                            .frame(width: 28, height: 28)
                            .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Highlight \(color.displayName)")
                    }
                }
                .padding(.leading, 6)

                Divider()
                    .frame(height: 18)
                    .background(Color.white.opacity(0.25))
                    .padding(.horizontal, 2)

                // Action Icons
                HStack(spacing: 6) {
                    // Note
                    Button {
                        HapticEngine.light()
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                            showingNoteInput.toggle()
                        }
                    } label: {
                        Image(systemName: showingNoteInput ? "note.text.badge.plus" : "note.text")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(showingNoteInput ? Color.inkOrange : Color.white)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add Note")
                    .help("Add Note")

                    // Delete / Unhighlight
                    if let onUnhighlight = onUnhighlight {
                        Button {
                            HapticEngine.medium()
                            onUnhighlight()
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color.red.opacity(0.9))
                                .frame(width: 32, height: 32)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove Highlight")
                        .help("Remove Highlight")
                    }

                    // Copy
                    Button {
                        HapticEngine.light()
                        UIPasteboard.general.string = selectedText
                        onCopy()
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.white)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Copy")
                    .help("Copy text")

                    // Define (Dictionary)
                    Button {
                        HapticEngine.light()
                        SystemDictionaryPresenter.shared.presentDefinition(for: selectedText)
                    } label: {
                        Image(systemName: "book.closed")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.white)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Define")
                    .help("Define Word")

                    // More Options (•••)
                    Button {
                        HapticEngine.light()
                        showingMorePopover.toggle()
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color.white)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("More Options")
                    .help("More Options")
                    .popover(isPresented: $showingMorePopover) {
                        moreOptionsPopover
                    }

                    if let onDismiss = onDismiss {
                        Divider()
                            .frame(height: 18)
                            .background(Color.white.opacity(0.25))

                        Button {
                            HapticEngine.light()
                            onDismiss()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.white.opacity(0.7))
                                .frame(width: 28, height: 32)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Dismiss")
                    }
                }
                .padding(.trailing, 6)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Capsule(style: .continuous)
                            .fill(Color.black.opacity(0.65))
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(Color.white.opacity(0.18), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.35), radius: 10, y: 5)
            )

            // Expandable Inline Note Input
            if showingNoteInput {
                HStack(spacing: 8) {
                    TextField("Add a note to this highlight...", text: $noteText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color.white.opacity(0.15), lineWidth: 0.8)
                        )
                        .foregroundColor(.white)

                    Button {
                        let trimmed = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            onAddNote(trimmed)
                        }
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                            showingNoteInput = false
                            noteText = ""
                        }
                    } label: {
                        Text("Save")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundColor(.inkGreen)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Color.inkGreen.opacity(0.2), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    Button {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                            showingNoteInput = false
                            noteText = ""
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white.opacity(0.6))
                            .padding(7)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.black.opacity(0.7))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color.white.opacity(0.18), lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                )
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.95).combined(with: .opacity).combined(with: .move(edge: .top)),
                    removal: .opacity.combined(with: .scale(scale: 0.95))
                ))
            }
        }
    }

    private var moreOptionsPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Style Picker (Highlight, Underline, Strikethrough)
            VStack(alignment: .leading, spacing: 6) {
                Text("STYLE")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.5))
                    .tracking(0.8)

                HStack(spacing: 8) {
                    ForEach(AnnotationMarkupStyle.allCases) { style in
                        Button {
                            HapticEngine.selection()
                            selectedMarkupStyle = style
                            onMarkup?(activeColor, style)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: style.icon)
                                    .font(.system(size: 11, weight: selectedMarkupStyle == style ? .bold : .medium))
                                Text(style.displayName)
                                    .font(.system(size: 11, weight: .medium, design: .rounded))
                            }
                            .foregroundColor(selectedMarkupStyle == style ? .inkOrange : .white.opacity(0.75))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(
                                selectedMarkupStyle == style
                                    ? Color.inkOrange.opacity(0.2)
                                    : Color.white.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Divider()
                .background(Color.white.opacity(0.15))

            // Adlerian Marginalia Shorthand Symbols
            VStack(alignment: .leading, spacing: 6) {
                Text("MARGINALIA (ADLER SHORTHAND)")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.5))
                    .tracking(0.8)

                HStack(spacing: 8) {
                    ForEach(marginaliaSymbols, id: \.symbol) { item in
                        Button {
                            HapticEngine.light()
                            onAddMarginaliaSymbol?(item.symbol)
                            showingMorePopover = false
                        } label: {
                            VStack(spacing: 2) {
                                Text(item.symbol)
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(.white)
                                    .frame(width: 26, height: 26)
                                    .background(Color.white.opacity(0.12), in: Circle())

                                Text(item.shortLabel)
                                    .font(.system(size: 8, weight: .semibold, design: .rounded))
                                    .foregroundColor(Color.white.opacity(0.6))
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(item.label)
                    }
                }
            }

            Divider()
                .background(Color.white.opacity(0.15))

            // Actions: Speak & Zettelkasten
            VStack(spacing: 6) {
                Button {
                    HapticEngine.light()
                    showingMorePopover = false
                    onSpeak(selectedText)
                } label: {
                    HStack {
                        Label("Read Aloud", systemImage: "speaker.wave.2.fill")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white)
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)

                Button {
                    HapticEngine.medium()
                    showingMorePopover = false
                    onCreateZettelkastenCard(selectedText)
                } label: {
                    HStack {
                        Label("Create Zettelkasten Card", systemImage: "brain.head.profile")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.inkGreen)
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(width: 280)
        .background(Color(hex: "#1A1A24"))
    }
}

