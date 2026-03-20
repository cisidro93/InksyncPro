import SwiftUI

struct ModernFileRow: View {
    let pdf: ConvertedPDF
    let isSelected: Bool
    let isBatch: Bool
    @EnvironmentObject var conversionManager: ConversionManager
    
    // ✅ NEW: Isolated State for smooth List scrolling
    @State private var localCover: UIImage? = nil
    
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
                } else {
                    Rectangle().fill(Theme.surfaceElevated)
                    Image(systemName: "doc.text.fill")
                        .foregroundColor(Theme.textSecondary)
                }
            }
            .frame(width: 40, height: 56)
            .cornerRadius(4)
            .clipped()
            
            VStack(alignment: .leading, spacing: 4) {
                Text(pdf.name)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(Theme.text)
                    .lineLimit(1)
                
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
        // ✅ NEW: Lazy Asynchronous Fetch with Cancellation
        .task(id: pdf.id) {
            await conversionManager.loadThumbnailAsync(for: pdf)
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
    
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                // Stack effect
                if group.count > 1 {
                    RoundedRectangle(cornerRadius: 4).fill(Theme.surfaceElevated).frame(width: 40, height: 56).offset(x: 3, y: -3)
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
            .frame(width: 40, height: 56)
            .cornerRadius(4)
            .clipped()
            
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
                    
                    Text("\(group.count) Issues")
                        .font(.caption)
                        .foregroundColor(Theme.textSecondary)
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
        // ✅ NEW: Lazy Asynchronous Fetch with Cancellation
        .task(id: group.id) {
            if let issueID = group.coverIssueID,
               let pdf = conversionManager.convertedPDFs.first(where: { $0.id == issueID }) {
                await conversionManager.loadThumbnailAsync(for: pdf)
            }
        }
    }
}
