# iCloud Architecture & Duplicate Engine Post-Mortem

**Date:** March 28, 2026

## Objective
The goal was to definitively solve the issue of iOS aggressively syncing heavy comic files (.cbz, .epub) in the public `Documents` directory via iCloud Drive. Duplicate files ("file 2", "file 3", etc.) were being created automatically when space was low, or iCloud encountered sync conflicts.

## The Strategy (What We Tried)
We attempted to build an isolated **Inbox / Vault Architecture** paired with a **Duplicate Quarantine Engine**.

### 1. The Inbox / Vault Routing
Instead of acting natively inside `Documents`, we split the application's file system:
- **The Inbox (`Documents`):** Served only as a drop zone for users copying files in via the iOS Files app or PC.
- **The Vault (`Library/Application Support/InksyncVault`):** A private, non-user-accessible directory immune to Apple's native iCloud Document syncing. 
- **Implementation:** Built `AppStorageContext.swift` to globally detour all file operations away from `Documents` to the `Vault`. `LibraryScanner.swift` was fitted with an ingestion engine that would passively watch the Inbox, ingest new items, move them to the Vault, and strip the iCloud metadata flags.

### 2. The Duplicate Quarantine Engine
To handle historical duplicates that iCloud already ghosted on the system:
- Built `DuplicateReviewManager.swift` and `QuarantineManager.swift` to generate SHA-256 hashes of the files.
- Added UX components (`DuplicateResolutionView.swift` and `LibraryRecoveryBannerView.swift`) so the user could manually resolve duplicates in batches instead of waiting for the scanner.

## Why It Failed
1. **Unmanageable Bloat:** The Inbox-to-Vault ingestion loop was imperfect. If parsing failed, or the file was too large, the app essentially held two copies of massive comic files natively on-device, leading to massive storage bloat.
2. **Broken UX for Manual Conflict Resolution:** The `DuplicateReviewManager` logic failed at scale. Even when the user empirically verified duplicates existed in the Inbox, triggering the duplicate resolution system incorrectly reported "no duplicates found."
3. **Severe Technical Debt:** Re-routing 15+ complex storage systems, conversion engines, and PDF parsers to dynamically determine whether they should read from the Vault or Inbox became too complex and prone to catastrophic compiler timeouts. 

## Next Steps Forward
For future implementations, **DO NOT attempt to fight iCloud at the file level by copying items internally to a Vault.**

Instead, if we try this again later, we should:
1. Allow the user to keep everything in `Documents`.
2. Apply the `URLResourceKey.isExcludedFromBackupKey` directly to the active files without moving them around.
3. If duplicates appear, do not use an ingestion flow. Simply use a fast Regex scan on the filename strings (e.g., `* 2.cbz`) as a secondary heuristic rather than relying on deep SHA hashing and a separate Quarantine state manager.
