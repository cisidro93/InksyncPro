import SwiftUI

// ============================================================================
// ContinueReadingShelf
// ============================================================================
// Panels-style horizontal shelf showing in-progress reads at the top of the
// library. Each card has a circular progress ring overlaid on the cover.
// Only rendered when ≥1 book is in-progress. Zero extra state — reads from
// ReaderProgressTracker directly.
// ============================================================================

struct ContinueReadingShelf: View {
    let inProgress: [ConvertedPDF]
    let onTap: (ConvertedPDF) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Section header
            HStack {
                Image(systemName: "book.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.orange.gradient)
                Text("Continue Reading")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(Theme.text)
                Spacer()
                Text("\(inProgress.count)")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(Theme.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Theme.surface, in: Capsule())
            }
            .padding(.horizontal, 16)

            // Horizontal card scroll
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(inProgress) { pdf in
                        ContinueReadingCard(pdf: pdf)
                            .onTapGesture { onTap(pdf) }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
            }
        }
        .padding(.top, 16)
        .padding(.bottom, 8)
    }
}

// MARK: - Individual Card

private struct ContinueReadingCard: View {
    let pdf: ConvertedPDF
    @EnvironmentObject var conversionManager: ConversionManager
    @State private var cover: UIImage? = nil

    private var progress: Double {
        Double(pdf.metadata.lastReadPage ?? 0) / Double(max(pdf.pageCount, 1))
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // Cover image
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.surface)

                if let img = conversionManager.thumbnailCache.object(forKey: pdf.id.uuidString as NSString) ?? cover {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .clipped()
                } else {
                    Image(systemName: "book.closed.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(Theme.textSecondary)
                }

                // Spine shadow overlay
                HStack(spacing: 0) {
                    LinearGradient(
                        colors: [.black.opacity(0.35), .clear],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .frame(width: 20)
                    Spacer()
                }

                // Bottom scrim for text legibility
                VStack(spacing: 0) {
                    Spacer()
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.75)],
                        startPoint: .top, endPoint: .bottom
                    )
                    .frame(height: 60)
                }
            }
            .frame(width: 110, height: 165)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 6, y: 4)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.white.opacity(0.12), lineWidth: 0.5)
            )

            // Bottom info
            VStack(alignment: .leading, spacing: 3) {
                Text(pdf.name)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .shadow(radius: 2)
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.7))
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)

            // Progress ring — top right corner
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.15), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: CGFloat(progress))
                    .stroke(
                        progress >= 0.98 ? Color.green : Theme.orange,
                        style: StrokeStyle(lineWidth: 3, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.spring(response: 0.5), value: progress)
            }
            .frame(width: 26, height: 26)
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
        .frame(width: 110, height: 165)
        .task(id: pdf.id) {
            let key = pdf.id.uuidString as NSString
            if let cached = conversionManager.thumbnailCache.object(forKey: key) {
                cover = cached; return
            }
            guard let url = conversionManager.getCoverURL(for: pdf),
                  FileManager.default.fileExists(atPath: url.path) else { return }
            let img = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                let opts = [kCGImageSourceShouldCache: false] as CFDictionary
                guard let src = CGImageSourceCreateWithURL(url as CFURL, opts) else { return nil }
                let down = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceShouldCacheImmediately: true,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceThumbnailMaxPixelSize: 280] as CFDictionary
                guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, down) else { return nil }
                return UIImage(cgImage: cg)
            }.value
            if let img { conversionManager.thumbnailCache.setObject(img, forKey: key); cover = img }
        }
    }
}
