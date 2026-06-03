import SwiftUI



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
        VStack(alignment: .leading, spacing: 5) {

            // ── Cover ─────────────────────────────────────────────────────────
            ZStack(alignment: .bottom) {
                // Image or placeholder
                Group {
                    if let img = conversionManager.thumbnailCache.object(forKey: pdf.id.uuidString as NSString) ?? localCover {
                        // Phase 4B: Landscape cover normalization — blur-background technique.
                        // For any cover (portrait or landscape) we always maintain the 2:3 cell.
                        // A blurred, darkened copy of the image fills the background; the real
                        // cover is rendered .scaledToFit on top, centred. Portrait covers that
                        // naturally fill .fill are unaffected visually; landscape covers benefit
                        // from the blurred halo instead of an ugly hard crop.
                        ZStack {
                            // Blurred background layer (always fills the 2:3 frame)
                            Image(uiImage: img)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .blur(radius: 18, opaque: true)
                                .overlay(Color.black.opacity(0.45))

                            // Foreground: actual cover scaled to fit
                            Image(uiImage: img)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                // Subtle drop shadow so the cover lifts off the blur bg
                                .shadow(color: .black.opacity(0.5), radius: 8, y: 4)
                        }

                        // Book spine overlay — left-edge depth cue
                        HStack(spacing: 0) {
                            LinearGradient(
                                colors: [.black.opacity(0.30), .black.opacity(0.06), .clear],
                                startPoint: .leading, endPoint: .trailing
                            )
                            .frame(width: 18)
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

                // Bottom scrim + progress bar (premium Panels-style)
                if isInProgress || isFullyRead {
                    VStack(spacing: 0) {
                        Spacer()
                        LinearGradient(
                            colors: [.clear, .black.opacity(0.72)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 60)
                    }

                    VStack(spacing: 5) {
                        Spacer()
                        HStack {
                            Text(isFullyRead ? "Finished" : "\(Int(readingProgress * 100))%")
                                .font(.system(size: 9, weight: .black, design: .rounded))
                                .foregroundColor(isFullyRead ? Color.green : .white)
                            Spacer()
                        }
                        .padding(.horizontal, 8)

                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color.white.opacity(0.18))
                                    .frame(height: 4)
                                Capsule()
                                    .fill(
                                        isFullyRead
                                            ? AnyShapeStyle(Color.green)
                                            : AnyShapeStyle(LinearGradient(
                                                colors: [Color(hue: 0.56, saturation: 0.8, brightness: 1.0),
                                                         Color(hue: 0.52, saturation: 0.9, brightness: 0.95)],
                                                startPoint: .leading, endPoint: .trailing
                                              ))
                                    )
                                    .frame(width: g.size.width * CGFloat(readingProgress), height: 4)
                                    .shadow(color: isFullyRead ? Color.green.opacity(0.6) : Color.blue.opacity(0.5), radius: 4, y: 0)
                            }
                        }
                        .frame(height: 4)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                    }
                }

                // "NEW" badge — gradient pill at bottom-left
                if isNew {
                    HStack {
                        Text("NEW")
                            .font(.system(size: 8, weight: .black, design: .rounded))
                            .foregroundColor(.white)
                            .tracking(0.8)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(
                                LinearGradient(
                                    colors: [Color(hue: 0.56, saturation: 0.85, brightness: 1.0),
                                             Color(hue: 0.63, saturation: 0.9, brightness: 0.9)],
                                    startPoint: .leading, endPoint: .trailing
                                ),
                                in: Capsule()
                            )
                            .shadow(color: Color.blue.opacity(0.35), radius: 4, y: 2)
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
            // ⚠️ WIDTH FIX: .fill content mode lets landscape-ratio covers expand
            // the ZStack beyond the outer .aspectRatio frame, making column widths vary.
            // Constraining to maxWidth/Height here forces every cover into its grid slot.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .frame(maxWidth: .infinity)
            .aspectRatio(0.63, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(isSelected && !isBatch ? 0.7 : 0.08), lineWidth: isSelected && !isBatch ? 2 : 0.5)
            )
            // Dual shadow: crisp near + soft ambient (Apple Books technique)
            .shadow(color: .black.opacity(0.28), radius: 4, y: 3)
            .shadow(color: .black.opacity(0.12), radius: 14, y: 10)

            // ── Text + type badge ────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 3) {
                Text(pdf.name)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(Theme.text)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: 32, maxHeight: 38, alignment: .topLeading)

                if pdf.contentType == .comic {
                    let isManga = pdf.metadata.isManga ?? false
                    Text(isManga ? "MANGA" : "COMIC")
                        .font(.system(size: 9, weight: .black, design: .rounded))
                        .foregroundColor(Color(hex: isManga ? mangaBadgeColorHex : comicBadgeColorHex))
                        .tracking(1.0)
                } else {
                    Text(pdf.fileExtensionString.uppercased())
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundColor(Theme.textTertiary)
                        .tracking(1.0)
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
            if let image = await ThumbnailGenerationQueue.shared.generateThumbnail(for: pdf, in: conversionManager) {
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

/// A glassmorphic folder representing a collection or series folder.
/// Shows a smaller thumbnail of the artwork peeking out of a transparent glass pocket.
struct FolderThumbnailView: View {
    let image: UIImage?
    let count: Int
    
    var body: some View {
        ZStack {
            // Folder Back
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.primary.opacity(0.08), Color.primary.opacity(0.02)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
                .background(.ultraThinMaterial)
            
            // Folder Tab (Top-Left)
            VStack(spacing: 0) {
                HStack {
                    Path { path in
                        path.move(to: CGPoint(x: 10, y: 0))
                        path.addLine(to: CGPoint(x: 50, y: 0))
                        path.addQuadCurve(to: CGPoint(x: 58, y: 8), control: CGPoint(x: 55, y: 0))
                        path.addLine(to: CGPoint(x: 65, y: 16))
                        path.addLine(to: CGPoint(x: 10, y: 16))
                        path.closeSubpath()
                    }
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: 80, height: 16)
                    .offset(y: -8)
                    Spacer()
                }
                Spacer()
            }
            
            // Artwork Cover (Centered, smaller, tilted with shadow)
            Group {
                if let img = image {
                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        Color.secondary.opacity(0.1)
                        Image(systemName: "books.vertical.fill")
                            .font(.system(size: 28))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .frame(width: 76, height: 108)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
            .rotationEffect(.degrees(-3))
            .offset(y: -4)
            .clipped()
            
            // Folder Front Pocket (overlapping bottom portion)
            VStack {
                Spacer()
                ZStack(alignment: .top) {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.12), Color.white.opacity(0.02)],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                        .background(.thinMaterial)
                    
                    // Folder front flap edge highlight line
                    Capsule()
                        .fill(Color.white.opacity(0.20))
                        .frame(height: 1.2)
                        .padding(.top, 0.5)
                }
                .frame(height: 64)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
        )
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
    
    private var coverImage: UIImage? {
        if let issueID = group.coverIssueID,
           let cached = conversionManager.thumbnailCache.object(forKey: issueID.uuidString as NSString) {
            return cached
        }
        return localCover
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {

            // Folder Image with pocket stack design
            ZStack(alignment: .bottomTrailing) {
                FolderThumbnailView(image: coverImage, count: group.count)
                    .aspectRatio(0.63, contentMode: .fit)

                // Issue count pill — bottom-right corner (compact)
                if !isBatch {
                    Text("\(group.count)")
                        .font(.system(size: 10, weight: .black, design: .rounded))
                        .foregroundColor(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().stroke(.white.opacity(0.2), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                        .padding(6)
                }

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
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(5)
                                .background(Color.inkGreen, in: Circle())
                                .overlay(Circle().stroke(.white.opacity(0.35), lineWidth: 0.8))
                                .shadow(color: Color.inkGreen.opacity(0.55), radius: 5, y: 2)
                                .padding(7)
                            Spacer()
                        }
                        Spacer()
                    }
                }
            }
            .frame(maxWidth: .infinity)

            // Text Details
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(group.title)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(Theme.text)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    if UserDefaults.standard.bool(forKey: "showSeriesHealthScore") {
                        SeriesHealthBadge(issues: group.issues)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 32, maxHeight: 38, alignment: .topLeading)

                // Publisher / type metadata line
                HStack(spacing: 5) {
                    if let publisher = group.issues.first?.metadata.publisher, !publisher.isEmpty {
                        Text(publisher.uppercased())
                            .font(.system(size: 8, weight: .semibold, design: .rounded))
                            .foregroundColor(Theme.textTertiary)
                            .tracking(0.6)
                            .lineLimit(1)
                    } else if let first = group.issues.first(where: { $0.contentType == .comic }) {
                        let isManga = first.metadata.isManga ?? false
                        Text(isManga ? "MANGA" : "COMICS")
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .foregroundColor(Color(hex: isManga ? mangaBadgeColorHex : comicBadgeColorHex))
                            .tracking(0.8)
                    }

                    Spacer()

                    // Reading progress ring
                    if cachedReadCount > 0 || group.count > 0 {
                        SeriesProgressRing(
                            readCount: cachedReadCount,
                            totalCount: group.count
                        )
                        .frame(width: 30, height: 30)
                    }
                }
            }
        }
        .padding(6)
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
            
            if let image = await ThumbnailGenerationQueue.shared.generateThumbnail(for: pdf, in: conversionManager) {
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
