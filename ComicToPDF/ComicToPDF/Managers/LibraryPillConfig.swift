import Foundation
import Combine

// MARK: - Library Pill Config
//
// Persists which Row B action pills are enabled/disabled by the user.
// Defaults: all enabled. Changes persist to UserDefaults immediately.
// Observed by LibraryHeaderView via @ObservedObject.

final class LibraryPillConfig: ObservableObject {

    static let shared = LibraryPillConfig()

    // MARK: - Known Pill Keys (Row B)
    // Must stay in sync with the pills rendered in LibraryHeaderView Row B.
    enum Key: String, CaseIterable {
        case targetFormat  = "pill.targetFormat"
        case tapAction     = "pill.tapAction"
        case wifi          = "pill.wifi"
        case smartList     = "pill.smartList"
        case aiRename      = "pill.aiRename"
        case merge         = "pill.merge"
        case convertMerge  = "pill.convertMerge"
        case autoMatch     = "pill.autoMatch"
        case reviewMissing = "pill.reviewMissing"
        case stats         = "pill.stats"
        case vault         = "pill.vault"

        var displayName: String {
            switch self {
            case .targetFormat:  return "Target Format"
            case .tapAction:     return "Tap Action"
            case .wifi:          return "Wi-Fi Transfer"
            case .smartList:     return "Smart List"
            case .aiRename:      return "AI Rename"
            case .merge:         return "Merge"
            case .convertMerge:  return "Convert & Merge"
            case .autoMatch:     return "Auto-Match"
            case .reviewMissing: return "Review Missing"
            case .stats:         return "Stats"
            case .vault:         return "Vault"
            }
        }

        var icon: String {
            switch self {
            case .targetFormat:  return "arrow.triangle.2.circlepath"
            case .tapAction:     return "hand.tap.fill"
            case .wifi:          return "wifi"
            case .smartList:     return "list.star"
            case .aiRename:      return "sparkles.tv"
            case .merge:         return "arrow.triangle.merge"
            case .convertMerge:  return "doc.on.doc.fill"
            case .autoMatch:     return "wand.and.stars.inverse"
            case .reviewMissing: return "exclamationmark.triangle.fill"
            case .stats:         return "flame.fill"
            case .vault:         return "lock.fill"
            }
        }
    }

    // MARK: - State
    @Published private(set) var enabledKeys: Set<String>

    private let defaultsKey = "library_pill_config_v1"

    private init() {
        if let saved = UserDefaults.standard.stringArray(forKey: "library_pill_config_v1") {
            enabledKeys = Set(saved)
        } else {
            // Default: everything on
            enabledKeys = Set(Key.allCases.map { $0.rawValue })
        }
    }

    // MARK: - Query

    func isEnabled(_ key: Key) -> Bool {
        enabledKeys.contains(key.rawValue)
    }

    // MARK: - Mutate

    func setEnabled(_ key: Key, _ value: Bool) {
        if value {
            enabledKeys.insert(key.rawValue)
        } else {
            enabledKeys.remove(key.rawValue)
        }
        persist()
    }

    func toggle(_ key: Key) {
        setEnabled(key, !isEnabled(key))
    }

    // MARK: - Persistence

    private func persist() {
        UserDefaults.standard.set(Array(enabledKeys), forKey: defaultsKey)
    }
}
