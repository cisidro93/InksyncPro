import Foundation
import SwiftData
import SwiftUI
import CoreTransferable

/// Core Data Container replacing the old `PDFCollection`. Supports N-depth nested folders and series.
@Model
final class InkContainer: Identifiable {
    @Attribute(.unique) var id: UUID
    var name: String
    var icon: String
    var color: String
    var creationDate: Date
    var explicitCoverFileID: UUID?
    
    // Recursive Hierarchy
    var parent: InkContainer?
    
    @Relationship(deleteRule: .cascade, inverse: \InkContainer.parent)
    var children: [InkContainer]?
    
    // Backing Documents (Many-To-Many for Reading Lists)
    @Relationship(deleteRule: .nullify, inverse: \InkDocument.containers)
    var items: [InkDocument]?
    
    init(id: UUID = UUID(), name: String, icon: String = "folder", color: String = "blue", creationDate: Date = Date(), explicitCoverFileID: UUID? = nil) {
        self.id = id
        self.name = name
        self.icon = icon
        self.color = color
        self.creationDate = creationDate
        self.explicitCoverFileID = explicitCoverFileID
    }
}

/// Core Document representing exactly one parsed Archive, PDF, or EPUB
@Model
final class InkDocument: Identifiable {
    @Attribute(.unique) var id: UUID
    var name: String
    var url: URL
    var pageCount: Int
    var fileSize: Int64
    var isFavorite: Bool
    var isPrivate: Bool
    var coverImageData: Data?
    
    // Embedded Value Types (SwiftData generates JSON/BLOB automatically for these Codable structs)
    var metadata: PDFMetadata
    var contentType: ContentType
    var chapters: [Chapter]
    var addedByMode: AppUIMode
    
    // Parent Link (Many-to-Many for Series + Custom Reading Lists)
    var containers: [InkContainer]?
    
    var fileExtensionString: String {
        return url.pathExtension.uppercased()
    }
    
    var formattedSize: String {
        let mb = Double(fileSize) / 1024 / 1024
        return String(format: "%.1f MB", mb)
    }
    
    init(id: UUID = UUID(), name: String, url: URL, pageCount: Int, fileSize: Int64, metadata: PDFMetadata, isFavorite: Bool = false, isPrivate: Bool = false, coverImageData: Data? = nil, contentType: ContentType = .comic, chapters: [Chapter] = [], addedByMode: AppUIMode = .pro) {
        self.id = id
        self.name = name
        self.url = url
        self.pageCount = pageCount
        self.fileSize = fileSize
        self.metadata = metadata
        self.isFavorite = isFavorite
        self.isPrivate = isPrivate
        self.coverImageData = coverImageData
        self.contentType = contentType
        self.chapters = chapters
        self.addedByMode = addedByMode
    }
}

// MARK: - CoreTransferable Drag and Drop Bridge
// Passes UUID strings to guarantee thread safety across the app's structural components.
extension InkDocument: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(exporting: \.id.uuidString)
    }
}

extension InkContainer: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(exporting: \.id.uuidString)
    }
}
