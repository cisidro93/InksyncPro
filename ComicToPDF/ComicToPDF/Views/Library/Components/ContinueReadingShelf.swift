import SwiftUI

// ============================================================================
// PremiumHeroBanner (Replaces ContinueReadingShelf)
// ============================================================================
// A stunning, high-impact Hero Banner for the top of the Library.
// Displays the most recent in-progress books with a glassmorphism aesthetic,
// glowing progress bars, and a premium edge-to-edge layout.
// ============================================================================

struct ContinueReadingShelf: View {
    let inProgress: [ConvertedPDF]
    let onTap: (ConvertedPDF) -> Void
    
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @State private var activeIndex: Int = 0
    
    // Show max 5 recent items to avoid cluttering the hero section
    private var displayItems: [ConvertedPDF] { Array(inProgress.prefix(5)) }
    
    var body: some View {
        if !displayItems.isEmpty {
            VStack(spacing: 10) {
                // Subtle Header
                HStack {
                    Text("Continue Reading")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                        .textCase(.uppercase)
                        .tracking(1.2)
                    Spacer()
                }
                .padding(.horizontal, hSizeClass == .regular ? 24 : 16)
                
                // Hero Banner Carousel — Compact height (~118pt iPhone, 132pt iPad)
                TabView(selection: $activeIndex) {
                    ForEach(Array(displayItems.enumerated()), id: \.element.id) { index, pdf in
                        PremiumHeroCard(pdf: pdf)
                            .tag(index)
                            .onTapGesture { onTap(pdf) }
                            .contextMenu {
                                Button {
                                    HapticEngine.selection()
                                    ReaderProgressTracker.shared.clearReadingData(for: pdf.id, in: conversionManager)
                                } label: {
                                    Label("Clear Reading History", systemImage: "clock.arrow.circlepath")
                                }
                                
                                Button {
                                    HapticEngine.selection()
                                    ReaderProgressTracker.shared.markUnread(pdfID: pdf.id)
                                } label: {
                                    Label("Mark as Unread", systemImage: "circle")
                                }
                                
                                Button {
                                    HapticEngine.selection()
                                    ReaderProgressTracker.shared.markComplete(pdfID: pdf.id, totalPages: pdf.pageCount)
                                } label: {
                                    Label("Mark as Read", systemImage: "checkmark.circle")
                                }
                            }
                            .padding(.horizontal, hSizeClass == .regular ? 24 : 16)
                    }
                }
                .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))
                .frame(height: hSizeClass == .regular ? 132 : 118)
                
                // Custom Dot Indicator
                if displayItems.count > 1 {
                    HStack(spacing: 5) {
                        ForEach(0..<displayItems.count, id: \.self) { index in
                            Circle()
                                .fill(activeIndex == index ? Theme.purple : Theme.textTertiary.opacity(0.6))
                                .frame(width: activeIndex == index ? 7 : 5, height: activeIndex == index ? 7 : 5)
                                .animation(.spring(response: 0.3), value: activeIndex)
                        }
                    }
                    .padding(.top, 2)
                }
            }
            .padding(.top, 10)
            .padding(.bottom, 6)
        }
    }
}

// MARK: - Premium Hero Card (Compact Horizontal Layout)

private struct PremiumHeroCard: View {
    let pdf: ConvertedPDF
    @EnvironmentObject var conversionManager: ConversionManager
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @State private var cover: UIImage? = nil
    
    private var progress: CGFloat {
        CGFloat(pdf.metadata.lastReadPage ?? 0) / CGFloat(max(pdf.pageCount, 1))
    }
    
