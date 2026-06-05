import Foundation
import Combine

// ARCH NOTE: LibraryDatabaseService is the GRDB-backed persistence actor. It is additive:
// it does NOT replace the existing SwiftData path in LibraryPersistenceManager.
// The existing SwiftData/MigrationService pipeline remains active.
// This actor exposes the clean 8-method API specified in the engineering brief,
// plus the 4 new query methods, as new public surface area.
//
// PERSISTENCE NOTE: SQLite (GRDB) is local-only by design.
// iCloud portability is handled via JSON export in BackupRestoreView.
// Do NOT move library.db into the iCloud Documents container.

// MARK: - Write Request (for coalescer)

private enum WriteRequest: Sendable {
    case saveFiles([ConvertedPDF])
    case saveProgress(ReadingProgress, String)
    case saveAnnotations([Annotation], String)
    case saveZettelRecord(ZettelRecord)
}

// MARK: - LibraryDatabaseService

actor LibraryDatabaseService {
    static let shared = LibraryDatabaseService()

    // MARK: Database path

    private static var databaseURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("InkSyncPro")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("library.db")
    }

    // MARK: State

    private var db: LibraryDB?
    private var writeStream: AsyncStream<WriteRequest>.Continuation?
    private var coalesceTask: Task<Void, Never>?
    private var buffer: [WriteRequest] = []
    private var debounceTask: Task<Void, Never>?

    private init() {}

    // MARK: - Bootstrap

    func bootstrap() async {
        do {
            let dbURL = Self.databaseURL
            let legacyJSONExists = FileManager.default.fileExists(
                atPath: dbURL.deletingLastPathComponent().appendingPathComponent("inksync_pro_library.json").path
            )

            let db = try LibraryDB(path: dbURL.path)
            try db.createSchema()
            self.db = db

            if legacyJSONExists && !UserDefaults.standard.bool(forKey: "grdb_migration_v1_complete") {
                await runMigration(db: db, legacyPath: dbURL.deletingLastPathComponent().appendingPathComponent("inksync_pro_library.json"))
            }

            startCoalescer()
        } catch {
            Logger.shared.log("LibraryDatabaseService: Bootstrap failed — \(error.localizedDescription)", category: "Import", type: .error)
        }
    }

    private func startCoalescer() {
        var continuation: AsyncStream<WriteRequest>.Continuation?
        let stream = AsyncStream<WriteRequest> { cont in continuation = cont }
        self.writeStream = continuation

        coalesceTask = Task.detached(priority: .background) { [weak self] in
            for await request in stream {
                guard let self = self else { break }
                await self.enqueueCoalesce(request)
            }
        }
    }

    private func enqueueCoalesce(_ request: WriteRequest) {
        buffer.append(request)
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            let requestsToFlush = self.buffer
            self.buffer.removeAll()
            await self.flushBuffer(requestsToFlush)
        }
    }

    private func flushBuffer(_ requests: [WriteRequest]) async {
        guard let db = self.db else { return }
        do {
            try db.write { handle in
                for req in requests {
                    switch req {
                    case .saveFiles(let pdfs):
                        let existingRows = try handle.fetchAll("SELECT * FROM library_files")
                        var existingRecords: [String: LibraryFileRecord] = [:]
                        for row in existingRows {
                            if let r = LibraryFileRecord(row: row) { existingRecords[r.id] = r }
                        }
                        
                        let newIds = Set(pdfs.map { $0.id.uuidString })
                        for pdf in pdfs {
                            var rec = LibraryFileRecord.from(pdf)
                            if let existing = existingRecords[rec.id] {
                                // Ignore modifiedAt difference
                                var tempRec = rec
                                tempRec.modifiedAt = existing.modifiedAt
                                if tempRec == existing { continue }
                            }
                            try rec.upsert(handle)
                        }
                        
                        for existingId in existingRecords.keys {
                            if !newIds.contains(existingId) {
                                try handle.execute("DELETE FROM library_files WHERE id = ?", arguments: [existingId])
                            }
                        }
                    case .saveProgress(let progress, let fileID):
                        let rec = ReadingProgressRecord.from(fileID: fileID, progress: progress)
                        try rec.upsert(handle)
                    case .saveAnnotations(let anns, let fileID):
                        try handle.execute("DELETE FROM annotations WHERE fileID = ?", arguments: [fileID])
                        for ann in anns {
                            let rec = AnnotationRecord.from(ann)
                            try rec.upsert(handle)
                        }
                    case .saveZettelRecord(let rec):
                        try rec.upsert(handle)
                    }
                }
            }
        } catch {
            Logger.shared.log("LibraryDatabaseService: Flush failed — \(error.localizedDescription)", category: "Import", type: .error)
        }
    }

    // MARK: - Public API (Spec-Required Eight Methods)

    func save(_ library: [ConvertedPDF]) {
        writeStream?.yield(.saveFiles(library))
    }


    func load() async -> [ConvertedPDF] {
        guard let db = self.db else { return [] }
        do {
            return try await Task.detached(priority: .userInitiated) {
                try db.read { handle in
                    let rows = try handle.fetchAll("SELECT * FROM library_files ORDER BY addedAt DESC")
                    return rows.compactMap { row -> ConvertedPDF? in
                        guard let rec = LibraryFileRecord(row: row) else { return nil }
                        return rec.toDomainModel()
                    }
                }
            }.value
        } catch {
            Logger.shared.log("LibraryDatabaseService: Load failed — \(error.localizedDescription)", category: "Import", type: .error)
            return []
        }
    }

    func saveProgress(_ progress: ReadingProgress, for fileID: String) {
        writeStream?.yield(.saveProgress(progress, fileID))
    }

    func loadProgress(for fileID: String) async -> ReadingProgress? {
        guard let db = self.db else { return nil }
        do {
            return try await Task.detached(priority: .userInitiated) {
                try db.read { handle in
                    let rows = try handle.fetchAll(
                        "SELECT * FROM reading_progress WHERE fileID = ? LIMIT 1",
                        arguments: [fileID]
                    )
                    return rows.first.flatMap { ReadingProgressRecord(row: $0)?.toDomainModel() }
                }
            }.value
        } catch {
            Logger.shared.log("LibraryDatabaseService: loadProgress failed — \(error.localizedDescription)", category: "Import", type: .error)
            return nil
        }
    }

    func saveAnnotations(_ annotations: [Annotation], for fileID: String) {
        writeStream?.yield(.saveAnnotations(annotations, fileID))
    }

    func loadAnnotations(for fileID: String) async -> [Annotation] {
        guard let db = self.db else { return [] }
        do {
            return try await Task.detached(priority: .userInitiated) {
                try db.read { handle in
                    let rows = try handle.fetchAll(
                        "SELECT * FROM annotations WHERE fileID = ? ORDER BY pageIndex ASC",
                        arguments: [fileID]
                    )
                    return rows.compactMap { AnnotationRecord(row: $0)?.toDomainModel() }
                }
            }.value
        } catch {
            Logger.shared.log("LibraryDatabaseService: loadAnnotations failed — \(error.localizedDescription)", category: "Import", type: .error)
            return []
        }
    }

    func saveZettelRecord(_ record: ZettelRecord) {
        writeStream?.yield(.saveZettelRecord(record))
    }

    func loadAllZettelRecords() async -> [ZettelRecord] {
        guard let db = self.db else { return [] }
        do {
            return try await Task.detached(priority: .userInitiated) {
                try db.read { handle in
                    let rows = try handle.fetchAll("SELECT * FROM zettel_notes ORDER BY modifiedAt DESC")
                    return rows.compactMap { ZettelRecord(row: $0) }
                }
            }.value
        } catch {
            Logger.shared.log("LibraryDatabaseService: loadAllZettelRecords failed — \(error.localizedDescription)", category: "Import", type: .error)
            return []
        }
    }

    // MARK: - Migration

    private func runMigration(db: LibraryDB, legacyPath: URL) async {
        Logger.shared.log("LibraryDatabaseService: Starting one-time v1 migration", category: "Import")
        do {
            guard let data = try? Data(contentsOf: legacyPath) else {
                Logger.shared.log("LibraryDatabaseService: No legacy JSON found — skipping migration", category: "Import")
                UserDefaults.standard.set(true, forKey: "grdb_migration_v1_complete")
                return
            }

            let index = try JSONDecoder().decode(LibraryPersistenceManager.LibraryIndex.self, from: data)
            let pdfs = index.files

            try db.write { handle in
                let batchSize = 100
                for batchStart in stride(from: 0, to: pdfs.count, by: batchSize) {
                    let batch = pdfs[batchStart..<min(batchStart + batchSize, pdfs.count)]
                    for pdf in batch {
                        let rec = LibraryFileRecord.from(pdf)
                        try rec.upsert(handle)
                    }
                }
            }

            let safetyURL = legacyPath.deletingLastPathComponent()
                .appendingPathComponent("library.db.migrated.json")
            let tmpURL = legacyPath.deletingLastPathComponent()
                .appendingPathComponent("library.db.migrated.tmp.json")
            try data.write(to: tmpURL)
            _ = try FileManager.default.replaceItemAt(safetyURL, withItemAt: tmpURL)

            UserDefaults.standard.set(true, forKey: "grdb_migration_v1_complete")
            Logger.shared.log("LibraryDatabaseService: Migration complete — \(pdfs.count) records migrated", category: "Import")
        } catch {
            Logger.shared.log("LibraryDatabaseService: Migration failed — \(error.localizedDescription). Falling back to SwiftData path.", category: "Import", type: .error)
        }
    }

    // Used by LibraryQueryService (same module, different file — needs internal access)
    func databaseHandle() -> LibraryDB? {
        return self.db
    }
}

