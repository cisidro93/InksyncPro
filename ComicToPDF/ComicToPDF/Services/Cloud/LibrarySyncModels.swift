import Foundation

// MARK: - Sync Envelope

struct LibrarySyncEnvelope: Codable {
    let schemaVersion: Int              // Current: 2. v1 = legacy bare JSON
    let deviceID: String                // Stable per-device UUID from Keychain
    let vectorClock: [String: Int]      // deviceID → logical clock value
    let exportedAt: TimeInterval        // Wall-clock timestamp (informational only)
    let records: LibrarySyncPayload
}

// MARK: - Sync Payload

struct LibrarySyncPayload: Codable {
    let files: [SyncFileRecord]
    let progress: [SyncProgressRecord]
    let deletions: [SyncTombstone]
}

// MARK: - Sync File Record

struct SyncFileRecord: Codable {
    let metadata: ConvertedPDF
    let modifiedBy: String              // deviceID of last writer
    let modifiedClock: Int              // Clock value at time of last write
}

// MARK: - Sync Progress Record

struct SyncProgressRecord: Codable {
    let fileID: String
    let progress: ReaderProgressTracker
    let modifiedBy: String
    let modifiedClock: Int
}

// MARK: - Sync Tombstone

struct SyncTombstone: Codable {
    let fileID: String
    let deletedBy: String
    let deletedClock: Int
}
