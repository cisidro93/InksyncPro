//
//  InksyncIntents.swift
//  InksyncPro
//
//  App Intents & Siri Shortcuts Integration
//  Cold-Launch Proofed via AppRouter.shared.pendingIntentAction
//

import AppIntents
import SwiftData
import SwiftUI

// MARK: - Resume Reading

struct ResumeReadingIntent: AppIntent {
    static let title: LocalizedStringResource = "Resume Last Read Title"
    static let description = IntentDescription("Immediately opens the last book, manga, or comic you were reading in InksyncPro.")

    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRouter.shared.pendingIntentAction = .resumeLastRead(mode: nil)
        NotificationCenter.default.post(name: NSNotification.Name("InksyncResumeLastRead"), object: nil)
        return .result()
    }
}

// MARK: - Open Shelf

struct OpenShelfIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Global Shelf"
    static let description = IntentDescription("Opens InksyncPro and deploys the animated InkShelf.")

    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRouter.shared.pendingIntentAction = .openShelf
        NotificationCenter.default.post(name: NSNotification.Name("InksyncOpenShelf"), object: nil)
        return .result()
    }
}

// MARK: - Open Specific Book

struct OpenSpecificBookIntent: AppIntent {
    static let title: LocalizedStringResource = "Open a Specific Title"
    static let description = IntentDescription("Opens InksyncPro and jumps to a specific book, comic, or manga by title.")

    static let openAppWhenRun: Bool = true

    @Parameter(title: "Title", description: "Part of the title to search for in your library.", requestValueDialog: "Which book or comic would you like to open?")
    var bookTitle: String

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRouter.shared.pendingIntentAction = .openBook(title: bookTitle)
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
    static let title: LocalizedStringResource = "Read in Panel Mode"
    static let description = IntentDescription("Opens the last-read comic in Panel Navigation mode.")

    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRouter.shared.pendingIntentAction = .resumeLastRead(mode: "panelNavigation")
        NotificationCenter.default.post(
            name: NSNotification.Name("InksyncResumeLastRead"),
            object: nil,
            userInfo: ["readingMode": "panelNavigation"]
        )
        return .result(dialog: "Opening in Panel Navigation mode.")
    }
}

// MARK: - Start RSVP Speed Reading

struct StartRSVPIntent: AppIntent {
    static let title: LocalizedStringResource = "Speed Read with RSVP"
    static let description = IntentDescription("Launches RSVP speed reading mode for your current book in InksyncPro.")

    static let openAppWhenRun: Bool = true

    @Parameter(title: "Book Title", description: "Optional title to speed read.", default: nil)
    var bookTitle: String?

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRouter.shared.pendingIntentAction = .startRSVP(title: bookTitle)
        NotificationCenter.default.post(
            name: NSNotification.Name("InksyncStartRSVP"),
            object: nil,
            userInfo: bookTitle != nil ? ["searchTitle": bookTitle!] : nil
        )
        return .result(dialog: "Starting RSVP speed reading in InksyncPro.")
    }
}

// MARK: - Start Narration (TTS)

struct StartNarrationIntent: AppIntent {
    static let title: LocalizedStringResource = "Read Aloud with TTS"
    static let description = IntentDescription("Begins audio narration of the current book in InksyncPro.")

    static let openAppWhenRun: Bool = true

    @Parameter(title: "Book Title", description: "Optional title to narrate.", default: nil)
    var bookTitle: String?

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRouter.shared.pendingIntentAction = .startNarration(title: bookTitle)
        NotificationCenter.default.post(
            name: NSNotification.Name("InksyncStartNarration"),
            object: nil,
            userInfo: bookTitle != nil ? ["searchTitle": bookTitle!] : nil
        )
        return .result(dialog: "Starting narration in InksyncPro.")
    }
}

// MARK: - Add Bookmark

struct AddBookmarkIntent: AppIntent {
    static let title: LocalizedStringResource = "Bookmark Current Page"
    static let description = IntentDescription("Adds a bookmark to the current page in any open title.")

    static let openAppWhenRun: Bool = false   // Background-capable

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRouter.shared.pendingIntentAction = .addBookmark
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
                "Resume reading in \(.applicationName)",
                "Resume my comic in \(.applicationName)",
                "Resume my book in \(.applicationName)",
                "Continue my manga in \(.applicationName)",
                "Continue reading \(.applicationName)"
            ],
            shortTitle: "Resume Reading",
            systemImageName: "book.closed"
        )

        AppShortcut(
            intent: OpenShelfIntent(),
            phrases: [
                "Open my shelf in \(.applicationName)",
                "Show my shelf in \(.applicationName)",
                "Open my library in \(.applicationName)"
            ],
            shortTitle: "Open Shelf",
            systemImageName: "books.vertical"
        )

        AppShortcut(
            intent: OpenSpecificBookIntent(),
            phrases: [
                "Open a book in \(.applicationName)",
                "Open a comic in \(.applicationName)",
                "Open manga in \(.applicationName)",
                "Search comic in \(.applicationName)"
            ],
            shortTitle: "Open Title",
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
            intent: StartRSVPIntent(),
            phrases: [
                "Speed read in \(.applicationName)",
                "Start RSVP in \(.applicationName)",
                "RSVP read in \(.applicationName)"
            ],
            shortTitle: "Speed Read",
            systemImageName: "bolt.fill"
        )

        AppShortcut(
            intent: StartNarrationIntent(),
            phrases: [
                "Read aloud in \(.applicationName)",
                "Start narration in \(.applicationName)",
                "Narrate my book in \(.applicationName)"
            ],
            shortTitle: "Read Aloud",
            systemImageName: "speaker.wave.2.fill"
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
