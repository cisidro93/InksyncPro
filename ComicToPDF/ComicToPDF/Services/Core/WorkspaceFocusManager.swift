import Foundation
import Combine

/// Manages the curated set of PDFs the user has explicitly sent to the Work Area.
/// Persists IDs in AppStorage (UserDefaults) so they survive app restarts.
/// The Work Area only shows pinned files, keeping the canvas focused on the active project.
@MainActor
final class WorkspaceFocusManager: ObservableObject {
    static let shared = WorkspaceFocusManager()

    private let defaultsKey = "com.inksyncpro.workspacePinnedIDs"

    /// Ordered list of pinned PDF IDs — order reflects when they were added.
    @Published private(set) var pinnedIDs: [UUID] = []

    private init() {
        load()
    }

    // MARK: - Public API

    var isEmpty: Bool { pinnedIDs.isEmpty }
    var count: Int { pinnedIDs.count }

    func isPinned(_ pdf: ConvertedPDF) -> Bool {
        pinnedIDs.contains(pdf.id)
    }

    /// Add a PDF to the Work Area focus list.
    func pin(_ pdf: ConvertedPDF) {
        guard !pinnedIDs.contains(pdf.id) else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
            pinnedIDs.append(pdf.id)
        }
        save()
        HapticEngine.success()
        Logger.shared.log("Pinned \"\(pdf.name)\" to Work Area", category: "Workspace")
    }

    /// Remove a single PDF from the focus list.
    func unpin(_ pdf: ConvertedPDF) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
            pinnedIDs.removeAll { $0 == pdf.id }
        }
        save()
    }

    /// Reorder via drag-to-reorder (list editor).
    func move(fromOffsets: IndexSet, toOffset: Int) {
        pinnedIDs.move(fromOffsets: fromOffsets, toOffset: toOffset)
        save()
    }

    /// Remove a set of IDs (used when a PDF is deleted from the library).
    func purge(ids: Set<UUID>) {
        let before = pinnedIDs.count
        pinnedIDs.removeAll { ids.contains($0) }
        if pinnedIDs.count != before { save() }
    }

    /// Clear all pinned files (e.g. when starting a new project session).
    func clearAll() {
        withAnimation { pinnedIDs.removeAll() }
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let stored = UserDefaults.standard.array(forKey: defaultsKey) as? [String] else { return }
        pinnedIDs = stored.compactMap { UUID(uuidString: $0) }
    }

    private func save() {
        UserDefaults.standard.set(pinnedIDs.map { $0.uuidString }, forKey: defaultsKey)
    }
}
