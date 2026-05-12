import SwiftUI
import PDFKit
import UIKit

// MARK: - LibraryGridItem
struct LibraryGridItem: View {
    let pdf: ConvertedPDF
    @EnvironmentObject var conversionManager: ConversionManager
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Cover Image
            ZStack {
                if let uiImage = conversionManager.getThumbnail(for: pdf) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(Color.gray.opacity(0.1))
                    Image(systemName: "doc.richtext").font(.largeTitle).foregroundColor(.gray)
                }
            }
            .frame(height: 200)
            .frame(maxWidth: .infinity)
            .cornerRadius(12)
            .overlay(
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        if pdf.contentKind == .book {
                            Image(systemName: "book.fill")
                                .font(.system(size: 14))
                                .foregroundColor(.white)
                                .padding(6)
                                .background(Color.black.opacity(0.7))
                                .clipShape(Circle())
                                .padding(6)
                        } else if pdf.contentKind == .document {
                            Image(systemName: "doc.fill")
                                .font(.system(size: 14))
                                .foregroundColor(.white)
                                .padding(6)
                                .background(Color.black.opacity(0.7))
                                .clipShape(Circle())
                                .padding(6)
                        }
                    }
                }
            )
            .shadow(radius: 2)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.gray.opacity(0.1), lineWidth: 1)
            )
            
            // Metadata
            VStack(alignment: .leading, spacing: 4) {
                Text(pdf.name)
                    .font(.headline)
                    .lineLimit(2)
                    .foregroundColor(.primary)
                
                HStack {
                    if let collectionId = pdf.collectionId,
                       let col = conversionManager.collections.first(where: { $0.id == collectionId }) {
                        Circle().fill(colorFor(col.color)).frame(width: 8, height: 8)
                    }
                    Text(pdf.formattedSize)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 8)
        }
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(12)
        .contentShape(Rectangle())
    }
}

// MARK: - LibraryPDFRowWithCover
struct LibraryPDFRowWithCover: View {
    let pdf: ConvertedPDF
    let isSelected: Bool
    @EnvironmentObject var conversionManager: ConversionManager
    
    // ✅ PERF: Isolated thumbnail state — prevents global objectWillChange cascades
    @State private var localCover: UIImage? = nil
    
    var body: some View {
        HStack(spacing: 12) {
            // Cover Image or Placeholder
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
                    Rectangle()
                        .fill(Color.orange.opacity(0.1))
                    Image(systemName: "doc.richtext")
                        .font(.title)
                        .foregroundColor(.orange)
                }
            }
            .frame(width: 50, height: 70)
            .cornerRadius(4)
            .overlay(
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        if pdf.contentKind == .book {
                            Image(systemName: "book.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.white)
                                .padding(4)
                                .background(Color.black.opacity(0.7))
                                .clipShape(Circle())
                                .padding(2)
                        } else if pdf.contentKind == .document {
                            Image(systemName: "doc.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.white)
                                .padding(4)
                                .background(Color.black.opacity(0.7))
                                .clipShape(Circle())
                                .padding(2)
                        }
                    }
                }
            )
            .clipped()
            
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(pdf.name)
                        .font(.headline)
                        .lineLimit(1)
                    if pdf.isFavorite {
                        Image(systemName: "star.fill")
                        .foregroundColor(.yellow)
                        .font(.caption)
                    }
                }
                
                HStack {
                    if let collectionId = pdf.collectionId,
                       let collection = conversionManager.collections.first(where: { $0.id == collectionId }) {
                        Text(collection.name)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(collection.color).opacity(0.2))
                            .foregroundColor(Color(collection.color))
                            .cornerRadius(4)
                    }
                    
                    Text("\(pdf.pageCount) Pages • \(pdf.formattedSize)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                if let series = pdf.metadata.series, !series.isEmpty {
                    Text(series)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.blue)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        // ✅ PERF: Async thumbnail loading per-cell — no global re-render
        .task(id: pdf.id) {
            let key = pdf.id.uuidString as NSString
            if let cached = conversionManager.thumbnailCache.object(forKey: key) {
                self.localCover = cached; return
            }
            guard let coverURL = conversionManager.getCoverURL(for: pdf),
                  FileManager.default.fileExists(atPath: coverURL.path) else { return }
            
            let generated = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
                guard let source = CGImageSourceCreateWithURL(coverURL as CFURL, sourceOptions) else { return nil }
                let downsampleOptions = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 300
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

// MARK: - SearchFilterBar
struct SearchFilterBar: View {
    @Binding var searchText: String
    @Binding var showFilters: Bool
    
    var body: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .padding(.leading, 12)
                
                TextField("Search library...", text: $searchText)
                    .foregroundColor(.primary)
                    .accentColor(.blue)
                    .padding(.vertical, 12)
                
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                            .padding(.trailing, 12)
                    }
                }
            }
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
            
            Button(action: { showFilters.toggle() }) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.title2)
                    .foregroundColor(.blue)
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }
}

