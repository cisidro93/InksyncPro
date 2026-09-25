import SwiftUI

/// Backwards-compatible wrapper routing to the unified VolumeStudioView in physical archive mode.
struct SeriesMergeConfigurationView: View {
    let sourceFiles: [ConvertedPDF]
    let initialSelection: Set<UUID>
    let suggestedName: String?
    
    init(sourceFiles: [ConvertedPDF], suggestedName: String? = nil) {
        self.sourceFiles = sourceFiles
        self.initialSelection = Set(sourceFiles.map(\.id))
        self.suggestedName = suggestedName
    }
    
    init(seriesFiles: [ConvertedPDF], initialSelection: Set<UUID>, suggestedName: String? = nil) {
        self.sourceFiles = seriesFiles
        self.initialSelection = initialSelection
        self.suggestedName = suggestedName
    }
    
    var body: some View {
        VolumeStudioView(
            existingOmnibus: nil,
            initialFileIDs: Array(initialSelection),
            suggestedName: suggestedName ?? "",
            parentSeriesID: sourceFiles.first?.metadata.series,
            initialMode: .physicalMerge
        )
    }
}
