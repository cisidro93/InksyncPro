import SwiftUI
import AVFoundation

/// Highlight color palette for Pro PDF Reader
enum PDFHighlightColor: String, CaseIterable, Identifiable {
    case yellow = "#FFD600"
    case green = "#00E676"
    case blue = "#29B6F6"
    case pink = "#FF4081"
    case purple = "#B388FF"

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .yellow: return Color(red: 1.0, green: 0.84, blue: 0.0)
        case .green:  return Color(red: 0.0, green: 0.90, blue: 0.46)
        case .blue:   return Color(red: 0.16, green: 0.71, blue: 0.96)
        case .pink:   return Color(red: 1.0, green: 0.25, blue: 0.51)
        case .purple: return Color(red: 0.70, green: 0.53, blue: 1.0)
        }
    }

    var uiColor: UIColor {
        switch self {
        case .yellow: return UIColor(red: 1.0, green: 0.84, blue: 0.0, alpha: 1.0)
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
        case .yellow: return UIColor(red: 1.0,  green: 0.84, blue: 0.0,  alpha: 0.45)
        case .green:  return UIColor(red: 0.0,  green: 0.90, blue: 0.46, alpha: 0.45)
        case .blue:   return UIColor(red: 0.16, green: 0.71, blue: 0.96, alpha: 0.45)
        case .pink:   return UIColor(red: 1.0,  green: 0.25, blue: 0.51, alpha: 0.45)
        case .purple: return UIColor(red: 0.70, green: 0.53, blue: 1.0,  alpha: 0.45)
        }
    }

    var displayName: String {
        switch self {
        case .yellow: return "Solar Yellow"
        case .green: return "Emerald Green"
        case .blue: return "Electric Blue"
        case .pink: return "Neon Pink"
        case .purple: return "Soft Purple"
        }
    }
}

/// Floating Contextual Text Markup HUD for Pro PDF Reader
struct ProPDFTextSelectionHUD: View {
    let selectedText: String
    let pageIndex: Int
    var onHighlight: (PDFHighlightColor) -> Void
    var onAddNote: (String) -> Void
    var onCopy: () -> Void
    var onSpeak: (String) -> Void
    var onCreateZettelkastenCard: (String) -> Void
    var onAddMarginaliaSymbol: ((String) -> Void)? = nil

    @State private var showingNoteInput = false
    @State private var noteText = ""
    @State private var hoveredSymbolLabel: String? = nil
    @State private var showingLegendPopover = false

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
                HStack {
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
                HStack(spacing: 12) {
                    // Color Pickers
                    HStack(spacing: 8) {
                        ForEach(PDFHighlightColor.allCases) { highlightColor in
                            Button(action: {
                                HapticEngine.selection()
                                onHighlight(highlightColor)
                            }) {
                                ZStack {
                                    Circle()
                                        .fill(highlightColor.color)
                                        .frame(width: 24, height: 24)
                                        .shadow(color: highlightColor.color.opacity(0.5), radius: 3)
                                        .overlay(
                                            Circle()
                                                .stroke(Color.white.opacity(0.85), lineWidth: 1.5)
                                        )
                                }
                                .frame(width: 36, height: 36)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Divider()
                        .frame(height: 20)
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

