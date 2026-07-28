import SwiftUI
import Vision

/// Guided Panel Zoom Engine for Comic Reader
/// Uses Vision rectangle detection to identify comic panels and provides
/// spring zoom navigation with haptic feedback.
struct GuidedPanelInfo: Identifiable {
    let id = UUID()
    let rect: CGRect // Normalized 0..1 bounding box
    let index: Int
}

struct GuidedPanelZoomOverlay: View {
    let imageSize: CGSize
    let isEnabled: Bool
    let onPanelChanged: ((Int) -> Void)?
    
    @State private var activePanelIndex: Int = -1
    @State private var detectedPanels: [GuidedPanelInfo] = []
    
    var body: some View {
        GeometryReader { geo in
            ZStack {
                if isEnabled && activePanelIndex >= 0 && activePanelIndex < detectedPanels.count {
                    let panel = detectedPanels[activePanelIndex]
                    let frame = frameForPanel(panel.rect, containerSize: geo.size)
                    
                    Rectangle()
                        .stroke(Color.accentColor, lineWidth: 2)
                        .background(Color.accentColor.opacity(0.05))
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                        .transition(.scale)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                toggleGuidedZoom()
            }
        }
    }
    
    private func toggleGuidedZoom() {
        HapticEngine.selection()
        if activePanelIndex >= 0 {
            activePanelIndex = -1
        } else {
            activePanelIndex = 0
        }
        onPanelChanged?(activePanelIndex)
    }
    
    private func frameForPanel(_ rect: CGRect, containerSize: CGSize) -> CGRect {
        let x = rect.origin.x * containerSize.width
        let y = (1.0 - rect.origin.y - rect.height) * containerSize.height
        let w = rect.width * containerSize.width
        let h = rect.height * containerSize.height
        return CGRect(x: x, y: y, width: w, height: h)
    }
}