// MARK: - LibraryDB (Thin SQLite wrapper — replaces GRDB dependency for SPM-free compilation)
// ARCH NOTE: This is a lightweight wrapper over SQLite3 via the swift-sqlite Zephyr approach.
// It avoids the SPM GRDB add which requires manual Xcode action.
// Once GRDB is added via SPM, replace this with actual DatabaseQueue calls.

import SQLite3

final class LibraryDB: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let path: String

    init(path: String) throws {
        self.path = path
        guard sqlite3_open(path, &handle) == SQLITE_OK else {
            throw NSError(domain: "LibraryDB", code: Int(sqlite3_errcode(handle)))
        }
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA foreign_keys=ON")
    }

    deinit { sqlite3_close(handle) }

    func createSchema() throws {
        try execute("""
            CREATE TABLE IF NOT EXISTS library_files (
                id TEXT PRIMARY KEY,
                path TEXT NOT NULL,
                filename TEXT NOT NULL,
                fileType TEXT NOT NULL,
                isManga INTEGER NOT NULL DEFAULT 0,
                series TEXT,
                issueNumber TEXT,
                volume TEXT,
                title TEXT,
                publisher TEXT,
                publicationDate TEXT,
                creator TEXT,
                descriptionText TEXT,
                genre TEXT,
                language TEXT,
                tags TEXT,
                pageCount INTEGER,
                readingDirection TEXT,
                selectedCoverID TEXT,
                coverVariants TEXT,
                customFields TEXT,
                addedAt REAL NOT NULL,
                modifiedAt REAL NOT NULL,
                isLinkedFile INTEGER NOT NULL DEFAULT 0,
                bookmarkData BLOB
            );
            CREATE INDEX IF NOT EXISTS idx_lf_series   ON library_files(series);
            CREATE INDEX IF NOT EXISTS idx_lf_fileType ON library_files(fileType);
            CREATE INDEX IF NOT EXISTS idx_lf_addedAt  ON library_files(addedAt);
            CREATE INDEX IF NOT EXISTS idx_lf_isManga  ON library_files(isManga);

            CREATE TABLE IF NOT EXISTS reading_progress (
                fileID TEXT PRIMARY KEY REFERENCES library_files(id) ON DELETE CASCADE,
                currentPage INTEGER NOT NULL DEFAULT 0,
                totalPages INTEGER NOT NULL DEFAULT 0,
                completionFraction REAL NOT NULL DEFAULT 0.0,
                lastOpenedAt REAL,
                isCompleted INTEGER NOT NULL DEFAULT 0
            );

            CREATE TABLE IF NOT EXISTS annotations (
                id TEXT PRIMARY KEY,
                fileID TEXT NOT NULL REFERENCES library_files(id) ON DELETE CASCADE,
                pageIndex INTEGER NOT NULL,
                type TEXT NOT NULL,
                color TEXT,
                textContent TEXT,
                normalizedX REAL,
                normalizedY REAL,
                normalizedW REAL,
                normalizedH REAL,
                inkData BLOB,
                createdAt REAL NOT NULL,
                contentHash TEXT,
                zettelID TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_ann_fileID      ON annotations(fileID);
            CREATE INDEX IF NOT EXISTS idx_ann_contentHash ON annotations(contentHash)
                WHERE contentHash IS NOT NULL;

            CREATE TABLE IF NOT EXISTS zettel_notes (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                body TEXT NOT NULL DEFAULT '',
                tags TEXT,
                backlinks TEXT,
                sourceFileID TEXT REFERENCES library_files(id) ON DELETE SET NULL,
                sourcePage INTEGER,
                createdAt REAL NOT NULL,
                modifiedAt REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_zn_sourceFileID ON zettel_notes(sourceFileID);

            -- PERF H3: FTS5 virtual table for O(log N) library search.
            -- LIKE '%q%' on 5 columns forces a full table scan on every keystroke;
            -- FTS5 MATCH uses an inverted index and is ~100x faster at scale.
            -- content='' + content_rowid= makes this a "contentless" FTS5 table
            -- that stores only the index, not duplicated text.
            CREATE VIRTUAL TABLE IF NOT EXISTS library_fts USING fts5(
                title, series, creator, publisher, tags,
                content='library_files',
                content_rowid='rowid'
            );
        """)
    }

    func read<T>(_ block: (LibraryDB) throws -> T) throws -> T {
        try block(self)
    }

    func write(_ block: (LibraryDB) throws -> Void) throws {
        try execute("BEGIN TRANSACTION")
        do {
            try block(self)
            try execute("COMMIT")
        } catch {
            _ = try? execute("ROLLBACK")
            throw error
        }
    }

    @discardableResult
    func execute(_ sql: String, arguments: [Any] = []) throws -> [[String: Any]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(domain: "LibraryDB", code: Int(sqlite3_errcode(handle)),
                          userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(handle))])
        }
        defer { sqlite3_finalize(stmt) }

        for (i, arg) in arguments.enumerated() {
            let idx = Int32(i + 1)
            switch arg {
            case let s as String: sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
            case let n as Int:    sqlite3_bind_int64(stmt, idx, Int64(n))
            case let d as Double: sqlite3_bind_double(stmt, idx, d)
            case let b as Data:   _ = b.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32(b.count), SQLITE_TRANSIENT) }
            default:              sqlite3_bind_null(stmt, idx)
            }
        }

        var rows: [[String: Any]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [String: Any] = [:]
            for col in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, col))
                switch sqlite3_column_type(stmt, col) {
                case SQLITE_INTEGER: row[name] = Int(sqlite3_column_int64(stmt, col))
                case SQLITE_FLOAT:   row[name] = sqlite3_column_double(stmt, col)
                case SQLITE_TEXT:    row[name] = String(cString: sqlite3_column_text(stmt, col))
                case SQLITE_BLOB:
                    let bytes = sqlite3_column_blob(stmt, col)
                    let count = Int(sqlite3_column_bytes(stmt, col))
                    if let b = bytes { row[name] = Data(bytes: b, count: count) }
                default: break
                }
            }
            rows.append(row)
        }

        return rows
    }

    func fetchAll(_ sql: String, arguments: [Any] = []) throws -> [[String: Any]] {
        try execute(sql, arguments: arguments)
    }
}