// MARK: - PDFActionViews
struct PDFActionViews: View {
    @EnvironmentObject var conversionManager: ConversionManager
    let pdf: ConvertedPDF
    
    var body: some View {
        HStack {
            Button(action: {
                // ✅ Fix: Wrap async call in Task
                Task {
                    await conversionManager.convertComic(pdf, mangaMode: false)
                }
            }) {
                Label("Convert", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.borderedProminent)
            
            Button(role: .destructive, action: {
                conversionManager.deletePDF(pdf)
            }) {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}


import SwiftUI

// MARK: - 1. Recently Read Shelf

/// A horizontal scrollable row showing the most recently read files, displayed at the top of the library.
struct RecentlyReadShelf: View {
    let pdfs: [ConvertedPDF]
    let onTap: (ConvertedPDF) -> Void
    @EnvironmentObject var conversionManager: ConversionManager

    var recentItems: [ConvertedPDF] {
        pdfs
            .filter { ($0.metadata.lastReadPage ?? 0) > 0 }
            .sorted {
                let aDate = ReaderProgressTracker.shared.progress(for: $0.id)?.lastOpenedAt ?? .distantPast
                let bDate = ReaderProgressTracker.shared.progress(for: $1.id)?.lastOpenedAt ?? .distantPast
                return aDate > bDate
            }
            .prefix(10)
            .map { $0 }
    }

    var body: some View {
        if !recentItems.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(Theme.orange)
                    Text("Recently Read")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(Theme.text)
                    Spacer()
                }
                .padding(.horizontal, 16)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(recentItems) { pdf in
                            Button { onTap(pdf) } label: {
                                RecentlyReadCell(
                                    pdf: pdf,
                                    conversionManager: conversionManager
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            .padding(.vertical, 8)
        }
    }
}

/// Isolated per-item cell with its own async thumbnail state.
private struct RecentlyReadCell: View {
    let pdf: ConvertedPDF
    let conversionManager: ConversionManager
    @State private var cover: UIImage? = nil

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                if let img = cover {
                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Theme.surface)
                    Image(systemName: "book.fill")
                        .foregroundColor(Theme.textSecondary)
                }
            }
            .frame(width: 70, height: 100)
            .cornerRadius(8)
            .clipped()
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.1), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.25), radius: 4, y: 3)

            Text(pdf.name)
                .font(.system(size: 10))
                .foregroundColor(Theme.textSecondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 70)

            let progress = Double(pdf.metadata.lastReadPage ?? 0) / Double(max(pdf.pageCount, 1))
            ProgressView(value: min(progress, 1.0))
                .tint(progress >= 1.0 ? .green : Theme.orange)
                .frame(width: 60)
        }
        .task(id: pdf.id) {
            let key = pdf.id.uuidString as NSString
            if let cached = conversionManager.thumbnailCache.object(forKey: key) {
                cover = cached; return
            }
            guard let coverURL = conversionManager.getCoverURL(for: pdf),
                  FileManager.default.fileExists(atPath: coverURL.path) else { return }
            let img = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                let src = [kCGImageSourceShouldCache: false] as CFDictionary
                guard let source = CGImageSourceCreateWithURL(coverURL as CFURL, src) else { return nil }
                let opts = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceShouldCacheImmediately: true,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceThumbnailMaxPixelSize: 300] as CFDictionary
                guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, opts) else { return nil }
                return UIImage(cgImage: cg)
            }.value
            if let img {
                conversionManager.thumbnailCache.setObject(img, forKey: key)
                cover = img
            }
        }
    }
}

// MARK: - 1.5 Up Next Smart Binge Shelf (Phase 3)

struct UpNextBingeShelf: View {
    let allPDFs: [ConvertedPDF]
    let onTap: (ConvertedPDF) -> Void
    @EnvironmentObject var conversionManager: ConversionManager

