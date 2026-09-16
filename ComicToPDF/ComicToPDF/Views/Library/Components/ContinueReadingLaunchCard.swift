import SwiftUI

// MARK: - ContinueReadingLaunchCard
//
// Apple Books & Kavsoft UI/UX inspired floating glassmorphic launch card.
// Prominently displays the most recent active reading session with book cover,
// reading progress percentage, time remaining, and an instant 1-tap resume action.

struct ContinueReadingLaunchCard: View {
    let pdf: ConvertedPDF
    let progress: ReadingProgress
    var onResume: () -> Void
    var onDismiss: () -> Void

    @EnvironmentObject var conversionManager: ConversionManager
    @Environment(\.horizontalSizeClass) private var hSizeClass
    private var isCompact: Bool { hSizeClass == .compact }

    var body: some View {
        HStack(spacing: 12) {
            // ── Book Cover Thumbnail ───────────────────────────────────────────
            coverView
                .frame(width: isCompact ? 48 : 56, height: isCompact ? 68 : 78)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.35), radius: 6, y: 3)

            // ── Metadata & Progress Column ─────────────────────────────────────
            VStack(alignment: .leading, spacing: 4) {
                // Header badge row
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 9, weight: .bold))
                    Text("CONTINUE READING")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .tracking(0.6)
                }
                .foregroundStyle(Color(hex: "#B39DDB"))

                // Document / Book Title
                Text(pdf.metadata.title.isEmpty ? pdf.name : pdf.metadata.title)
                    .font(.system(size: isCompact ? 14 : 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)

                // Page & Reading Velocity Info
                HStack(spacing: 5) {
                    let pageCount = max(pdf.pageCount, 1)
                    let currentPage = min(progress.currentPageIndex + 1, pageCount)
                    let pct = Int(progress.completionFraction * 100)
                    Text("Page \(currentPage) of \(pageCount) • \(pct)%")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))

                    if let minutes = progress.estimatedMinutesRemaining, minutes > 0 {
                        Text("• ~\(minutes)m left")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color(hex: "#B39DDB").opacity(0.85))
                    }
                }

                // Micro Progress Bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.12))
                            .frame(height: 3)

                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [Color(hex: "#7B5EA7"), Color(hex: "#B39DDB")],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: max(3, geo.size.width * CGFloat(progress.completionFraction)), height: 3)
                    }
                }
                .frame(height: 3)
                .padding(.top, 2)
            }

            Spacer(minLength: 4)

            // ── Right Action Cluster ───────────────────────────────────────────
            VStack(alignment: .trailing, spacing: 10) {
                // Dismiss card for current session
                Button {
                    HapticEngine.light()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                        onDismiss()
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.4))
                        .padding(4)
                }
                .buttonStyle(.plain)

                // Resume Play Button
                Button {
                    HapticEngine.medium()
                    onResume()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 12, weight: .bold))
                        if !isCompact {
                            Text("Resume")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, isCompact ? 12 : 14)
                    .padding(.vertical, 8)
                    .background(
                        LinearGradient(
                            colors: [Color(hex: "#7B5EA7"), Color(hex: "#9C27B0")],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: Capsule()
                    )
                    .shadow(color: Color(hex: "#7B5EA7").opacity(0.4), radius: 8, y: 3)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.28), radius: 14, y: 5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0.22), Color.white.opacity(0.04)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.8
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture {
            HapticEngine.medium()
            onResume()
        }
    }

    // MARK: - Cover View
    @ViewBuilder
    private var coverView: some View {
        if let cached = conversionManager.thumbnailCache.object(forKey: pdf.id.uuidString as NSString) {
            Image(uiImage: cached)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                LinearGradient(
                    colors: [Color(hex: "#372948"), Color(hex: "#1E1A29")],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: "book.closed.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Color(hex: "#B39DDB").opacity(0.6))
            }
            .task {
                await ThumbnailGenerationQueue.shared.enqueue(pdf, manager: conversionManager)
            }
        }
    }
}
