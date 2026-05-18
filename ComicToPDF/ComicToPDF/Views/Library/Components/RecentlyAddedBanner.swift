import SwiftUI

// ============================================================================
// RecentlyAddedBanner
// ============================================================================
// Chunky/Panels-style banner showing the last 3 additions as large horizontal
// cards above the main grid. Shown when library has ≥5 items.
// ============================================================================

struct RecentlyAddedBanner: View {
    let recent: [ConvertedPDF]   // already sorted newest-first, max 5
    let onTap: (ConvertedPDF) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.purple.gradient)
                Text("Recently Added")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(Theme.text)
                Spacer()
            }
            .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(recent) { pdf in
                        RecentAddedCard(pdf: pdf)
                            .onTapGesture { onTap(pdf) }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
            }
        }
        .padding(.top, 4)
        .padding(.bottom, 8)
    }
}

// MARK: - Card

private struct RecentAddedCard: View {
    let pdf: ConvertedPDF
    @EnvironmentObject var conversionManager: ConversionManager
    @State private var cover: UIImage? = nil
    @State private var shimmer = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // Background / cover
            ZStack {
                if let img = conversionManager.thumbnailCache.object(forKey: pdf.id.uuidString as NSString) ?? cover {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .clipped()
                } else {
                    // Shimmer placeholder
                    LinearGradient(
                        colors: shimmer
                            ? [Theme.surface, Theme.surfaceElevated, Theme.surface]
                            : [Theme.surfaceElevated, Theme.surface, Theme.surfaceElevated],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .onAppear {
                        withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                            shimmer = true
                        }
                    }
                }

                // Spine
                HStack(spacing: 0) {
                    LinearGradient(colors: [.black.opacity(0.3), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 18)
                    Spacer()
                }

                // Bottom scrim
                VStack(spacing: 0) {
                    Spacer()
                    LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 70)
                }
            }
            .frame(width: 130, height: 195)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.3), radius: 8, y: 5)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(.white.opacity(0.1), lineWidth: 0.5)
            )

            // NEW badge + title
            VStack(alignment: .leading, spacing: 4) {
                Text("NEW")
                    .font(.system(size: 8, weight: .black, design: .rounded))
                    .foregroundColor(.white)
                    .tracking(0.8)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.purple, in: Capsule())

                Text(pdf.name)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .shadow(radius: 3)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 10)
        }
        .frame(width: 130, height: 195)
        .task(id: pdf.id) {
            let key = pdf.id.uuidString as NSString
            if let cached = conversionManager.thumbnailCache.object(forKey: key) { cover = cached; return }
            guard let url = conversionManager.getCoverURL(for: pdf),
                  FileManager.default.fileExists(atPath: url.path) else { return }
            let img = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                let opts = [kCGImageSourceShouldCache: false] as CFDictionary
                guard let src = CGImageSourceCreateWithURL(url as CFURL, opts) else { return nil }
                let down = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceShouldCacheImmediately: true,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceThumbnailMaxPixelSize: 320] as CFDictionary
                guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, down) else { return nil }
                return UIImage(cgImage: cg)
            }.value
            if let img { conversionManager.thumbnailCache.setObject(img, forKey: key); cover = img }
        }
    }
}
