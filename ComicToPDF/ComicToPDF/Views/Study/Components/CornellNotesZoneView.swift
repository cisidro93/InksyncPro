import SwiftUI
import PencilKit

// MARK: - Cornell Notes 3-Zone Paper View
struct CornellNotesZoneView: View {
    let notebookWidth: CGFloat
    @Binding var isCoveredForRecitation: Bool
    @Binding var cornellCuesText: String
    @Binding var cornellSummaryText: String
    let isMarkdownMode: Bool
    let paperStyle: PaperStyle
    let paperSpacing: CGFloat
    @Binding var localNotes: String
    @Binding var isFocused: Bool
    @Binding var canvasView: PKCanvasView
    @Binding var isSmartShapesEnabled: Bool
    var onLinkTapped: ((URL) -> Void)?
    var onCanvasSaved: (() -> Void)?
    let onGenerateCues: () -> Void
    let onGenerateSummary: () -> Void
    
    @Environment(\.colorScheme) private var colorScheme
    
    init(
        notebookWidth: CGFloat,
        isCoveredForRecitation: Binding<Bool>,
        cornellCuesText: Binding<String>,
        cornellSummaryText: Binding<String>,
        isMarkdownMode: Bool,
        paperStyle: PaperStyle,
        paperSpacing: CGFloat,
        localNotes: Binding<String>,
        isFocused: Binding<Bool>,
        canvasView: Binding<PKCanvasView>,
        isSmartShapesEnabled: Binding<Bool>,
        onLinkTapped: ((URL) -> Void)? = nil,
        onCanvasSaved: (() -> Void)? = nil,
        onGenerateCues: @escaping () -> Void,
        onGenerateSummary: @escaping () -> Void
    ) {
        self.notebookWidth = notebookWidth
        self._isCoveredForRecitation = isCoveredForRecitation
        self._cornellCuesText = cornellCuesText
        self._cornellSummaryText = cornellSummaryText
        self.isMarkdownMode = isMarkdownMode
        self.paperStyle = paperStyle
        self.paperSpacing = paperSpacing
        self._localNotes = localNotes
        self._isFocused = isFocused
        self._canvasView = canvasView
        self._isSmartShapesEnabled = isSmartShapesEnabled
        self.onLinkTapped = onLinkTapped
        self.onCanvasSaved = onCanvasSaved
        self.onGenerateCues = onGenerateCues
        self.onGenerateSummary = onGenerateSummary
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Top Bar Controls for Cornell
            HStack {
                Label("Cornell 3-Zone Layout", systemImage: "doc.text.fill")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.inkAccentKnowledge)
                Spacer()
                
                // Cover to Recite Toggle
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                        isCoveredForRecitation.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isCoveredForRecitation ? "eye.slash.fill" : "eye.fill")
                        Text(isCoveredForRecitation ? "Reciting (Notes Hidden)" : "Cover to Recite")
                    }
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(isCoveredForRecitation ? Color.orange : Color.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(isCoveredForRecitation ? Color.orange.opacity(0.15) : Color.primary.opacity(0.08), in: Capsule())
                }
                .buttonStyle(.plain)
                
                // AI Cue Generator
                Button {
                    onGenerateCues()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                        Text("Auto-Cues")
                    }
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.purple)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.purple.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                
                // 1-Tap Paste Button
                Button {
                    if let string = UIPasteboard.general.string, !string.isEmpty {
                        HapticEngine.success()
                        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                        if localNotes.isEmpty {
                            localNotes = trimmed
                        } else {
                            localNotes += "\n\n" + trimmed
                        }
                    } else {
                        HapticEngine.warning()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.clipboard")
                        Text("Paste")
                    }
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.orange.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.03))
            
            Divider()
            
            // Upper Section: Cue Column (28%) + Notes Area (72%)
            HStack(spacing: 0) {
                // Cue Column
                VStack(alignment: .leading, spacing: 4) {
                    Text("CUES & RECALL")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.inkTextTertiary)
                        .padding(.top, 6)
                        .padding(.leading, 8)
                    
                    TextEditor(text: $cornellCuesText)
                        .font(.system(size: 12, weight: .semibold))
                        .scrollContentBackground(.hidden)
                        .padding(6)
                }
                .frame(width: max(110, notebookWidth * 0.28))
                .background(Color.primary.opacity(0.02))
                
                Divider()
                
                // Notes Column with Recitation Mask
                ZStack {
                    if isMarkdownMode {
                        NotebookPaperBackground(style: paperStyle, spacing: paperSpacing, colorScheme: colorScheme)
                        MarkdownTextEditor(text: $localNotes, isFocused: $isFocused, paperStyle: paperStyle, onLinkTapped: onLinkTapped)
                    } else {
                        NotebookPaperBackground(style: paperStyle, spacing: paperSpacing, colorScheme: colorScheme)
                        StudyCanvasView(canvasView: $canvasView, isSmartShapesEnabled: $isSmartShapesEnabled, onSaved: { onCanvasSaved?() })
                    }
                    
                    if isCoveredForRecitation {
                        Rectangle()
                            .fill(.thinMaterial)
                            .overlay(
                                VStack(spacing: 8) {
                                    Image(systemName: "eye.slash")
                                        .font(.title2)
                                        .foregroundStyle(Color.orange)
                                    Text("Recitation Mode Active")
                                        .font(.system(size: 13, weight: .bold, design: .rounded))
                                    Text("Test your recall using the Cues column on the left.")
                                        .font(.caption2)
                                        .foregroundStyle(Theme.textSecondary)
                                        .multilineTextAlignment(.center)
                                }
                                .padding()
                            )
                            .transition(.opacity)
                    }
                }
            }
            
            Divider()
            
            // Lower Section: Summary Zone (20%)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("SUMMARY")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.inkAccentKnowledge)
                    Spacer()
                    Button("Auto-Summary") {
                        onGenerateSummary()
                    }
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.inkBlue)
                }
                .padding(.horizontal, 10)
                .padding(.top, 4)
                
                TextEditor(text: $cornellSummaryText)
                    .font(.system(size: 12, design: .serif))
                    .scrollContentBackground(.hidden)
                    .frame(height: 70)
                    .padding(.horizontal, 6)
            }
            .background(Color.inkAccentKnowledge.opacity(0.04))
        }
    }
}
