import SwiftUI

// MARK: - Thumbnail Concurrency Gate
// Limits simultaneous disk-decode operations to prevent I/O saturation on large libraries.
// 4 concurrent jobs gives full pipeline utilization without hammering the NAND on first scroll.
private let thumbnailSemaphore = AsyncSemaphore(limit: 4)

/// Lightweight cooperative semaphore for Swift concurrency.
/// Parks waiting tasks instead of spinning — safe to use from any actor.
actor AsyncSemaphore {
    private let limit: Int
    private var count = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    
    init(limit: Int) { self.limit = limit }
    
    func wait() async {
        if count < limit { count += 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    
    func signal() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            count = max(0, count - 1)
        }
    }
}

struct ModernGridFileCell: View {
    let pdf: ConvertedPDF
    let isSelected: Bool
    let isBatch: Bool
    @EnvironmentObject var conversionManager: ConversionManager

    @State private var localCover: UIImage? = nil
    @State private var shimmerPhase: CGFloat = -1

    @AppStorage("mangaBadgeColorHex") private var mangaBadgeColorHex = "#2dd4a0"
    @AppStorage("comicBadgeColorHex") private var comicBadgeColorHex = "#3d6fff"

    private var readingProgress: Double {
        Double(pdf.metadata.lastReadPage ?? 0) / Double(max(pdf.pageCount, 1))
    }
    private var isFullyRead: Bool { readingProgress >= 0.98 && pdf.pageCount > 0 }
    private var isInProgress: Bool { readingProgress > 0.01 && !isFullyRead }
    private var isNew: Bool { (pdf.metadata.lastReadPage ?? 0) == 0 }
    private var isCloudPending: Bool {
        if case .cloud = pdf.sourceMode { return localCover == nil && conversionManager.thumbnailCache.object(forKey: pdf.id.uuidString as NSString) == nil }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {

            // ── Cover ─────────────────────────────────────────────────────────
            ZStack(alignment: .bottom) {
                // Image or placeholder
                Group {
                    if let img = conversionManager.thumbnailCache.object(forKey: pdf.id.uuidString as NSString) ?? localCover {
                        Image(uiImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fill)

                        // Book spine overlay — left-edge depth cue
                        HStack(spacing: 0) {
                            LinearGradient(
                                colors: [.black.opacity(0.28), .black.opacity(0.06), .clear],
                                startPoint: .leading, endPoint: .trailing
                            )
                            .frame(width: 20)
                            Spacer()
                        }
                    } else if isCloudPending {
                        // Animated cloud-fetch pulse — cover is being extracted in background
                        ZStack {
                            LinearGradient(
                                colors: [Color(red: 0.1, green: 0.35, blue: 0.55),
                                         Color(red: 0.05, green: 0.2, blue: 0.4)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                            Image(systemName: "icloud.and.arrow.down")
                                .font(.system(size: 26))
                                .foregroundColor(.white.opacity(0.7))
                                .symbolEffect(.pulse, isActive: true)
                        }
                    } else if case .cloud = pdf.sourceMode {
                        cloudPlaceholder
                    } else {
                        // Shimmer loading placeholder
                        GeometryReader { geo in
                            let w = geo.size.width
                            ZStack {
                                let ext = pdf.fileExtensionString.uppercased()
                                let (c1, c2): (Color, Color) = {
                                    switch ext {
                                    case "CBZ","CBR": return (Color(red:0.15,green:0.25,blue:0.6), Color(red:0.1,green:0.15,blue:0.4))
                                    case "PDF":       return (Color(red:0.6,green:0.15,blue:0.15), Color(red:0.4,green:0.1,blue:0.1))
                                    case "EPUB":      return (Color(red:0.15,green:0.5,blue:0.3),  Color(red:0.1,green:0.35,blue:0.2))
                                    default:          return (Color(red:0.25,green:0.25,blue:0.3), Color(red:0.15,green:0.15,blue:0.2))
                                    }
                                }()
                                LinearGradient(colors: [c1, c2], startPoint: .topLeading, endPoint: .bottomTrailing)

                                // Shimmer sweep
                                LinearGradient(colors: [.clear, .white.opacity(0.07), .clear], startPoint: .leading, endPoint: .trailing)
                                    .frame(width: w * 0.5)
                                    .offset(x: shimmerPhase * w)
                                    .onAppear {
                                        withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) {
                                            shimmerPhase = 1.8
                                        }
                                    }
                                    .blendMode(.screen)

                                VStack(spacing: 8) {
                                    Image(systemName: "doc.text.fill").font(.system(size: 26)).foregroundColor(.white.opacity(0.4))
                                    Text(ext).font(.system(size: 10, weight: .black, design: .rounded)).foregroundColor(.white.opacity(0.35)).tracking(1.5)
                                }
                            }
                        }
                    }
                }

                // Bottom scrim + progress bar (Kindle-style)
                if isInProgress || isFullyRead {
                    VStack(spacing: 0) {
                        Spacer()
                        LinearGradient(
                            colors: [.clear, .black.opacity(0.65)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 52)
                    }

                    VStack(spacing: 4) {
                        Spacer()
                        HStack {
                            Text(isFullyRead ? "Finished" : "\(Int(readingProgress * 100))% read")
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .foregroundColor(.white.opacity(0.9))
                            Spacer()
                        }
                        .padding(.horizontal, 8)

                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color.white.opacity(0.2))
                                    .frame(height: 3)
                                Capsule()
                                    .fill(isFullyRead ? Color.green : Color.white)
                                    .frame(width: g.size.width * CGFloat(readingProgress), height: 3)
                            }
                        }
                        .frame(height: 3)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                    }
                }

                // "New" badge — frosted pill at bottom-left (Manga Plus style)
                if isNew {
                    HStack {
                        Text("NEW")
                            .font(.system(size: 8, weight: .black, design: .rounded))
                            .foregroundColor(.white)
                            .tracking(0.6)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(Color.blue, in: Capsule())
                            .padding(8)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                }

                // Fully-read checkmark (Panels style)
                if isFullyRead {
                    VStack {
                        HStack {
                            Spacer()
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(.white, Color.green)
                                .padding(8)
                                .shadow(color: .black.opacity(0.4), radius: 4)
                        }
                        Spacer()
                    }
                }

                // Source badges (cloud / linked drive) — top-left
                VStack {
                    HStack {
                        if case .linked = pdf.sourceMode {
                            sourceBadge(icon: "externaldrive.fill", color: Theme.blue)
                        } else if case .cloud = pdf.sourceMode {
                            sourceBadge(icon: "icloud.fill", color: Theme.orange)
                        }
                        Spacer()
                    }
                    Spacer()
                }

                // Batch selection overlay
                if isBatch {
                    VStack {
                        HStack {
                            Spacer()
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundColor(isSelected ? Theme.blue : .white)
                                .padding(8)
                                .shadow(radius: 2)
                        }
                        Spacer()
                    }
                }

                // 📌 Work Area pin badge — top-right (only when not in batch mode)
                if !isBatch && WorkspaceFocusManager.shared.isPinned(pdf) {
                    VStack {
                        HStack {
                            Spacer()
                            Image(systemName: "pin.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(5)
                                .background(Color.inkAccentKnowledge, in: Circle())
                                .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                                .padding(6)
                        }
                        Spacer()
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(0.63, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(isSelected && !isBatch ? 0.7 : 0.1), lineWidth: isSelected && !isBatch ? 2 : 0.5)
            )
            // Dual shadow: crisp near + soft ambient (Apple Books technique)
            .shadow(color: .black.opacity(0.22), radius: 3, y: 2)
            .shadow(color: .black.opacity(0.10), radius: 12, y: 8)

            // ── Text + type badge ────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 3) {
                Text(pdf.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.text)
                    .lineLimit(2)
                    .frame(height: 36, alignment: .topLeading)

                if pdf.contentType == .comic {
                    let isManga = pdf.metadata.isManga ?? false
                    Text(isManga ? "MANGA" : "COMIC")
                        .font(.system(size: 9, weight: .black, design: .rounded))
                        .foregroundColor(Color(hex: isManga ? mangaBadgeColorHex : comicBadgeColorHex))
                        .tracking(0.8)
                } else {
                    Text(pdf.fileExtensionString.uppercased())
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundColor(Theme.textTertiary)
                        .tracking(0.8)
                }
            }
            .padding(.horizontal, 2)
        }
        .padding(6)
        .background(isSelected && !isBatch ? Theme.surfaceElevated : Color.clear)
        .cornerRadius(12)
        .contentShape(Rectangle())
        .hoverEffect(.lift)
        .task(id: pdf.id) {
            let key = pdf.id.uuidString as NSString

            // 1. Already in NSCache — instant return
            if let cached = conversionManager.thumbnailCache.object(forKey: key) {
                self.localCover = cached; return
            }

            // 2. Cover file exists on disk (cold-start or just-extracted cloud cover)
            //    Load it into cache and display it.
            let coverURL = conversionManager.getCoverURL(for: pdf)
            if let url = coverURL, FileManager.default.fileExists(atPath: url.path) {
                await thumbnailSemaphore.wait()
                defer { Task { await thumbnailSemaphore.signal() } }
                let safeURL = url
                let generated = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                    let opts = [kCGImageSourceShouldCache: false] as CFDictionary
                    guard let src = CGImageSourceCreateWithURL(safeURL as CFURL, opts) else { return nil }
                    let down = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                kCGImageSourceShouldCacheImmediately: true,
                                kCGImageSourceCreateThumbnailWithTransform: true,
                                kCGImageSourceThumbnailMaxPixelSize: 360] as CFDictionary
                    guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, down) else { return nil }
                    return UIImage(cgImage: cg)
                }.value
                if let image = generated {
                    conversionManager.thumbnailCache.setObject(image, forKey: key)
                    self.localCover = image
                }
                return
            }

            // 3. Cloud file with no cover yet.
            //    CloudCoverExtractor is running in the background (fired from
            //    PhysicalFileSystemRouter.backfillMissingThumbnails Pass 3).
            //    When it finishes, it posts .cloudCoverReady → ConversionManager
            //    updates thumbnailCache and calls objectWillChange.send() →
            //    this View re-renders and the body picks up the cached image.
            //    Nothing to do here — the body's existing cache check handles it.
        }
    }

    // MARK: - Placeholder Views

    private var formatPlaceholder: some View {
        let ext = pdf.fileExtensionString.uppercased()
        let (bg1, bg2): (Color, Color) = {
            switch ext {
            case "CBZ", "CBR": return (Color(red: 0.15, green: 0.25, blue: 0.6), Color(red: 0.1, green: 0.15, blue: 0.4))
            case "PDF":        return (Color(red: 0.6, green: 0.15, blue: 0.15), Color(red: 0.4, green: 0.1, blue: 0.1))
            case "EPUB":       return (Color(red: 0.15, green: 0.5, blue: 0.3),  Color(red: 0.1, green: 0.35, blue: 0.2))
            default:           return (Color(red: 0.25, green: 0.25, blue: 0.3), Color(red: 0.15, green: 0.15, blue: 0.2))
            }
        }()
        return ZStack {
            LinearGradient(colors: [bg1, bg2], startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 8) {
                Image(systemName: "doc.text.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.white.opacity(0.5))
                Text(ext)
                    .font(.system(size: 11, weight: .black, design: .rounded))
                    .foregroundColor(.white.opacity(0.4))
                    .tracking(1.5)
            }
        }
    }

    private var cloudPlaceholder: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.1, green: 0.35, blue: 0.55), Color(red: 0.05, green: 0.2, blue: 0.4)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 8) {
                Image(systemName: "icloud.and.arrow.down")
                    .font(.system(size: 28))
                    .foregroundColor(.white.opacity(0.7))
                Text("CLOUD")
                    .font(.system(size: 10, weight: .black, design: .rounded))
                    .foregroundColor(.white.opacity(0.5))
                    .tracking(1.5)
            }
        }
    }

    @ViewBuilder
    private func sourceBadge(icon: String, color: Color) -> some View {
        Image(systemName: icon)
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(.white)
            .padding(5)
            .background(color.opacity(0.9), in: Circle())
            .padding(6)
            .shadow(color: .black.opacity(0.3), radius: 3)
    }
}


