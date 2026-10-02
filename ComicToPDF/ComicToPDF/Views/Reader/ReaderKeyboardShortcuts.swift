import SwiftUI
import UIKit

// ============================================================================
// ReaderKeyboardShortcuts
// ============================================================================
// Professional hardware keyboard engine for Apple Magic Keyboard, Smart Folio,
// and Bluetooth Page Turners (AirTurn, PageFlip, Coda Stomp).
//
// 🛡️ Split-View Notebook Safety Architecture:
// When text editing is active (e.g. typing notes in MarkdownTextEditor or search),
// all unmodified alphanumeric single-key shortcuts (Space, a-z, arrows) are
// STRICTLY MUTED to prevent accidental page turns or feature toggles mid-sentence.
//
// 📖 Hands-On-Keys Reading:
// Command-modified page-turn hotkeys (⌘] and ⌘[) remain 100% active at all times,
// allowing seamless page turning even while actively taking notes in the notebook.
// ============================================================================

struct ReaderKeyboardShortcuts: ViewModifier {
    var isEditingText: Bool = false
    var onNextPage: () -> Void
    var onPreviousPage: () -> Void
    var onToggleReflow: (() -> Void)? = nil
    var onToggleSpeech: (() -> Void)? = nil
    var onToggleHighlighter: (() -> Void)? = nil
    var onToggleMarkup: (() -> Void)? = nil
    var onToggleNotebook: (() -> Void)? = nil
    var onToggleSidebar: (() -> Void)? = nil
    var onZoomIn: (() -> Void)? = nil
    var onZoomOut: (() -> Void)? = nil
    var onResetZoom: (() -> Void)? = nil
    var onShowHelp: (() -> Void)? = nil
    var onDismiss: () -> Void

    /// Dynamic check combining explicit view state with active responder hierarchy
    private var isTextEditingActive: Bool {
        isEditingText || UIResponder.isTextInputActive
    }

    func body(content: Content) -> some View {
        content
            .background(
                Group {
                    // ── 1. SPLIT-NOTEBOOK SAFE PAGE TURNING (Always Active) ──
                    // Works even while actively typing in the Cornell / Markdown notebook!
                    Button("") { onNextPage() }
                        .keyboardShortcut("]", modifiers: [.command])
                    Button("") { onNextPage() }
                        .keyboardShortcut(.rightArrow, modifiers: [.command])

                    Button("") { onPreviousPage() }
                        .keyboardShortcut("[", modifiers: [.command])
                    Button("") { onPreviousPage() }
                        .keyboardShortcut(.leftArrow, modifiers: [.command])

                    // ── 2. READING NAVIGATION (Muted while typing notes) ──
                    if !isTextEditingActive {
                        Button("") { onNextPage() }
                            .keyboardShortcut(.rightArrow, modifiers: [])
                        Button("") { onNextPage() }
                            .keyboardShortcut(.downArrow, modifiers: [])
                        Button("") { onNextPage() }
                            .keyboardShortcut(.space, modifiers: [])
                        Button("") { onNextPage() }
                            .keyboardShortcut("l", modifiers: [])
                        Button("") { onNextPage() }
                            .keyboardShortcut("j", modifiers: [])

                        Button("") { onPreviousPage() }
                            .keyboardShortcut(.leftArrow, modifiers: [])
                        Button("") { onPreviousPage() }
                            .keyboardShortcut(.upArrow, modifiers: [])
                        Button("") { onPreviousPage() }
                            .keyboardShortcut(.space, modifiers: [.shift])
                        Button("") { onPreviousPage() }
                            .keyboardShortcut("h", modifiers: [])
                        Button("") { onPreviousPage() }
                            .keyboardShortcut("k", modifiers: [])

                        // Help / Cheat sheet ('?')
                        if let onShowHelp {
                            Button("") { onShowHelp() }
                                .keyboardShortcut("?", modifiers: [])
                        }
                    }

                    // Universal Help / Shortcuts Sheet (⌘/)
                    if let onShowHelp {
                        Button("") { onShowHelp() }
                            .keyboardShortcut("/", modifiers: [.command])
                    }

                    // ── 3. SMART READING ENGINES (Command-Protected) ──

                    // Reflow Mode (⌘R, ⇧⌘R)
                    if let onToggleReflow {
                        Button("") { onToggleReflow() }
                            .keyboardShortcut("r", modifiers: [.command])
                        Button("") { onToggleReflow() }
                            .keyboardShortcut("r", modifiers: [.command, .shift])
                    }

                    // Speech & Narration / Read Aloud (⌘D, ⌥Space)
                    if let onToggleSpeech {
                        Button("") { onToggleSpeech() }
                            .keyboardShortcut("d", modifiers: [.command])
                        Button("") { onToggleSpeech() }
                            .keyboardShortcut(.space, modifiers: [.option])
                    }

                    // Stylus Highlighter Mode (⌘H, ⇧⌘H)
                    if let onToggleHighlighter {
                        Button("") { onToggleHighlighter() }
                            .keyboardShortcut("h", modifiers: [.command])
                        Button("") { onToggleHighlighter() }
                            .keyboardShortcut("h", modifiers: [.command, .shift])
                    }

                    // Inking / Pencil Markup (⌘M, ⇧⌘A)
                    if let onToggleMarkup {
                        Button("") { onToggleMarkup() }
                            .keyboardShortcut("m", modifiers: [.command])
                        Button("") { onToggleMarkup() }
                            .keyboardShortcut("a", modifiers: [.command, .shift])
                    }

                    // Study Notebook Controls (⌘N, ⌥⌘N, ⌘P, ⌥⌘V)
                    if let onToggleNotebook {
                        Button("") { onToggleNotebook() }
                            .keyboardShortcut("n", modifiers: [.command])
                        Button("") { onToggleNotebook() }
                            .keyboardShortcut("n", modifiers: [.command, .option])
                    }

                    // Stamp Current Page in Notebook (⌘P)
                    Button("") {
                        NotificationCenter.default.post(name: NSNotification.Name("InksyncPro.stampPageLink"), object: nil)
                    }
                    .keyboardShortcut("p", modifiers: [.command])

                    // Paste Quote into Notebook (⌥⌘V)
                    Button("") {
                        NotificationCenter.default.post(name: NSNotification.Name("InksyncPro.pasteQuoteToNotebook"), object: nil)
                    }
                    .keyboardShortcut("v", modifiers: [.command, .option])


                    // Table of Contents / Sidebar / Save Notes
                    if isTextEditingActive {
                        // When text editing in Notebook, ⌘S flushes save
                        Button("") {
                            NotificationCenter.default.post(name: NSNotification.Name("InksyncPro.saveNotes"), object: nil)
                        }
                        .keyboardShortcut("s", modifiers: [.command])

                        if let onToggleSidebar {
                            Button("") { onToggleSidebar() }
                                .keyboardShortcut("t", modifiers: [.command])
                            Button("") { onToggleSidebar() }
                                .keyboardShortcut("s", modifiers: [.command, .option])
                        }
                    } else {
                        // When reading, ⌘S, ⌘T, ⌥⌘S toggle Sidebar / Table of Contents
                        if let onToggleSidebar {
                            Button("") { onToggleSidebar() }
                                .keyboardShortcut("s", modifiers: [.command])
                            Button("") { onToggleSidebar() }
                                .keyboardShortcut("t", modifiers: [.command])
                            Button("") { onToggleSidebar() }
                                .keyboardShortcut("s", modifiers: [.command, .option])
                        }
                    }

                    // ── 4. ZOOM & VIEW CONTROLS ──
                    if let onZoomIn {
                        Button("") { onZoomIn() }
                            .keyboardShortcut("+", modifiers: [.command])
                        Button("") { onZoomIn() }
                            .keyboardShortcut("=", modifiers: [.command])
                    }

                    if let onZoomOut {
                        Button("") { onZoomOut() }
                            .keyboardShortcut("-", modifiers: [.command])
                    }

                    if let onResetZoom {
                        Button("") { onResetZoom() }
                            .keyboardShortcut("0", modifiers: [.command])
                    }

                    // ── 5. DISMISS / EXIT ──
                    Button("") { onDismiss() }
                        .keyboardShortcut(.escape, modifiers: [])
                    Button("") { onDismiss() }
                        .keyboardShortcut("w", modifiers: [.command])
                }
                .opacity(0)
                .allowsHitTesting(false)
            )
    }
}

