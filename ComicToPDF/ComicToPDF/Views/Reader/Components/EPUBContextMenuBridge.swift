import SwiftUI
import UIKit
import AVFoundation

// MARK: - Highlight Color Palette

public enum EPUBHighlightColor: String, CaseIterable, Identifiable, Sendable {
    case yellow    = "#FFD60A"
    case green     = "#34C759"
    case coral     = "#FF453A"
    case purple    = "#AF52DE"
    case underline = "underline"
    
    public var id: String { rawValue }
    
    public var displayColor: Color {
        switch self {
        case .yellow:    return Color(hex: "#FFD60A")
        case .green:     return Color(hex: "#34C759")
        case .coral:     return Color(hex: "#FF453A")
        case .purple:    return Color(hex: "#AF52DE")
        case .underline: return Color.primary
        }
    }
}

// MARK: - EPUB Selection Context Menu Bridge

/// Floating contextual popover menu displayed above active EPUB text selections.
/// Provides instant Highlight, System Dictionary Definition, Study Drawer Citation Injection, and On-Device Speech.
public struct EPUBContextMenuBridge: View {
    let bookTitle: String
    let chapterTitle: String
    let selectedText: String
    let selectionRect: CGRect
    var onHighlight: (EPUBHighlightColor) -> Void
    var onDefine: (String) -> Void
    var onAddToStudyDrawer: (String, String) -> Void
    var onSpeak: (String) -> Void
    var onDismiss: () -> Void
    
    @State private var showingDictionary = false
    @State private var dictionaryWord = ""
    
    public init(
        bookTitle: String,
        chapterTitle: String,
        selectedText: String,
        selectionRect: CGRect,
        onHighlight: @escaping (EPUBHighlightColor) -> Void,
        onDefine: @escaping (String) -> Void,
        onAddToStudyDrawer: @escaping (String, String) -> Void,
        onSpeak: @escaping (String) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.bookTitle = bookTitle
        self.chapterTitle = chapterTitle
        self.selectedText = selectedText
        self.selectionRect = selectionRect
        self.onHighlight = onHighlight
        self.onDefine = onDefine
        self.onAddToStudyDrawer = onAddToStudyDrawer
        self.onSpeak = onSpeak
        self.onDismiss = onDismiss
    }
    
    public var body: some View {
        HStack(spacing: 8) {
            // Highlight Palette
            HStack(spacing: 6) {
                ForEach(EPUBHighlightColor.allCases) { colorOption in
                    Button {
                        HapticEngine.selection()
                        onHighlight(colorOption)
                        onDismiss()
                    } label: {
                        if colorOption == .underline {
                            Image(systemName: "underline")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.primary)
                                .frame(width: 22, height: 22)
                                .background(Color.primary.opacity(0.1), in: Circle())
                        } else {
                            Circle()
                                .fill(colorOption.displayColor)
                                .frame(width: 20, height: 20)
                                .overlay(Circle().stroke(Color.white.opacity(0.4), lineWidth: 1))
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            
            Divider()
                .frame(height: 18)
                .background(Color.primary.opacity(0.15))
            
            // Define (Dictionary)
            Button {
                HapticEngine.light()
                let cleanWord = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
                dictionaryWord = cleanWord
                showingDictionary = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "character.book.closed.fill")
                        .font(.system(size: 11))
                    Text("Define")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                }
                .foregroundColor(.inkTextPrimary)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            
            // Add to Study Drawer
            Button {
                HapticEngine.success()
                let citation = "> [!cite] [[\(bookTitle)#\(chapterTitle)]]\n> \"\(selectedText)\""
                onAddToStudyDrawer(citation, selectedText)
                onDismiss()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "graduationcap.fill")
                        .font(.system(size: 11))
                    Text("Study")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                }
                .foregroundColor(.inkViolet)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(Color.inkViolet.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            
            // Speak (TTS)
            Button {
                HapticEngine.light()
                onSpeak(selectedText)
                onDismiss()
            } label: {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.inkBlue)
                    .padding(6)
                    .background(Color.inkBlue.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)
            
            // Copy
            Button {
                HapticEngine.light()
                UIPasteboard.general.string = selectedText
                onDismiss()
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.inkTextSecondary)
                    .padding(6)
                    .background(Color.primary.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.inkSurfaceRaised.opacity(0.95).background(.ultraThinMaterial))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.primary.opacity(0.12), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.25), radius: 10, y: 4)
        .sheet(isPresented: $showingDictionary) {
            SystemDictionaryModal(term: dictionaryWord)
        }
    }
}

// MARK: - Native UIKit Reference Library Modal

public struct SystemDictionaryModal: UIViewControllerRepresentable {
    let term: String
    
    public init(term: String) {
        self.term = term
    }
    
    public func makeUIViewController(context: Context) -> UIReferenceLibraryViewController {
        return UIReferenceLibraryViewController(term: term)
    }
    
    public func updateUIViewController(_ uiViewController: UIReferenceLibraryViewController, context: Context) {}
}
