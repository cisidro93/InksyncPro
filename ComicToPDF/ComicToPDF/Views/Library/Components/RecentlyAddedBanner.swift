import SwiftUI

// ============================================================================
// RecentlyAddedBanner  (Compact Strip Edition)
// ============================================================================
// Was: large 130×195 cover cards — felt like a second full shelf stacked above
// the grid and dominated the screen on iPhone.
// Now: slim 88×130 spine-style cards that let the user skim without scrolling,
// with a tight section header that doesn't compete with the main shelf filter.
// ============================================================================

struct RecentlyAddedBanner: View {
    let recent: [ConvertedPDF]
    let onTap: (ConvertedPDF) -> Void

    @Environment(\.horizontalSizeClass) private var hSizeClass

    // Compact dimensions — roughly paperback-spine proportions
    private var cardW: CGFloat { hSizeClass == .regular ? 100 : 82 }
    private var cardH: CGFloat { hSizeClass == .regular ? 148 : 122 }
    private var hPad:  CGFloat { hSizeClass == .regular ? 20  : 16  }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {

            // ── Header ──────────────────────────────────────────────────────
            HStack(spacing: 6) {
                Text("RECENTLY ADDED")
                    .font(.system(size: 11, weight: .black, design: .rounded))
                    .foregroundColor(Theme.textSecondary)
                    .tracking(1.1)
                Spacer()
            }
            .padding(.horizontal, hPad)

            // ── Compact card strip ───────────────────────────────────────────
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(recent) { pdf in
                        Button {
                            onTap(pdf)
                        } label: {
                            RecentAddedCompactCard(pdf: pdf, cardW: cardW, cardH: cardH)
                        }
                        .buttonStyle(CellButtonStyle())
                    }
                }
                .padding(.horizontal, hPad)
                .padding(.bottom, 2)
            }
        }
        .padding(.top, 6)
        .padding(.bottom, 4)
    }
}

// MARK: - Compact Card

private struct RecentAddedCompactCard: View {
    let pdf: ConvertedPDF
    let cardW: CGFloat
    let cardH: CGFloat

    @EnvironmentObject var conversionManager: ConversionManager
    @State private var cover: UIImage? = nil

    var body: some View {
        ZStack(alignment: .bottom) {
            // ── Cover ──────────────────────────────────────────────────────
            Group {
                if let img = conversionManager.thumbnailCache.object(
                    forKey: pdf.id.uuidString as NSString) ?? cover
                {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .clipped()
                } else {
                    compactPlaceholder
                }
            }
            .frame(width: cardW, height: cardH)

            // ── Bottom title scrim ──────────────────────────────────────────
            LinearGradient(
                colors: [.clear, .black.opacity(0.75)],
                startPoint: .center, endPoint: .bottom
            )
            .frame(height: cardH * 0.45)

            // ── Title ──────────────────────────────────────────────────────
            Text(pdf.name)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 5)
                .padding(.bottom, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: cardW, height: cardH)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.22), radius: 4, y: 2)
        .task(id: pdf.id) { await loadCover() }
    }

    @ViewBuilder
    private var compactPlaceholder: some View {
        let ext = pdf.fileExtensionString.uppercased()
        let (c1, c2): (Color, Color) = {
            switch ext {
            case "CBZ", "CBR": return (.init(red: 0.15, green: 0.25, blue: 0.6), .init(red: 0.1, green: 0.15, blue: 0.4))
            case "PDF":        return (.init(red: 0.55, green: 0.13, blue: 0.13), .init(red: 0.4, green: 0.1, blue: 0.1))
            case "EPUB":       return (.init(red: 0.12, green: 0.45, blue: 0.28), .init(red: 0.08, green: 0.3, blue: 0.18))
            default:           return (.init(red: 0.22, green: 0.22, blue: 0.28), .init(red: 0.14, green: 0.14, blue: 0.18))
            }
        }()
        LinearGradient(colors: [c1, c2], startPoint: .topLeading, endPoint: .bottomTrailing)
        Image(systemName: "doc.text.fill")
            .font(.system(size: 18))
            .foregroundColor(.white.opacity(0.35))
    }

    private func loadCover() async {
        let key = pdf.id.uuidString as NSString
        if conversionManager.thumbnailCache.object(forKey: key) != nil { return }
        guard let url = conversionManager.getCoverURL(for: pdf),
              FileManager.default.fileExists(atPath: url.path) else { return }
        let img = await Task.detached(priority: .utility) { () -> UIImage? in
            let opts = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let src = CGImageSourceCreateWithURL(url as CFURL, opts) else { return nil }
            let down = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceShouldCacheImmediately: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 300] as CFDictionary
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, down) else { return nil }
            return UIImage(cgImage: cg)
        }.value
        if let img {
            conversionManager.thumbnailCache.setObject(img, forKey: key)
            cover = img
        }
    }
}