    private var progressDetailText: String {
        let lastRead = pdf.metadata.lastReadPage ?? 0
        let total = max(pdf.pageCount, 1)
        let pagesLeft = max(0, total - lastRead)
        let pagesWord = pagesLeft == 1 ? "page left" : "pages left"
        
        if let issue = pdf.metadata.issueNumber, !issue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Issue \(issue) · \(pagesLeft) \(pagesWord)"
        } else if let ch = SeriesNameParser.chapterKey(from: pdf.name) {
            return "Ch. \(ch) · \(pagesLeft) \(pagesWord)"
        } else {
            return "\(pagesLeft) \(pagesWord) in book"
        }
    }
    
    var body: some View {
        GeometryReader { geo in
            ZStack {
                // 1. Background Blurred Cover
                if let img = cover {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .blur(radius: 35)
                        .overlay(Color.black.opacity(0.55))
                        .clipped()
                } else {
                    Theme.surfaceElevated
                }
                
                // 2. Glassmorphism Container
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.25), Color.white.opacity(0.06)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    )
                
                // 3. Compact Horizontal Content
                HStack(spacing: hSizeClass == .regular ? 16 : 12) {
                    // Cover Thumbnail
                    ZStack {
                        if let img = cover {
                            Image(uiImage: img)
                                .resizable()
                                .scaledToFill()
                        } else {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Theme.surfaceElevated)
                            Image(systemName: "book.closed.fill")
                                .font(.system(size: 24))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .frame(
                        width: hSizeClass == .regular ? 76 : 64,
                        height: hSizeClass == .regular ? 104 : 88
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.white.opacity(0.15), lineWidth: 0.8)
                    )
                    .shadow(color: .black.opacity(0.4), radius: 6, y: 3)
                    
                    // Book Metadata & Glowing Progress
                    VStack(alignment: .leading, spacing: 3) {
                        if let series = pdf.metadata.series, !series.isEmpty {
                            Text(series.uppercased())
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .foregroundStyle(Theme.purple)
                                .tracking(1.2)
                                .lineLimit(1)
                        }
                        
                        Text(pdf.name)
                            .font(.system(size: hSizeClass == .regular ? 16 : 14, weight: .bold))
                            .foregroundColor(.white)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .shadow(radius: 1)
                        
                        Spacer(minLength: 2)
                        
                        // Progress Percentage & Chapter / Pages Left Detail
                        HStack(spacing: 4) {
                            Text("\(Int(progress * 100))%")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(Theme.purple)
                            
                            Text("·")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.white.opacity(0.4))
                            
                            Text(progressDetailText)
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundColor(.white.opacity(0.65))
                        }
                        
                        // Glowing Neon Progress Bar
                        GeometryReader { barGeo in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color.white.opacity(0.12))
                                    .frame(height: 5)
                                Capsule()
                                    .fill(
                                        LinearGradient(
                                            colors: [Theme.purple, Color.pink],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                                    .frame(width: max(0, min(barGeo.size.width * progress, barGeo.size.width)), height: 5)
                                    .shadow(color: Theme.purple.opacity(0.8), radius: 6, y: 0)
                            }
                        }
                        .frame(height: 5)
                        .padding(.top, 2)
                    }
                    .padding(.vertical, 4)
                    
                    // Resume Action Button
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: hSizeClass == .regular ? 36 : 30))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Theme.purple, Color.pink],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .shadow(color: Theme.purple.opacity(0.6), radius: 8, y: 2)
                        .padding(.trailing, 2)
                }
                .padding(.horizontal, hSizeClass == .regular ? 16 : 12)
                .padding(.vertical, hSizeClass == .regular ? 14 : 10)
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 12, y: 5)
        }
        .task(id: pdf.id) {
            let key = pdf.id.uuidString as NSString
            if let cached = conversionManager.thumbnailCache.object(forKey: key) {
                cover = cached
                return
            }
            if let thumbnail = await conversionManager.loadCoverThumbnail(for: pdf) {
                cover = thumbnail
            } else {
                await ThumbnailGenerationQueue.shared.enqueue(pdf, manager: conversionManager)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .thumbnailGenerated)) { note in
            if let id = note.userInfo?["id"] as? UUID, id == pdf.id,
               let image = note.userInfo?["image"] as? UIImage {
                self.cover = image
            }
        }
    }
}
