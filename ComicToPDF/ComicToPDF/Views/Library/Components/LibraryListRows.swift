import SwiftUI

struct ModernFileRow: View {
    let pdf: ConvertedPDF
    let isSelected: Bool
    let isBatch: Bool
    @EnvironmentObject var conversionManager: ConversionManager
    
    // ✅ NEW: Isolated State for smooth List scrolling
    @State private var localCover: UIImage? = nil
    
    // ✅ PHASE 7: Dynamic User Aesthetic Colors
    @AppStorage("mangaBadgeColorHex") private var mangaBadgeColorHex = "#2dd4a0"
    @AppStorage("comicBadgeColorHex") private var comicBadgeColorHex = "#3d6fff"
    
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if let directCacheImg = conversionManager.thumbnailCache.object(forKey: pdf.id.uuidString as NSString) {
                    Image(uiImage: directCacheImg)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else if let img = localCover {
                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else if case .cloud = pdf.sourceMode {
                    Rectangle().fill(Theme.surfaceElevated)
                    Image(systemName: "icloud.and.arrow.down")
                        .font(.system(size: 20))
                        .foregroundColor(Theme.orange.opacity(0.8))
                } else {
                    Rectangle().fill(Theme.surfaceElevated)
                    Image(systemName: "doc.text.fill")
                        .foregroundColor(Theme.textSecondary)
                }
            }
            .frame(width: 44, height: 66)
            .aspectRatio(0.66, contentMode: .fit)
            .cornerRadius(4)
            .clipped()
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
            )
            .shadow(color: Color(.sRGBLinear, white: 0, opacity: 0.25), radius: 4, y: 2)
            