    // Engine to calculate the exact next issue to read based on completed volumes
    var upNextItems: [ConvertedPDF] {
        var nextToRead: [String: ConvertedPDF] = [:] // SeriesName : PDF
        
        // Group by series
        let seriesGroups = Dictionary(grouping: allPDFs.filter { $0.metadata.series != nil && !$0.metadata.series!.isEmpty }, by: { $0.metadata.series! })
        
        for (seriesName, issues) in seriesGroups {
            // Sort issues by number
            let sortedIssues = issues.sorted { a, b in
                let aNum = Double(a.metadata.issueNumber ?? a.metadata.volume ?? "0") ?? 0
                let bNum = Double(b.metadata.issueNumber ?? b.metadata.volume ?? "0") ?? 0
                return aNum < bNum
            }
            
            // Find highest completed
            if let lastReadIdx = sortedIssues.lastIndex(where: { 
                let progress = Double($0.metadata.lastReadPage ?? 0) / Double(max($0.pageCount, 1))
                return progress > 0.95 // 95% complete or more
            }) {
                // If there's a next issue in the series that hasn't been completed yet
                if lastReadIdx + 1 < sortedIssues.count {
                    let nextItem = sortedIssues[lastReadIdx + 1]
                    let nextProgress = Double(nextItem.metadata.lastReadPage ?? 0) / Double(max(nextItem.pageCount, 1))
                    if nextProgress < 0.95 {
                        nextToRead[seriesName] = nextItem
                    }
                }
            }
        }
        
        return Array(nextToRead.values).sorted { $0.name < $1.name }.prefix(8).map { $0 }
    }
    
    var body: some View {
        let items = upNextItems
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "sparkles.tv")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(Theme.purple)
                    Text("Up Next")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(Theme.text)
                    Spacer()
                }
                .padding(.horizontal, 16)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(items) { pdf in
                            Button { onTap(pdf) } label: {
                                UpNextCell(pdf: pdf, conversionManager: conversionManager)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                }
            }
            .padding(.top, 16)
        }
    }
}

private struct UpNextCell: View {
    let pdf: ConvertedPDF
    let conversionManager: ConversionManager
    @State private var cover: UIImage? = nil

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                if let img = cover {
                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Theme.surface)
                    Image(systemName: "book.fill")
                        .foregroundColor(Theme.textSecondary)
                }
            }
            .frame(width: 90, height: 135)
            .cornerRadius(8)
            .clipped()
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.1), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.25), radius: 6, y: 4)

            if let issue = pdf.metadata.issueNumber ?? pdf.metadata.volume {
                Text("Vol. \(issue)")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Theme.purple)
                    .clipShape(Capsule())
                    .offset(y: -20)
                    .padding(.bottom, -20)
            }

            Text(pdf.name)
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 90)
        }
        .task(id: pdf.id) {
            let key = pdf.id.uuidString as NSString
            if let cached = conversionManager.thumbnailCache.object(forKey: key) {
                cover = cached; return
            }
            guard let coverURL = conversionManager.getCoverURL(for: pdf),
                  FileManager.default.fileExists(atPath: coverURL.path) else { return }
            let img = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                let src = [kCGImageSourceShouldCache: false] as CFDictionary
                guard let source = CGImageSourceCreateWithURL(coverURL as CFURL, src) else { return nil }
                let opts = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceShouldCacheImmediately: true,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceThumbnailMaxPixelSize: 360] as CFDictionary
                guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, opts) else { return nil }
                return UIImage(cgImage: cg)
            }.value
            if let img {
                conversionManager.thumbnailCache.setObject(img, forKey: key)
                cover = img
            }
        }
    }
}

// MARK: - 2. Missing Issue Detector

struct MissingIssueDetector {
    /// Analyzes issues in a series and returns gaps in issue numbering
    static func detectGaps(in issues: [ConvertedPDF]) -> [String] {
        let issueNumbers = issues
            .compactMap { $0.metadata.issueNumber }
            .compactMap { Int($0) }
            .sorted()
        
        guard let first = issueNumbers.first, let last = issueNumbers.last else { return [] }
        
        let fullRange = Set(first...last)
        let existing = Set(issueNumbers)
        let missing = fullRange.subtracting(existing).sorted()
        
        return missing.map { String($0) }
    }
    