// MARK: - SQLITE_TRANSIENT shim

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - Record Upsert helpers

extension LibraryFileRecord {
    func upsert(_ db: LibraryDB) throws {
        try db.execute("""
            INSERT OR REPLACE INTO library_files
            (id, path, filename, fileType, isManga, series, issueNumber, volume,
             title, publisher, publicationDate, creator, descriptionText, genre, language,
             tags, pageCount, readingDirection, selectedCoverID, coverVariants, customFields,
             addedAt, modifiedAt, isLinkedFile, bookmarkData)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        """, arguments: [
            id, path, filename, fileType, isManga,
            series as Any, issueNumber as Any, volume as Any,
            title as Any, publisher as Any, publicationDate as Any,
            creator as Any, descriptionText as Any, genre as Any, language as Any,
            tags as Any, pageCount as Any, readingDirection as Any,
            selectedCoverID as Any, coverVariants as Any, customFields as Any,
            addedAt, modifiedAt, isLinkedFile,
            bookmarkData as Any
        ])
    }

    init?(row: [String: Any]) {
        guard let id = row["id"] as? String,
              let path = row["path"] as? String,
              let filename = row["filename"] as? String,
              let fileType = row["fileType"] as? String,
              let addedAt = row["addedAt"] as? Double,
              let modifiedAt = row["modifiedAt"] as? Double else { return nil }
        self.id = id; self.path = path; self.filename = filename
        self.fileType = fileType
        self.isManga = (row["isManga"] as? Int) ?? 0
        self.series = row["series"] as? String
        self.issueNumber = row["issueNumber"] as? String
        self.volume = row["volume"] as? String
        self.title = row["title"] as? String
        self.publisher = row["publisher"] as? String
        self.publicationDate = row["publicationDate"] as? String
        self.creator = row["creator"] as? String
        self.descriptionText = row["descriptionText"] as? String
        self.genre = row["genre"] as? String
        self.language = row["language"] as? String
        self.tags = row["tags"] as? String
        self.pageCount = row["pageCount"] as? Int
        self.readingDirection = row["readingDirection"] as? String
        self.selectedCoverID = row["selectedCoverID"] as? String
        self.coverVariants = row["coverVariants"] as? String
        self.customFields = row["customFields"] as? String
        self.addedAt = addedAt; self.modifiedAt = modifiedAt
        self.isLinkedFile = (row["isLinkedFile"] as? Int) ?? 0
        self.bookmarkData = row["bookmarkData"] as? Data
    }
}

