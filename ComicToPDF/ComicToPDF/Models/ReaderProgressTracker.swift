import Foundation

/// One reading session's worth of velocity data.
struct ReadingSessionEvent: Codable {
    let date: Date
    let pagesRead: Int
    let secondsSpent: Double

    /// Pages per minute for this session.
    var pagesPerMinute: Double {
        guard secondsSpent > 0 else { return 0 }
        return Double(pagesRead) / (secondsSpent / 60.0)
    }
}

struct CodableCropInsets: Codable, Equatable, Sendable {
    var top: Double    // Percentage 0.0 to 0.40 (e.g. 0.10 = 10% trim from top)
    var bottom: Double // Percentage 0.0 to 0.40
    var left: Double   // Percentage 0.0 to 0.40
    var right: Double  // Percentage 0.0 to 0.40
    var modeRaw: String = "custom" // "none", "smartAuto", "custom"
    
    static let zero = CodableCropInsets(top: 0, bottom: 0, left: 0, right: 0, modeRaw: "none")
    static let none = CodableCropInsets(top: 0, bottom: 0, left: 0, right: 0, modeRaw: "none")
    static let smartAuto = CodableCropInsets(top: 0, bottom: 0, left: 0, right: 0, modeRaw: "smartAuto")
    
    var isEnabled: Bool {
        modeRaw != "none"
    }
}

struct ReadingProgress: Codable, Identifiable {
    var id: UUID { pdfID }
    var pdfID: UUID
    var lastOpenedAt: Date
    var currentPageIndex: Int
    var currentChapterIndex: Int?
    var currentChapterOffset: Double?
    var totalPagesRead: Int
    var completionFraction: Double
    var readingSessionDates: [Date]
    var estimatedMinutesRemaining: Int?
    var prefersMangaMode: Bool?
    var colorFilter: String?

    // Precise velocity tracking — optional for backwards-compatible JSON decoding of existing saves
    var sessionEvents: [ReadingSessionEvent]?
    // Spread-mode parity — saves canonical lead index so resume restores correct spread
    var lastCanonicalLeadIndex: Int?
    var wasInDualPageMode: Bool?
    // Per-document custom crop persistence
    var customCrop: CodableCropInsets?
    // EPUB Canonical Fragment Identifier (CFI) location sync
    var currentCFI: String?
}

