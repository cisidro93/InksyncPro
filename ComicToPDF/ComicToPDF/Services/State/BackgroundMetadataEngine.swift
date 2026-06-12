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
            TaskEngine.shared.appAlert = AppAlert(title: "API Key Required", message: "Please enter your ComicVine API Key in Settings to enable Auto-Match.")
            isRunning = false
            return
        }
        
        // Disable screen sleep so users can leave it open overnight
        UIApplication.shared.isIdleTimerDisabled = true
        
        // Request background execution time (usually 30 seconds max)
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "BackgroundMetadataEngine") { [weak self, weak manager] in
            guard let self = self, let manager = manager else { return }
            // This closure runs on a background thread. Mutating a @MainActor class directly will crash the app instantly with no log.
            Task { @MainActor in
                Logger.shared.log("Background Task Expired by iOS.", category: "Metadata", type: .warning)
                self.gracefulShutdown(manager: manager)
            }
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
        
        // Group queue by query to reduce API calls
        var clusters: [String: [ConvertedPDF]] = [:]
        for file in queue {
            let query = MetadataHeuristics.cleanFilename(file.name)
            clusters[query, default: []].append(file)
        }
        
        Logger.shared.log("Starting Background Metadata Matching for \(queueCount) items across \(clusters.count) clusters.", category: "Metadata")
        
        var matchCount = 0
        var failCount = 0
        
        for (query, files) in clusters {
            if isCancelled { break }
            
            // Check if iOS is about to kill us in the background
            if UIApplication.shared.backgroundTimeRemaining < 5.0 && UIApplication.shared.applicationState == .background {
                Logger.shared.log("Pausing background process to comply with iOS background limits.", category: "Metadata", type: .warning)
                break 
            }
            
            TaskEngine.shared.processingStatus = "Searching Series: \(query)..."
            
            do {
                let results = try await ComicVineService.shared.searchVolumes(query: query, apiKey: apiKey)
                
                if let bestVolume = results.first {
                    TaskEngine.shared.processingStatus = "Downloading details for \(bestVolume.name)..."
                    
                    // Bulk fetch issues with pagination
                    var allIssues: [ComicVineIssueDetails] = []
                    var offset = 0
                    let limit = 100
                    var totalResults = 100 // Assume at least one loop
                    
                    while offset < totalResults {
                        let response = try await ComicVineService.shared.getIssuesForVolume(volumeID: bestVolume.id, apiKey: apiKey, offset: offset)
                        allIssues.append(contentsOf: response.results)
                        
                        if let total = response.number_of_total_results {
                            totalResults = total
                        } else {
                            break
                        }
                        
                        offset += limit
                        if isCancelled { break }
                    }
                    
                    // In-memory mapping
                    for file in files {
                        if isCancelled { break }
                        currentProgress += 1
                        TaskEngine.shared.conversionProgress = Double(currentProgress) / Double(queueCount)
                        
                        let issueStr = MetadataHeuristics.extractIssueNumber(from: file.name)
                        
                        if let issueNumStr = issueStr, let issueNum = Int(issueNumStr) {
                            // Best effort match for issue number
                            if let issue = allIssues.first(where: { 
                                if let apiNumStr = $0.issue_number, let apiNum = Double(apiNumStr) {
                                    return apiNum == Double(issueNum)
                                }
                                return $0.issue_number == issueNumStr
                            }) {
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
                    }
                } else {
                    for file in files {
                        currentProgress += 1
                        TaskEngine.shared.conversionProgress = Double(currentProgress) / Double(queueCount)
                        markAsFailed(id: file.id, manager: manager)
                        failCount += 1
                    }
                }
            } catch {
                Logger.shared.log("Failed API check for cluster \(query): \(error.localizedDescription)", category: "Metadata", type: .error)
                for file in files {
                    currentProgress += 1
                    TaskEngine.shared.conversionProgress = Double(currentProgress) / Double(queueCount)
                    markAsFailed(id: file.id, manager: manager)
                    failCount += 1
                }
            }
            // No saveLibrary() here — the 300ms debounce in saveLibrary() coalesces burst calls.
            // A single save in finishCleanly() is sufficient and avoids N disk writes for N comics.
        }
        
        finishCleanly(manager: manager, message: "Matched: \(matchCount). Failed: \(failCount).")
    }
    
    private func finishCleanly(manager: ConversionManager, message: String) {
        isRunning = false
        UIApplication.shared.isIdleTimerDisabled = false
        manager.saveLibrary() // Persist perfectly matched items to SwiftData before terminating
        
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
    
    // MARK: - DateFormatter (static — DateFormatter is expensive to initialize)
    private static let coverDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    // MARK: - Appliers
    
    private func applyPartialMatch(to fileID: UUID, manager: ConversionManager, volume: ComicVineVolume, issueNum: Int?) {
        if let idx = manager.convertedPDFs.firstIndex(where: { $0.id == fileID }) {
            var mutablePDF = manager.convertedPDFs[idx]
            mutablePDF.metadata.series = volume.name
            mutablePDF.metadata.universalSeriesID = String(volume.id)
            mutablePDF.metadata.volume = volume.name
            mutablePDF.metadata.publisher = volume.publisher?.name
            if let num = issueNum {
                mutablePDF.metadata.issueNumber = "\(num)"
            }
            manager.convertedPDFs[idx] = mutablePDF
        }
    }
    
    private func applyFullMatch(to fileID: UUID, manager: ConversionManager, volume: ComicVineVolume, issue: ComicVineIssueDetails, issueNum: Int) {
        if let idx = manager.convertedPDFs.firstIndex(where: { $0.id == fileID }) {
            var mutablePDF = manager.convertedPDFs[idx]
            mutablePDF.metadata.series = volume.name
            mutablePDF.metadata.universalSeriesID = String(volume.id)
            mutablePDF.metadata.volume = volume.name
            mutablePDF.metadata.issueNumber = "\(issueNum)"
            mutablePDF.metadata.publisher = volume.publisher?.name
            mutablePDF.metadata.universalIssueID = String(issue.id)
            
            if let dateString = issue.cover_date, let date = BackgroundMetadataEngine.coverDateFormatter.date(from: dateString) {
                mutablePDF.metadata.publicationDate = date
            }
            
            if let desc = issue.description {
                mutablePDF.metadata.summary = desc.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression, range: nil)
            }
            manager.convertedPDFs[idx] = mutablePDF
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
