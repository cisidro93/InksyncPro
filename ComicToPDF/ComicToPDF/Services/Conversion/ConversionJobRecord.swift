import Foundation

// MARK: - Job Status

enum ConversionJobStatus: String, Codable, CaseIterable {
    case queued     = "queued"
    case running    = "running"
    case succeeded  = "succeeded"
    case failed     = "failed"
    case retrying   = "retrying"
    case abandoned  = "abandoned"
}

// MARK: - Conversion Job Record

struct ConversionJobRecord: Codable, Identifiable {
    let id: UUID
    let fileID: UUID
    let fileName: String
    let outputFormat: String

    var status: ConversionJobStatus
    var attemptCount: Int
    var lastAttemptAt: Date?
    var failureReason: String?
    var nextRetryAt: Date?
    var enqueuedAt: Date
    var completedAt: Date?

    // Retry policy: 0s / 5s / permanent abandonment
    static func retryDelay(forAttemptCount attempt: Int) -> TimeInterval? {
        switch attempt {
        case 1: return 0      // Immediate retry
        case 2: return 5      // 5 second delay
        default: return nil   // Abandon
        }
    }

    init(
        fileID: UUID,
        fileName: String,
        outputFormat: String
    ) {
        self.id = UUID()
        self.fileID = fileID
        self.fileName = fileName
        self.outputFormat = outputFormat
        self.status = .queued
        self.attemptCount = 0
        self.lastAttemptAt = nil
        self.failureReason = nil
        self.nextRetryAt = nil
        self.enqueuedAt = Date()
        self.completedAt = nil
    }
}
