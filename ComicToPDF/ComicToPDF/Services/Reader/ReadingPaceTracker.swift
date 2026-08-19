import Foundation

// MARK: - Dynamic Reading Pace Tracker Actor

/// High-precision reading pace tracker computing running exponential moving average
/// Words Per Minute (WPM) to estimate remaining reading time in active chapters and books.
public actor ReadingPaceTracker {
    
    public static let shared = ReadingPaceTracker()
    
    // Default adult baseline reading speed: 220 WPM
    private var smoothedWPM: Double = 220.0
    private let smoothingAlpha: Double = 0.25
    
    // History buffer for recent page turns (words, seconds)
    private var turnHistory: [(words: Int, duration: TimeInterval)] = []
    
    public init() {}
    
    // MARK: - Pace Recording API
    
    /// Records a completed page turn with the word count and duration spent reading.
    /// Filters out rapid skimming (< 2 seconds) and long idle pauses (> 300 seconds).
    public func recordPageTurn(wordsOnPage: Int, timeSpentSeconds: TimeInterval) {
        guard wordsOnPage > 10, timeSpentSeconds >= 2.0 && timeSpentSeconds <= 300.0 else {
            return
        }
        
        let sessionWPM = (Double(wordsOnPage) / timeSpentSeconds) * 60.0
        
        // Clamp raw session WPM to realistic bounds [80 ... 800 WPM]
        let clampedWPM = max(80.0, min(800.0, sessionWPM))
        
        // Exponential Moving Average (EMA)
        smoothedWPM = (smoothingAlpha * clampedWPM) + ((1.0 - smoothingAlpha) * smoothedWPM)
        
        turnHistory.append((words: wordsOnPage, duration: timeSpentSeconds))
        if turnHistory.count > 20 {
            turnHistory.removeFirst()
        }
    }
    
    /// Returns the current smoothed reading speed in words per minute.
    public func currentWPM() -> Double {
        return smoothedWPM
    }
    
    // MARK: - Time Estimation Calculations
    
    /// Computes the estimated remaining time in seconds to finish the active chapter.
    public func remainingTimeInChapter(totalWordsInChapter: Int, currentWordOffset: Int) -> TimeInterval {
        let remainingWords = max(0, totalWordsInChapter - currentWordOffset)
        guard remainingWords > 0, smoothedWPM > 0 else { return 0 }
        
        let minutes = Double(remainingWords) / smoothedWPM
        return minutes * 60.0
    }
    
    /// Returns a human-friendly string for the remaining time in the active chapter (e.g. "4 min left in chapter").
    public func formattedRemainingTimeInChapter(totalWordsInChapter: Int, currentWordOffset: Int) -> String {
        let seconds = remainingTimeInChapter(totalWordsInChapter: totalWordsInChapter, currentWordOffset: currentWordOffset)
        let minutes = Int(ceil(seconds / 60.0))
        
        if minutes <= 0 {
            return "< 1 min left"
        } else if minutes == 1 {
            return "1 min left in chapter"
        } else if minutes < 60 {
            return "\(minutes) min left in chapter"
        } else {
            let hours = minutes / 60
            let remMin = minutes % 60
            return "\(hours)h \(remMin)m left in chapter"
        }
    }
    
    /// Resets the tracker back to the default baseline speed.
    public func resetPace() {
        smoothedWPM = 220.0
        turnHistory.removeAll()
    }
}
