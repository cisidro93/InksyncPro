import SwiftUI

// MARK: - Walter Pauk Cornell 3-Zone Note Editor View

/// Interactive multi-zone Cornell active learning canvas with live Recitation Cover Mode.
public struct CornellNoteEditorView: View {
    @Binding var note: StudyNote
    var onConvertToFlashcard: ((String) -> Void)? = nil
    
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var focusedField: CornellField?
    
    private enum CornellField: Hashable {
        case title
        case cueColumn
        case mainNotes
        case summary
    }
    
    public init(
        note: Binding<StudyNote>,
        onConvertToFlashcard: ((String) -> Void)? = nil
    ) {
        self._note = note
        self.onConvertToFlashcard = onConvertToFlashcard
    }
    
    public var body: some View {
        GeometryReader { geo in
            let availableWidth = geo.size.width
            let isCompact = availableWidth < 520
            let cueWidth = min(150.0, availableWidth * (isCompact ? 0.28 : 0.32))

            ZStack {
                // MARK: - Mathematical Vector Paper Background
                VectorPaperCanvasView(template: note.paperTemplate)
                
                // MARK: - Note Layout Zones
                VStack(spacing: 0) {
                    // Header Bar (Title, Adler Marker, Recitation Toggle)
                    editorHeaderBar(isCompact: isCompact)
                    
                    Divider()
                        .background(Color.primary.opacity(0.08))
                    
                    // 3-Zone Split Body
                    VStack(spacing: 0) {
                        // Upper Split: Cue Column | Main Notes Field
                        HStack(spacing: 0) {
                            // Zone 1: Left Cue / Recall Column
                            cueColumnSection
                                .frame(width: cueWidth)
                            
                            // Vertical Divider
                            Rectangle()
                                .fill(Color.primary.opacity(0.12))
                                .frame(width: 1)
                            
                            // Zone 2: Main Notes Field (with Recitation Cover)
                            mainNotesSection(isCompact: isCompact)
                                .frame(maxWidth: .infinity)
                        }
                        .frame(maxHeight: .infinity)
                        
                        // Horizontal Divider for Summary
                        Rectangle()
                            .fill(Color.primary.opacity(0.12))
                            .frame(height: 1)
                        
                        // Zone 3: Bottom Summary / Synthesis Block
                        summarySection
                            .frame(height: isCompact ? 110 : 130)
                    }
                }
            }
        }
    }
    
    // MARK: - Editor Header Bar
    
    private func editorHeaderBar(isCompact: Bool) -> some View {
        HStack(spacing: isCompact ? 8 : 12) {
            // Note Title Field
            TextField("Note Title...", text: $note.title)
                .font(.system(size: isCompact ? 15 : 16, weight: .bold, design: .rounded))
                .foregroundColor(.inkTextPrimary)
                .focused($focusedField, equals: .title)
                .frame(minWidth: 80)
            
            Spacer()
            
            // Adler Marker Selector
            Menu {
                Section("Mortimer Adler Reading Marker") {
                    Button {
                        note.adlerMarker = nil
                    } label: {
                        Label("None", systemImage: "xmark")
                    }
                    
                    ForEach(AdlerMarker.allCases) { marker in
                        Button {
                            HapticEngine.selection()
                            note.adlerMarker = marker
                        } label: {
                            Label("\(marker.symbol) \(marker.title)", systemImage: marker.sfSymbol)
                        }
                    }
                }
            } label: {
                if let marker = note.adlerMarker {
                    HStack(spacing: 3) {
                        Text(marker.symbol)
                            .font(.system(size: 12, weight: .black))
                        if !isCompact {
                            Text(marker.title)
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                        }
                    }
                    .foregroundColor(marker.accentColor)
                    .padding(.horizontal, isCompact ? 6 : 8)
                    .padding(.vertical, 4)
                    .background(marker.accentColor.opacity(0.15), in: Capsule())
                } else {
                    HStack(spacing: 3) {
                        Image(systemName: "tag")
                            .font(.system(size: 10, weight: .bold))
                        if !isCompact {
                            Text("Marker")
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                        }
                    }
                    .foregroundColor(.inkTextSecondary)
                    .padding(.horizontal, isCompact ? 6 : 8)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.06), in: Capsule())
                }
            }
            
            // Paper Template Picker
            Menu {
                Section("Paper Template") {
                    ForEach(VectorPaperTemplate.allCases) { template in
                        Button {
                            HapticEngine.selection()
                            note.paperTemplate = template
                        } label: {
                            Label(template.rawValue, systemImage: template.iconName)
                        }
                    }
                }
            } label: {
                Image(systemName: note.paperTemplate.iconName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.inkTextPrimary)
                    .padding(6)
                    .background(Color.primary.opacity(0.08), in: Circle())
            }
            
