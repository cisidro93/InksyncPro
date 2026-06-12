import Foundation

// MARK: - Type-Safe Notification Names
//
// All NotificationCenter names used across InksyncPro are declared here as static
// constants to prevent silent failures from typos at the post or observe site.
// Usage:  NotificationCenter.default.post(name: .libraryNeedsRescan, ...)
//         NotificationCenter.default.publisher(for: .handoffRequested)
extension Notification.Name {

    // MARK: Library & Import
    /// Fired when the on-disk library has changed and needs a full rescan.
    static let libraryNeedsRescan     = Notification.Name("LibraryNeedsRescan")
    /// Fired when the library data needs to be written to disk immediately.
    static let libraryNeedsSave       = Notification.Name("LibraryNeedsSave")
    /// Fired after a merge completes, carrying the newly created `ConvertedPDF`.
    static let openMergedBook         = Notification.Name("OpenMergedBook")
    /// Fired when a thumbnail is successfully generated for a converted PDF.
    static let thumbnailGenerated     = Notification.Name("ThumbnailGenerated")
    // NOTE: .cloudCoverReady is declared in BookmarkResolver.swift alongside the
    // other cloud-cover notification infrastructure. Do not redeclare it here.

    // MARK: Reader & Handoff
    /// Fired by the Handoff continuation to deep-link into a specific book + page.
    static let handoffRequested       = Notification.Name("HandoffRequested")
    /// Fired by the "Resume" App Intent or widget to open the most-recently read book.
    static let inksyncResumeLastRead  = Notification.Name("InksyncResumeLastRead")
    /// Fired by the "Open Shelf" App Intent to dismiss any open reader/sheet.
    static let inksyncOpenShelf       = Notification.Name("InksyncOpenShelf")
    /// Fired by the "Open Book" App Intent to deep-link to a title by name.
    static let inksyncOpenBook        = Notification.Name("InksyncOpenBook")

    // MARK: UI Interactions
    /// Fired when the Library tab icon is double-tapped — triggers scroll-to-top.
    static let inkTabDoubleTapLibrary = Notification.Name("InkTab_DoubleTap_0")
    /// Fired when a series row's context menu "Rename" is tapped.
    static let requestSeriesRename    = Notification.Name("RequestSeriesRename")
}