struct ModernGridSeriesCell: View {
    let group: SeriesGroup
    let isSelected: Bool
    let isBatch: Bool
    @EnvironmentObject var conversionManager: ConversionManager

    @State private var localCover: UIImage? = nil
    // Cached progress — computed in .task, not in body to avoid per-render disk reads
    @State private var cachedReadCount: Int = 0
    @State private var cachedNewCount: Int = 0

    @AppStorage("mangaBadgeColorHex") private var mangaBadgeColorHex = "#2dd4a0"
    @AppStorage("comicBadgeColorHex") private var comicBadgeColorHex = "#3d6fff"
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            
            // Cover Image with Stack Effect
            ZStack(alignment: .bottom) {
                ZStack {
                    if group.count > 1 { // Stack Effect Backgrounds
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Theme.surface.opacity(0.8))
                            .aspectRatio(0.66, contentMode: .fit)
                            .shadow(color: Color(.sRGBLinear, white: 0, opacity: 0.2), radius: 4, y: 2)
                            .rotationEffect(.degrees(-3))
                            .scaleEffect(0.9)
                            .offset(y: -8)
                        
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Theme.surfaceElevated.opacity(0.9))
                            .aspectRatio(0.66, contentMode: .fit)
                            .shadow(color: Color(.sRGBLinear, white: 0, opacity: 0.25), radius: 5, y: 3)
                            .rotationEffect(.degrees(2))
                            .scaleEffect(0.95)
                            .offset(y: -4)
                    }
                    