    /// Returns a compact description like "Missing: #23, #31, #45"
    static func gapDescription(in issues: [ConvertedPDF]) -> String? {
        let gaps = detectGaps(in: issues)
        guard !gaps.isEmpty else { return nil }
        if gaps.count <= 5 {
            return "Missing: #" + gaps.joined(separator: ", #")
        } else {
            return "Missing \(gaps.count) issues (#\(gaps.first!)...#\(gaps.last!))"
        }
    }
}

/// A banner shown at the top of SeriesDetailView when missing issues are detected
struct MissingIssueBanner: View {
    let gaps: [String]
    
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 16))
                .foregroundColor(.yellow)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("\(gaps.count) Missing Issue\(gaps.count == 1 ? "" : "s") Detected")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.text)
                
                let displayGaps = gaps.prefix(8).joined(separator: ", ")
                let suffix = gaps.count > 8 ? " +\(gaps.count - 8) more" : ""
                Text("#\(displayGaps)\(suffix)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.orange)
            }
            
            Spacer()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.yellow.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(.yellow.opacity(0.2), lineWidth: 1)
                )
        )
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
    }
}

// MARK: - 3. Batch Volume Assignment Sheet

struct BatchVolumeAssignmentSheet: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var conversionManager: ConversionManager
    
    let selectedIDs: Set<UUID>
    @State private var volumeText = ""
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "book.closed.fill")
                    .font(.system(size: 48))
                    .foregroundColor(Theme.blue)
                    .padding(.top, 32)
                
                Text("Assign Volume")
                    .font(.title2.bold())
                    .foregroundColor(Theme.text)
                
                Text("Set the volume number for \(selectedIDs.count) selected file\(selectedIDs.count == 1 ? "" : "s").")
                    .font(.subheadline)
                    .foregroundColor(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                
                TextField("Volume Number (e.g., 3)", text: $volumeText)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.numberPad)
                    .padding(.horizontal, 40)
                
                Button {
                    guard !volumeText.isEmpty else { return }
                    for id in selectedIDs {
                        if let idx = conversionManager.convertedPDFs.firstIndex(where: { $0.id == id }) {
                            conversionManager.convertedPDFs[idx].metadata.volume = volumeText
                        }
                    }
                    conversionManager.saveLibrary()
                    dismiss()
                } label: {
                    Text("Assign Volume \(volumeText.isEmpty ? "" : volumeText)")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(volumeText.isEmpty ? Color.gray : Theme.blue)
                        .cornerRadius(12)
                }
                .disabled(volumeText.isEmpty)
                .padding(.horizontal, 40)
                
                Spacer()
            }
            .navigationTitle("Batch Volume")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

// MARK: - 5. Series Health Score

struct SeriesHealthBadge: View {
    let issues: [ConvertedPDF]
    
    /// Calculates metadata completeness as a percentage
    var healthScore: Int {
        guard !issues.isEmpty else { return 0 }
        let fields = issues.map { pdf -> Int in
            var score = 0
            if pdf.metadata.series != nil && !(pdf.metadata.series?.isEmpty ?? true) { score += 1 }
            if pdf.metadata.issueNumber != nil { score += 1 }
            if pdf.metadata.volume != nil && !(pdf.metadata.volume?.isEmpty ?? true) { score += 1 }
            if pdf.metadata.publisher != nil { score += 1 }
            if pdf.metadata.author != nil { score += 1 }
            return score
        }
        let totalPossible = issues.count * 5
        return Int(Double(fields.reduce(0, +)) / Double(max(totalPossible, 1)) * 100)
    }
    
    var scoreColor: Color {
        if healthScore >= 80 { return .green }
        if healthScore >= 50 { return .orange }
        return .red
    }
    
    var body: some View {
        Text("\(healthScore)%")
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundColor(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(scoreColor)
            .clipShape(Capsule())
    }
}

// MARK: - 6. Quick Volume Jump

struct QuickVolumeJumpOverlay: View {
    let volumeGroups: [(key: String, issues: [ConvertedPDF])]
    let onJump: (String) -> Void
    @State private var isExpanded = false
    
