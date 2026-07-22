import SwiftUI

/// Kindle-style 3-zone tap overlay for frictionless page turning:
/// - Left 15% zone: Previous Page / Spread
/// - Right 75% zone: Next Page / Spread
/// - Center 10% zone: Toggle Reader Chrome HUD
struct KindleTapZoneOverlay: View {
    let onPrevPage: () -> Void
    let onNextPage: () -> Void
    let onCenterTap: () -> Void
    
    private var tapZoneStyle: TapZoneStyle {
        EBookPreferences.shared.tapZoneStyle
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let zones = tapZoneStyle.zones
            let leftWidth = width * zones.leftEdge
            let centerWidth = width * max(0.05, zones.rightEdge - zones.leftEdge)
            let rightWidth = max(0, width - leftWidth - centerWidth)

            HStack(spacing: 0) {
                // Left Zone — Previous Page
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: leftWidth)
                    .onTapGesture {
                        onPrevPage()
                    }
                
                // Center Zone — Toggle HUD / Chrome to return to library
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: centerWidth)
                    .onTapGesture {
                        onCenterTap()
                    }
                
                // Right Zone — Next Page
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: rightWidth)
                    .onTapGesture {
                        onNextPage()
                    }
            }
        }
        .ignoresSafeArea()
    }
}
