import Foundation

// Additive query layer on top of LibraryDatabaseService.
// All methods use parameterized SQL — zero string interpolation.
// Query execution time logged at .debug level.

struct LibraryQueryService {

    private static func timed<T>(_ label: String, block: () async throws -> T) async rethrows -> T {
        let start = Date()
        let result = try await block()
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        Logger.shared.log("LibraryQueryService [\(label)] completed in \(ms)ms", category: "Library")
        return result
    }

    // Returns files where completionFraction == 0 (never opened).
    // Optionally filtered by fileType ("COMIC", "MANGA", "BOOK", "HYBRID").
    static func fetchUnread(fileType: String? = nil) async -> [ConvertedPDF] {
        await timed("fetchUnread") {
            let db = LibraryDatabaseService.shared
            return await Task.detached(priority: .userInitiated) {
                guard let dbHandle = await db.databaseHandle() else { return [] }
                do {
                    let sql: String
                    let args: [Any]
                    if let ft = fileType {
                        sql = """
                            SELECT f.* FROM library_files f
                            LEFT JOIN reading_progress p ON f.id = p.fileID
                            WHERE f.fileType = ?
                            AND (p.completionFraction IS NULL OR p.completionFraction = 0.0)
                            ORDER BY f.addedAt DESC
                        """
                        args = [ft]
                    } else {
                        sql = """
                            SELECT f.* FROM library_files f
                            LEFT JOIN reading_progress p ON f.id = p.fileID
                            WHERE (p.completionFraction IS NULL OR p.completionFraction = 0.0)
                            ORDER BY f.addedAt DESC
                        """
                        args = []
                    }
                    let rows = try dbHandle.fetchAll(sql, arguments: args)
                    return rows.compactMap { LibraryFileRecord(row: $0)?.toDomainModel() }
                } catch {
                    Logger.shared.log("LibraryQueryService.fetchUnread failed: \(error.localizedDescription)", category: "Library", type: .error)
                    return []
                }
            }.value
        }
    }

    // Returns files added within a date range. after is inclusive. before defaults to now.
    static func fetchAdded(after: Date, before: Date? = nil) async -> [ConvertedPDF] {
        await timed("fetchAdded") {
            let db = LibraryDatabaseService.shared
            let afterTS = after.timeIntervalSince1970
            let beforeTS = (before ?? Date()).timeIntervalSince1970
            return await Task.detached(priority: .userInitiated) {
                guard let dbHandle = await db.databaseHandle() else { return [] }
                do {
                    let rows = try dbHandle.fetchAll(
                        "SELECT * FROM library_files WHERE addedAt >= ? AND addedAt <= ? ORDER BY addedAt DESC",
                        arguments: [afterTS, beforeTS]
                    )
                    return rows.compactMap { LibraryFileRecord(row: $0)?.toDomainModel() }
                } catch {
                    Logger.shared.log("LibraryQueryService.fetchAdded failed: \(error.localizedDescription)", category: "Library", type: .error)
                    return []
                }
            }.value
        }
    }

    // Returns all files in a given series, sorted by issueNumber then title.
    static func fetchSeries(_ seriesName: String) async -> [ConvertedPDF] {
        await timed("fetchSeries") {
            let db = LibraryDatabaseService.shared
            return await Task.detached(priority: .userInitiated) {
                guard let dbHandle = await db.databaseHandle() else { return [] }
                do {
                    let rows = try dbHandle.fetchAll(
                        "SELECT * FROM library_files WHERE series = ? ORDER BY issueNumber ASC, title ASC",
                        arguments: [seriesName]
                    )
                    return rows.compactMap { LibraryFileRecord(row: $0)?.toDomainModel() }
                } catch {
                    Logger.shared.log("LibraryQueryService.fetchSeries failed: \(error.localizedDescription)", category: "Library", type: .error)
                    return []
                }
            }.value
        }
    }

    // Full-text search across title, series, creator, publisher, and tags.
    // PERF H3: Uses FTS5 MATCH instead of 5× LIKE '%q%' — inverted index, O(log N).
    // Falls back to LIKE scan if the FTS table is empty on first run/migration.
    static func fetchSearch(query: String) async -> [ConvertedPDF] {
        await timed("fetchSearch") {
            let db = LibraryDatabaseService.shared
            // Build an FTS5 prefix-match expression: each token becomes "word*"
            let ftsQuery = query
                .components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty }
                .map { "\($0)*" }
                .joined(separator: " ")
            return await Task.detached(priority: .userInitiated) {
                guard let dbHandle = await db.databaseHandle() else { return [] }
                do {
                    let rows = try dbHandle.fetchAll("""
                        SELECT f.* FROM library_files f
                        JOIN library_fts ON library_fts.rowid = f.rowid
                        WHERE library_fts MATCH ?
                        ORDER BY rank
                        LIMIT 200
                    """, arguments: [ftsQuery])
                    if !rows.isEmpty {
                        return rows.compactMap { LibraryFileRecord(row: $0)?.toDomainModel() }
                    }
                    // FTS table empty (first launch before populate) — fall back to LIKE
                    let pattern = "%\(query)%"
                    let fallback = try dbHandle.fetchAll("""
                        SELECT * FROM library_files
                        WHERE title LIKE ?
                           OR series LIKE ?
                           OR creator LIKE ?
                           OR publisher LIKE ?
                           OR tags LIKE ?
                        ORDER BY addedAt DESC
                        LIMIT 200
                    """, arguments: [pattern, pattern, pattern, pattern, pattern])
                    return fallback.compactMap { LibraryFileRecord(row: $0)?.toDomainModel() }
                } catch {
                    Logger.shared.log("LibraryQueryService.fetchSearch failed: \(error.localizedDescription)", category: "Library", type: .error)
                    return []
                }
            }.value
        }
    }
}
