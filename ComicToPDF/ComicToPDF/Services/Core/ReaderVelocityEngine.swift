import Foundation
import Combine

/// A helper class to track page reading speeds and dynamically estimate remaining reading times.
/// Employs Kindle-like outlier filtering (ignoring quick flips < 2s and long pauses > 3 mins).
class ReaderVelocityEngine: ObservableObject {
    @Published var estimatedTimeRemaining: String = "Learning speed..."
    
    private var pageDurations: [Double] = []
    private let maxSamples = 15
    private let minValidDuration: Double = 2.0   // Ignore page-flips < 2s
    private let maxValidDuration: Double = 180.0 // Ignore idle periods > 3 mins (180s)
    private let minRequiredSamples = 3
    
    func recordPageDuration(_ duration: Double, remainingPages: Int) {
        // Filter outliers
        guard duration >= minValidDuration && duration <= maxValidDuration else { return }
        
        pageDurations.append(duration)
        if pageDurations.count > maxSamples {
            pageDurations.removeFirst()
        }
        
        recalculateEstimate(remainingPages: remainingPages)
    }
    
    private func recalculateEstimate(remainingPages: Int) {
        guard pageDurations.count >= minRequiredSamples else {
            estimatedTimeRemaining = "Learning speed..."
            return
        }
        
        let sum = pageDurations.reduce(0.0, +)
        let averageDuration = sum / Double(pageDurations.count)
        
        let remainingSeconds = Double(remainingPages) * averageDuration
        let remainingMinutes = Int(ceil(remainingSeconds / 60.0))
        
        if remainingMinutes <= 0 {
            estimatedTimeRemaining = "Less than a min left"
        } else if remainingMinutes < 60 {
            estimatedTimeRemaining = "\(remainingMinutes)m left"
        } else {
            let hours = remainingMinutes / 60
            let mins = remainingMinutes % 60
            if mins == 0 {
                estimatedTimeRemaining = "\(hours)h left"
            } else {
                estimatedTimeRemaining = "\(hours)h \(mins)m left"
            }
        }
    }
}
