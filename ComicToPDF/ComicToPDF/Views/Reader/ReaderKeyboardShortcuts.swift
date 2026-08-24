import SwiftUI

/// ViewModifier providing comprehensive hardware keyboard, Apple Magic Keyboard,
/// and Bluetooth Page Turner / Pedal (PageFlip, AirTurn, Coda Stomp) shortcuts.
struct ReaderKeyboardShortcuts: ViewModifier {
    var onNextPage: () -> Void
    var onPreviousPage: () -> Void
    var onToggleMarkup: (() -> Void)? = nil
    var onToggleNotebook: (() -> Void)? = nil
    var onToggleSidebar: (() -> Void)? = nil
    var onZoomIn: (() -> Void)? = nil
    var onZoomOut: (() -> Void)? = nil
    var onResetZoom: (() -> Void)? = nil
    var onDismiss: () -> Void

    func body(content: Content) -> some View {
        content
            .background(
                Group {
                    // ── Next Page (Right Arrow, Down Arrow, Space, PageDown, 'j', 'l') ──
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

                    // ── Previous Page (Left Arrow, Up Arrow, Shift+Spacebar, 'h', 'k') ──
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

                    // ── Inking / Markup Toggle ('m', ⌘M) ──
                    if let onToggleMarkup {
                        Button("") { onToggleMarkup() }
                            .keyboardShortcut("m", modifiers: [])
                        Button("") { onToggleMarkup() }
                            .keyboardShortcut("m", modifiers: [.command])
                    }

                    // ── Study Notebook ('n', ⌘N) ──
                    if let onToggleNotebook {
                        Button("") { onToggleNotebook() }
                            .keyboardShortcut("n", modifiers: [])
                        Button("") { onToggleNotebook() }
                            .keyboardShortcut("n", modifiers: [.command])
                    }

                    // ── Table of Contents / Sidebar ('t', ⌘T) ──
                    if let onToggleSidebar {
                        Button("") { onToggleSidebar() }
                            .keyboardShortcut("t", modifiers: [])
                        Button("") { onToggleSidebar() }
                            .keyboardShortcut("t", modifiers: [.command])
                    }

                    // ── Zoom In / Larger Font (⌘+, +, =) ──
                    if let onZoomIn {
                        Button("") { onZoomIn() }
                            .keyboardShortcut("+", modifiers: [.command])
                        Button("") { onZoomIn() }
                            .keyboardShortcut("=", modifiers: [.command])
                    }

                    // ── Zoom Out / Smaller Font (⌘-, -) ──
                    if let onZoomOut {
                        Button("") { onZoomOut() }
                            .keyboardShortcut("-", modifiers: [.command])
                    }

                    // ── Reset Zoom / Default Font (⌘0, 0) ──
                    if let onResetZoom {
                        Button("") { onResetZoom() }
                            .keyboardShortcut("0", modifiers: [.command])
                    }

                    // ── Dismiss / Exit Reader (Escape, ⌘W) ──
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

extension View {
    func readerKeyboardShortcuts(
        onNextPage: @escaping () -> Void,
        onPreviousPage: @escaping () -> Void,
        onToggleMarkup: (() -> Void)? = nil,
        onToggleNotebook: (() -> Void)? = nil,
        onToggleSidebar: (() -> Void)? = nil,
        onZoomIn: (() -> Void)? = nil,
        onZoomOut: (() -> Void)? = nil,
        onResetZoom: (() -> Void)? = nil,
        onDismiss: @escaping () -> Void
    ) -> some View {
        self.modifier(ReaderKeyboardShortcuts(
            onNextPage: onNextPage,
            onPreviousPage: onPreviousPage,
            onToggleMarkup: onToggleMarkup,
            onToggleNotebook: onToggleNotebook,
            onToggleSidebar: onToggleSidebar,
            onZoomIn: onZoomIn,
            onZoomOut: onZoomOut,
            onResetZoom: onResetZoom,
            onDismiss: onDismiss
        ))
    }
}
