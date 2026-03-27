import SwiftData
import Foundation

@Model
final class SDSeriesMemory {
    @Attribute(.unique) var seriesNameNormalized: String
    var conversionCount: Int = 0
    var lastDeviceID: UUID?
    var confirmedMangaRTL: Bool?
    var averagePanelConfidence: Double?
    var hasUserEverEditedPanels: Bool = false
    var hasUserEverEditedMetadata: Bool = false

    init(seriesNameNormalized: String) {
        self.seriesNameNormalized = seriesNameNormalized
    }

    var canSkipImportSheet: Bool {
        conversionCount >= 3
            && confirmedMangaRTL != nil
            && lastDeviceID != nil
            && (averagePanelConfidence ?? 0) >= 0.85
            && !hasUserEverEditedPanels
    }

    var canSuppressPanelReview: Bool {
        conversionCount >= 2
            && (averagePanelConfidence ?? 0) >= 0.85
            && !hasUserEverEditedPanels
    }
}
