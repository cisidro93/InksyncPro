import SwiftUI

// ============================================================================
// KeyboardShortcutsCheatSheetView
// ============================================================================
// Glassmorphic, categorized keyboard reference HUD for Apple Magic Keyboard,
// Smart Folio, and Bluetooth hardware keyboards.
// Discoverable via '?' or '⌘/', and through the native iPadOS ⌘-hold overlay.
// ============================================================================

struct KeyboardShortcutsCheatSheetView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Header Banner
                    headerCard

                    // 1. Reading & Navigation
                    shortcutSection(
                        title: "Reading & Navigation",
                        icon: "book.fill",
                        color: Color.inkBlue,
                        shortcuts: [
                            ("Next Page", ["Space", "→", "PageDown"]),
                            ("Previous Page", ["⇧ Space", "←", "PageUp"]),
                            ("Next Page (Split-Notebook Safe)", ["⌘ ]", "⌘ →"]),
                            ("Previous Page (Split-Notebook Safe)", ["⌘ [", "⌘ ←"]),
                            ("Zoom In / Out / Fit", ["⌘ +", "⌘ -", "⌘ 0"]),
                            ("Close Reader", ["Esc", "⌘ W"])
                        ]
                    )

                    // 2. Smart Engines & Tools
                    shortcutSection(
                        title: "Smart Reading Engines & Tools",
                        icon: "sparkles",
                        color: Color(hex: "#8b5cf6"),
                        shortcuts: [
                            ("Toggle Reflow Mode", ["⌘ R"]),
                            ("Read Aloud / Dictation", ["⌘ D", "⌥ Space"]),
                            ("Stylus Highlighter Mode", ["⇧ ⌘ H"]),
                            ("Inking & Markup Dock", ["⌘ M", "⇧ ⌘ A"]),
                            ("Study Notebook (Split/Sheet)", ["⌘ N"]),
                            ("Table of Contents / Sidebar", ["⌘ S", "⌘ T"])
                        ]
                    )

                    // 3. Study Notebook & Quoting
                    shortcutSection(
                        title: "Study Notebook & Quoting",
                        icon: "note.text",
                        color: Color(hex: "#f59e0b"),
                        shortcuts: [
                            ("Toggle Study Notebook", ["⌘ N"]),
                            ("Stamp Current Page Link", ["⌘ P"]),
                            ("Paste Formatted Book Quote", ["⌥ ⌘ V"]),
                            ("Metabolize as Dialectic Triad", ["⌥ ⌘ D"]),
                            ("Toggle Recall Curtain", ["⌥ ⌘ R"]),
                            ("Save Notes to Storage", ["⌘ S"]),
                            ("Dictate / Voice Note", ["⌘ D"])
                        ]
                    )

                    // 4. Library & Shelf Management
                    shortcutSection(
                        title: "Library & Shelves",
                        icon: "books.vertical.fill",
                        color: Color(hex: "#10b981"),
                        shortcuts: [
                            ("Move Highlight Ring", ["←", "↑", "→", "↓"]),
                            ("Open Highlighted Book", ["Return", "Space"]),
                            ("Cycle Shelf Tabs", ["[", "]"]),
                            ("Search Library", ["⌘ F"]),
                            ("Toggle Batch Mode", ["⌘ B"]),
                            ("Select All (in Batch Mode)", ["⌘ A"]),
                            ("Switch Tabs (Library/Convert/Settings)", ["⌘ 1", "⌘ 2", "⌘ 3"])
                        ]
                    )

                    // Pro Tip Card
                    proTipCard
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
            }
            .background(Theme.bg)
            .navigationTitle("Keyboard Shortcuts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundColor(Color.inkBlue)
                }
            }
        }
    }

    // MARK: - Components

    private var headerCard: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.inkBlue.opacity(0.15))
                    .frame(width: 52, height: 52)
                Image(systemName: "keyboard.fill")
                    .font(.system(size: 24))
                    .foregroundColor(Color.inkBlue)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("Magic Keyboard & Hardware Shortcuts")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundColor(Theme.text)
                Text("Navigate, read, and annotate without lifting a finger from the keyboard.")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }

    private func shortcutSection(
        title: String,
        icon: String,
        color: Color,
        shortcuts: [(String, [String])]
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(color)
                Text(title)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundColor(Theme.text)
            }
            .padding(.leading, 4)

            VStack(spacing: 0) {
                ForEach(shortcuts.indices, id: \.self) { index in
                    let item = shortcuts[index]
                    HStack {
                        Text(item.0)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(Theme.text)

                        Spacer()

                        HStack(spacing: 6) {
                            ForEach(item.1, id: \.self) { key in
                                Text(key)
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3.5)
                                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
                                    )
                                    .foregroundColor(Theme.text)
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)

                    if index < shortcuts.count - 1 {
                        Divider()
                            .padding(.leading, 14)
                    }
                }
            }
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
            )
        }
    }

    private var proTipCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "command")
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(Color(hex: "#8b5cf6"))

            VStack(alignment: .leading, spacing: 2) {
                Text("iPadOS Native Shortcuts Overlay")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(Theme.text)
                Text("Press and hold the ⌘ (Command) key on your keyboard for 1 second anywhere in the app to view the system HUD.")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
            }
        }
        .padding(14)
        .background(Color(hex: "#8b5cf6").opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(hex: "#8b5cf6").opacity(0.2), lineWidth: 0.5)
        )
    }
}
