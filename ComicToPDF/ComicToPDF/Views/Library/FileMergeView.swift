import SwiftUI

/// FileMergeView: Unified backwards-compatible pass-through wrapper delegating to VolumeStudioView.
/// Consolidates all standalone physical merging, comic bundling, and archive creation into the unified studio.
struct FileMergeView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    private let initialSelection: Set<UUID>
    
    init(initialSelection: Set<UUID> = []) {
        self.initialSelection = initialSelection
    }
    
    var body: some View {
        let files = conversionManager.convertedPDFs.filter { initialSelection.contains($0.id) }.sorted(by: ConvertedPDF.naturalIssueSort)
        VolumeStudioView(initialFiles: files, initialMode: .physicalMerge)
    }
}
