import Foundation

// ARCH NOTE: These structs are the private persistence boundary between the domain layer
// and GRDB. They are intentionally NOT the domain models (ConvertedPDF, Annotation, etc.)
// so that the persistence schema can evolve independently of the public API.
// Conversion happens at the actor boundary inside LibraryDatabaseService.

// MARK: - LibraryFileRecord

struct LibraryFileRecord: Codable, Equatable {
    static let databaseTableName = "library_files"

    var id: String
    var path: String
    var filename: String
    var fileType: String
    var isManga: Int
    var series: String?
    var issueNumber: String?
    var volume: String?
    var title: String?
    var publisher: String?
    var publicationDate: String?
    var creator: String?
    var descriptionText: String?
    var genre: String?
    var language: String?
    var tags: String?           // JSON [String]
    var pageCount: Int?
    var readingDirection: String?
    var selectedCoverID: String?
    var coverVariants: String?  // JSON dict
    var customFields: String?   // JSON dict
    var addedAt: Double
    var modifiedAt: Double
    var isLinkedFile: Int
    var bookmarkData: Data?

    // MARK: Domain → Record

    static func from(_ pdf: ConvertedPDF) -> LibraryFileRecord {
        let encoder = JSONEncoder()
        func encodeOrNil<T: Encodable>(_ value: T) -> String? {
            (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) }
        }

        let fileType: String
        switch pdf.contentType {
        case .comic:  fileType = "COMIC"
        case .manga:  fileType = "MANGA"
        case .book:   fileType = "BOOK"
        case .hybrid: fileType = "HYBRID"
        }

        let pubDateStr: String? = pdf.metadata.publicationDate.map { ISO8601DateFormatter().string(from: $0) }

        let coverVariantsStr: String? = {
            let dict = pdf.metadata.coverVariants.reduce(into: [String: String]()) { acc, kv in
                acc[kv.key.uuidString] = kv.value.absoluteString
            }
            return encodeOrNil(dict)
        }()

        return LibraryFileRecord(
            id: pdf.id.uuidString,
            path: pdf.url.absoluteString,
            filename: pdf.name,
            fileType: fileType,
            isManga: (pdf.metadata.isManga == true) ? 1 : 0,
            series: pdf.metadata.series,
            issueNumber: pdf.metadata.issueNumber,
            volume: pdf.metadata.volume,
            title: pdf.metadata.title,
            publisher: pdf.metadata.publisher,
            publicationDate: pubDateStr,
            creator: pdf.metadata.author,
            descriptionText: pdf.metadata.summary,
            genre: nil,
            language: nil,
            tags: encodeOrNil(pdf.metadata.tags),
            pageCount: pdf.pageCount,
            readingDirection: nil,
            selectedCoverID: pdf.metadata.selectedCoverID?.uuidString,
            coverVariants: coverVariantsStr,
            customFields: nil,
            addedAt: pdf.lastModified.timeIntervalSince1970,
            modifiedAt: Date().timeIntervalSince1970,
            isLinkedFile: pdf.isLinked ? 1 : 0,
            bookmarkData: pdf.driveBookmarkData
        )
    }

    func toDomainModel() -> ConvertedPDF {
        let decoder = JSONDecoder()
        func decodeOrEmpty<T: Decodable>(_ str: String?, as: T.Type) -> T? {
            guard let s = str, let d = s.data(using: .utf8) else { return nil }
            return try? decoder.decode(T.self, from: d)
        }

        let id = UUID(uuidString: self.id) ?? UUID()
        let url = URL(string: path) ?? URL(fileURLWithPath: path)

        var metadata = PDFMetadata(title: title ?? filename)
        metadata.series = series
        metadata.issueNumber = issueNumber
        metadata.volume = volume
        metadata.publisher = publisher
        metadata.author = creator
        metadata.summary = descriptionText
        metadata.isManga = isManga == 1
        metadata.tags = decodeOrEmpty(tags, as: [String].self) ?? []

        if let pubStr = publicationDate {
            metadata.publicationDate = ISO8601DateFormatter().date(from: pubStr)
        }

        if let covID = selectedCoverID.flatMap({ UUID(uuidString: $0) }) {
            metadata.selectedCoverID = covID
        }

        if let varStr = coverVariants,
           let varDict = decodeOrEmpty(varStr, as: [String: String].self) {
            metadata.coverVariants = varDict.reduce(into: [:]) { acc, kv in
                if let k = UUID(uuidString: kv.key), let v = URL(string: kv.value) {
                    acc[k] = v
                }
            }
        }

        let contentType: ContentType
        switch fileType {
        case "MANGA":  contentType = .manga
        case "BOOK":   contentType = .book
        case "HYBRID": contentType = .hybrid
        default:       contentType = .comic
        }

        var pdf = ConvertedPDF(
            id: id,
            name: filename,
            url: url,
            pageCount: pageCount ?? 0,
            fileSize: 0,
            metadata: metadata,
            contentType: contentType
        )

        if isLinkedFile == 1, let bkData = bookmarkData {
            pdf.sourceMode = .linked(bookmarkData: bkData)
        }

        return pdf
    }
}

