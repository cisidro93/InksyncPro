import AppIntents
import SwiftData
import SwiftUI

// MARK: - Resume Reading

struct ResumeReadingIntent: AppIntent {
    static var title: LocalizedStringResource = "Resume Last Read Comic"
    static var description = IntentDescription("Immediately opens the last comic you were reading in InksyncPro.")

    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: NSNotification.Name("InksyncResumeLastRead"), object: nil)
        return .result()
    }
}

// MARK: - Open Shelf

struct OpenShelfIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Global Shelf"
    static var description = IntentDescription("Opens InksyncPro and deploys the animated InkShelfComponent.")

    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: NSNotification.Name("InksyncOpenShelf"), object: nil)
        return .result()
    }
}

// MARK: - Open Specific Book

struct OpenSpecificBookIntent: AppIntent {
    static var title: LocalizedStringResource = "Open a Specific Comic"
    static var description = IntentDescription("Opens InksyncPro and jumps to a specific comic by title.")

    static var openAppWhenRun: Bool = true

    @Parameter(title: "Comic Title", description: "Part of the title to search for in your library.", requestValueDialog: "Which comic would you like to open?")
    var bookTitle: String

    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(
            name: NSNotification.Name("InksyncOpenBook"),
            object: nil,
            userInfo: ["searchTitle": bookTitle]
        )
        return .result(dialog: "Opening \(bookTitle) in InksyncPro.")
    }
}

// MARK: - Start Guided Panel Mode

struct StartGuidedModeIntent: AppIntent {
    static var title: LocalizedStringResource = "Read in Panel Mode"
    static var description = IntentDescription("Opens the last-read comic in Panel Navigation mode.")

    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(
            name: NSNotification.Name("InksyncResumeLastRead"),
            object: nil,
            userInfo: ["readingMode": "panelNavigation"]
        )
        return .result(dialog: "Opening in Panel Navigation mode.")
    }
}

// MARK: - Add Bookmark

struct AddBookmarkIntent: AppIntent {
    static var title: LocalizedStringResource = "Bookmark Current Page"
    static var description = IntentDescription("Adds a bookmark to the current page in any open comic.")

    static var openAppWhenRun: Bool = false   // Background-capable

    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: NSNotification.Name("InksyncAddBookmark"), object: nil)
        return .result(dialog: "Bookmark added.")
    }
}

// MARK: - Shortcuts Provider

struct InksyncShortcutsProvider: AppShortcutsProvider {
    @AppShortcutsBuilder
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ResumeReadingIntent(),
            phrases: [
                "Resume my comic in \(.applicationName)",
                "Read in \(.applicationName)",
                "Continue reading \(.applicationName)"
            ],
            shortTitle: "Resume Reading",
            systemImageName: "book.closed"
        )

        AppShortcut(
            intent: OpenShelfIntent(),
            phrases: [
                "Open my shelf in \(.applicationName)",
                "Show my shelf in \(.applicationName)"
            ],
            shortTitle: "Open Shelf",
            systemImageName: "books.vertical"
        )

        AppShortcut(
            intent: OpenSpecificBookIntent(),
            phrases: [
                "Search comic in \(.applicationName)",
                "Open a comic in \(.applicationName)"
            ],
            shortTitle: "Open Comic",
            systemImageName: "book.pages"
        )

        AppShortcut(
            intent: StartGuidedModeIntent(),
            phrases: [
                "Read panels in \(.applicationName)",
                "Panel mode in \(.applicationName)",
                "Guided reading in \(.applicationName)"
            ],
            shortTitle: "Panel Mode",
            systemImageName: "viewfinder"
        )

        AppShortcut(
            intent: AddBookmarkIntent(),
            phrases: [
                "Bookmark this page in \(.applicationName)",
                "Save my place in \(.applicationName)"
            ],
            shortTitle: "Add Bookmark",
            systemImageName: "bookmark.fill"
        )
    }
}
