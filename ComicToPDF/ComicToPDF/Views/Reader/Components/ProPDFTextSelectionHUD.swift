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
    var onAddNote: (String) -> Void
    var onCopy: () -> Void
    var onSpeak: (String) -> Void
    var onCreateZettelkastenCard: (String) -> Void
    var onAddMarginaliaSymbol: ((String) -> Void)? = nil
    var onDismiss: (() -> Void)? = nil

    @State private var showingNoteInput = false
    @State private var noteText = ""
    @State private var hoveredSymbolLabel: String? = nil
    @State private var showingLegendPopover = false
    @State private var selectedMarkupStyle: AnnotationMarkupStyle = .highlight

    private let marginaliaSymbols = [
        (symbol: "?", label: "Question / Needs Clarification", shortLabel: "Question"),
        (symbol: "!", label: "Important / Key Insight", shortLabel: "Important"),
        (symbol: "★", label: "Core Thesis / Main Argument", shortLabel: "Core Thesis"),
        (symbol: "≠", label: "Counter-Argument / Disagreement", shortLabel: "Counter-Argument"),
        (symbol: "Δ", label: "Shift in Logic / Topic Change", shortLabel: "Logic Shift")
    ]

    var body: some View {
        VStack(spacing: 8) {
            // Marginalia Symbol Bar Header with Active Label
            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    Text("MARGINALIA (ADLER SHORTHAND)")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.5))
                        .tracking(0.8)
                    Spacer()
                    
                    if let label = hoveredSymbolLabel {
                        Text(label)
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.inkOrange)
                            .transition(.opacity)
                    } else {
                        Button {
                            showingLegendPopover.toggle()
                        } label: {
                            Image(systemName: "questionmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.white.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $showingLegendPopover) {
                            marginaliaLegendPopover
                        }
                    }

                    if let onDismiss = onDismiss {
                        Button {
                            HapticEngine.light()
                            onDismiss()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(Color.white.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                        .help("Dismiss Selection")
                        .accessibilityLabel("Dismiss Selection")
                    }
                }
                .padding(.horizontal, 14)

                HStack(spacing: 12) {
                    ForEach(marginaliaSymbols, id: \.symbol) { item in
                        Button {
                            HapticEngine.light()
                            hoveredSymbolLabel = item.shortLabel
                            onAddMarginaliaSymbol?(item.symbol)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                withAnimation { hoveredSymbolLabel = nil }
                            }
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
                        .help(item.label)
                    }
                }
            }
            .padding(.top, 8)


            if showingNoteInput {
                HStack(spacing: 8) {
                    TextField("Add a note to this selection...", text: $noteText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.4))
                        .cornerRadius(8)
                        .foregroundColor(.white)

                    Button(action: {
                        let trimmed = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            onAddNote(trimmed)
                        }
                        showingNoteInput = false
                        noteText = ""
                    }) {
                        Text("Save")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.inkGreen)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.inkGreen.opacity(0.15))
                            .cornerRadius(8)
                    }

                    Button(action: {
                        showingNoteInput = false
                        noteText = ""
                    }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white.opacity(0.6))
                            .padding(8)
                    }
                }
                .padding(8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                HStack(spacing: 10) {
                    // Markup Style Selector (Highlight, Underline, Strikethrough)
                    HStack(spacing: 4) {
                        ForEach(AnnotationMarkupStyle.allCases) { style in
                            Button(action: {
                                HapticEngine.selection()
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                    selectedMarkupStyle = style
                                }
                            }) {
                                Image(systemName: style.icon)
                                    .font(.system(size: 11, weight: selectedMarkupStyle == style ? .bold : .medium))
                                    .foregroundColor(selectedMarkupStyle == style ? .inkOrange : .white.opacity(0.65))
                                    .frame(width: 24, height: 24)
                                    .background(
                                        selectedMarkupStyle == style
                                            ? Color.inkOrange.opacity(0.2)
                                            : Color.white.opacity(0.08),
                                        in: RoundedRectangle(cornerRadius: 6)
                                    )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(style.displayName)
                        }
                    }
                    .padding(2)
                    .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))

                    Divider()
                        .frame(height: 18)
                        .background(Color.white.opacity(0.2))

                    // Color Pickers
                    HStack(spacing: 6) {
                        ForEach(PDFHighlightColor.allCases) { highlightColor in
                            Button(action: {
                                HapticEngine.selection()
                                if let onMarkup = onMarkup {
                                    onMarkup(highlightColor, selectedMarkupStyle)
                                } else {
                                    onHighlight(highlightColor)
                                }
                            }) {
                                ZStack {
                                    Circle()
                                        .fill(highlightColor.color)
                                        .frame(width: 22, height: 22)
                                        .shadow(color: highlightColor.color.opacity(0.5), radius: 3)
                                        .overlay(
                                            Circle()
                                                .stroke(Color.white.opacity(0.85), lineWidth: 1.5)
                                        )
                                }
                                .frame(width: 32, height: 32)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Divider()
                        .frame(height: 18)
                        .background(Color.white.opacity(0.2))

                    // Action Buttons
                    HStack(spacing: 10) {
                        Button(action: {
                            HapticEngine.light()
                            showingNoteInput = true
                        }) {
                            Label("Note", systemImage: "note.text")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.white)
                        }

                        Button(action: {
                            HapticEngine.light()
                            SystemDictionaryPresenter.shared.presentDefinition(for: selectedText)
                        }) {
                            Label("Define", systemImage: "book.closed")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.white)
                        }

                        Button(action: {
                            HapticEngine.light()
                            UIPasteboard.general.string = selectedText
                            onCopy()
                        }) {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.white)
                        }

                        Button(action: {
                            HapticEngine.light()
                            onSpeak(selectedText)
                        }) {
                            Image(systemName: "speaker.wave.2.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.white)
                        }

                        Button(action: {
                            HapticEngine.medium()
                            onCreateZettelkastenCard(selectedText)
                        }) {
                            Label("Zettel", systemImage: "brain.head.profile")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.inkGreen)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.inkGreen.opacity(0.2))
                                .cornerRadius(6)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }

        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.15), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
        )
    }

    private var marginaliaLegendPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Adlerian Marginalia Symbols", systemImage: "book.pages")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.inkOrange)
                Spacer()
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                ForEach(marginaliaSymbols, id: \.symbol) { item in
                    HStack(spacing: 8) {
                        Text(item.symbol)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 24, height: 24)
                            .background(Color.white.opacity(0.15), in: Circle())
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.shortLabel)
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.white)
                            Text(item.label)
                                .font(.caption2)
                                .foregroundColor(.white.opacity(0.7))
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 260)
        .background(Color(hex: "#1A1A24"))
    }
}