// MARK: - ReadingProgressRecord

struct ReadingProgressRecord: Codable, Equatable {
    static let databaseTableName = "reading_progress"

    var fileID: String
    var currentPage: Int
    var totalPages: Int
    var completionFraction: Double
    var lastOpenedAt: Double
    var isCompleted: Int

    static func from(fileID: String, progress: ReadingProgress) -> ReadingProgressRecord {
        ReadingProgressRecord(
            fileID: fileID,
            currentPage: progress.currentPageIndex,
            totalPages: 0,
            completionFraction: progress.completionFraction,
            lastOpenedAt: progress.lastOpenedAt.timeIntervalSince1970,
            isCompleted: progress.completionFraction >= 1.0 ? 1 : 0
        )
    }

    func toDomainModel() -> ReadingProgress {
        ReadingProgress(
            pdfID: UUID(uuidString: fileID) ?? UUID(),
            lastOpenedAt: Date(timeIntervalSince1970: lastOpenedAt),
            currentPageIndex: currentPage,
            currentChapterIndex: nil,
            currentChapterOffset: nil,
            totalPagesRead: currentPage,
            completionFraction: completionFraction,
            readingSessionDates: []
        )
    }
}

// MARK: - AnnotationRecord

struct AnnotationRecord: Codable, Equatable {
    static let databaseTableName = "annotations"

    var id: String
    var fileID: String
    var pageIndex: Int
    var type: String
    var color: String?
    var textContent: String?
    var normalizedX: Double?
    var normalizedY: Double?
    var normalizedW: Double?
    var normalizedH: Double?
    var inkData: Data?
    var createdAt: Double
    var contentHash: String?
    var zettelID: String?

    static func from(_ ann: Annotation) -> AnnotationRecord {
        AnnotationRecord(
            id: ann.id.uuidString,
            fileID: ann.pdfID.uuidString,
            pageIndex: ann.pageIndex,
            type: ann.kind.rawValue,
            color: ann.colorHex,
            textContent: ann.selectedText ?? ann.noteText,
            normalizedX: ann.bounds?.x,
            normalizedY: ann.bounds?.y,
            normalizedW: ann.bounds?.width,
            normalizedH: ann.bounds?.height,
            inkData: nil,
            createdAt: ann.createdAt.timeIntervalSince1970,
            contentHash: ann.contentHash,
            zettelID: nil
        )
    }

    func toDomainModel() -> Annotation {
        let id = UUID(uuidString: self.id) ?? UUID()
        let pdfID = UUID(uuidString: fileID) ?? UUID()
        let kind = Annotation.AnnotationKind(rawValue: type) ?? .highlight
        var bounds: CodableCGRect?
        if let x = normalizedX, let y = normalizedY, let w = normalizedW, let h = normalizedH {
            bounds = CodableCGRect(x: x, y: y, width: w, height: h)
        }
        var ann = Annotation(
            id: id,
            pdfID: pdfID,
            pageIndex: pageIndex,
            chapterTitle: nil,
            kind: kind,
            createdAt: Date(timeIntervalSince1970: createdAt),
            modifiedAt: Date(timeIntervalSince1970: createdAt),
            colorHex: color,
            selectedText: textContent,
            noteText: nil,
            tags: nil,
            bounds: bounds
        )
        ann.contentHash = contentHash
        return ann
    }
}

// MARK: - ZettelRecord

