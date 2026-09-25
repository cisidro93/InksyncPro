import SwiftUI

/// BatchMergeReorderView: Unified backwards-compatible pass-through wrapper delegating to VolumeStudioView.
/// Consolidates batch reordering and file merging into the unified studio.
struct BatchMergeReorderView: View {
    @Binding var selectedFiles: [ConvertedPDF]
    
    var body: some View {
        VolumeStudioView(initialFiles: selectedFiles, initialMode: .physicalMerge)
    }
}
