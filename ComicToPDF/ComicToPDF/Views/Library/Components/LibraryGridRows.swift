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
                if let img = localCover {
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
            .aspectRatio(0.7, contentMode: .fill) // Standard comic aspect ratio
            .cornerRadius(8)
            .clipped()
            
            // Text Details
            VStack(alignment: .leading, spacing: 4) {
                Text(pdf.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(height: 38, alignment: .topLeading) // Fixed height to align rows
                
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        // Content Type Badge
                        HStack(spacing: 3) {
                            Image(systemName: pdf.contentType.icon).font(.system(size: 8))
                            Text(pdf.contentType.rawValue.uppercased()).font(.system(size: 10, weight: .bold))
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(pdf.contentType.badgeColor.opacity(0.2))
                        .foregroundColor(pdf.contentType.badgeColor)
                        .cornerRadius(4)
                        
                        // ✅ NEW: File Extension Badge
                        if !pdf.fileExtensionString.isEmpty {
                            Text(pdf.fileExtensionString)
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.gray.opacity(0.3))
                                .foregroundColor(.white)
                                .cornerRadius(4)
                        }
                    }
                    
                    Text(pdf.formattedSize)
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(8)
        .background(isSelected && !isBatch ? Theme.surfaceElevated : Color.clear)
        .cornerRadius(12)
        .contentShape(Rectangle())
        .hoverEffect(.lift)
        .task(id: pdf.id) {
            if let img = conversionManager.getThumbnail(for: pdf) {
                await MainActor.run { self.localCover = img }
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
            ZStack(alignment: .topTrailing) {
                ZStack {
                    if group.count > 1 { // Stack Effect Backgrounds
                        RoundedRectangle(cornerRadius: 12).fill(Theme.surfaceElevated).padding(4).offset(y: -8)
                        RoundedRectangle(cornerRadius: 12).fill(Theme.surfaceElevated).padding(2).offset(y: -4)
                    }
                    if let img = localCover {
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
                .cornerRadius(8)
                .clipped()
                
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
            .aspectRatio(0.7, contentMode: .fit) // Standard comic aspect ratio
            
            // Text Details
            VStack(alignment: .leading, spacing: 4) {
                Text(group.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(height: 38, alignment: .topLeading)
                
                HStack(spacing: 6) {
                    HStack(spacing: 3) {
                        Image(systemName: "books.vertical.fill").font(.system(size: 8))
                        Text("SERIES").font(.system(size: 10, weight: .bold))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.blue.opacity(0.2))
                    .foregroundColor(Theme.blue)
                    .cornerRadius(4)
                    
                    Spacer()
                    
                    Text("\(group.count) Issues")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(8)
        .background(isSelected && !isBatch ? Theme.surfaceElevated : Color.clear)
        .cornerRadius(12)
        .contentShape(Rectangle())
        .hoverEffect(.lift)
        // ✅ NEW: Lazy Asynchronous Fetch
        .task(id: group.id) {
            if let issueID = group.coverIssueID,
               let pdf = conversionManager.convertedPDFs.first(where: { $0.id == issueID }),
               let img = conversionManager.getThumbnail(for: pdf) {
                await MainActor.run { self.localCover = img }
            }
        }
    }
}
