import SwiftUI

/// Backwards-compatible wrapper routing to the unified VolumeStudioView in Virtual mode.
struct VirtualOmnibusEditorView: View {
    let omnibus: VirtualOmnibus?
    let initialFileIDs: [UUID]
    let suggestedName: String
    let parentSeriesID: String?
    
    init(omnibus: VirtualOmnibus? = nil, initialFileIDs: [UUID] = [], suggestedName: String = "", parentSeriesID: String? = nil) {
        self.omnibus = omnibus
        self.initialFileIDs = initialFileIDs
        self.suggestedName = suggestedName
        self.parentSeriesID = parentSeriesID
    }
    
    var body: some View {
        VolumeStudioView(
            existingOmnibus: omnibus,
            initialFileIDs: initialFileIDs,
            suggestedName: suggestedName,
            parentSeriesID: parentSeriesID,
            initialMode: .virtual
        )
    }
}
