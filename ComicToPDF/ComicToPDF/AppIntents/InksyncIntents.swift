import AppIntents
import SwiftData
import SwiftUI

struct ResumeReadingIntent: AppIntent {
    static var title: LocalizedStringResource = "Resume Last Read Comic"
    static var description = IntentDescription("Immediately opens the last comic you were reading in InksyncPro.")
    
    // Automatically launches the app
    static var openAppWhenRun: Bool = true
    
    @MainActor
    func perform() async throws -> some IntentResult {
        // Here we would ideally fetch the last read InkDocument from SwiftData
        // For Phase 4 demonstration, we broadcast an internal Notification that the App structure listens for.
        NotificationCenter.default.post(name: NSNotification.Name("InksyncResumeLastRead"), object: nil)
        return .result()
    }
}

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

// Register the Shortcuts App Integration
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
    }
}