struct ZettelRecord: Codable, Equatable {
    static let databaseTableName = "zettel_notes"

    var id: String
    var title: String
    var body: String
    var tags: String?       // JSON [String]
    var backlinks: String?  // JSON [String]
    var sourceFileID: String?
    var sourcePage: Int?
    var createdAt: Double
    var modifiedAt: Double
}

// MARK: - VirtualOmnibusRecord

struct VirtualOmnibusRecord: Codable, Equatable {
    static let databaseTableName = "virtual_omnibuses"

    var id: String
    var name: String
    var fileIDsJson: String       // JSON [String]
    var coverFileID: String?
    var lastReadPageIndex: Int
    var lastReadFileID: String?
    var addedAt: Double
    var modifiedAt: Double
    var remoteSyncURL: String?
    var lastSyncedAt: Double?

    static func from(_ omni: VirtualOmnibus) -> VirtualOmnibusRecord {
        let encoder = JSONEncoder()
        let fileIDsStr = (try? encoder.encode(omni.fileIDs.map { $0.uuidString })).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return VirtualOmnibusRecord(
            id: omni.id.uuidString,
            name: omni.name,
            fileIDsJson: fileIDsStr,
            coverFileID: omni.coverFileID?.uuidString,
            lastReadPageIndex: omni.lastReadPageIndex,
            lastReadFileID: omni.lastReadFileID?.uuidString,
            addedAt: omni.addedAt.timeIntervalSince1970,
            modifiedAt: omni.modifiedAt.timeIntervalSince1970,
            remoteSyncURL: omni.remoteSyncURL,
            lastSyncedAt: omni.lastSyncedAt?.timeIntervalSince1970
        )
    }

    func toDomainModel() -> VirtualOmnibus {
        let decoder = JSONDecoder()
        let ids: [UUID] = {
            guard let data = fileIDsJson.data(using: .utf8),
                  let strArray = try? decoder.decode([String].self, from: data) else { return [] }
            return strArray.compactMap { UUID(uuidString: $0) }
        }()
        let coverUUID = coverFileID.flatMap { UUID(uuidString: $0) }
        let lastFileUUID = lastReadFileID.flatMap { UUID(uuidString: $0) }
        return VirtualOmnibus(
            id: UUID(uuidString: id) ?? UUID(),
            name: name,
            fileIDs: ids,
            coverFileID: coverUUID,
            lastReadPageIndex: lastReadPageIndex,
            lastReadFileID: lastFileUUID,
            addedAt: Date(timeIntervalSince1970: addedAt),
            modifiedAt: Date(timeIntervalSince1970: modifiedAt),
            remoteSyncURL: remoteSyncURL,
            lastSyncedAt: lastSyncedAt.map { Date(timeIntervalSince1970: $0) }
        )
    }
}

extension VirtualOmnibusRecord {
    func upsert(_ db: LibraryDB) throws {
        try db.execute("""
            INSERT OR REPLACE INTO virtual_omnibuses
            (id, name, fileIDsJson, coverFileID, lastReadPageIndex, lastReadFileID, addedAt, modifiedAt, remoteSyncURL, lastSyncedAt)
            VALUES (?,?,?,?,?,?,?,?,?,?)
        """, arguments: [id, name, fileIDsJson, coverFileID as Any, lastReadPageIndex, lastReadFileID as Any, addedAt, modifiedAt, remoteSyncURL as Any, lastSyncedAt as Any])
    }

    init?(row: [String: Any]) {
        guard let id = row["id"] as? String,
              let name = row["name"] as? String,
              let fileIDsJson = row["fileIDsJson"] as? String,
              let addedAt = row["addedAt"] as? Double,
              let modifiedAt = row["modifiedAt"] as? Double else { return nil }
        self.id = id
        self.name = name
        self.fileIDsJson = fileIDsJson
        self.coverFileID = row["coverFileID"] as? String
        self.lastReadPageIndex = (row["lastReadPageIndex"] as? Int) ?? 0
        self.lastReadFileID = row["lastReadFileID"] as? String
        self.addedAt = addedAt
        self.modifiedAt = modifiedAt
        self.remoteSyncURL = row["remoteSyncURL"] as? String
        self.lastSyncedAt = row["lastSyncedAt"] as? Double
    }
}

