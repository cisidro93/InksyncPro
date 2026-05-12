import Foundation

// Pure merge logic — no I/O, no actors, fully testable.
// Implements all 7 merge rules from the engineering brief in priority order.

struct CloudSyncMerger {

    func merge(
        local: LibrarySyncPayload,
        localVector: [String: Int],
        remote: LibrarySyncEnvelope
    ) -> MergeResult {
        var mergedFiles: [SyncFileRecord] = []
        var conflicts: [SyncConflict] = []

        let localByID  = Dictionary(uniqueKeysWithValues: local.files.map { ($0.metadata.id, $0) })
        let remoteByID = Dictionary(uniqueKeysWithValues: remote.records.files.map { ($0.metadata.id, $0) })
        let tombstoneByID = Dictionary(uniqueKeysWithValues: remote.records.deletions.map { ($0.fileID, $0) })

        let allIDs = Set(localByID.keys).union(remoteByID.keys)

        for fileID in allIDs {
            let localRec  = localByID[fileID]
            let remoteRec = remoteByID[fileID]

            // Rule 1: Remote only → accept unconditionally
            if localRec == nil, let r = remoteRec {
                mergedFiles.append(r)
                continue
            }

            // Rule 2: Local only → keep unconditionally (unless tombstoned, handled below)
            if remoteRec == nil, let l = localRec {
                // Rule 6 + 7: Check for remote tombstone
                if let tombstone = tombstoneByID[fileID.uuidString] {
                    let localModifiedClock = l.modifiedClock
                    let tombstoneClock = tombstone.deletedClock

                    if localModifiedClock > tombstoneClock {
                        // Rule 7: Local was modified after deletion → keep, emit conflict
                        mergedFiles.append(l)
                        conflicts.append(.deleteModifyConflict(fileID: fileID.uuidString, survivor: l))
                    }
                    // Rule 6: Local not modified after tombstone → apply deletion (do not append)
                } else {
                    mergedFiles.append(l)
                }
                continue
            }

            guard let l = localRec, let r = remoteRec else { continue }

            // Determine shared sync point: highest clock both devices agreed on
            let sharedClock = localVector[r.modifiedBy] ?? 0
            let localModifiedSinceShared  = l.modifiedClock > sharedClock
            let remoteModifiedSinceShared = r.modifiedClock > sharedClock

            // Rule 4: Only one side modified → take modified side
            if localModifiedSinceShared && !remoteModifiedSinceShared {
                mergedFiles.append(l)
                continue
            }
            if remoteModifiedSinceShared && !localModifiedSinceShared {
                mergedFiles.append(r)
                continue
            }

            // Rule 5: Both modified since shared sync point → conflict, keep local
            if localModifiedSinceShared && remoteModifiedSinceShared {
                mergedFiles.append(l)
                conflicts.append(.metadataConflict(fileID: fileID.uuidString, local: l, remote: r))
                continue
            }

            // Neither modified since sync → keep local (identical)
            mergedFiles.append(l)
        }

        // Rule 3: Merge progress — always take higher completionFraction
        var progressMap: [String: SyncProgressRecord] = [:]
        for p in local.progress { progressMap[p.fileID] = p }
        for p in remote.records.progress {
            if let existing = progressMap[p.fileID] {
                if p.progress.completionFraction > existing.progress.completionFraction {
                    progressMap[p.fileID] = p
                } else if p.progress.completionFraction == existing.progress.completionFraction {
                    let remoteDate = p.progress.lastOpenedAt
                    let localDate  = existing.progress.lastOpenedAt
                    if remoteDate > localDate { progressMap[p.fileID] = p }
                }
            } else {
                progressMap[p.fileID] = p
            }
        }

        let merged = LibrarySyncPayload(
            files: mergedFiles,
            progress: Array(progressMap.values),
            deletions: []
        )

        return MergeResult(merged: merged, conflicts: conflicts)
    }
}

// MARK: - Result Types

struct MergeResult {
    let merged: LibrarySyncPayload
    let conflicts: [SyncConflict]
}

enum SyncConflict {
    case metadataConflict(fileID: String, local: SyncFileRecord, remote: SyncFileRecord)
    case deleteModifyConflict(fileID: String, survivor: SyncFileRecord)
}
