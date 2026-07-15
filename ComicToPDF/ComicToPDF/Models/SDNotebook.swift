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
    
    // Page template
    var templateStyle: String // plain, ruled, grid, dots, legal, collegeRuled
    
    // Optional link to a specific book / file in the library
    var linkedBookID: UUID?
    
    init(
        id: UUID = UUID(),
        title: String,
        coverGradientIndex: Int = 0,
        coverTitleColorHex: String = "#FFFFFF",
        templateStyle: String = "plain",
        linkedBookID: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.coverGradientIndex = coverGradientIndex
        self.coverTitleColorHex = coverTitleColorHex
        self.templateStyle = templateStyle
        self.linkedBookID = linkedBookID
        self.createdAt = Date()
        self.modifiedAt = Date()
    }
}
