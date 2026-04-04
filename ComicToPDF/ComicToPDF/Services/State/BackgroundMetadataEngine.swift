import Foundation
import UIKit
import Combine
import SwiftUI

/// Handles strict rate-limited metadata auto-matching in the background.
/// Respects iOS background execution rules and idle timers for overnight processing.
@MainActor
class BackgroundMetadataEngine: ObservableObject {
    static let shared = BackgroundMetadataEngine()
    
    @Published var isRunning = false
    @Published var queueCount = 0
    @Published var currentProgress = 0
    
    private var isCancelled = false
    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    
    private init() {}
    
    func cancel() {
        isCancelled = true
    }
    
    func startEngine(manager: ConversionManager) async {
        guard !isRunning else { return }
        isRunning = true
        isCancelled = false
        
        let apiKey = AppSettingsManager.shared.conversionSettings.comicVineAPIKey
        if apiKey.isEmpty {
            isRunning = false
            return
        }
        
        // Disable screen sleep so users can leave it open overnight
        UIApplication.shared.isIdleTimerDisabled = true
        
        // Request background execution time (usually 30 seconds max)
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "BackgroundMetadataEngine") {
            // This closure runs if the time expires. We must clean up.
            Logger.shared.log("Background Task Expired by iOS.", category: "Metadata", type: .warning)
            self.gracefulShutdown(manager: manager)
        }
        
        TaskEngine.shared.isConverting = true
        TaskEngine.shared.processingStatus = "Starting Background Matching..."
        
        // Get queue of unmatched PDFs
        let queue = manager.convertedPDFs.filter { 
            ($0.metadata.universalIssueID == nil) && ($0.metadata.autoMatchFailed != true) && ($0.contentType == .comic)
        }
        
        queueCount = queue.count
        currentProgress = 0
        
        if queue.isEmpty {
            finishCleanly(manager: manager, message: "No unmatched comics found.")
            return
        }
        
        Logger.shared.log("Starting Background Metadata Matching for \(queueCount) items.", category: "Metadata")
        
        var matchCount = 0
        var failCount = 0
        
        for file in queue {
            if isCancelled { break }
            
            // Check if iOS is about to kill us in the background
            if UIApplication.shared.backgroundTimeRemaining < 5.0 && UIApplication.shared.applicationState == .background {
                Logger.shared.log("Pausing background process to comply with iOS background limits.", category: "Metadata", type: .warning)
                break 
            }
            
            currentProgress += 1
            TaskEngine.shared.conversionProgress = Double(currentProgress) / Double(queueCount)
            TaskEngine.shared.processingStatus = "Searching: \(file.name)..."
            
            let query = MetadataHeuristics.cleanFilename(file.name)
            let issueStr = MetadataHeuristics.extractIssueNumber(from: file.name)
            
            do {
                let results = try await ComicVineService.shared.searchVolumes(query: query, apiKey: apiKey)
                
                if let bestVolume = results.first {
                    if let issueNumStr = issueStr, let issueNum = Int(issueNumStr) {
                        if let issue = try await ComicVineService.shared.getIssue(volumeID: bestVolume.id, issueNumber: issueNumStr, apiKey: apiKey) {
                            applyFullMatch(to: file.id, manager: manager, volume: bestVolume, issue: issue, issueNum: issueNum)
                            matchCount += 1
                        } else {
                            applyPartialMatch(to: file.id, manager: manager, volume: bestVolume, issueNum: issueNum)
                            matchCount += 1
                        }
                    } else {
                        applyPartialMatch(to: file.id, manager: manager, volume: bestVolume, issueNum: nil)
                        matchCount += 1
                    }
                } else {
                    markAsFailed(id: file.id, manager: manager)
                    failCount += 1
                }
            } catch {
                Logger.shared.log("Failed API check for \(file.name): \(error.localizedDescription)", category: "Metadata", type: .error)
                markAsFailed(id: file.id, manager: manager)
                failCount += 1
            }
            
            // Save state aggressively so progress isn't lost if the user force-closes the app
            manager.saveLibrary()
        }
        
        finishCleanly(manager: manager, message: "Matched: \(matchCount). Failed: \(failCount).")
    }
    
    private func finishCleanly(manager: ConversionManager, message: String) {
        isRunning = false
        UIApplication.shared.isIdleTimerDisabled = false
        
        TaskEngine.shared.isConverting = false
        TaskEngine.shared.processingStatus = ""
        TaskEngine.shared.statusMessage = nil
        TaskEngine.shared.appAlert = AppAlert(title: "Background Engine Complete", message: message)
        
        if self.bgTask != .invalid {
            UIApplication.shared.endBackgroundTask(self.bgTask)
            self.bgTask = .invalid
        }
    }
    
    private func gracefulShutdown(manager: ConversionManager) {
        self.isCancelled = true
        self.isRunning = false
        UIApplication.shared.isIdleTimerDisabled = false
        manager.saveLibrary()
        
        if self.bgTask != .invalid {
            UIApplication.shared.endBackgroundTask(self.bgTask)
            self.bgTask = .invalid
        }
    }
    
    // MARK: - Appliers
    
    private func applyPartialMatch(to fileID: UUID, manager: ConversionManager, volume: ComicVineVolume, issueNum: Int?) {
        if let idx = manager.convertedPDFs.firstIndex(where: { $0.id == fileID }) {
            manager.convertedPDFs[idx].metadata.series = volume.name
            manager.convertedPDFs[idx].metadata.universalSeriesID = String(volume.id)
            manager.convertedPDFs[idx].metadata.volume = volume.name
            manager.convertedPDFs[idx].metadata.publisher = volume.publisher?.name
            if let num = issueNum {
                manager.convertedPDFs[idx].metadata.issueNumber = "\(num)"
            }
        }
    }
    
    private func applyFullMatch(to fileID: UUID, manager: ConversionManager, volume: ComicVineVolume, issue: ComicVineIssueDetails, issueNum: Int) {
        if let idx = manager.convertedPDFs.firstIndex(where: { $0.id == fileID }) {
            manager.convertedPDFs[idx].metadata.series = volume.name
            manager.convertedPDFs[idx].metadata.universalSeriesID = String(volume.id)
            manager.convertedPDFs[idx].metadata.volume = volume.name
            manager.convertedPDFs[idx].metadata.issueNumber = "\(issueNum)"
            manager.convertedPDFs[idx].metadata.publisher = volume.publisher?.name
            manager.convertedPDFs[idx].metadata.universalIssueID = String(issue.id)
            
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            if let dateString = issue.cover_date, let date = formatter.date(from: dateString) {
                manager.convertedPDFs[idx].metadata.publicationDate = date
            }
            
            if let desc = issue.description {
                manager.convertedPDFs[idx].metadata.summary = desc.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression, range: nil)
            }
        }
    }
    
    private func markAsFailed(id: UUID, manager: ConversionManager) {
        if let idx = manager.convertedPDFs.firstIndex(where: { $0.id == id }) {
            manager.convertedPDFs[idx].metadata.autoMatchFailed = true
            // Capture these for the UI presentation layer if they want to review them in this session
            let failedPDF = manager.convertedPDFs[idx]
            if !manager.failedMetadataPDFs.contains(where: { $0.id == failedPDF.id }) {
                manager.failedMetadataPDFs.append(failedPDF)
            }
        }
    }
}