extension ReadingProgress {
    /// Non-destructively merges local and remote reading progress records.
    /// Prevents offline reading overwrites by choosing the furthest forward progress
    /// while unifying reading session histories, timestamps, and active customizations.
    static func merge(local: ReadingProgress, remote: ReadingProgress) -> ReadingProgress {
        var merged = local

        // Determine latest active interaction timestamps
        let localLatestActivity = local.sessionEvents?.last?.date ?? local.lastOpenedAt
        let remoteLatestActivity = remote.sessionEvents?.last?.date ?? remote.lastOpenedAt
        let timeDifference = localLatestActivity.timeIntervalSince(remoteLatestActivity)

        // Evaluate positional difference
        let remoteIsFurther: Bool
        if let remoteChapter = remote.currentChapterIndex, let localChapter = local.currentChapterIndex {
            if remoteChapter != localChapter {
                remoteIsFurther = remoteChapter > localChapter
            } else {
                remoteIsFurther = (remote.currentChapterOffset ?? Double(remote.currentPageIndex)) >
                                  (local.currentChapterOffset ?? Double(local.currentPageIndex))
            }
        } else {
            remoteIsFurther = remote.completionFraction > local.completionFraction ||
                             (remote.completionFraction == local.completionFraction && remote.currentPageIndex > local.currentPageIndex)
        }

        // Intentional regression defense:
        // If the device with the earlier page position had a distinctly newer active reading session
        // (i.e. user deliberately navigated back to reread > 60s after the other device was opened),
        // preserve that deliberate position rather than forcefully snapping forward to a stale furthest point.
        let adoptRemotePosition: Bool
        if remoteIsFurther {
            let isLocalIntentionalReread = timeDifference > 60
            adoptRemotePosition = !isLocalIntentionalReread
        } else {
            let isRemoteIntentionalReread = timeDifference < -60
            adoptRemotePosition = isRemoteIntentionalReread
        }

        if adoptRemotePosition {
            merged.currentPageIndex = remote.currentPageIndex
            merged.currentChapterIndex = remote.currentChapterIndex
            merged.currentChapterOffset = remote.currentChapterOffset
            merged.completionFraction = remote.completionFraction
            merged.currentCFI = remote.currentCFI ?? local.currentCFI
            merged.lastCanonicalLeadIndex = remote.lastCanonicalLeadIndex
            merged.wasInDualPageMode = remote.wasInDualPageMode
        } else {
            merged.currentPageIndex = local.currentPageIndex
            merged.currentChapterIndex = local.currentChapterIndex
            merged.currentChapterOffset = local.currentChapterOffset
            merged.completionFraction = local.completionFraction
            merged.currentCFI = local.currentCFI ?? remote.currentCFI
            merged.lastCanonicalLeadIndex = local.lastCanonicalLeadIndex
            merged.wasInDualPageMode = local.wasInDualPageMode
        }

        // Always take maximum lifetime pages read and newest access timestamp
        merged.totalPagesRead = max(local.totalPagesRead, remote.totalPagesRead)
        merged.lastOpenedAt = max(local.lastOpenedAt, remote.lastOpenedAt)

        // Union and deduplicate reading session dates (normalize to day)
        let calendar = Calendar.current
        let combinedDates = (local.readingSessionDates + remote.readingSessionDates)
        var seenDays = Set<Date>()
        var uniqueDates: [Date] = []
        for d in combinedDates.sorted(by: >) {
            let start = calendar.startOfDay(for: d)
            if !seenDays.contains(start) {
                seenDays.insert(start)
                uniqueDates.append(d)
            }
        }
        merged.readingSessionDates = uniqueDates

        // Union session events (deduplicate within 60s windows, sort chronologically, cap at 200 via FIFO eviction)
        var events = (local.sessionEvents ?? []) + (remote.sessionEvents ?? [])
        events.sort { $0.date < $1.date }
        var deduplicatedEvents: [ReadingSessionEvent] = []
        for event in events {
            if let last = deduplicatedEvents.last, abs(event.date.timeIntervalSince(last.date)) < 60 {
                continue
            }
            deduplicatedEvents.append(event)
        }
        // Explicit FIFO (First-In-First-Out) eviction: oldest session records beyond the 200 cap are dropped
        if deduplicatedEvents.count > 200 {
            deduplicatedEvents.removeFirst(deduplicatedEvents.count - 200)
        }
        merged.sessionEvents = deduplicatedEvents

        // Non-destructive preservation of display settings and crop insets
        if merged.customCrop == nil || merged.customCrop == .zero {
            merged.customCrop = remote.customCrop ?? local.customCrop
        }
        if merged.prefersMangaMode == nil {
            merged.prefersMangaMode = remote.prefersMangaMode ?? local.prefersMangaMode
        }
        if merged.colorFilter == nil {
            merged.colorFilter = remote.colorFilter ?? local.colorFilter
        }

        return merged
    }
}

@MainActor
class ReaderProgressTracker: ObservableObject {
    static let shared = ReaderProgressTracker()
    
    @Published private var progressMap: [UUID: ReadingProgress] = [:]
    private var saveTasks: [UUID: Task<Void, Never>] = [:]
    
    /// Save per-document crop insets permanently to disk & iCloud
    func saveCropInsets(_ crop: CodableCropInsets, for pdfID: UUID) {
        var prog = progress(for: pdfID) ?? ReadingProgress(
            pdfID: pdfID,
            lastOpenedAt: Date(),
            currentPageIndex: 0,
            totalPagesRead: 0,
            completionFraction: 0.0,
            readingSessionDates: []
        )
        prog.customCrop = crop
        update(prog)
    }
    
    /// Fetch per-document saved crop insets
    func cropInsets(for pdfID: UUID) -> CodableCropInsets? {
        progress(for: pdfID)?.customCrop
    }
    
    private let queue = DispatchQueue(label: "com.inksync.ProgressTracker", qos: .userInitiated)
// Removed fileManager properties to avoid actor isolation issues
    private nonisolated func getProgressDir() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let newDir = appSupport.appendingPathComponent("progress")
        
