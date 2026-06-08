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
            VStack(spacing: 12) {
                // Subtle Header
                HStack {
                    Text("Continue Reading")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                        .textCase(.uppercase)
                        .tracking(1.2)
                    Spacer()
                }
                .padding(.horizontal, hSizeClass == .regular ? 24 : 16)
                
                // Hero Banner Carousel
                TabView(selection: $activeIndex) {
                    ForEach(Array(displayItems.enumerated()), id: \.element.id) { index, pdf in
                        PremiumHeroCard(pdf: pdf)
                            .tag(index)
                            .onTapGesture { onTap(pdf) }
                            .padding(.horizontal, hSizeClass == .regular ? 24 : 16)
                    }
                }
                .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))
                .frame(height: hSizeClass == .regular ? 260 : 380)
                
                // Custom Dot Indicator
                if displayItems.count > 1 {
                    HStack(spacing: 6) {
                        ForEach(0..<displayItems.count, id: \.self) { index in
                            Circle()
                                .fill(activeIndex == index ? Theme.purple : Theme.textTertiary)
                                .frame(width: activeIndex == index ? 8 : 6, height: activeIndex == index ? 8 : 6)
                                .animation(.spring(response: 0.3), value: activeIndex)
                        }
                    }
                }
            }
            .padding(.top, 16)
            .padding(.bottom, 8)
        }
    }
}

// MARK: - Premium Hero Card

private struct PremiumHeroCard: View {
    let pdf: ConvertedPDF
    @EnvironmentObject var conversionManager: ConversionManager
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @State private var cover: UIImage? = nil
    
    private var progress: CGFloat {
        CGFloat(pdf.metadata.lastReadPage ?? 0) / CGFloat(max(pdf.pageCount, 1))
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
                        .blur(radius: 40)
                        .overlay(Color.black.opacity(0.4))
                        .clipped()
                } else {
                    Theme.surfaceElevated
                }
                
                // 2. Glassmorphism Container
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.3), Color.white.opacity(0.05)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    )
                
                // 3. Content Layout (iPad vs iPhone)
                if hSizeClass == .regular {
                    iPadLayout(geo: geo)
                } else {
                    iPhoneLayout(geo: geo)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
        }
        .task(id: pdf.id) {
            let key = pdf.id.uuidString as NSString
            if let cached = conversionManager.thumbnailCache.object(forKey: key) { cover = cached; return }
            guard let url = conversionManager.getCoverURL(for: pdf),
                  FileManager.default.fileExists(atPath: url.path) else { return }
            await ThumbnailGenerationQueue.shared.enqueue(pdf, manager: conversionManager)
        }
        .onReceive(NotificationCenter.default.publisher(for: .thumbnailGenerated)) { note in
            if let id = note.userInfo?["id"] as? UUID, id == pdf.id,
               let image = note.userInfo?["image"] as? UIImage {
                self.cover = image
            }
        }
    }
    
    // MARK: - iPad Wide Layout
    @ViewBuilder
    private func iPadLayout(geo: GeometryProxy) -> some View {
        HStack(spacing: 24) {
            // High-Res Crisp Cover
            ZStack {
                if let img = cover {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "book.closed.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .frame(width: 160, height: 220)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.4), radius: 12, y: 6)
            
            // Info & Progress
            VStack(alignment: .leading, spacing: 8) {
                if let series = pdf.metadata.series, !series.isEmpty {
                    Text(series.uppercased())
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.purple)
                        .tracking(1.5)
                }
                
                Text(pdf.name)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .shadow(radius: 2)
                
                Spacer()
                
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("\(Int(progress * 100))% COMPLETED")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(.white.opacity(0.7))
                        Spacer()
                        Text("\(pdf.metadata.lastReadPage ?? 0) / \(pdf.pageCount)")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(.white.opacity(0.5))
                    }
                    
                    // Glowing Neon Progress Bar
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.1)).frame(height: 6)
                        Capsule()
                            .fill(LinearGradient(colors: [Theme.purple, Color.pink], startPoint: .leading, endPoint: .trailing))
                            .frame(width: geo.size.width * 0.4 * progress, height: 6) // Roughly 40% of geo width is the bar area
                            .shadow(color: Theme.purple.opacity(0.8), radius: 8, y: 0)
                    }
                }
            }
            .padding(.vertical, 20)
            Spacer()
            
            // Action Button
            Image(systemName: "play.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(LinearGradient(colors: [Theme.purple, Color.pink], startPoint: .topLeading, endPoint: .bottomTrailing))
                .shadow(color: Theme.purple.opacity(0.5), radius: 10, y: 4)
                .padding(.trailing, 12)
        }
        .padding(20)
    }
    
    // MARK: - iPhone Tall Layout
    @ViewBuilder
    private func iPhoneLayout(geo: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            // Full Width Cover Top
            ZStack(alignment: .bottom) {
                if let img = cover {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(height: 240)
                        .clipped()
                } else {
                    Rectangle().fill(Theme.surfaceElevated).frame(height: 240)
                    Image(systemName: "book.closed.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(Theme.textSecondary)
                }
                
                // Gradient Fade to Body
                LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 100)
            }
            
            // Info & Progress Bottom
            VStack(alignment: .leading, spacing: 8) {
                if let series = pdf.metadata.series, !series.isEmpty {
                    Text(series.uppercased())
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.purple)
                        .tracking(1.5)
                }
                
                Text(pdf.name)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .shadow(radius: 2)
                
                Spacer()
                
                // Glowing Neon Progress Bar
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.1)).frame(height: 6)
                    Capsule()
                        .fill(LinearGradient(colors: [Theme.purple, Color.pink], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(0, (geo.size.width - 40) * progress), height: 6)
                        .shadow(color: Theme.purple.opacity(0.8), radius: 8, y: 0)
                }
                .padding(.bottom, 4)
            }
            .padding(20)
            .frame(height: 140)
        }
    }
}
