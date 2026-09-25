//
//  AppGroupSyncService.swift
//  InksyncPro
//
//  Bridges Core App State to App Group Container (group.com.antigravity.inksync)
//  Powers Live Home Screen Widgets, Lock Screen Complications, and Interactive Intents
//

import Foundation
import UIKit
import WidgetKit

@MainActor
public final class AppGroupSyncService {
    public static let shared = AppGroupSyncService()
    
    public static let appGroupSuiteName = "group.com.antigravity.inksync"
    
    private var groupDefaults: UserDefaults? {
        UserDefaults(suiteName: Self.appGroupSuiteName)
    }
    
    private init() {}
    
    /// Syncs latest library, reading session, and active book data to shared App Group container
    public func syncToAppGroup() {
        guard let defaults = groupDefaults else {
            Logger.shared.log("AppGroupSyncService: Could not access App Group suite \(Self.appGroupSuiteName)", category: "Widget", type: .warning)
            return
        }
        
        let allBooks = ConversionManager.shared.convertedPDFs
        defaults.set(allBooks.count, forKey: "shelfCount")
        
        let goalMinutes = EBookPreferences.shared.dailyReadingGoalMinutes
        defaults.set(goalMinutes, forKey: "dailyReadingGoalMinutes")
        
        // Calculate minutes read today from session events across all books
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        var secondsReadToday: Double = 0
        
        for progress in ReaderProgressTracker.shared.allProgress {
            if let events = progress.sessionEvents {
                for event in events where event.date >= today {
                    secondsReadToday += event.secondsSpent
                }
            }
        }
        let minutesToday = Int(secondsReadToday / 60.0)
        defaults.set(minutesToday, forKey: "minutesTodayRead")
        
        // Locate most recently opened book
        let recentProgress = ReaderProgressTracker.shared.recentSessions().first
        if let recent = recentProgress,
           let book = allBooks.first(where: { $0.id == recent.pdfID }) {
            
            defaults.set(book.name, forKey: "currentBookTitle")
            defaults.set(book.metadata.author ?? "", forKey: "currentBookAuthor")
            defaults.set(recent.completionFraction, forKey: "currentBookProgress")
            defaults.set(recent.estimatedMinutesRemaining ?? 0, forKey: "currentBookMinutesLeft")
            
            let totalPages = book.pageCount
            let pagesLeft = max(0, totalPages - recent.currentPageIndex)
            defaults.set(pagesLeft, forKey: "currentBookPagesLeft")
            defaults.set(book.id.uuidString, forKey: "currentBookID")
            
            // Extract and store low-res cover thumbnail for widget display
            if let thumbnail = book.thumbnail {
                if let jpegData = thumbnail.jpegData(compressionQuality: 0.6) {
                    defaults.set(jpegData, forKey: "currentBookCoverData")
                }
            } else if let cachedURL = ThumbnailManager.shared.getCachedThumbnailURL(for: book.id),
                      let diskData = try? Data(contentsOf: cachedURL) {
                defaults.set(diskData, forKey: "currentBookCoverData")
            }
        } else if let firstBook = allBooks.first {
            defaults.set(firstBook.name, forKey: "currentBookTitle")
            defaults.set(firstBook.metadata.author ?? "", forKey: "currentBookAuthor")
            defaults.set(0.0, forKey: "currentBookProgress")
            defaults.set(firstBook.pageCount, forKey: "currentBookPagesLeft")
            defaults.set(firstBook.id.uuidString, forKey: "currentBookID")
        }
        
        defaults.synchronize()
        
        // Notify WidgetKit to reload timelines for all widgets
        WidgetCenter.shared.reloadAllTimelines()
        Logger.shared.log("AppGroupSyncService: Successfully synced state to App Group and reloaded widget timelines.", category: "Widget", type: .info)
    }
    
    /// Drains any interactive intent actions received from Widgets while app was in background
    public func drainPendingWidgetActions() {
        guard let defaults = groupDefaults else { return }
        
        if defaults.bool(forKey: "pendingClearShelf") {
            Logger.shared.log("AppGroupSyncService: Processing pendingClearShelf intent from widget", category: "Widget", type: .info)
            defaults.set(false, forKey: "pendingClearShelf")
            defaults.set(0, forKey: "shelfCount")
            defaults.synchronize()
            
            // Post notification for library/shelf reset if needed
            NotificationCenter.default.post(name: NSNotification.Name("Inksync_ClearShelfRequested"), object: nil)
        }
    }
}
