import SwiftUI

// MARK: - Mortimer Adler Syntopical Marker Pill Bar

/// Glassmorphic horizontal selector for Mortimer Adler active reading marginalia notation tokens.
public struct AdlerMarkerPillBar: View {
    @Binding var selectedMarker: AdlerMarker?
    let markerCounts: [AdlerMarker: Int]
    
    public init(
        selectedMarker: Binding<AdlerMarker?>,
        markerCounts: [AdlerMarker: Int] = [:]
    ) {
        self._selectedMarker = selectedMarker
        self.markerCounts = markerCounts
    }
    
    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // "All Markers" Pill
                Button {
                    HapticEngine.selection()
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                        selectedMarker = nil
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .font(.system(size: 11, weight: .bold))
                        Text("All")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                    }
                    .foregroundColor(selectedMarker == nil ? .white : .inkTextSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        selectedMarker == nil
                            ? AnyShapeStyle(Color.inkViolet)
                            : AnyShapeStyle(Color.primary.opacity(0.06))
                    )
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                
                // Individual Adler Markers
                ForEach(AdlerMarker.allCases) { marker in
                    let isSelected = selectedMarker == marker
                    let count = markerCounts[marker] ?? 0
                    
                    Button {
                        HapticEngine.selection()
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                            if selectedMarker == marker {
                                selectedMarker = nil // Toggle off
                            } else {
                                selectedMarker = marker
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Text(marker.symbol)
                                .font(.system(size: 12, weight: .black, design: .rounded))
                                .foregroundColor(isSelected ? .white : marker.accentColor)
                            
                            Text(marker.title)
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundColor(isSelected ? .white : .inkTextPrimary)
                            
                            if count > 0 {
                                Text("\(count)")
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .foregroundColor(isSelected ? .white.opacity(0.8) : .inkTextTertiary)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(
                                        Color.white.opacity(isSelected ? 0.25 : 0.08),
                                        in: Capsule()
                                    )
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            isSelected
                                ? AnyShapeStyle(marker.accentColor)
                                : AnyShapeStyle(Color.primary.opacity(0.06))
                        )
                        .clipShape(Capsule())
                        .overlay(
                            Capsule()
                                .stroke(marker.accentColor.opacity(isSelected ? 0 : 0.2), lineWidth: 0.8)
                        )
                    }
                    .buttonStyle(.plain)
                    .help(marker.meaning)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
        }
    }
}
