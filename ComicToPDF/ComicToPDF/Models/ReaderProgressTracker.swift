import Foundation

struct ReadingProgress: Codable, Identifiable {
    var id: UUID { pdfID }
    var pdfID: UUID
    var lastOpenedAt: Date
    var currentPageIndex: Int           // comics and documents
    var currentChapterIndex: Int?       // books
    var currentChapterOffset: Double?   // 0.0–1.0 scroll position in chapter
    var totalPagesRead: Int             // cumulative, never decrements
    var completionFraction: Double      // 0.0–1.0
    var readingSessionDates: [Date]     // for streak calculation
    var estimatedMinutesRemaining: Int? // books only
}

@MainActor
class ReaderProgressTracker: ObservableObject {
    static let shared = ReaderProgressTracker()
    
    @Published private var progressMap: [UUID: ReadingProgress] = [:]
    
    private let queue = DispatchQueue(label: "com.inksync.ProgressTracker", qos: .userInitiated)
    private let fileManager = FileManager.default
    private lazy var progressDir: URL = {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("progress")
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }()
    
    private init() {
        loadAll()
    }
    
    func progress(for pdfID: UUID) -> ReadingProgress? {
        return progressMap[pdfID]
    }
    
    func update(_ progress: ReadingProgress) {
        progressMap[progress.pdfID] = progress
        save(pdfID: progress.pdfID)
    }
    
    func markComplete(pdfID: UUID) {
        guard var prog = progressMap[pdfID] else { return }
        prog.completionFraction = 1.0
        prog.lastOpenedAt = Date()
        update(prog)
    }
    
    func deleteProgress(for pdfID: UUID) {
        progressMap.removeValue(forKey: pdfID)
        let fileURL = progressDir.appendingPathComponent("\(pdfID.uuidString).json")
        queue.async {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }
    
    // MARK: - Stats
    
    func readingStreak() -> Int {
        // Calculate consecutive days reading
        let allDates = progressMap.values.flatMap { $0.readingSessionDates }
        guard !allDates.isEmpty else { return 0 }
        
        // Normalize to start of day
        let calendar = Calendar.current
        let uniqueDays = Set(allDates.map { calendar.startOfDay(for: $0) }).sorted(by: >)
        
        var streak = 0
        var expectedDate = calendar.startOfDay(for: Date())
        
        // If they haven't read today, check if they read yesterday (streak is still alive)
        if uniqueDays.first != expectedDate {
            if let yesterday = calendar.date(byAdding: .day, value: -1, to: expectedDate),
               uniqueDays.first == yesterday {
                expectedDate = yesterday
            } else {
                return 0 // Didn't read today or yesterday
            }
        }
        
        for date. in uniqueDays {
            if date == expectedDate {
                streak += 1
                expectedDate = calendar.date(byAdding: .day, value: -1, to: expectedDate) ?? expectedDate
            } else {
                break
            }
        }
        return streak
    }
    
    func totalPagesThisWeek() -> Int {
        let calendar = Calendar.current
        guard let weekAgo = calendar.date(byAdding: .day, value: -7, to: Date()) else { return 0 }
        
        // Note: For an accurate "pages this week", we would need a history of pages read per day.
        // As a proxy based on the model, we filter for sessions this week, but since totalPagesRead
        // is cumulative, we can't easily isolate the week's delta without storing an explicit log.
        // For now, we'll return a rough metric: total pages read of books opened this week.
        // Real implementation would log `(Date, pagesRead)` events.
        
        let recentlyOpened = progressMap.values.filter { $0.lastOpenedAt >= weekAgo }
        return recentlyOpened.reduce(0) { $0 + $1.totalPagesRead }
    }
    
    func seriesCompletion(collectionID: UUID, manager: ConversionManager) -> Double {
        let seriesBooks = manager.convertedPDFs.filter { $0.collectionId == collectionID }
        guard !seriesBooks.isEmpty else { return 0 }
        
        let totalFraction = seriesBooks.reduce(0.0) { sum, book in
            sum + (progressMap[book.id]?.completionFraction ?? 0.0)
        }
        
        return totalFraction / Double(seriesBooks.count)
    }
    
    // MARK: - Persistence
    
    private func loadAll() {
        queue.async { [weak self] in
            guard let self = self else { return }
            do {
                let files = try self.fileManager.contentsOfDirectory(at: self.progressDir, includingPropertiesForKeys: nil)
                var loadedMap: [UUID: ReadingProgress] = [:]
                
                for file in files where file.pathExtension == "json" {
                    if let uuid = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                       let data = try? Data(contentsOf: file),
                       let progress = try? JSONDecoder().decode(ReadingProgress.self, from: data) {
                        loadedMap[uuid] = progress
                    }
                }
                
                Task { @MainActor in
                    self.progressMap = loadedMap
                }
            } catch {
                print("Failed to load progress data: \(error)")
            }
        }
    }
    
    private func save(pdfID: UUID) {
        guard let progress = progressMap[pdfID] else { return }
        let fileURL = progressDir.appendingPathComponent("\(pdfID.uuidString).json")
        
        queue.async {
            do {
                let data = try JSONEncoder().encode(progress)
                try data.write(to: fileURL, options: .atomic)
            } catch {
                print("Failed to save progress for \(pdfID): \(error)")
            }
        }
    }
}