        // Ensure new directory exists
        if !FileManager.default.fileExists(atPath: newDir.path) {
            try? FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)
        }
        
        // Migration logic
        let oldDocs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        if let oldDocs = oldDocs {
            let oldDir = oldDocs.appendingPathComponent("progress")
            if FileManager.default.fileExists(atPath: oldDir.path) {
                // Move contents from oldDir to newDir
                if let files = try? FileManager.default.contentsOfDirectory(at: oldDir, includingPropertiesForKeys: nil) {
                    for file in files {
                        let destFile = newDir.appendingPathComponent(file.lastPathComponent)
                        if !FileManager.default.fileExists(atPath: destFile.path) {
                            try? FileManager.default.moveItem(at: file, to: destFile)
                        } else {
                            try? FileManager.default.removeItem(at: file)
                        }
                    }
                }
                // Try to remove oldDir
                try? FileManager.default.removeItem(at: oldDir)
            }
        }
        
        return newDir
    }
    
    /// Key prefix used in NSUbiquitousKeyValueStore so our keys never collide with other apps.
    private let iCloudPrefix = "InksyncPro.progress."
    private let iCloudStore  = NSUbiquitousKeyValueStore.default

    private init() {
        loadAll()
        mergeFromiCloud()          // pull remote progress on cold launch
        // Listen for iCloud push updates while the app is foregrounded
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: iCloudStore,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.mergeFromiCloud() }
        }
        iCloudStore.synchronize()
    }
    
    func progress(for pdfID: UUID) -> ReadingProgress? {
        return progressMap[pdfID]
    }
    
    func recentSessions() -> [ReadingProgress] {
        return progressMap.values.sorted { $0.lastOpenedAt > $1.lastOpenedAt }
    }

    /// Phase 4D-3: All progress records — used by ZettelkastenGraphEngine session auto-nodes.
    var allProgress: [ReadingProgress] { Array(progressMap.values) }

    func update(_ progress: ReadingProgress) {
        var updated = progress

        // Estimate time remaining using rolling velocity if available, else fallback
        let velocity = rollingVelocity(for: updated.pdfID) // pages per minute
        if updated.completionFraction > 0, updated.completionFraction <= 1.0 {
            let ppm = velocity > 0 ? velocity : (updated.currentChapterIndex != nil ? 0.25 : 2.0)
            let pagesRemaining = Double(max(0, updated.totalPagesRead)) * (1.0 - updated.completionFraction) / max(updated.completionFraction, 0.001)
            updated.estimatedMinutesRemaining = Int(pagesRemaining / ppm)
        }

        progressMap[updated.pdfID] = updated
        save(pdfID: updated.pdfID)
        syncToiCloud(pdfID: updated.pdfID, progress: updated)

        // Keep ConversionManager in-memory library and SQLite progress in sync
        if let idx = ConversionManager.shared.convertedPDFs.firstIndex(where: { $0.id == updated.pdfID }) {
            ConversionManager.shared.convertedPDFs[idx].metadata.lastReadPage = updated.currentPageIndex
            ConversionManager.shared.saveProgressOnly()
        }

        // Sync live progress, streak, and recent book cover to App Group for Home & Lock Screen Widgets
        AppGroupSyncService.shared.syncToAppGroup()

        // Broadcast to the app village (ModernLibraryView, ReadNowTabView, SeriesDetailView)
        NotificationCenter.default.post(
            name: .readingProgressDidChange,
            object: nil,
            userInfo: ["pdfID": updated.pdfID, "progress": updated]
        )
    }

    /// Record pages turned and time spent during a session turn.
    /// Call this on every page turn from any active reader engine.
    func logPageTurn(pdfID: UUID, pages: Int, seconds: Double) {
        guard pages > 0, seconds > 0 else { return }
        var prog = progressMap[pdfID] ?? ReadingProgress(
            pdfID: pdfID,
            lastOpenedAt: Date(),
            currentPageIndex: 0,
            totalPagesRead: 0,
            completionFraction: 0.0,
            readingSessionDates: [Date()]
        )
        let event = ReadingSessionEvent(date: Date(), pagesRead: pages, secondsSpent: seconds)
        var events = prog.sessionEvents ?? []
        events.append(event)
        // Trim to last 200 events to prevent unbounded growth
        if events.count > 200 { events.removeFirst(events.count - 200) }
        prog.sessionEvents = events
        prog.totalPagesRead += pages
        prog.lastOpenedAt = Date()
        if !prog.readingSessionDates.contains(where: { Calendar.current.isDateInToday($0) }) {
            prog.readingSessionDates.append(Date())
        }
        progressMap[pdfID] = prog
        save(pdfID: pdfID)
    }

    /// Rolling 7-day average velocity in pages per minute. Returns 0 if no data.
    func rollingVelocity(for pdfID: UUID) -> Double {
        guard let prog = progressMap[pdfID],
              let events = prog.sessionEvents, !events.isEmpty else { return 0 }
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        let recent = events.filter { $0.date >= cutoff }
        guard !recent.isEmpty else { return 0 }
        let totalPages   = recent.reduce(0)   { $0 + $1.pagesRead }
        let totalMinutes = recent.reduce(0.0) { $0 + ($1.secondsSpent / 60.0) }
        guard totalMinutes > 0 else { return 0 }
        return Double(totalPages) / totalMinutes
    }
    
    func markComplete(pdfID: UUID, totalPages: Int? = nil) {
        let pages = totalPages ?? ConversionManager.shared.convertedPDFs.first(where: { $0.id == pdfID })?.pageCount ?? 1
        var prog = progressMap[pdfID] ?? ReadingProgress(
            pdfID: pdfID,
            lastOpenedAt: Date(),
            currentPageIndex: max(1, pages),
            totalPagesRead: max(1, pages),
            completionFraction: 1.0,
            readingSessionDates: [Date()]
        )
        prog.currentPageIndex = max(1, pages)
        prog.totalPagesRead = max(prog.totalPagesRead, pages)
        prog.completionFraction = 1.0
        prog.lastOpenedAt = Date()
        update(prog)
    }

    func markUnread(pdfID: UUID) {
        var prog = progressMap[pdfID] ?? ReadingProgress(
            pdfID: pdfID,
            lastOpenedAt: Date(),
            currentPageIndex: 0,
            totalPagesRead: 0,
            completionFraction: 0.0,
            readingSessionDates: []
        )
        prog.currentPageIndex = 0
        prog.completionFraction = 0.0
        prog.lastOpenedAt = Date()
        update(prog)
    }
    
    func deleteProgress(for pdfID: UUID) {
        progressMap.removeValue(forKey: pdfID)
        let fileURL = getProgressDir().appendingPathComponent("\(pdfID.uuidString).json")
        queue.async {
            try? FileManager.default.removeItem(at: fileURL)
        }
        iCloudStore.removeObject(forKey: iCloudPrefix + pdfID.uuidString)
        iCloudStore.synchronize()
        NotificationCenter.default.post(
            name: .readingProgressDidChange,
            object: nil,
            userInfo: ["pdfID": pdfID]
        )
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
        
        for date in uniqueDays {
            if date == expectedDate {
                streak += 1
                expectedDate = calendar.date(byAdding: .day, value: -1, to: expectedDate) ?? expectedDate
            } else {
                break
            }
        }
        return streak
    }
    
    func totalMinutesReadToday() -> Int {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        var totalSeconds: Double = 0
        for prog in progressMap.values {
            if let events = prog.sessionEvents {
                for event in events where event.date >= startOfToday {
                    totalSeconds += event.secondsSpent
                }
            }
        }
        return Int(totalSeconds / 60.0)
    }

    func totalMinutesRead(on date: Date) -> Int {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else { return 0 }
        var totalSeconds: Double = 0
        for prog in progressMap.values {
            if let events = prog.sessionEvents {
                for event in events where event.date >= startOfDay && event.date < endOfDay {
                    totalSeconds += event.secondsSpent
                }
            }
        }
        return Int(totalSeconds / 60.0)
    }

    func totalMinutesReadThisWeek() -> Int {
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        var totalSeconds: Double = 0
        for prog in progressMap.values {
            if let events = prog.sessionEvents {
                for event in events where event.date >= cutoff {
                    totalSeconds += event.secondsSpent
                }
            }
        }
        return Int(totalSeconds / 60.0)
    }
    
    func totalPagesThisWeek() -> Int {
        // Uses sessionEvents for an accurate weekly count — each event stores exact pages read
        // in that turn, so filtering by date gives a true delta rather than cumulative total.
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        return progressMap.values.reduce(0) { sum, prog in
            sum + (prog.sessionEvents?.filter { $0.date >= cutoff }.reduce(0) { $0 + $1.pagesRead } ?? 0)
        }
    }
    
    func seriesCompletion(collectionID: UUID, manager: ConversionManager) -> Double {
        let seriesBooks = manager.convertedPDFs.filter { $0.collectionId == collectionID }
        guard !seriesBooks.isEmpty else { return 0 }
        
        let totalFraction = seriesBooks.reduce(0.0) { sum, book in
            sum + (progressMap[book.id]?.completionFraction ?? 0.0)
        }
        
        return totalFraction / Double(seriesBooks.count)
    }
    
    /// Returns pages read on a specific day of the current week (0=Mon, 6=Sun)
    func pagesReadOn(dayOfWeekIndex: Int) -> Int {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        
        // Find the Monday of this week
        let weekday = calendar.component(.weekday, from: today)
        let daysFromMonday = (weekday + 5) % 7  // Convert Sun=1 to Mon=0
        guard let monday = calendar.date(byAdding: .day, value: -daysFromMonday, to: today) else { return 0 }
        guard let targetDay = calendar.date(byAdding: .day, value: dayOfWeekIndex, to: monday) else { return 0 }
        let nextDay = calendar.date(byAdding: .day, value: 1, to: targetDay) ?? targetDay
        
        // Sum pages from sessions on that day
        var total = 0
        for progress in progressMap.values {
            let sessionsOnDay = progress.readingSessionDates.filter { date in
                date >= targetDay && date < nextDay
            }
            // Each session roughly correlates to some pages read; use totalPagesRead as proxy
            if !sessionsOnDay.isEmpty {
                total += max(1, progress.totalPagesRead / max(progress.readingSessionDates.count, 1)) * sessionsOnDay.count
            }
        }
        return total
    }
    
    // MARK: - Persistence
    
    private func loadAll() {
        queue.async { [weak self] in
            guard let self = self else { return }
            do {
                let dir = self.getProgressDir()
                let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
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
                Logger.shared.log("Failed to load progress data: \(error)", category: "Progress", type: .error)
            }
        }
    }
    
    // MARK: - iCloud Sync

    /// Encode one progress record into iCloud KV store (~2 KB per book, well within the 1 MB limit).
    private func syncToiCloud(pdfID: UUID, progress: ReadingProgress) {
        guard let data = try? JSONEncoder().encode(progress) else { return }
        iCloudStore.set(data, forKey: iCloudPrefix + pdfID.uuidString)
    }

    /// Pull all remote records and non-destructively merge with local records.
    /// Protects offline reading sessions from being overwritten by stale device timestamps.
    private func mergeFromiCloud() {
        let allKeys = iCloudStore.dictionaryRepresentation.keys.filter { $0.hasPrefix(iCloudPrefix) }
        var changed = false
        for key in allKeys {
            guard let data = iCloudStore.data(forKey: key),
                  let remote = try? JSONDecoder().decode(ReadingProgress.self, from: data) else { continue }
            if let local = progressMap[remote.pdfID] {
                let merged = ReadingProgress.merge(local: local, remote: remote)
                let hasProgressChanged = merged.completionFraction != local.completionFraction ||
                                         merged.currentPageIndex != local.currentPageIndex ||
                                         merged.currentChapterIndex != local.currentChapterIndex ||
                                         merged.lastOpenedAt != local.lastOpenedAt
                if hasProgressChanged {
                    progressMap[remote.pdfID] = merged
                    save(pdfID: remote.pdfID)
                    changed = true
                }
            } else {
                progressMap[remote.pdfID] = remote
                save(pdfID: remote.pdfID)
                changed = true
            }
        }
        if changed { objectWillChange.send() }
    }

    private func save(pdfID: UUID) {
        saveTasks[pdfID]?.cancel()
        
        saveTasks[pdfID] = Task { [weak self] in
            // 2-Second Sliding Window Debouncer
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            
            guard let self = self, let progress = self.progressMap[pdfID] else { return }
            let fileURL = self.getProgressDir().appendingPathComponent("\(pdfID.uuidString).json")

            // ✅ Swift 6: Use Task.detached for background I/O instead of DispatchQueue.async
            // to avoid crossing actor isolation boundaries from @MainActor context.
            await Task.detached(priority: .background) {
                do {
                    let data = try JSONEncoder().encode(progress)
                    try data.write(to: fileURL, options: .atomic)
                } catch {
                    Logger.shared.log("Failed to save progress for \(pdfID): \(error)", category: "Progress", type: .error)
                }
            }.value
        }
    }
}