            // Recitation Cover Mode Toggle Button
            Button {
                HapticEngine.medium()
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    note.isRecitationCoverActive.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: note.isRecitationCoverActive ? "eye.slash.fill" : "eye")
                        .font(.system(size: 12, weight: .bold))
                    if !isCompact {
                        Text(note.isRecitationCoverActive ? "Covered" : "Recite")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                    }
                }
                .foregroundColor(note.isRecitationCoverActive ? .white : .inkViolet)
                .padding(.horizontal, isCompact ? 8 : 10)
                .padding(.vertical, 5)
                .background(
                    note.isRecitationCoverActive
                        ? AnyShapeStyle(Color.inkViolet)
                        : AnyShapeStyle(Color.inkViolet.opacity(0.12)),
                    in: Capsule()
                )
            }
            .buttonStyle(.plain)
            .help("Obscure main notes to test active recall using only the cue column.")
        }
        .padding(.horizontal, isCompact ? 10 : 16)
        .padding(.vertical, 8)
        .background(Color.inkSurface.opacity(0.85).background(.ultraThinMaterial))
    }
    
    // MARK: - Zone 1: Cue / Recall Column
    
    private var cueColumnSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("CUES & QUESTIONS")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(.inkTextTertiary)
                .padding(.horizontal, 10)
                .padding(.top, 8)
            
            ZStack(alignment: .topLeading) {
                if note.cueColumnText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("• Key questions\n• Vocabulary\n• Review cues")
                        .font(.system(size: 13, weight: .regular, design: .rounded))
                        .foregroundColor(.inkTextTertiary.opacity(0.45))
                        .italic()
                        .lineSpacing(4)
                        .padding(.horizontal, 10)
                        .padding(.top, 8)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }

                TextEditor(text: $note.cueColumnText)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(.inkTextPrimary)
                    .lineSpacing(4)
                    .padding(.horizontal, 6)
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                    .focused($focusedField, equals: .cueColumn)
            }
        }
        .background(Color.primary.opacity(0.02))
    }
    
    // MARK: - Zone 2: Main Notes Field
    
    private func mainNotesSection(isCompact: Bool) -> some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(isCompact ? "NOTES" : "MAIN NOTES & CLOZE (==syntax==)")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(.inkTextTertiary)
                        .lineLimit(1)
                    
                    Spacer()
                    
                    Button {
                        if let string = UIPasteboard.general.string, !string.isEmpty {
                            HapticEngine.success()
                            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                            if note.mainNotesMarkdown.isEmpty {
                                note.mainNotesMarkdown = trimmed
                            } else {
                                note.mainNotesMarkdown += "\n\n" + trimmed
                            }
                        } else {
                            HapticEngine.warning()
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "doc.on.clipboard")
                            Text("Paste")
                        }
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundColor(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    
                    if let onConvert = onConvertToFlashcard, !note.mainNotesMarkdown.isEmpty {
                        Button {
                            onConvert(note.mainNotesMarkdown)
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "plus.rectangle.on.rectangle")
                                if !isCompact {
                                    Text("Make Flashcard")
                                } else {
                                    Text("Card")
                                }
                            }
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundColor(.inkViolet)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.inkViolet.opacity(0.12), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, isCompact ? 8 : 12)
                .padding(.top, 8)
                
                ZStack(alignment: .topLeading) {
                    if note.mainNotesMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("# Core Concepts & Big Ideas\n• Supporting arguments & proofs\n• Formulas & definitions\n==Cloze recall markers==")
                            .font(.system(size: 14, weight: .regular, design: .rounded))
                            .foregroundColor(.inkTextTertiary.opacity(0.45))
                            .italic()
                            .lineSpacing(5)
                            .padding(.horizontal, 12)
                            .padding(.top, 8)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }

                    TextEditor(text: $note.mainNotesMarkdown)
                        .font(.system(size: 14, weight: .regular, design: .rounded))
                        .foregroundColor(.inkTextPrimary)
                        .lineSpacing(5)
                        .padding(.horizontal, 8)
                        .scrollContentBackground(.hidden)
                        .background(Color.clear)
                        .focused($focusedField, equals: .mainNotes)
                }
            }
            
            // Recitation Cover Mode Overlay
            if note.isRecitationCoverActive {
                ZStack {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .overlay(Color.inkBackground.opacity(0.85))
                    
                    VStack(spacing: 10) {
                        Image(systemName: "eye.slash.circle.fill")
                            .font(.system(size: 36, weight: .bold))
                            .foregroundColor(.inkViolet)
                        
                        Text("Recitation Mode Active")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundColor(.inkTextPrimary)
                        
                        Text("Notes are hidden. Test your active recall using only the Cue prompts on the left.")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundColor(.inkTextSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                        
                        Button {
                            HapticEngine.light()
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                note.isRecitationCoverActive = false
                            }
                        } label: {
                            Text("Reveal Notes")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundColor(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .background(Color.inkViolet, in: Capsule())
                        }
                        .padding(.top, 4)
                    }
                    .padding()
                }
                .transition(.opacity)
            }
        }
    }
    
    // MARK: - Zone 3: Summary / Synthesis Block
    
    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("SUMMARY & SYNTHESIS")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(.inkTextTertiary)
                .padding(.horizontal, 12)
                .padding(.top, 8)
            
            ZStack(alignment: .topLeading) {
                if note.summaryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Synthesize the key takeaways and actionable conclusions in 2–3 concise sentences...")
                        .font(.system(size: 13, weight: .regular, design: .rounded))
                        .foregroundColor(.inkTextTertiary.opacity(0.45))
                        .italic()
                        .lineSpacing(3)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }

                TextEditor(text: $note.summaryText)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundColor(.inkTextPrimary)
                    .lineSpacing(3)
                    .padding(.horizontal, 8)
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                    .focused($focusedField, equals: .summary)
            }
        }
        .background(Color.primary.opacity(0.03))
    }
}