extension ReadingProgressRecord {
    func upsert(_ db: LibraryDB) throws {
        try db.execute("""
            INSERT OR REPLACE INTO reading_progress
            (fileID, currentPage, totalPages, completionFraction, lastOpenedAt, isCompleted)
            VALUES (?,?,?,?,?,?)
        """, arguments: [fileID, currentPage, totalPages, completionFraction, lastOpenedAt, isCompleted])
    }

    init?(row: [String: Any]) {
        guard let fileID = row["fileID"] as? String else { return nil }
        self.fileID = fileID
        self.currentPage = (row["currentPage"] as? Int) ?? 0
        self.totalPages = (row["totalPages"] as? Int) ?? 0
        self.completionFraction = (row["completionFraction"] as? Double) ?? 0
        self.lastOpenedAt = (row["lastOpenedAt"] as? Double) ?? 0
        self.isCompleted = (row["isCompleted"] as? Int) ?? 0
    }
}

extension AnnotationRecord {
    func upsert(_ db: LibraryDB) throws {
        try db.execute("""
            INSERT OR REPLACE INTO annotations
            (id, fileID, pageIndex, type, color, textContent,
             normalizedX, normalizedY, normalizedW, normalizedH,
             inkData, createdAt, contentHash, zettelID)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        """, arguments: [
            id, fileID, pageIndex, type,
            color as Any, textContent as Any,
            normalizedX as Any, normalizedY as Any, normalizedW as Any, normalizedH as Any,
            inkData as Any, createdAt,
            contentHash as Any, zettelID as Any
        ])
    }

