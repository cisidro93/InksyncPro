import SwiftUI

enum SmartCollectionRule: String, CaseIterable, Identifiable {
    case recentlyAdded = "Recently Added"
    case readingNow    = "Reading Now"
    case allUnread     = "All Unread"
    case completed     = "Completed"
    case onDrive       = "On Drive"
    case cloudLibrary  = "Cloud Library"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .recentlyAdded: return "clock.fill"
        case .readingNow:    return "book.fill"
        case .allUnread:     return "book.closed.fill"
        case .completed:     return "checkmark.seal.fill"
        case .onDrive:       return "externaldrive.fill"
        case .cloudLibrary:  return "cloud.fill"
        }
    }

    var tintColor: Color {
        switch self {
        case .recentlyAdded: return .blue
        case .readingNow:    return .orange
        case .allUnread:     return .red
        case .completed:     return .green
        case .onDrive:       return Color(hex: "#6AB0F5")  // steel-blue
        case .cloudLibrary:  return Color(hex: "#A78BFA")  // violet
        }
    }
}

