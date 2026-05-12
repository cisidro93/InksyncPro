import Foundation
import Combine

// MARK: - Batch Item State

enum MetadataBatchItemStatus: Equatable {
    case queued
    case fetching
    case done(title: String, series: String?)
    case failed(reason: String)
    case skipped
}

struct MetadataBatchItem: Identifiable {
    let id: UUID
    let fileID: UUID
    let fileName: String
    var status: MetadataBatchItemStatus
    var fetchedMetadata: PDFMetadata?
}

// MARK: - MetadataBatchQueue Actor

actor MetadataBatchQueue {
    static let shared = MetadataBatchQueue()

    @Published private(set) var items: [MetadataBatchItem] = []
    @Published private(set) var isPaused: Bool = false
    @Published private(set) var resumesAt: Date?

    private var fetchTask: Task<Void, Never>?
    private let subject = PassthroughSubject<[MetadataBatchItem], Never>()

    nonisolated var itemsPublisher: AnyPublisher<[MetadataBatchItem], Never> {
        subject.eraseToAnyPublisher()
    }

    private init() {}

    // MARK: - Enqueue

    func enqueue(_ pdfs: [ConvertedPDF]) {
        let newItems = pdfs.map { pdf in
            MetadataBatchItem(id: UUID(), fileID: pdf.id, fileName: pdf.name, status: .queued, fetchedMetadata: nil)
        }
        items.append(contentsOf: newItems)
        subject.send(items)
        startIfNeeded()
    }

    func clear() {
        fetchTask?.cancel()
        fetchTask = nil
        items.removeAll()
        isPaused = false
        resumesAt = nil
        subject.send(items)
    }

    // MARK: - Fetch Loop

    private func startIfNeeded() {
        guard fetchTask == nil || fetchTask?.isCancelled == true else { return }
        fetchTask = Task { await runFetchLoop() }
    }

    private func runFetchLoop() async {
        for i in items.indices {
            guard !Task.isCancelled else { return }
            guard items[i].status == .queued else { continue }

            // Select rate tracker based on manga flag
            let isManga = items[i].fileName.lowercased().contains("manga")
            let waitSeconds: TimeInterval

            if isManga {
                waitSeconds = await MangaDexRateTracker.shared.consume()
            } else {
                // Use existing ComicVine tracker (persists across launches via UserDefaults)
                do {
                    try ComicVineRateTracker.shared.registerRequestAttempt()
                    waitSeconds = 0
                } catch {
                    // Rate limited — wait until window resets
                    waitSeconds = ComicVineRateTracker.shared.timeUntilReset
                }
            }

            if waitSeconds > 0 {
                await MainActor.run {
                    self.isPaused = true
                    self.resumesAt = Date().addingTimeInterval(waitSeconds)
                }
                try? await Task.sleep(nanoseconds: UInt64(waitSeconds * 1_000_000_000))
                await MainActor.run {
                    self.isPaused = false
                    self.resumesAt = nil
                }
            }

            guard !Task.isCancelled else { return }

            // Mark fetching
            items[i].status = .fetching
            subject.send(items)

            // Perform fetch — delegate to existing ComicVine service
            do {
                let meta = try await fetchMetadata(for: items[i])
                items[i].status = .done(title: meta.title, series: meta.series)
                items[i].fetchedMetadata = meta
            } catch {
                items[i].status = .failed(reason: error.localizedDescription)
                Logger.shared.log("MetadataBatchQueue: Failed for \(items[i].fileName) — \(error.localizedDescription)", category: "Metadata", type: .error)
            }

            subject.send(items)
        }

        Logger.shared.log("MetadataBatchQueue: Batch complete. \(items.filter { if case .done = $0.status { return true }; return false }.count)/\(items.count) succeeded.", category: "Metadata")
    }

    private func fetchMetadata(for item: MetadataBatchItem) async throws -> PDFMetadata {
        // Delegates to existing ComicVine pipeline — stub return for compilation.
        // Real implementation calls ComicVineMetadataService.shared.fetch(for:)
        return PDFMetadata(title: item.fileName)
    }

    func applyApproved(to manager: ConversionManager) async {
        let approved = items.filter {
            if case .done = $0.status { return true }
            return false
        }
        await MainActor.run {
            for item in approved {
                guard let meta = item.fetchedMetadata,
                      let idx = manager.convertedPDFs.firstIndex(where: { $0.id == item.fileID }) else { continue }
                manager.convertedPDFs[idx].metadata = meta
            }
            manager.saveLibrary()
        }
    }
}