                    if let issueID = group.coverIssueID, let directCacheImg = conversionManager.thumbnailCache.object(forKey: issueID.uuidString as NSString) {
                        Image(uiImage: directCacheImg)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else if let img = localCover {
                        Image(uiImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle().fill(Theme.surfaceElevated)
                        Image(systemName: "books.vertical.fill")
                            .font(.largeTitle)
                            .foregroundColor(Theme.textSecondary)
                    }
                }
                .aspectRatio(0.63, contentMode: .fit) // Standard comic aspect ratio
                .cornerRadius(12)
                .clipped()
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.15), radius: 10, y: 5)
                
                // Floating Glass Series Badge
                HStack(spacing: 4) {
                    Image(systemName: "books.vertical.fill").font(.system(size: 10))
                    Text("\(group.count) \(group.count == 1 ? "Issue" : "Issues")").font(.system(size: 10, weight: .bold))
                    
                    if let first = group.issues.first(where: { $0.contentType == .comic }) {
                        let isManga = first.metadata.isManga ?? false
                        Text("· \(isManga ? "MANGA" : "COMIC")")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(Color(hex: isManga ? mangaBadgeColorHex : comicBadgeColorHex))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.2), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                .padding(.bottom, 6)
                
                // Batch Selection Overlay
                if isBatch {
                    VStack {
                        HStack {
                            Spacer()
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundColor(isSelected ? Theme.blue : .white)
                                .padding(8)
                                .shadow(radius: 2)
                        }
                        Spacer()
                    }
                }

                // ✅ Series Completion Badge — shown when every issue is read
                if !isBatch && cachedReadCount > 0 && cachedReadCount >= group.count {
                    VStack {
                        HStack {
                            Spacer()
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(6)
                                .background(Color.inkGreen, in: Circle())
                                .overlay(Circle().stroke(.white.opacity(0.4), lineWidth: 1))
                                .shadow(color: Color.inkGreen.opacity(0.6), radius: 6, y: 2)
                                .padding(6)
                        }
                        Spacer()
                    }
                }
            }
            .frame(maxWidth: .infinity)
            
            // Text Details
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(group.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Theme.text)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    
                    if UserDefaults.standard.bool(forKey: "showSeriesHealthScore") {
                        SeriesHealthBadge(issues: group.issues)
                    }
                }
                .frame(height: 38, alignment: .topLeading)
                
                // Reading progress: segmented arc ring
                if cachedReadCount > 0 || group.count > 0 {
                    SeriesProgressRing(
                        readCount: cachedReadCount,
                        totalCount: group.count
                    )
                    .frame(width: 36, height: 36)
                } else if cachedNewCount > 0 {
                    Text("\(cachedNewCount) new")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Theme.blue)
                }
            }
        }
        .padding(8)
        .background(isSelected && !isBatch ? Theme.surfaceElevated : Color.clear)
        .cornerRadius(12)
        .contentShape(Rectangle())
        .hoverEffect(.lift)
        // Throttled loader — gets the cover of the series' issue #1
        .task(id: group.id) {
            // 1. Build progress map once — 1 read per issue instead of 2.
            //    uniquingKeysWith: keeps first value, never crashes on duplicate IDs.
            let progressMap = Dictionary(
                group.issues.map { ($0.id, ReaderProgressTracker.shared.progress(for: $0.id)) },
                uniquingKeysWith: { first, _ in first }
            )
            let readCount = progressMap.values.filter { ($0?.completionFraction ?? 0) >= 0.95 }.count
            let newCount  = progressMap.values.filter { $0 == nil }.count


            self.cachedReadCount = readCount
            self.cachedNewCount = newCount

            // 2. Load thumbnail
            guard let issueID = group.coverIssueID,
                  let pdf = conversionManager.convertedPDFs.first(where: { $0.id == issueID }) else { return }
            let key = issueID.uuidString as NSString
            if let cached = conversionManager.thumbnailCache.object(forKey: key) {
                self.localCover = cached; return
            }
            guard let coverURL = conversionManager.getCoverURL(for: pdf),
                  FileManager.default.fileExists(atPath: coverURL.path) else { return }
            
            await thumbnailSemaphore.wait()
            defer { Task { await thumbnailSemaphore.signal() } }
            
            let generated = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
                guard let source = CGImageSourceCreateWithURL(coverURL as CFURL, sourceOptions) else { return nil }
                let downsampleOptions = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 360
                ] as CFDictionary
                guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions) else { return nil }
                return UIImage(cgImage: cgImage)
            }.value
            
            if let image = generated {
                conversionManager.thumbnailCache.setObject(image, forKey: key)
                self.localCover = image
            }
        }
    }
}

