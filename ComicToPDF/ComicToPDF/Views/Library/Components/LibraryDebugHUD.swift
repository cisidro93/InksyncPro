import SwiftUI

// MARK: - Library Debug HUD
// A floating diagnostic overlay shown only when Settings → System → Enable Developer Tools
// is active. Provides a real-time snapshot of the library cache state, thumbnail memory
// footprint, and the composition of cachedLibraryItems.
//
// Zero-overhead when hidden: the view is never constructed when showEditorDebug is false.

struct LibraryDebugHUD: View {
    let allItems: [LibraryListItem]
    let conversionManager: ConversionManager
    let viewModel: LibraryViewModel

    // Rebuild timestamp so we can show "last rebuilt X seconds ago"
    @State private var lastRebuildDate: Date = .now
    @State private var timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var secondsAgo: Int = 0

    // Derived stats (computed once per render, no extra state)
    private var seriesCount: Int    { allItems.filter { if case .series = $0 { return true }; return false }.count }
    private var singleCount: Int    { allItems.filter { if case .single  = $0 { return true }; return false }.count }
    private var totalPDFs: Int      { conversionManager.convertedPDFs.count }
    private var collectionCount: Int { conversionManager.collections.count }

    // Thumbnail cache introspection via NSCache (no public count API — estimate via
    // a lightweight probe of a known key range).
    private var cacheEstimate: String {
        // NSCache doesn't expose item count. We read totalCostLimit and display
        // the configured limit alongside a qualitative fill indicator.
        let cache = conversionManager.thumbnailCache
        // Probe 0–199 IDs to estimate loaded ratio
        let loaded = conversionManager.convertedPDFs
            .prefix(50)
            .filter { cache.object(forKey: $0.id.uuidString as NSString) != nil }
            .count
        let sampled = min(conversionManager.convertedPDFs.count, 50)
        guard sampled > 0 else { return "empty" }
        let pct = Int(Double(loaded) / Double(sampled) * 100)
        return "\(loaded)/\(sampled) sampled (\(pct)% warm)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "ladybug.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.red)
                Text("LIBRARY DEBUG")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(.red)
                Spacer()
                Text("↻ \(secondsAgo)s")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))
            }

            Divider().background(Color.white.opacity(0.2))

            // Stats grid
            Group {
                debugRow("total PDFs",   value: "\(totalPDFs)")
                debugRow("collections",  value: "\(collectionCount)")
                debugRow("series tiles", value: "\(seriesCount)")
                debugRow("single tiles", value: "\(singleCount)")
                debugRow("cache",        value: cacheEstimate)
                debugRow("items total",  value: "\(allItems.count)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: 230)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.black.opacity(0.75))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.red.opacity(0.35), lineWidth: 1)
                )
        )
        .shadow(color: .red.opacity(0.2), radius: 8)
        .padding(.trailing, 12)
        .padding(.bottom, 90) // clear tab bar
        .allowsHitTesting(false)
        .onReceive(timer) { _ in
            secondsAgo += 1
        }
        .onChange(of: allItems.count) { _, _ in
            // Reset counter whenever the cache is rebuilt
            secondsAgo = 0
            lastRebuildDate = .now
        }
    }

    @ViewBuilder
    private func debugRow(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.white.opacity(0.55))
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(.cyan)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