    var body: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                
                if isExpanded {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 4) {
                            ForEach(volumeGroups, id: \.key) { group in
                                Button {
                                    onJump(group.key)
                                    withAnimation { isExpanded = false }
                                } label: {
                                    Text(group.key == "Ungrouped" ? "?" : "V\(group.key)")
                                        .font(.system(size: 11, weight: .bold, design: .rounded))
                                        .foregroundColor(.white)
                                        .frame(width: 36, height: 28)
                                        .background(Theme.blue)
                                        .cornerRadius(6)
                                }
                            }
                        }
                        .padding(6)
                    }
                    .frame(width: 48)
                    .frame(maxHeight: 260)
                    .background(.ultraThinMaterial)
                    .cornerRadius(12)
                    .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                    .transition(.scale(scale: 0.5, anchor: .bottomTrailing).combined(with: .opacity))
                }
                
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        isExpanded.toggle()
                    }
                } label: {
                    Image(systemName: isExpanded ? "xmark" : "book.pages")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 44, height: 44)
                        .background(Theme.orange)
                        .clipShape(Circle())
                        .shadow(color: Theme.orange.opacity(0.4), radius: 6, y: 3)
                }
            }
            .padding(.trailing, 16)
            .padding(.bottom, 16)
        }
    }
}

// MARK: - 7. Duplicate File Finder

struct DuplicateFinderView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @Environment(\.dismiss) var dismiss
    
    struct DuplicateGroup: Identifiable {
        let id = UUID()
        let name: String
        let files: [ConvertedPDF]
    }
    
    var duplicateGroups: [DuplicateGroup] {
        var sizeMap: [Int64: [ConvertedPDF]] = [:]
        for pdf in conversionManager.convertedPDFs {
            sizeMap[pdf.fileSize, default: []].append(pdf)
        }
        
        return sizeMap
            .filter { $0.value.count > 1 }
            .map { DuplicateGroup(name: "\($0.value.first?.name ?? "Unknown") (\($0.value.count) copies)", files: $0.value) }
            .sorted { $0.files.count > $1.files.count }
    }
    
    var body: some View {
        NavigationStack {
            List {
                if duplicateGroups.isEmpty {
                    Section {
                        VStack(spacing: 12) {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 44))
                                .foregroundColor(.green)
                            Text("No Duplicates Found")
                                .font(.headline)
                            Text("Your library is clean!")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 32)
                    }
                } else {
                    Section {
                        Text("\(duplicateGroups.count) potential duplicate group\(duplicateGroups.count == 1 ? "" : "s") found based on file size matching.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    ForEach(duplicateGroups) { group in
                        Section(header: Text(group.name)) {
                            ForEach(group.files) { pdf in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(pdf.name)
                                            .font(.subheadline)
                                            .lineLimit(1)
                                        Text("\(ByteCountFormatter.string(fromByteCount: pdf.fileSize, countStyle: .file))")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    Button(role: .destructive) {
                                        conversionManager.deletePDF(pdf)
                                    } label: {
                                        Image(systemName: "trash")
                                            .foregroundColor(.red)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Duplicate Finder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - 8. Import History Log

struct ImportHistoryView: View {
    @Environment(\.dismiss) var dismiss
    
    var logEntries: [LogEntry] {
        Logger.shared.parsedLogs
            .filter { $0.category == "Import" || $0.category == "SmartList" || $0.category == "Library" }
    }
    
    var body: some View {
        NavigationStack {
            List {
                if logEntries.isEmpty {
                    Section {
                        VStack(spacing: 12) {
                            Image(systemName: "tray.fill")
                                .font(.system(size: 44))
                                .foregroundColor(.secondary)
                            Text("No Import History")
                                .font(.headline)
                            Text("Import files to see activity here.")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 32)
                    }
                } else {
                    ForEach(logEntries.indices, id: \.self) { idx in
                        let entry = logEntries[idx]
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: iconFor(category: entry.category))
                                .foregroundColor(colorFor(category: entry.category))
                                .frame(width: 24)
                            
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.message)
                                    .font(.system(size: 13))
                                    .lineLimit(3)
                                
                                Text(entry.timestamp.formatted(date: .abbreviated, time: .shortened))
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .navigationTitle("Import History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
    
    private func iconFor(category: String) -> String {
        switch category {
        case "Import": return "arrow.down.doc.fill"
        case "SmartList": return "list.bullet.clipboard.fill"
        case "Library": return "books.vertical.fill"
        default: return "doc.fill"
        }
    }
    
    private func colorFor(category: String) -> Color {
        switch category {
        case "Import": return .blue
        case "SmartList": return .orange
        case "Library": return .green
        default: return .gray
        }
    }
}