// MARK: - Cover Preview Card (used by context menu preview: blocks)
struct CoverPreviewCard: View {
    let pdf: ConvertedPDF
    let manager: ConversionManager

    var body: some View {
        ZStack {
            Color(UIColor.systemBackground)

            if let img = manager.getThumbnail(for: pdf) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "doc.richtext")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text(pdf.metadata.title.isEmpty ? pdf.name : pdf.metadata.title)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.primary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }
            }
        }
        .frame(width: 180, height: 260)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Series Progress Ring
// Segmented arc ring: one segment per issue, filled = read, partial = in-progress.
// Capped at 20 segments for visual clarity on large runs (500+ issue series).
struct SeriesProgressRing: View {
    let readCount: Int
    let totalCount: Int

    private var displayCount: Int { min(totalCount, 20) }
    private var displayRead: Int { totalCount > 20 ? Int((Double(readCount) / Double(max(totalCount, 1))) * 20) : readCount }
    private var allRead: Bool { readCount >= totalCount && totalCount > 0 }

    var body: some View {
        ZStack {
            ForEach(0..<displayCount, id: \.self) { i in
                let segmentFraction = 1.0 / Double(displayCount)
                let gap = min(0.04, segmentFraction * 0.3)
                let start = segmentFraction * Double(i) + gap / 2
                let end   = segmentFraction * Double(i + 1) - gap / 2

                // Filled (read) vs unfilled
                Circle()
                    .trim(from: start, to: end)
                    .stroke(
                        i < displayRead
                            ? (allRead ? Color.green : Theme.orange)
                            : Color.white.opacity(0.15),
                        style: StrokeStyle(lineWidth: 3.5, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
            }

            // Centre: read count or checkmark
            if allRead {
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .black))
                    .foregroundColor(.green)
            } else if readCount > 0 {
                Text("\(readCount)")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundColor(Theme.textSecondary)
            }
        }
    }
}

struct CellButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