            VStack(alignment: .leading, spacing: 6) {
                Text(pdf.name)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(Theme.text)
                    .lineLimit(1)
                
                // Reading Progress Bar
                GeometryReader { geo in
                    let progress = Double(pdf.metadata.lastReadPage ?? 0) / Double(max(pdf.pageCount, 1))
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color(.secondarySystemFill))
                        Capsule().fill(Theme.orange)
                            .frame(width: max(0, geo.size.width * CGFloat(progress)))
                    }
                }
                .frame(width: 120, height: 3)
                
                // ✅ Show Fetched Metadata Context
                if let series = pdf.metadata.series, !series.isEmpty {
                    Text("\(series) \(pdf.metadata.issueNumber.map { "#\($0)" } ?? "")")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(1)
                }
                
                HStack(spacing: 6) {
                    // Content Type Badge
                    HStack(spacing: 3) {
                        Image(systemName: pdf.contentType.icon)
                            .font(.system(size: 8))
                        Text(pdf.contentType.rawValue.uppercased())
                            .font(.system(size: 10, weight: .bold))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(pdf.contentType.badgeColor.opacity(0.2))
                    .foregroundColor(pdf.contentType.badgeColor)
                    .cornerRadius(4)
                    
                    // ✅ NEW: File Extension Badge
                    if !pdf.fileExtensionString.isEmpty {
                        Text(pdf.fileExtensionString)
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.gray.opacity(0.3))
                            .foregroundColor(.white)
                            .cornerRadius(4)
                    }
                    
                    // ✅ NEW: Manga / Comic Badge
                    if pdf.contentType == .comic {
                        let isManga = pdf.metadata.isManga ?? false
                        Text(isManga ? "MANGA" : "COMIC")
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(hex: isManga ? mangaBadgeColorHex : comicBadgeColorHex).opacity(0.2))
                            .foregroundColor(Color(hex: isManga ? mangaBadgeColorHex : comicBadgeColorHex))
                            .cornerRadius(4)
                    }
                    
                    // ✅ NEW: Storage Location Badge
                    if case .linked(_) = pdf.sourceMode {
                        HStack(spacing: 3) {
                            Image(systemName: "externaldrive.fill")
                                .font(.system(size: 8))
                            Text("EXTERNAL")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.blue.opacity(0.2))
                        .foregroundColor(Theme.blue)
                        .cornerRadius(4)
                    } else if case .cloud(_, _) = pdf.sourceMode {
                        HStack(spacing: 3) {
                            Image(systemName: "icloud.fill")
                                .font(.system(size: 8))
                            Text("CLOUD")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.orange.opacity(0.2))
                        .foregroundColor(Theme.orange)
                        .cornerRadius(4)
                    }
                    
                    Text(pdf.formattedSize)
                        .font(.caption)
                        .foregroundColor(Theme.textSecondary)
                    if pdf.isFavorite {
                        Image(systemName: "heart.fill")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
            }
            
            Spacer()
            
            if isBatch {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundColor(isSelected ? Theme.blue : Theme.textSecondary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .hoverEffect(.lift)
        // ✅ PERF: Async thumbnail load — reads back from NSCache after write
        // so the image immediately appears without triggering a global objectWillChange.
        .task(id: pdf.id) {
            let key = pdf.id.uuidString as NSString
            // Fast path: already cached in memory
            if let cached = conversionManager.thumbnailCache.object(forKey: key) {
                self.localCover = cached; return
            }
            await conversionManager.loadThumbnailAsync(for: pdf)
            // Read back after write so this cell re-renders with the loaded image
            if let loaded = conversionManager.thumbnailCache.object(forKey: key) {
                self.localCover = loaded
            }
        }
    }
}

struct ModernSeriesRow: View {
    let group: SeriesGroup
    let isSelected: Bool
    let isBatch: Bool
    @EnvironmentObject var conversionManager: ConversionManager
    
    // ✅ NEW: Isolated State for smooth List scrolling
    @State private var localCover: UIImage? = nil
    
    // ✅ PHASE 7: Dynamic User Aesthetic Colors
    @AppStorage("mangaBadgeColorHex") private var mangaBadgeColorHex = "#2dd4a0"
    @AppStorage("comicBadgeColorHex") private var comicBadgeColorHex = "#3d6fff"
    
    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottom) {
                // Stack effect
                if group.count > 1 {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Theme.surface.opacity(0.8))
                        .aspectRatio(0.66, contentMode: .fit)
                        .shadow(color: Color(.sRGBLinear, white: 0, opacity: 0.2), radius: 2, y: 1)
                        .rotationEffect(.degrees(-3))
                        .scaleEffect(0.9)
                        .offset(y: -4)
                    
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Theme.surfaceElevated.opacity(0.9))
                        .aspectRatio(0.66, contentMode: .fit)
                        .shadow(color: Color(.sRGBLinear, white: 0, opacity: 0.25), radius: 3, y: 2)
                        .rotationEffect(.degrees(2))
                        .scaleEffect(0.95)
                        .offset(y: -2)
                }
                
                if let uuid = group.coverIssueID, let directCacheImg = conversionManager.thumbnailCache.object(forKey: uuid.uuidString as NSString) {
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
                        .foregroundColor(Theme.textSecondary)
                }
            }
            .frame(width: 44, height: 66)
            .aspectRatio(0.66, contentMode: .fit)
            .cornerRadius(4)
            .clipped()
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
            )
            .shadow(color: Color(.sRGBLinear, white: 0, opacity: 0.25), radius: 4, y: 2)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(group.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(Theme.text)
                    .lineLimit(1)
                
                HStack(spacing: 6) {
                    HStack(spacing: 3) {
                        Image(systemName: "books.vertical.fill")
                            .font(.system(size: 8))
                        Text("SERIES")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.blue.opacity(0.2))
                    .foregroundColor(Theme.blue)
                    .cornerRadius(4)
                    
                    if let first = firstComicIssue {
                        let isManga = first.metadata.isManga ?? false
                        Text(isManga ? "MANGA" : "COMIC")
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(hex: isManga ? mangaBadgeColorHex : comicBadgeColorHex).opacity(0.2))
                            .foregroundColor(Color(hex: isManga ? mangaBadgeColorHex : comicBadgeColorHex))
                            .cornerRadius(4)
                    }
                    
                    Text("\(group.count) \(group.count == 1 ? "Issue" : "Issues")")
                        .font(.caption)
                        .foregroundColor(Theme.textSecondary)
                    
                    if UserDefaults.standard.bool(forKey: "showSeriesHealthScore") {
                        SeriesHealthBadge(issues: group.issues)
                    }
                }
            }
            
            Spacer()
            
            if isBatch {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundColor(isSelected ? Theme.blue : Theme.textSecondary)
            } else {
                Image(systemName: "chevron.right")
                    .foregroundColor(Theme.textTertiary)
                    .font(.caption)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .hoverEffect(.lift)
        // ✅ PERF: Async thumbnail load — reads back from NSCache after write
        .task(id: group.id) {
            if let issueID = group.coverIssueID,
               let pdf = conversionManager.convertedPDFs.first(where: { $0.id == issueID }) {
                let key = issueID.uuidString as NSString
                if let cached = conversionManager.thumbnailCache.object(forKey: key) {
                    self.localCover = cached; return
                }
                await conversionManager.loadThumbnailAsync(for: pdf)
                if let loaded = conversionManager.thumbnailCache.object(forKey: key) {
                    self.localCover = loaded
                }
            }
        }
    }

    private var firstComicIssue: ConvertedPDF? {
        return group.issues.first(where: { $0.contentType == .comic })
    }
}