    init?(row: [String: Any]) {
        guard let id = row["id"] as? String,
              let fileID = row["fileID"] as? String,
              let type = row["type"] as? String,
              let createdAt = row["createdAt"] as? Double else { return nil }
        self.id = id; self.fileID = fileID
        self.pageIndex = (row["pageIndex"] as? Int) ?? 0
        self.type = type
        self.color = row["color"] as? String
        self.textContent = row["textContent"] as? String
        self.normalizedX = row["normalizedX"] as? Double
        self.normalizedY = row["normalizedY"] as? Double
        self.normalizedW = row["normalizedW"] as? Double
        self.normalizedH = row["normalizedH"] as? Double
        self.inkData = row["inkData"] as? Data
        self.createdAt = createdAt
        self.contentHash = row["contentHash"] as? String
        self.zettelID = row["zettelID"] as? String
    }
}

extension ZettelRecord {
    func upsert(_ db: LibraryDB) throws {
        try db.execute("""
            INSERT OR REPLACE INTO zettel_notes
            (id, title, body, tags, backlinks, sourceFileID, sourcePage, createdAt, modifiedAt)
            VALUES (?,?,?,?,?,?,?,?,?)
        """, arguments: [
            id, title, body,
            tags as Any, backlinks as Any,
            sourceFileID as Any, sourcePage as Any,
            createdAt, modifiedAt
        ])
    }

    init?(row: [String: Any]) {
        guard let id = row["id"] as? String,
              let title = row["title"] as? String,
              let createdAt = row["createdAt"] as? Double,
              let modifiedAt = row["modifiedAt"] as? Double else { return nil }
        self.id = id; self.title = title
        self.body = (row["body"] as? String) ?? ""
        self.tags = row["tags"] as? String
        self.backlinks = row["backlinks"] as? String
        self.sourceFileID = row["sourceFileID"] as? String
        self.sourcePage = row["sourcePage"] as? Int
        self.createdAt = createdAt; self.modifiedAt = modifiedAt
    }
}
