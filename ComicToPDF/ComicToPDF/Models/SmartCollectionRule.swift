import SwiftUI

enum SmartCollectionRule: String, CaseIterable, Identifiable {
    case recentlyAdded = "Recently Added"
    case readingNow = "Reading Now"
    case allUnread = "All Unread"
    case manga = "Manga Mode"
    case completed = "Completed"
    
    var id: String { rawValue }
    
    var iconName: String {
        switch self {
        case .recentlyAdded: return "clock.fill"
        case .readingNow: return "book.fill"
        case .allUnread: return "book.closed.fill"
        case .manga: return "text.book.closed.fill"
        case .completed: return "checkmark.seal.fill"
        }
    }
    
    var tintColor: Color {
        switch self {
        case .recentlyAdded: return .blue
        case .readingNow: return .orange
        case .allUnread: return .red
        case .manga: return .purple
        case .completed: return .green
        }
    }
}
