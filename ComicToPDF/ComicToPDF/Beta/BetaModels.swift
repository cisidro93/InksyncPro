import Foundation
import SwiftData
import SwiftUI

public enum BetaContentType: String, Codable, CaseIterable, Sendable {
    case comic = "Comic"
    case manga = "Manga"
    case pdf = "PDF"
    case epub = "EPUB"
    
    public var icon: String {
        switch self {
        case .comic: return "book.closed.fill"
        case .manga: return "character.book.closed.fill"
        case .pdf: return "doc.richtext.fill"
        case .epub: return "text.book.closed.fill"
        }
    }
    
    public var themeColor: Color {
        switch self {
        case .comic: return .cyan
        case .manga: return .purple
        case .pdf: return .red
        case .epub: return .orange
        }
    }
}

@Model
public final class BetaBook {
    @Attribute(.unique) public var id: UUID
    public var title: String
    public var filePath: String // Sandbox-resilient relative path
    public var contentType: BetaContentType
    public var fileSize: Int64
    public var pageCount: Int
    public var currentPage: Int
    public var isFavorite: Bool
    public var dateAdded: Date
    public var lastReadDate: Date?
    public var seriesName: String?
    public var volumeNumber: String?
    
    // Cascades delete to highlights associated with this book.
    @Relationship(deleteRule: .cascade, inverse: \BetaHighlight.book)
    public var highlights: [BetaHighlight] = []
    
    public init(
        id: UUID = UUID(),
        title: String,
        filePath: String,
        contentType: BetaContentType,
        fileSize: Int64,
        pageCount: Int,
        currentPage: Int = 0,
        isFavorite: Bool = false,
        dateAdded: Date = Date(),
        seriesName: String? = nil,
        volumeNumber: String? = nil
    ) {
        self.id = id
        self.title = title
        self.filePath = filePath
        self.contentType = contentType
        self.fileSize = fileSize
        self.pageCount = pageCount
        self.currentPage = currentPage
        self.isFavorite = isFavorite
        self.dateAdded = dateAdded
        self.seriesName = seriesName
        self.volumeNumber = volumeNumber
    }
    
    public var resolvedURL: URL {
        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documentsDir.appendingPathComponent(filePath)
    }
    
    public var formattedSize: String {
        let mb = Double(fileSize) / (1024 * 1024)
        return String(format: "%.1f MB", mb)
    }
    
    public var progressPercent: Double {
        guard pageCount > 0 else { return 0 }
        return Double(currentPage) / Double(pageCount)
    }
}

@Model
public final class BetaHighlight {
    @Attribute(.unique) public var id: UUID
    public var pageIndex: Int
    public var text: String
    public var note: String
    public var colorHex: String
    public var dateCreated: Date
    
    public var book: BetaBook?
    
    public init(
        id: UUID = UUID(),
        pageIndex: Int,
        text: String,
        note: String = "",
        colorHex: String = "#FFD700",
        dateCreated: Date = Date()
    ) {
        self.id = id
        self.pageIndex = pageIndex
        self.text = text
        self.note = note
        self.colorHex = colorHex
        self.dateCreated = dateCreated
    }
}

@Model
public final class BetaDevice {
    @Attribute(.unique) public var id: UUID
    public var name: String
    public var type: String // "kindle" or "calibre"
    public var emailAddress: String?
    public var ipAddress: String?
    public var lastSeen: Date?
    
    public init(
        id: UUID = UUID(),
        name: String,
        type: String,
        emailAddress: String? = nil,
        ipAddress: String? = nil,
        lastSeen: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.emailAddress = emailAddress
        self.ipAddress = ipAddress
        self.lastSeen = lastSeen
    }
}