// MARK: - View Extension

extension View {
    func readerKeyboardShortcuts(
        isEditingText: Bool = false,
        onNextPage: @escaping () -> Void,
        onPreviousPage: @escaping () -> Void,
        onToggleReflow: (() -> Void)? = nil,
        onToggleSpeech: (() -> Void)? = nil,
        onToggleHighlighter: (() -> Void)? = nil,
        onToggleMarkup: (() -> Void)? = nil,
        onToggleNotebook: (() -> Void)? = nil,
        onToggleSidebar: (() -> Void)? = nil,
        onZoomIn: (() -> Void)? = nil,
        onZoomOut: (() -> Void)? = nil,
        onResetZoom: (() -> Void)? = nil,
        onShowHelp: (() -> Void)? = nil,
        onDismiss: @escaping () -> Void
    ) -> some View {
        self.modifier(ReaderKeyboardShortcuts(
            isEditingText: isEditingText,
            onNextPage: onNextPage,
            onPreviousPage: onPreviousPage,
            onToggleReflow: onToggleReflow,
            onToggleSpeech: onToggleSpeech,
            onToggleHighlighter: onToggleHighlighter,
            onToggleMarkup: onToggleMarkup,
            onToggleNotebook: onToggleNotebook,
            onToggleSidebar: onToggleSidebar,
            onZoomIn: onZoomIn,
            onZoomOut: onZoomOut,
            onResetZoom: onResetZoom,
            onShowHelp: onShowHelp,
            onDismiss: onDismiss
        ))
    }
}

// MARK: - UIResponder Extension for Active Text Input Detection

extension UIResponder {
    /// True if any text field, text view, or web text element is currently first responder
    static var isTextInputActive: Bool {
        guard let keyWindow = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow }) else {
            return false
        }
        guard let responder = keyWindow.findActiveFirstResponder() else { return false }
        return responder is UITextView || responder is UITextField || responder is UISearchBar
    }
}

extension UIView {
    func findActiveFirstResponder() -> UIResponder? {
        if isFirstResponder { return self }
        for subview in subviews {
            if let responder = subview.findActiveFirstResponder() {
                return responder
            }
        }
        return nil
    }
}
