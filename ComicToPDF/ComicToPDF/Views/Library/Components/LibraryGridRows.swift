import SwiftUI

// MARK: - Thumbnail Concurrency Gate
// Limits simultaneous disk-decode operations to prevent I/O saturation on large libraries.
// 4 concurrent jobs gives full pipeline utilization without hammering the NAND on first scroll.
private let thumbnailSemaphore = AsyncSemaphore(limit: 4)

/// Lightweight cooperative semaphore for Swift concurrency.
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
    
    // ✅ NEW: Isolated Image State for Lazy Loading
    @State private var localCover: UIImage? = nil
    
    // ✅ PHASE 7: Dynamic User Aesthetic Colors
    @AppStorage("mangaBadgeColorHex") private var mangaBadgeColorHex = "#2dd4a0"
    @AppStorage("comicBadgeColorHex") private var comicBadgeColorHex = "#3d6fff"
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Cover Image Setup
            ZStack(alignment: .topTrailing) {
                if let directCacheImg = conversionManager.thumbnailCache.object(forKey: pdf.id.uuidString as NSString) {
                    Image(uiImage: directCacheImg)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else if let img = localCover {
                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(Theme.surfaceElevated)
                    Image(systemName: "doc.text.fill")
                        .font(.largeTitle)
                        .foregroundColor(Theme.textSecondary)
                }
                
                // ✅ NEW: Top-Left External Drive Badge
                if case .linked(_) = pdf.sourceMode {
                    VStack {
                        HStack {
                            Image(systemName: "externaldrive.fill")
                                .font(.caption2)
                                .foregroundColor(.white)
                                .padding(6)
                                .background(Theme.blue.opacity(0.9))
                                .clipShape(Circle())
                                .padding(6)
                                .shadow(color: .black.opacity(0.3), radius: 3)
                            Spacer()
                        }
                        Spacer()
                    }
                }
                
                // Batch Selection Overlay
                if isBatch {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundColor(isSelected ? Theme.blue : .white)
                        .padding(8)
                        .shadow(radius: 2)
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(0.66, contentMode: .fit) // Standard comic aspect ratio
            .cornerRadius(8)
            .clipped()
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
            )
                // ✅ FIXED: Removed heavy double-shadow passes to ensure buttery 120fps scrolling.
                // Since the Library Grid is visually black, shadows were invisible anyway but triggering off-screen rendering.
            
            // Text Details & Kindle-Style Progress
            VStack(alignment: .leading, spacing: 4) {
                Text(pdf.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(height: 38, alignment: .topLeading) // Fixed height to align rows
                
                // Reading Progress Bar
                GeometryReader { geo in
                    let progress = Double(pdf.metadata.lastReadPage ?? 0) / Double(max(pdf.pageCount, 1))
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color(.secondarySystemFill))
                        Capsule().fill(Theme.orange)
                            .frame(width: max(0, geo.size.width * CGFloat(progress)))
                    }
                }
                .frame(height: 3)
                .padding(.top, 2)
                
                HStack {
                    if pdf.metadata.lastReadPage == pdf.pageCount && pdf.pageCount > 0 {
                        Text("Read")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(Theme.textSecondary)
                    } else if let lastRead = pdf.metadata.lastReadPage, lastRead > 0 {
                        let progress = Double(lastRead) / Double(max(pdf.pageCount, 1))
                        Text("\(Int(progress * 100))%")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(Theme.textSecondary)
                    } else {
                        Text("New")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(Theme.blue)
                    }
                    Spacer()
                    if pdf.contentType == .comic {
                        let isManga = pdf.metadata.isManga ?? false
                        Text(isManga ? "MANGA" : "COMIC")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(Color(hex: isManga ? mangaBadgeColorHex : comicBadgeColorHex))
                    } else {
                        Text(pdf.fileExtensionString.uppercased())
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(Theme.textTertiary)
                    }
                }
            }
        }
        .padding(8)
        .background(isSelected && !isBatch ? Theme.surfaceElevated : Color.clear)
        .cornerRadius(12)
        .contentShape(Rectangle())
        .hoverEffect(.lift)
        // Throttled background thumbnail loader — acquires semaphore before hitting disk
        .task(id: pdf.id) {
            let key = pdf.id.uuidString as NSString
            // Fast path: already in memory cache
            if let cached = conversionManager.thumbnailCache.object(forKey: key) {
                self.localCover = cached; return
            }
            guard let coverURL = conversionManager.getCoverURL(for: pdf),
                  FileManager.default.fileExists(atPath: coverURL.path) else {
                // Cover not on disk yet — let the import pipeline generate it
                return
            }
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

struct ModernGridSeriesCell: View {
    let group: SeriesGroup
    let isSelected: Bool
    let isBatch: Bool
    @EnvironmentObject var conversionManager: ConversionManager
    
    // ✅ NEW: Isolated Image State
    @State private var localCover: UIImage? = nil
    
    // ✅ PHASE 7: Dynamic User Aesthetic Colors
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
                .aspectRatio(0.66, contentMode: .fit) // Standard comic aspect ratio
                .cornerRadius(8)
                .clipped()
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                )
                // ✅ FIXED: Removed heavy double-shadow passes from the top-layer stack bounds.
                
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
            }
        }
        .padding(8)
        .background(isSelected && !isBatch ? Theme.surfaceElevated : Color.clear)
        .cornerRadius(12)
        .contentShape(Rectangle())
        .hoverEffect(.lift)
        // Throttled loader — gets the cover of the series' issue #1
        .task(id: group.id) {
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
