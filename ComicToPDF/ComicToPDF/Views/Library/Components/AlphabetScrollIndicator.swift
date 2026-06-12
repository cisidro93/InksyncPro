import SwiftUI

// MARK: - Floating Alphabet Scroll Indicator

/// A transient floating letter indicator that appears on the trailing edge
/// while the user is scrolling. It shows the first letter of the currently
/// visible item and fades out 1.5 seconds after scrolling stops.
///
/// Usage: Overlay this on top of the scroll view. The parent passes
/// the current "anchor letter" derived from the visible item index.
///
/// Unlike a persistent alphabet ribbon, this does NOT take up permanent
/// horizontal space — it only overlays during active scrolling.
struct AlphabetScrollIndicator: View {
    /// The letter currently visible at the top of the scroll view.
    /// Pass `nil` when not scrolling to trigger the fade-out.
    var letter: String?

    /// Whether the indicator should be visible (parent drives this).
    var isVisible: Bool

    var body: some View {
        HStack {
            Spacer()
            VStack {
                Spacer()
                if let letter, isVisible {
                    Text(letter)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(.ultraThinMaterial)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(Color.inkTextPrimary.opacity(0.25))
                                )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(.white.opacity(0.15), lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                        .transition(.scale(scale: 0.7).combined(with: .opacity))
                }
                Spacer()
            }
        }
        .padding(.trailing, 12)
        .allowsHitTesting(false)   // never intercepts taps — transparent overlay
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: letter)
        .animation(.easeOut(duration: 0.3), value: isVisible)
    }
}

// MARK: - Scroll Indicator Controller

/// Manages the transient alphabet indicator state for a scroll view.
/// Expose `currentLetter` and `isIndicatorVisible` as bindings to pass
/// into `AlphabetScrollIndicator`. Call `didScroll(to:)` from your
/// scroll offset tracker.
@Observable @MainActor
final class AlphabetIndicatorController {

    var currentLetter: String = ""
    var isIndicatorVisible: Bool = false

    private var hideTask: Task<Void, Never>?

    /// Call from scroll offset tracker whenever scroll position changes.
    /// Pass the title of the first visible item so we can extract its first letter.
    func didScroll(firstVisibleTitle: String) {
        let letter = String(firstVisibleTitle.prefix(1).uppercased())
        guard !letter.isEmpty else { return }

        currentLetter = letter
        withAnimation { isIndicatorVisible = true }

        // Reset and restart the auto-hide timer
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            withAnimation { isIndicatorVisible = false }
        }
    }

    func hide() {
        hideTask?.cancel()
        withAnimation { isIndicatorVisible = false }
    }
}

// MARK: - Pill Customization Persistence

/// Keys that identify each optional pill button in the library header.
enum LibraryPillKey: String, CaseIterable, Identifiable {
    case targetFormat  = "targetFormat"
    case tapAction     = "tapAction"
    case wifi          = "wifi"
    case smartList     = "smartList"
    case aiRename      = "aiRename"
    case merge         = "merge"
    case convertMerge  = "convertMerge"
    case autoMatch     = "autoMatch"
    case reviewMissing = "reviewMissing"
    case stats         = "stats"
    case vault         = "vault"
    case metadataSpreadsheet = "metadataSpreadsheet"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .targetFormat:  return "Target Format"
        case .tapAction:     return "Tap Action"
        case .wifi:          return "Wi-Fi"
        case .smartList:     return "Smart List"
        case .aiRename:      return "AI Rename"
        case .merge:         return "Merge"
        case .convertMerge:  return "Convert & Merge"
        case .autoMatch:     return "Auto-Match"
        case .reviewMissing: return "Review Missing"
        case .stats:         return "Stats"
        case .vault:         return "Vault"
        case .metadataSpreadsheet: return "Grid Editor"
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
        case .convertMerge:  return "arrow.triangle.2.circlepath.doc"
        case .autoMatch:     return "wand.and.stars.inverse"
        case .reviewMissing: return "exclamationmark.triangle.fill"
        case .stats:         return "flame.fill"
        case .vault:         return "lock.fill"
        case .metadataSpreadsheet: return "tablecells"
        }
    }
}

// MARK: - Pill Config Store

/// Stores which pill buttons are enabled using AppStorage.
/// Default: all enabled (matches current behaviour).
@MainActor
final class LibraryPillConfig: ObservableObject {
    static let shared = LibraryPillConfig()

    private let storageKey = "libraryPillConfig_v1"

    /// Set of disabled pill keys. Empty = all visible.
    @Published var disabledPills: Set<LibraryPillKey> = []

    init() {
        if let data = UserDefaults.standard.data(forKey: storageKey) {
            let optSaved = try? JSONDecoder().decode(Set<String>.self, from: data)
            if let saved = optSaved {
                disabledPills = Set(saved.compactMap { LibraryPillKey(rawValue: $0) })
            }
        }
    }

    func isEnabled(_ key: LibraryPillKey) -> Bool {
        !disabledPills.contains(key)
    }

    func toggle(_ key: LibraryPillKey) {
        if disabledPills.contains(key) {
            disabledPills.remove(key)
        } else {
            disabledPills.insert(key)
        }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(disabledPills.map(\.rawValue)) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}

// MARK: - Pill Customization Sheet

/// A bottom sheet that lets users toggle individual pill buttons in the library header.
/// Triggered by long-pressing any pill in Row B.
struct LibraryPillCustomizeSheet: View {
    @ObservedObject var config = LibraryPillConfig.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(LibraryPillKey.allCases) { key in
                        Toggle(isOn: Binding(
                            get: { config.isEnabled(key) },
                            set: { _ in
                                withAnimation { config.toggle(key) }
                            }
                        )) {
                            Label {
                                Text(key.displayName)
                                    .font(.system(size: 15))
                                    .foregroundStyle(Color.primary)
                            } icon: {
                                Image(systemName: key.icon)
                                    .foregroundStyle(Color.inkAmber)
                                    .frame(width: 22)
                            }
                        }
                        .tint(Color.inkAmber)
                    }
                } header: {
                    Text("Show or hide toolbar actions. Changes apply immediately.")
                        .font(.system(size: 12))
                        .textCase(.none)
                        .foregroundStyle(Color.secondary)
                }
            }
            .navigationTitle("Customize Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.inkAmber)
                }
            }
        }
    }
}
