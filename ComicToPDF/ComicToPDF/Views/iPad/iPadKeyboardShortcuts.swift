import SwiftUI

struct iPadKeyboardShortcuts: ViewModifier {
    @Binding var selectedTab: Int
    @Binding var showImport: Bool

    func body(content: Content) -> some View {
        content
            // ⌘1–4 for tab switching
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIApplication.didBecomeActiveNotification
                )
            ) { _ in }
            // Note: keyboard shortcuts in SwiftUI TabView are handled natively
            // on iOS 16+ when using .tabViewStyle(.sidebarAdaptable)
            // For iOS 16-17 fallback, wire ⌘1-4 here:
            .background(
                Group {
                    Button("") { selectedTab = 0 }
                        .keyboardShortcut("1", modifiers: .command)
                    Button("") { selectedTab = 1 }
                        .keyboardShortcut("2", modifiers: .command)
                    Button("") { selectedTab = 2 }
                        .keyboardShortcut("3", modifiers: .command)
                    Button("") { selectedTab = 3 }
                        .keyboardShortcut("4", modifiers: .command)
                    Button("") { showImport = true }
                        .keyboardShortcut("o", modifiers: .command) // ⌘O = Open file
                }
                .opacity(0)   // invisible, just for shortcut registration
            )
    }
}
