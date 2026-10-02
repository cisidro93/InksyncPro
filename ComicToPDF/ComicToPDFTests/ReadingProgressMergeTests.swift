import XCTest
@testable import InksyncPro

final class ReadingProgressMergeTests: XCTestCase {

    func testFurthestForwardProgressAdoptedWhenNoIntentionalReread() {
        let pdfID = UUID()
        let now = Date()

        let local = ReadingProgress(
            pdfID: pdfID,
            lastOpenedAt: now.addingTimeInterval(-100),
            currentPageIndex: 10,
            currentChapterIndex: 1,
            currentChapterOffset: 10.0,
            totalPagesRead: 10,
            completionFraction: 0.1,
            readingSessionDates: [now.addingTimeInterval(-100)],
            sessionEvents: [
                ReadingSessionEvent(date: now.addingTimeInterval(-100), pagesRead: 10, secondsSpent: 300)
            ]
        )

        let remote = ReadingProgress(
            pdfID: pdfID,
            lastOpenedAt: now.addingTimeInterval(-50),
            currentPageIndex: 25,
            currentChapterIndex: 2,
            currentChapterOffset: 5.0,
            totalPagesRead: 25,
            completionFraction: 0.25,
            readingSessionDates: [now.addingTimeInterval(-50)],
            sessionEvents: [
                ReadingSessionEvent(date: now.addingTimeInterval(-50), pagesRead: 15, secondsSpent: 400)
            ]
        )

        let merged = ReadingProgress.merge(local: local, remote: remote)

        XCTAssertEqual(merged.currentPageIndex, 25)
        XCTAssertEqual(merged.currentChapterIndex, 2)
        XCTAssertEqual(merged.completionFraction, 0.25)
    }

    func testIntentionalRereadDefensePreservesDeliberateEarlierPage() {
        let pdfID = UUID()
        let now = Date()

        // Remote device was read up to page 50 two hours ago
        let remote = ReadingProgress(
            pdfID: pdfID,
            lastOpenedAt: now.addingTimeInterval(-7200),
            currentPageIndex: 50,
            currentChapterIndex: 5,
            currentChapterOffset: 0.0,
            totalPagesRead: 50,
            completionFraction: 0.5,
            readingSessionDates: [now.addingTimeInterval(-7200)],
            sessionEvents: [
                ReadingSessionEvent(date: now.addingTimeInterval(-7200), pagesRead: 50, secondsSpent: 1200)
            ]
        )

        // Local device deliberately reread chapter 1 page 5 just now (>60s after remote)
        let local = ReadingProgress(
            pdfID: pdfID,
            lastOpenedAt: now,
            currentPageIndex: 5,
            currentChapterIndex: 1,
            currentChapterOffset: 0.0,
            totalPagesRead: 55,
            completionFraction: 0.05,
            readingSessionDates: [now],
            sessionEvents: [
                ReadingSessionEvent(date: now, pagesRead: 5, secondsSpent: 180)
            ]
        )

        let merged = ReadingProgress.merge(local: local, remote: remote)

        // Intentional reread defense must preserve the deliberate local earlier position
        XCTAssertEqual(merged.currentPageIndex, 5, "Deliberate reread position must be preserved over stale furthest point")
        XCTAssertEqual(merged.currentChapterIndex, 1)
    }

    func testCustomCropInsetsAndSettingsPreservedDuringMerge() {
        let pdfID = UUID()
        let now = Date()

        var local = ReadingProgress(
            pdfID: pdfID,
            lastOpenedAt: now,
            currentPageIndex: 10,
            totalPagesRead: 10,
            completionFraction: 0.1,
            readingSessionDates: [now]
        )
        local.customCrop = CodableCropInsets(top: 0.05, bottom: 0.05, left: 0.02, right: 0.02, modeRaw: "custom")
        local.prefersMangaMode = true

        let remote = ReadingProgress(
            pdfID: pdfID,
            lastOpenedAt: now.addingTimeInterval(-10),
            currentPageIndex: 12,
            totalPagesRead: 12,
            completionFraction: 0.12,
            readingSessionDates: [now.addingTimeInterval(-10)]
        )

        let merged = ReadingProgress.merge(local: local, remote: remote)

        XCTAssertEqual(merged.customCrop?.modeRaw, "custom")
        XCTAssertEqual(merged.prefersMangaMode, true)
    }
}
