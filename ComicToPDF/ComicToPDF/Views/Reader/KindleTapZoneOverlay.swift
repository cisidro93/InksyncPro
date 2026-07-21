import SwiftUI

/// Kindle-style 3-zone tap overlay for frictionless page turning:
/// - Left 15% zone: Previous Page / Spread
/// - Right 75% zone: Next Page / Spread
/// - Center 10% zone: Toggle Reader Chrome HUD
struct KindleTapZoneOverlay: View {
    let onPrevPage: () -> Void
    let onNextPage: () -> Void
    let onCenterTap: () -> Void
    
    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                // Left 15% — Previous Page Zone
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: geo.size.width * 0.15)
                    .onTapGesture {
                        onPrevPage()
                    }
                
                // Center 10% — Toggle HUD Zone
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: geo.size.width * 0.10)
                    .onTapGesture {
                        onCenterTap()
                    }
                
                // Right 75% — Next Page Zone
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: geo.size.width * 0.75)
                    .onTapGesture {
                        onNextPage()
                    }
            }
        }
        .ignoresSafeArea()
    }
}
