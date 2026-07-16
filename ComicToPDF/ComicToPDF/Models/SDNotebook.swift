import Foundation
import SwiftData

@Model final class SDNotebook: Identifiable {
    @Attribute(.unique) var id: UUID
    var title: String
    var createdAt: Date
    var modifiedAt: Date
    
    // Cover customization
    var coverGradientIndex: Int
    var coverTitleColorHex: String
    var coverStyle: String?
    
    // Page template
    var templateStyle: String // plain, ruled, grid, dots, legal, collegeRuled
    var templateSize: Double? // Optional custom spacing (18.0, 24.0, 32.0)
    
    // Optional link to a specific book / file in the library
    var linkedBookID: UUID?
    
    init(
        id: UUID = UUID(),
        title: String,
        coverGradientIndex: Int = 0,
        coverTitleColorHex: String = "#FFFFFF",
        templateStyle: String = "plain",
        linkedBookID: UUID? = nil,
        coverStyle: String = "gradient",
        templateSize: Double? = 24.0
    ) {
        self.id = id
        self.title = title
        self.coverGradientIndex = coverGradientIndex
        self.coverTitleColorHex = coverTitleColorHex
        self.templateStyle = templateStyle
        self.linkedBookID = linkedBookID
        self.coverStyle = coverStyle
        self.templateSize = templateSize
        self.createdAt = Date()
        self.modifiedAt = Date()
    }
}
