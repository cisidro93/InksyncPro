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
        ZStack {
            // MARK: - Mathematical Vector Paper Background
            VectorPaperCanvasView(template: note.paperTemplate)
            
            // MARK: - Note Layout Zones
            VStack(spacing: 0) {
                // Header Bar (Title, Adler Marker, Recitation Toggle)
                editorHeaderBar
                
                Divider()
                    .background(Color.primary.opacity(0.08))
                
                // 3-Zone Split Body
                GeometryReader { geo in
                    let availableWidth = geo.size.width
                    let cueWidth = min(150.0, availableWidth * 0.32)
                    
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
                            mainNotesSection
                                .frame(maxWidth: .infinity)
                        }
                        .frame(maxHeight: .infinity)
                        
                        // Horizontal Divider for Summary
                        Rectangle()
                            .fill(Color.primary.opacity(0.12))
                            .frame(height: 1)
                        
                        // Zone 3: Bottom Summary / Synthesis Block
                        summarySection
                            .frame(height: 130)
                    }
                }
            }
        }
    }
    
    // MARK: - Editor Header Bar
    
    private var editorHeaderBar: some View {
        HStack(spacing: 12) {
            // Note Title Field
            TextField("Note Title...", text: $note.title)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundColor(.inkTextPrimary)
                .focused($focusedField, equals: .title)
            
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
                    HStack(spacing: 4) {
                        Text(marker.symbol)
                            .font(.system(size: 12, weight: .black))
                        Text(marker.title)
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                    }
                    .foregroundColor(marker.accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(marker.accentColor.opacity(0.15), in: Capsule())
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "tag")
                            .font(.system(size: 10, weight: .bold))
                        Text("Marker")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                    }
                    .foregroundColor(.inkTextSecondary)
                    .padding(.horizontal, 8)
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
                    .padding(7)
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
                    Text(note.isRecitationCoverActive ? "Covered" : "Recite")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                }
                .foregroundColor(note.isRecitationCoverActive ? .white : .inkViolet)
                .padding(.horizontal, 10)
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
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
            
            TextEditor(text: $note.cueColumnText)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(.inkTextPrimary)
                .lineSpacing(4)
                .padding(.horizontal, 6)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .focused($focusedField, equals: .cueColumn)
        }
        .background(Color.primary.opacity(0.02))
    }
    
    // MARK: - Zone 2: Main Notes Field
    
    private var mainNotesSection: some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("MAIN NOTES & CLOZE (==syntax==)")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(.inkTextTertiary)
                    
                    Spacer()
                    
                    if let onConvert = onConvertToFlashcard, !note.mainNotesMarkdown.isEmpty {
                        Button {
                            onConvert(note.mainNotesMarkdown)
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "plus.rectangle.on.rectangle")
                                Text("Make Flashcard")
                            }
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundColor(.inkViolet)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                
                TextEditor(text: $note.mainNotesMarkdown)
                    .font(.system(size: 14, weight: .regular, design: .rounded))
                    .foregroundColor(.inkTextPrimary)
                    .lineSpacing(5)
                    .padding(.horizontal, 8)
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                    .focused($focusedField, equals: .mainNotes)
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
            
            TextEditor(text: $note.summaryText)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundColor(.inkTextPrimary)
                .lineSpacing(3)
                .padding(.horizontal, 8)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .focused($focusedField, equals: .summary)
        }
        .background(Color.primary.opacity(0.03))
    }
}
