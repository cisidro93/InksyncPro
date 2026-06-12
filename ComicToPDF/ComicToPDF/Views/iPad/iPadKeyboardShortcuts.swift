import SwiftUI

struct iPadKeyboardShortcuts: ViewModifier {
    @Binding var selectedTab: Int
    @Binding var showImport: Bool
    @ObservedObject var router: AppRouter

    // Bindings to sheet states in ContentView
    @Binding var showingSettingsInspector: Bool
    @Binding var showingBatchMergeReorder: Bool
    @Binding var pdfToShare: ConvertedPDF?
    @Binding var pdfToEdit: ConvertedPDF?

    init(
        selectedTab: Binding<Int>,
        showImport: Binding<Bool>,
        showingSettingsInspector: Binding<Bool>,
        showingBatchMergeReorder: Binding<Bool>,
        pdfToShare: Binding<ConvertedPDF?>,
        pdfToEdit: Binding<ConvertedPDF?>
    ) {
        self._selectedTab = selectedTab
        self._showImport = showImport
        self._showingSettingsInspector = showingSettingsInspector
        self._showingBatchMergeReorder = showingBatchMergeReorder
        self._pdfToShare = pdfToShare
        self._pdfToEdit = pdfToEdit
        self.router = AppRouter.shared
    }

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
                    Button("") { showImport = true }
                        .keyboardShortcut("o", modifiers: .command) // ⌘O = Open file
                    Button("") {
                        handleGlobalDismissal()
                    }
                    .keyboardShortcut("w", modifiers: .command) // ⌘W = Close sheet / modal
                    Button("") {
                        handleGlobalBack()
                    }
                    .keyboardShortcut("[", modifiers: .command) // ⌘[ = Back
                }
                .opacity(0)   // invisible, just for shortcut registration
            )
    }

    private func handleGlobalDismissal() {
        if router.activeSheet != nil {
            router.dismissSheet()
        } else if router.activeFullScreen != nil {
            router.dismissFullScreen()
        } else if showingSettingsInspector {
            showingSettingsInspector = false
        } else if showingBatchMergeReorder {
            showingBatchMergeReorder = false
        } else if pdfToShare != nil {
            pdfToShare = nil
        } else if pdfToEdit != nil {
            pdfToEdit = nil
        }
    }

    private func handleGlobalBack() {
        if !router.path.isEmpty {
            router.path.removeLast()
        }
    }
}
