import SwiftUI

struct ModernGridFileCell: View {
    let pdf: ConvertedPDF
    let isSelected: Bool
    let isBatch: Bool
    @EnvironmentObject var conversionManager: ConversionManager
    
    // ✅ NEW: Isolated Image State for Lazy Loading
    @State private var localCover: UIImage? = nil
    
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
                    .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.5), radius: 8, x: 0, y: 4)
            .shadow(color: .black.opacity(0.3), radius: 16, x: 0, y: 8)
            
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
                    let progress = pdf.metadata.readingProgress ?? 0.0
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.1))
                        Capsule().fill(Theme.orange)
                            .frame(width: max(0, geo.size.width * CGFloat(progress)))
                    }
                }
                .frame(height: 3)
                .padding(.top, 2)
                
                HStack {
                    if pdf.metadata.isRead ?? false {
                        Text("Read")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(Theme.textSecondary)
                    } else if (pdf.metadata.readingProgress ?? 0.0) > 0 {
                        Text("\(Int((pdf.metadata.readingProgress ?? 0.0) * 100))%")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(Theme.textSecondary)
                    } else {
                        Text("New")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(Theme.blue)
                    }
                    Spacer()
                    Text(pdf.fileExtensionString.uppercased())
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(Theme.textTertiary)
                }
            }
        }
        .padding(8)
        .background(isSelected && !isBatch ? Theme.surfaceElevated : Color.clear)
        .cornerRadius(12)
        .contentShape(Rectangle())
        .hoverEffect(.lift)
        // ✅ PHASE 13: Background Thread Isolation
        // Detaches heavy synchronous IO (reading megabytes of JPEG Data) off the 120Hz Main Actor rendering queue.
        .task(id: pdf.id) {
            if let img = conversionManager.thumbnailCache.object(forKey: pdf.id.uuidString as NSString) {
                self.localCover = img
            } else if let coverURL = conversionManager.getCoverURL(for: pdf) {
                let generated = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                    let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
                    guard let source = CGImageSourceCreateWithURL(coverURL as CFURL, sourceOptions) else { return nil }
                    let downsampleOptions = [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceShouldCacheImmediately: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 400
                    ] as CFDictionary
                    
                    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions) else { return nil }
                    return UIImage(cgImage: cgImage)
                }.value
                
                if let image = generated {
                    conversionManager.thumbnailCache.setObject(image, forKey: pdf.id.uuidString as NSString)
                    await MainActor.run { self.localCover = image }
                }
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
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            
            // Cover Image with Stack Effect
            ZStack(alignment: .bottom) {
                ZStack {
                    if group.count > 1 { // Stack Effect Backgrounds
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Theme.surface.opacity(0.8))
                            .aspectRatio(0.66, contentMode: .fit)
                            .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                            .rotationEffect(.degrees(-3))
                            .scaleEffect(0.9)
                            .offset(y: -8)
                        
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Theme.surfaceElevated.opacity(0.9))
                            .aspectRatio(0.66, contentMode: .fit)
                            .shadow(color: .black.opacity(0.4), radius: 5, y: 3)
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
                .shadow(color: .black.opacity(0.5), radius: 8, x: 0, y: 4)
                .shadow(color: .black.opacity(0.3), radius: 16, x: 0, y: 8)
                
                // Floating Glass Series Badge
                HStack(spacing: 4) {
                    Image(systemName: "books.vertical.fill").font(.system(size: 10))
                    Text("\(group.count) Issues").font(.system(size: 10, weight: .bold))
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
                Text(group.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(height: 38, alignment: .topLeading)
            }
        }
        .padding(8)
        .background(isSelected && !isBatch ? Theme.surfaceElevated : Color.clear)
        .cornerRadius(12)
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
