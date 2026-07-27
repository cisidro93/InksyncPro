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
        Color(hex: rawValue)
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

    @State private var showingNoteInput = false
    @State private var noteText = ""

    var body: some View {
        VStack(spacing: 8) {
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
                            Circle()
                                .fill(highlightColor.color)
                                .frame(width: 22, height: 22)
                                .shadow(color: highlightColor.color.opacity(0.4), radius: 3)
                                .overlay(
                                    Circle()
                                        .stroke(Color.white.opacity(0.8), lineWidth: 1.5)
                                )
                                .onTapGesture {
                                    HapticEngine.light()
                                    onHighlight(highlightColor)
                                }
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
}
